// capture.m — capture system audio + microphone to separate WAV files
//
// Uses CoreAudio's Process Tap API (macOS 14.2+) to capture system audio,
// and the selected microphone device.  Outputs two separate 16-bit WAV files:
//   system file — stereo system audio at the aggregate device's sample rate
//   mic file    — mono microphone at the mic's native sample rate
//
// No mixing, no sample-rate conversion, no real-time drift compensation.
// Align and mix the two files in post-processing (rec mix).
//
// Build:   cc -o capture capture.m -framework CoreAudio -framework Foundation
// Run:     ./capture                              -> output_system.wav + output_mic.wav
//          ./capture -o recording                 -> recording_system.wav + recording_mic.wav
//          ./capture -d 10                        -> 10 seconds
//          ./capture -m                           -> interactively select mic
//          ./capture -m -o test -d 5              -> all options

#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <stdatomic.h>
#include <time.h>

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
#define RING_BUF_SAMPLES    (512 * 1024)   // 512k floats ≈ 2.7 s at 48 kHz stereo
#define MAX_TICK_FRAMES     16384          // max frames per write tick
#define TICK_INTERVAL_US    10000          // 10 ms polling interval

// ---------------------------------------------------------------------------
// Lock‑free SPSC ring buffer (single producer, single consumer)
// ---------------------------------------------------------------------------
typedef struct {
    float           *buf;
    uint32_t         size;        // power of 2
    uint32_t         mask;
    _Atomic uint32_t write_pos;
    _Atomic uint32_t read_pos;
} RingBuffer;

static void ringInit(RingBuffer *r, uint32_t minSize) {
    uint32_t p2 = 1;
    while (p2 < minSize) p2 <<= 1;
    r->buf  = calloc(p2, sizeof(float));
    r->size = p2;
    r->mask = p2 - 1;
    atomic_init(&r->write_pos, 0);
    atomic_init(&r->read_pos, 0);
}

static void ringDestroy(RingBuffer *r) {
    free(r->buf);
    r->buf = NULL;
}

static uint32_t ringAvailable(const RingBuffer *r) {
    uint32_t wp = atomic_load_explicit(&r->write_pos, memory_order_acquire);
    uint32_t rp = atomic_load_explicit(&r->read_pos, memory_order_relaxed);
    return wp - rp;
}

// Producer side — called from the real‑time IOProc thread.
// Drops samples if the ring is full (shouldn't happen with adequate sizing).
static void ringWrite(RingBuffer *r, const float *samples, uint32_t count) {
    uint32_t wp = atomic_load_explicit(&r->write_pos, memory_order_relaxed);
    uint32_t rp = atomic_load_explicit(&r->read_pos, memory_order_acquire);
    uint32_t filled = wp - rp;
    uint32_t avail  = r->size - filled;
    uint32_t n      = (count < avail) ? count : avail;

    for (uint32_t i = 0; i < n; i++)
        r->buf[(wp + i) & r->mask] = samples[i];
    atomic_store_explicit(&r->write_pos, wp + n, memory_order_release);
}

// Consumer side — called from the write thread.
static uint32_t ringRead(RingBuffer *r, float *samples, uint32_t maxCount) {
    uint32_t rp = atomic_load_explicit(&r->read_pos, memory_order_relaxed);
    uint32_t wp = atomic_load_explicit(&r->write_pos, memory_order_acquire);
    uint32_t n  = (maxCount < (wp - rp)) ? maxCount : (wp - rp);

    for (uint32_t i = 0; i < n; i++)
        samples[i] = r->buf[(rp + i) & r->mask];
    atomic_store_explicit(&r->read_pos, rp + n, memory_order_release);
    return n;
}

// ---------------------------------------------------------------------------
// WAV header helpers
// ---------------------------------------------------------------------------
static Float64 gSampleRate = 48000.0;

static void writeWavHeader(FILE *fp, size_t dataSize, Float64 sampleRate,
                           uint16_t channels) {
    uint16_t bitsPerSamp = 16;
    uint16_t blockAlign  = channels * (bitsPerSamp / 8);
    uint32_t byteRate    = (uint32_t)(sampleRate * blockAlign);
    uint32_t chunkSize   = (uint32_t)dataSize + 36;

    rewind(fp);
    fwrite("RIFF", 4, 1, fp);
    fwrite(&chunkSize, 4, 1, fp);
    fwrite("WAVE", 4, 1, fp);
    fwrite("fmt ", 4, 1, fp);

    uint32_t fmtLen = 16;
    uint16_t fmtTag = 1;          // PCM
    fwrite(&fmtLen, 4, 1, fp);
    fwrite(&fmtTag, 2, 1, fp);
    fwrite(&channels, 2, 1, fp);
    uint32_t sr = (uint32_t)sampleRate;
    fwrite(&sr, 4, 1, fp);
    fwrite(&byteRate, 4, 1, fp);
    fwrite(&blockAlign, 2, 1, fp);
    fwrite(&bitsPerSamp, 2, 1, fp);

    uint32_t d32 = (uint32_t)dataSize;
    fwrite("data", 4, 1, fp);
    fwrite(&d32, 4, 1, fp);
}

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------
static AudioObjectID         gTapID       = 0;
static AudioObjectID         gAggID       = 0;
static AudioObjectID         gMicID       = 0;
static AudioDeviceIOProcID   gSysIOProcID = NULL;
static AudioDeviceIOProcID   gMicIOProcID = NULL;
static FILE                 *gSysFile     = NULL;
static FILE                 *gMicFile     = NULL;
static size_t                gSysDataSize = 0;
static size_t                gMicDataSize = 0;
static uint32_t              gMicChannels = 0;     // 0 = mic not available
static Float64               gMicRate     = 0;     // mic device sample rate
static volatile sig_atomic_t gRunning     = 1;

static RingBuffer            gSysRing;              // stereo interleaved floats
static RingBuffer            gMicRing;              // mono floats

static void onSignal(int sig) { (void)sig; gRunning = 0; }

// ---------------------------------------------------------------------------
// System audio IOProc  →  pushes stereo Float32 samples into gSysRing
// ---------------------------------------------------------------------------
static OSStatus sysIOProc(AudioObjectID         inDevice,
                          const AudioTimeStamp *inNow,
                          const AudioBufferList *inInputData,
                          const AudioTimeStamp *inInputTime,
                          AudioBufferList       *outOutputData,
                          const AudioTimeStamp *inOutputTime,
                          void                 *inClientData) {
    (void)inDevice; (void)inNow; (void)inInputTime;
    (void)outOutputData; (void)inOutputTime; (void)inClientData;

    if (!inInputData) return kAudioHardwareNoError;

    for (UInt32 i = 0; i < inInputData->mNumberBuffers; i++) {
        const AudioBuffer *buf = &inInputData->mBuffers[i];
        if (!buf->mData || buf->mDataByteSize == 0) continue;
        ringWrite(&gSysRing, (float *)buf->mData,
                  buf->mDataByteSize / sizeof(float));
    }
    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------------------
// Microphone IOProc  →  mixes to mono, pushes Float32 into gMicRing
// ---------------------------------------------------------------------------
static OSStatus micIOProc(AudioObjectID         inDevice,
                          const AudioTimeStamp *inNow,
                          const AudioBufferList *inInputData,
                          const AudioTimeStamp *inInputTime,
                          AudioBufferList       *outOutputData,
                          const AudioTimeStamp *inOutputTime,
                          void                 *inClientData) {
    (void)inDevice; (void)inNow; (void)inInputTime;
    (void)outOutputData; (void)inOutputTime; (void)inClientData;

    if (!inInputData) return kAudioHardwareNoError;
    if (gMicChannels == 0) return kAudioHardwareNoError;

    for (UInt32 i = 0; i < inInputData->mNumberBuffers; i++) {
        const AudioBuffer *buf = &inInputData->mBuffers[i];
        if (!buf->mData || buf->mDataByteSize == 0) continue;

        float  *samples = (float *)buf->mData;
        UInt32  total   = buf->mDataByteSize / sizeof(float);
        UInt32  frames  = total / gMicChannels;

        if (gMicChannels == 1) {
            ringWrite(&gMicRing, samples, frames);
        } else {
            // Average all channels to mono
            for (UInt32 f = 0; f < frames; f++) {
                float sum = 0.0f;
                for (UInt32 c = 0; c < gMicChannels; c++)
                    sum += samples[f * gMicChannels + c];
                float mono = sum / (float)gMicChannels;
                ringWrite(&gMicRing, &mono, 1);
            }
        }
    }
    return kAudioHardwareNoError;
}

// ---------------------------------------------------------------------------
// Write loop  —  writes each ring buffer to its own file independently.
// No mixing, no SRC, no inter-channel synchronization.
// ---------------------------------------------------------------------------
static void writeLoop(int duration) {
    float   sysBuf[MAX_TICK_FRAMES * 2];
    float   micBuf[MAX_TICK_FRAMES];
    int16_t convSys[MAX_TICK_FRAMES * 2];
    int16_t convMic[MAX_TICK_FRAMES];
    time_t  start = time(NULL);

    while (gRunning) {
        // ---- Write system audio (stereo interleaved) ----
        uint32_t sysFrames = ringAvailable(&gSysRing) / 2;
        if (sysFrames > MAX_TICK_FRAMES) sysFrames = MAX_TICK_FRAMES;

        if (sysFrames > 0) {
            ringRead(&gSysRing, sysBuf, sysFrames * 2);

            // Stereo Float32 → SInt16
            for (uint32_t i = 0; i < sysFrames * 2; i++) {
                float s = sysBuf[i];
                if      (s >  1.0f) s =  1.0f;
                else if (s < -1.0f) s = -1.0f;
                convSys[i] = (int16_t)(s * 32767.0f);
            }

            size_t written = fwrite(convSys, sizeof(int16_t),
                                    sysFrames * 2, gSysFile);
            gSysDataSize += written * sizeof(int16_t);
        }

        // ---- Write microphone audio (mono) ----
        uint32_t micFrames = ringAvailable(&gMicRing);
        if (micFrames > MAX_TICK_FRAMES) micFrames = MAX_TICK_FRAMES;

        if (micFrames > 0 && gMicFile) {
            ringRead(&gMicRing, micBuf, micFrames);

            // Mono Float32 → SInt16
            for (uint32_t i = 0; i < micFrames; i++) {
                float s = micBuf[i];
                if      (s >  1.0f) s =  1.0f;
                else if (s < -1.0f) s = -1.0f;
                convMic[i] = (int16_t)(s * 32767.0f);
            }

            size_t written = fwrite(convMic, sizeof(int16_t),
                                    micFrames, gMicFile);
            gMicDataSize += written * sizeof(int16_t);
        }

        // ---- Overflow protection ----
        if (ringAvailable(&gSysRing) > RING_BUF_SAMPLES * 9 / 10) {
            uint32_t drop = ringAvailable(&gSysRing) - RING_BUF_SAMPLES / 2;
            if (drop > MAX_TICK_FRAMES * 2) drop = MAX_TICK_FRAMES * 2;
            ringRead(&gSysRing, sysBuf, drop);
        }
        if (ringAvailable(&gMicRing) > RING_BUF_SAMPLES * 9 / 10) {
            uint32_t drop = ringAvailable(&gMicRing) - RING_BUF_SAMPLES / 2;
            if (drop > MAX_TICK_FRAMES) drop = MAX_TICK_FRAMES;
            ringRead(&gMicRing, micBuf, drop);
        }

        // ---- Duration check ----
        if (duration > 0 && (time(NULL) - start) >= duration) gRunning = 0;

        usleep(TICK_INTERVAL_US);
    }
}

// ---------------------------------------------------------------------------
// Interactive microphone selector
// ---------------------------------------------------------------------------
typedef struct {
    AudioObjectID id;
    char          name[256];
    uint32_t      channels;
    Float64       rate;
} DevInfo;

static int devInfoCompare(const void *a, const void *b) {
    return strcasecmp(((const DevInfo *)a)->name,
                      ((const DevInfo *)b)->name);
}

static int interactiveSelectMic(AudioObjectID *outID, uint32_t *outChannels,
                                 Float64 *outRate, char *outName, size_t nameSize) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                                   &addr, 0, NULL, &dataSize);
    if (err != noErr || dataSize == 0) return -1;

    AudioObjectID *devices = malloc(dataSize);
    err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL,
                                      &dataSize, devices);
    if (err != noErr) { free(devices); return -1; }
    UInt32 devCount = dataSize / sizeof(AudioObjectID);

    DevInfo *inputs = calloc(devCount, sizeof(DevInfo));
    uint32_t inputCount = 0;

    for (UInt32 i = 0; i < devCount; i++) {
        AudioObjectID dev = devices[i];

        AudioObjectPropertyAddress inAddr = {
            kAudioDevicePropertyStreamConfiguration,
            kAudioObjectPropertyScopeInput,
            kAudioObjectPropertyElementMain
        };
        UInt32 bufSize = 0;
        AudioObjectGetPropertyDataSize(dev, &inAddr, 0, NULL, &bufSize);
        if (bufSize == 0) continue;
        AudioBufferList *buflist = malloc(bufSize);
        AudioObjectGetPropertyData(dev, &inAddr, 0, NULL, &bufSize, buflist);
        UInt32 inCh = 0;
        for (UInt32 j = 0; j < buflist->mNumberBuffers; j++)
            inCh += buflist->mBuffers[j].mNumberChannels;
        free(buflist);
        if (inCh == 0) continue;

        char devName[256] = "";
        AudioObjectPropertyAddress nAddr = {
            kAudioDevicePropertyDeviceName,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 ns = sizeof(devName) - 1;
        AudioObjectGetPropertyData(dev, &nAddr, 0, NULL, &ns, &devName);

        AudioObjectPropertyAddress fmtAddr = {
            kAudioDevicePropertyStreamFormat,
            kAudioObjectPropertyScopeInput,
            kAudioObjectPropertyElementMain
        };
        AudioStreamBasicDescription asbd = {};
        UInt32 fs = sizeof(asbd);
        AudioObjectGetPropertyData(dev, &fmtAddr, 0, NULL, &fs, &asbd);

        inputs[inputCount].id = dev;
        inputs[inputCount].channels = inCh;
        inputs[inputCount].rate = asbd.mSampleRate;
        strncpy(inputs[inputCount].name, devName, 255);
        inputs[inputCount].name[255] = '\0';
        inputCount++;
    }
    free(devices);

    if (inputCount == 0) {
        fprintf(stderr, "error: no audio input devices found\n");
        free(inputs);
        return -1;
    }

    qsort(inputs, inputCount, sizeof(DevInfo), devInfoCompare);

    printf("\nAvailable input devices:\n");
    for (uint32_t i = 0; i < inputCount; i++) {
        printf("  %2u. %s (%u ch, %.0f Hz)\n",
               i + 1, inputs[i].name,
               (unsigned)inputs[i].channels, inputs[i].rate);
    }

    printf("\nSelect microphone [1-%u]: ", inputCount);
    fflush(stdout);

    char line[64];
    uint32_t choice = 0;
    if (fgets(line, sizeof(line), stdin)) {
        choice = (uint32_t)atoi(line);
    }

    if (choice < 1 || choice > inputCount) {
        fprintf(stderr, "error: invalid selection (must be 1-%u)\n", inputCount);
        free(inputs);
        return -1;
    }

    uint32_t idx = choice - 1;
    *outID       = inputs[idx].id;
    *outChannels = inputs[idx].channels;
    *outRate     = inputs[idx].rate;
    strncpy(outName, inputs[idx].name, nameSize - 1);
    outName[nameSize - 1] = '\0';

    free(inputs);
    return 0;
}

// ---------------------------------------------------------------------------
// Derive base name from argv[0] (strip directory and extension)
// ---------------------------------------------------------------------------
static void defaultBaseName(const char *argv0, char *out, size_t outSize) {
    // Find last path component
    const char *base = strrchr(argv0, '/');
    base = base ? base + 1 : argv0;

    // Copy and strip .m or .c extension if present
    strncpy(out, base, outSize - 1);
    out[outSize - 1] = '\0';

    char *dot = strrchr(out, '.');
    if (dot && (strcmp(dot, ".m") == 0 || strcmp(dot, ".c") == 0))
        *dot = '\0';
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
    const char *outputBase = NULL;   // set below
    int         duration   = 0;
    int         interactiveMic = 0;

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "-o") && i + 1 < argc) outputBase = argv[++i];
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) duration = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-m"))                 interactiveMic = 1;
        else if (!strcmp(argv[i], "-h")) {
            printf("usage: %s [-o base] [-d seconds] [-m]\n", argv[0]);
            printf("  Record system audio + microphone to separate WAV files\n");
            printf("    {base}_system.wav  — system audio (stereo)\n");
            printf("    {base}_mic.wav     — microphone   (mono)\n");
            printf("\n");
            printf("  Post-process with: sox -M {base}_system.wav {base}_mic.wav ...\n");
            printf("\n");
            printf("  Options:\n");
            printf("    -o base   output file base name (default: based on argv[0])\n");
            printf("    -d secs   recording duration in seconds (default: until Ctrl+C)\n");
            printf("    -m        interactively select microphone input device\n");
            printf("\n");
            printf("  Example mixing:\n");
            printf("    # Mix L=sys(stereo→mono), R=mic:\n");
            printf("    sox -M output_system.wav output_mic.wav output.wav \\\n");
            printf("        remix 1,2 1\n");
            printf("    ffmpeg -i output_system.wav -i output_mic.wav \\\n");
            printf("      -filter_complex \"[0:a]pan=mono|c0=FL+FR[sys];[1:a]aformat=sample_rates=48000[mic];[sys][mic]join=inputs=2:channel_layout=stereo\" \\\n");
            printf("      output.wav\n");
            return 0;
        }
    }

    if (!outputBase) {
        char buf[1024];
        defaultBaseName(argv[0], buf, sizeof(buf));
        // If the tool is invoked as ./capture, default base is "capture"
        // but we want "output" for backward compatibility.  Let the user
        // pick: we'll use "output" as default.
        outputBase = "output";
    }

    // Build output file paths
    char sysPath[1024];
    char micPath[1024];
    snprintf(sysPath, sizeof(sysPath), "%s_system.wav", outputBase);
    snprintf(micPath, sizeof(micPath), "%s_mic.wav", outputBase);

    // ---- Init ring buffers ----
    ringInit(&gSysRing, RING_BUF_SAMPLES);
    ringInit(&gMicRing, RING_BUF_SAMPLES);

    // ---- Open output files ----
    gSysFile = fopen(sysPath, "wb");
    if (!gSysFile) {
        fprintf(stderr, "error: cannot create '%s'\n", sysPath);
        ringDestroy(&gSysRing);
        ringDestroy(&gMicRing);
        return 1;
    }

    gMicFile = fopen(micPath, "wb");
    if (!gMicFile) {
        fprintf(stderr, "error: cannot create '%s'\n", micPath);
        fclose(gSysFile);
        ringDestroy(&gSysRing);
        ringDestroy(&gMicRing);
        return 1;
    }

    // Write dummy headers (will be patched at the end with real dataSize)
    writeWavHeader(gSysFile, 0, gSampleRate, 2);
    writeWavHeader(gMicFile, 0, gMicRate > 0 ? gMicRate : gSampleRate, 1);

    // ---- Create process tap + aggregate device ----
    @autoreleasepool {
        CATapDescription *tapDesc = [[CATapDescription alloc]
            initStereoGlobalTapButExcludeProcesses:@[]];
        tapDesc.name = @"com.record.capture";
        tapDesc.UUID = [NSUUID UUID];

        OSStatus err = AudioHardwareCreateProcessTap(tapDesc, &gTapID);
        if (err != noErr) {
            fprintf(stderr, "error: AudioHardwareCreateProcessTap failed (%d)\n", err);
            goto cleanup;
        }

        NSString *tapUID = tapDesc.UUID.UUIDString;
        NSString *aggUID = [[NSUUID UUID] UUIDString];
        NSDictionary *aggDesc = @{
            @"name":         @"System Audio Recorder",
            @"uid":          aggUID,
            @"private":      @YES,
            @"taps":         @[@{@"uid": tapUID}],
            @"tapautostart": @NO,
        };

        err = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggDesc, &gAggID);
        if (err != noErr) {
            fprintf(stderr, "error: AudioHardwareCreateAggregateDevice failed (%d)\n", err);
            AudioHardwareDestroyProcessTap(gTapID);
            goto cleanup;
        }

        // Read the aggregate device's sample rate
        AudioObjectPropertyAddress addr = {
            kAudioDevicePropertyStreamFormat,
            kAudioObjectPropertyScopeInput,
            kAudioObjectPropertyElementMain
        };
        AudioStreamBasicDescription asbd = {};
        UInt32 size = sizeof(asbd);
        err = AudioObjectGetPropertyData(gAggID, &addr, 0, NULL, &size, &asbd);
        if (err == noErr && asbd.mSampleRate > 0)
            gSampleRate = asbd.mSampleRate;

        // Register system IOProc
        err = AudioDeviceCreateIOProcID(gAggID, sysIOProc, NULL, &gSysIOProcID);
        if (err != noErr) {
            fprintf(stderr, "error: AudioDeviceCreateIOProcID (sys) failed (%d)\n", err);
            AudioHardwareDestroyAggregateDevice(gAggID);
            AudioHardwareDestroyProcessTap(gTapID);
            goto cleanup;
        }
    }

    // ---- Find microphone device ----
    {
        if (interactiveMic) {
            char selName[256] = "";
            AudioObjectID selID = 0;
            uint32_t selChan = 0;
            Float64 selRate = 0;

            if (interactiveSelectMic(&selID, &selChan, &selRate,
                                     selName, sizeof(selName)) != 0) {
                fprintf(stderr, "warning: no microphone selected — mic will be silent\n");
            } else {
                gMicID = selID;
                gMicChannels = selChan;
                gMicRate = selRate;

                printf("mic: %s (%u ch, %.0f Hz)\n",
                       selName, (unsigned)selChan, selRate);

                OSStatus err = AudioDeviceCreateIOProcID(gMicID, micIOProc,
                                                         NULL, &gMicIOProcID);
                if (err != noErr) {
                    fprintf(stderr, "warning: could not open mic device — mic will be silent\n");
                    gMicID = 0;
                    gMicChannels = 0;
                    gMicRate = 0;
                }
            }
        } else {
            AudioObjectPropertyAddress defaultAddr = {
                kAudioHardwarePropertyDefaultInputDevice,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            AudioObjectID defaultDev = 0;
            UInt32 dsize = sizeof(defaultDev);
            OSStatus err = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                       &defaultAddr, 0, NULL,
                                                       &dsize, &defaultDev);
            if (err == noErr && defaultDev != 0) {
                AudioObjectPropertyAddress inAddr = {
                    kAudioDevicePropertyStreamConfiguration,
                    kAudioObjectPropertyScopeInput,
                    kAudioObjectPropertyElementMain
                };
                UInt32 bufSize = 0;
                AudioObjectGetPropertyDataSize(defaultDev, &inAddr, 0, NULL, &bufSize);
                AudioBufferList *buflist = malloc(bufSize);
                AudioObjectGetPropertyData(defaultDev, &inAddr, 0, NULL, &bufSize, buflist);
                UInt32 inCh = 0;
                for (UInt32 j = 0; j < buflist->mNumberBuffers; j++)
                    inCh += buflist->mBuffers[j].mNumberChannels;
                free(buflist);

                if (inCh > 0) {
                    AudioObjectPropertyAddress fmtAddr = {
                        kAudioDevicePropertyStreamFormat,
                        kAudioObjectPropertyScopeInput,
                        kAudioObjectPropertyElementMain
                    };
                    AudioStreamBasicDescription asbd = {};
                    UInt32 fs = sizeof(asbd);
                    AudioObjectGetPropertyData(defaultDev, &fmtAddr, 0, NULL, &fs, &asbd);

                    char devName[256] = "";
                    AudioObjectPropertyAddress nAddr = {
                        kAudioDevicePropertyDeviceName,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain
                    };
                    UInt32 ns = sizeof(devName) - 1;
                    AudioObjectGetPropertyData(defaultDev, &nAddr, 0, NULL, &ns, &devName);

                    gMicID = defaultDev;
                    gMicChannels = inCh;
                    gMicRate = asbd.mSampleRate;

                    printf("mic: %s (%u ch, %.0f Hz)  [default input device]\n",
                           devName, (unsigned)inCh, asbd.mSampleRate);

                    err = AudioDeviceCreateIOProcID(gMicID, micIOProc, NULL, &gMicIOProcID);
                    if (err != noErr) {
                        fprintf(stderr, "warning: could not open mic device — mic will be silent\n");
                        gMicID = 0;
                        gMicChannels = 0;
                        gMicRate = 0;
                    }
                } else {
                    fprintf(stderr, "warning: default input device has no input channels — mic will be silent\n");
                }
            }

            // Fallback: scan all devices if there's no default input device
            if (!gMicID) {
                AudioObjectPropertyAddress addr = {
                    kAudioHardwarePropertyDevices,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain
                };
                UInt32 dataSize = 0;
                AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &dataSize);
                AudioObjectID *devices = malloc(dataSize);
                AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &dataSize, devices);
                UInt32 devCount = dataSize / sizeof(AudioObjectID);

                AudioObjectID bestDevice = 0;
                uint32_t     bestScore  = 0;
                uint32_t     bestChan   = 0;
                Float64      bestRate   = 0;
                char         bestName[256] = "";

                for (UInt32 i = 0; i < devCount; i++) {
                    AudioObjectID dev = devices[i];

                    AudioObjectPropertyAddress inAddr = {
                        kAudioDevicePropertyStreamConfiguration,
                        kAudioObjectPropertyScopeInput,
                        kAudioObjectPropertyElementMain
                    };
                    UInt32 bufSize = 0;
                    AudioObjectGetPropertyDataSize(dev, &inAddr, 0, NULL, &bufSize);
                    AudioBufferList *buflist = malloc(bufSize);
                    AudioObjectGetPropertyData(dev, &inAddr, 0, NULL, &bufSize, buflist);
                    UInt32 inCh = 0;
                    for (UInt32 j = 0; j < buflist->mNumberBuffers; j++)
                        inCh += buflist->mBuffers[j].mNumberChannels;
                    free(buflist);
                    if (inCh == 0) continue;

                    AudioObjectPropertyAddress tAddr = {
                        kAudioDevicePropertyTransportType,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain
                    };
                    UInt32 transport = 0;
                    UInt32 ts = sizeof(transport);
                    AudioObjectGetPropertyData(dev, &tAddr, 0, NULL, &ts, &transport);

                    AudioObjectPropertyAddress fmtAddr = {
                        kAudioDevicePropertyStreamFormat,
                        kAudioObjectPropertyScopeInput,
                        kAudioObjectPropertyElementMain
                    };
                    AudioStreamBasicDescription asbd = {};
                    UInt32 fs = sizeof(asbd);
                    AudioObjectGetPropertyData(dev, &fmtAddr, 0, NULL, &fs, &asbd);

                    char devName[256] = "";
                    AudioObjectPropertyAddress nAddr = {
                        kAudioDevicePropertyDeviceName,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain
                    };
                    UInt32 ns = sizeof(devName) - 1;
                    AudioObjectGetPropertyData(dev, &nAddr, 0, NULL, &ns, &devName);

                    uint32_t score = 0;
                    if (transport == kAudioDeviceTransportTypeBuiltIn) score += 100;
                    if (asbd.mSampleRate == gSampleRate)              score += 50;
                    if (asbd.mSampleRate >= 48000)                    score += 10;

                    if (score > bestScore) {
                        bestDevice = dev;
                        bestScore  = score;
                        bestChan   = inCh;
                        bestRate   = asbd.mSampleRate;
                        strncpy(bestName, devName, sizeof(bestName) - 1);
                    }
                }
                free(devices);

                if (bestDevice) {
                    gMicID = bestDevice;
                    gMicChannels = bestChan;
                    gMicRate = bestRate;
                    printf("mic: %s (%u ch, %.0f Hz)  [fallback scan]\n",
                           bestName, (unsigned)bestChan, bestRate);

                    err = AudioDeviceCreateIOProcID(gMicID, micIOProc, NULL, &gMicIOProcID);
                    if (err != noErr) {
                        fprintf(stderr, "warning: could not open mic device — mic will be silent\n");
                        gMicID = 0;
                        gMicChannels = 0;
                        gMicRate = 0;
                    }
                } else {
                    fprintf(stderr, "warning: no input device found — mic will be silent\n");
                }
            }
        }
    }

    // ---- Start devices ----
    {
        OSStatus err = AudioDeviceStart(gAggID, gSysIOProcID);
        if (err != noErr) {
            fprintf(stderr, "error: AudioDeviceStart (sys) failed (%d)\n", err);
            if (gMicIOProcID) AudioDeviceDestroyIOProcID(gMicID, gMicIOProcID);
            AudioDeviceDestroyIOProcID(gAggID, gSysIOProcID);
            AudioHardwareDestroyAggregateDevice(gAggID);
            AudioHardwareDestroyProcessTap(gTapID);
            goto cleanup;
        }
        printf("system audio started (%.0f Hz)\n", gSampleRate);

        if (gMicID && gMicIOProcID) {
            err = AudioDeviceStart(gMicID, gMicIOProcID);
            if (err != noErr) {
                fprintf(stderr, "warning: could not start mic — mic will be silent\n");
                AudioDeviceDestroyIOProcID(gMicID, gMicIOProcID);
                gMicIOProcID = NULL;
                gMicChannels = 0;
            } else {
                printf("microphone started\n");
            }
        }
    }

    printf("\nrecording  ⇢  %s  and  %s   [Ctrl+C to stop]\n", sysPath, micPath);
    fflush(stdout);

    signal(SIGINT,  onSignal);
    signal(SIGTERM, onSignal);

    // ---- Write loop (drains both rings independently) ----
    writeLoop(duration);

    // ---- Stop & tear down ----
    AudioDeviceStop(gAggID, gSysIOProcID);
    AudioDeviceDestroyIOProcID(gAggID, gSysIOProcID);
    AudioHardwareDestroyAggregateDevice(gAggID);
    AudioHardwareDestroyProcessTap(gTapID);

    if (gMicIOProcID) {
        AudioDeviceStop(gMicID, gMicIOProcID);
        AudioDeviceDestroyIOProcID(gMicID, gMicIOProcID);
    }

    ringDestroy(&gSysRing);
    ringDestroy(&gMicRing);

    // ---- Patch WAV headers with actual data sizes ----
    writeWavHeader(gSysFile, gSysDataSize, gSampleRate, 2);
    writeWavHeader(gMicFile, gMicDataSize, gMicRate > 0 ? gMicRate : gSampleRate, 1);

    fclose(gSysFile);
    fclose(gMicFile);

    printf("\ndone — system: %zu bytes, mic: %zu bytes\n",
           gSysDataSize, gMicDataSize);
    printf("  system: %s\n", sysPath);
    printf("  mic:    %s\n", micPath);
    return 0;

cleanup:
    ringDestroy(&gSysRing);
    ringDestroy(&gMicRing);
    if (gSysFile) fclose(gSysFile);
    if (gMicFile) fclose(gMicFile);
    return 1;
}
