// capture.m — capture system audio + microphone to 2‑channel WAV
//
// Uses CoreAudio's Process Tap API (macOS 14.2+) to capture system audio,
// and the default input device for microphone capture.  Output is a 48 kHz
// 16‑bit WAV file with:
//   L = system audio (stereo mixed to mono)
//   R = microphone (mono)
//
// Build:   cc -o capture capture.m -framework CoreAudio -framework Foundation
// Run:     ./capture -o recording.wav           (until Ctrl+C)
//          ./capture -o recording.wav -d 10     (10 seconds)

#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <Foundation/Foundation.h>
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
#define RING_BUF_SAMPLES    (256 * 1024)   // 256k floats ≈ 1.3 s at 48 kHz
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

static void writeWavHeader(FILE *fp, size_t dataSize) {
    uint16_t channels    = 2;
    uint16_t bitsPerSamp = 16;
    uint16_t blockAlign  = channels * (bitsPerSamp / 8);
    uint32_t byteRate    = (uint32_t)(gSampleRate * blockAlign);
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
    uint32_t sr = (uint32_t)gSampleRate;
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
static FILE                 *gFile        = NULL;
static size_t                gDataSize    = 0;
static uint32_t              gMicChannels = 0;     // 0 = mic not available
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
// Write loop  —  drains rings, mixes L=sys‑mono R=mic, writes WAV
// ---------------------------------------------------------------------------
static void writeLoop(int duration) {
    float   sysBuf[MAX_TICK_FRAMES * 2];
    float   micBuf[MAX_TICK_FRAMES];
    int16_t conv[MAX_TICK_FRAMES * 2];
    time_t  start = time(NULL);

    while (gRunning) {
        // ---- Read system audio (stereo frames) ----
        uint32_t sysFrames = ringAvailable(&gSysRing) / 2;
        if (sysFrames > MAX_TICK_FRAMES) sysFrames = MAX_TICK_FRAMES;

        if (sysFrames > 0) {
            ringRead(&gSysRing, sysBuf, sysFrames * 2);

            // ---- Read corresponding mic data, pad with silence if short ----
            uint32_t micRead = ringRead(&gMicRing, micBuf, sysFrames);
            for (uint32_t i = micRead; i < sysFrames; i++)
                micBuf[i] = 0.0f;

            // ---- Mix: L = system (stereo → mono), R = mic ----
            for (uint32_t i = 0; i < sysFrames; i++) {
                float L = (sysBuf[i * 2] + sysBuf[i * 2 + 1]) * 0.5f;
                float R = micBuf[i];
                // Clamp
                if      (L >  1.0f) L =  1.0f;
                else if (L < -1.0f) L = -1.0f;
                if      (R >  1.0f) R =  1.0f;
                else if (R < -1.0f) R = -1.0f;
                conv[i * 2]     = (int16_t)(L * 32767.0f);
                conv[i * 2 + 1] = (int16_t)(R * 32767.0f);
            }

            size_t n = fwrite(conv, sizeof(int16_t), sysFrames * 2, gFile);
            gDataSize += n * sizeof(int16_t);
        }

        // ---- Overflow protection: drain rings if they exceed 90 % ----
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
// main
// ---------------------------------------------------------------------------
int main(int argc, char **argv) {
    const char *outputPath = "output.wav";
    int         duration   = 0;

    for (int i = 1; i < argc; i++) {
        if      (!strcmp(argv[i], "-o") && i + 1 < argc) outputPath = argv[++i];
        else if (!strcmp(argv[i], "-d") && i + 1 < argc) duration = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-h")) {
            printf("usage: %s [-o out.wav] [-d seconds]\n", argv[0]);
            printf("  Record system audio + microphone to WAV\n");
            printf("    L = system audio (stereo → mono)\n");
            printf("    R = microphone  (mono)\n");
            return 0;
        }
    }

    // ---- Init ring buffers ----
    ringInit(&gSysRing, RING_BUF_SAMPLES);
    ringInit(&gMicRing, RING_BUF_SAMPLES);

    // ---- Open output file ----
    gFile = fopen(outputPath, "wb");
    if (!gFile) {
        fprintf(stderr, "error: cannot create '%s'\n", outputPath);
        ringDestroy(&gSysRing);
        ringDestroy(&gMicRing);
        return 1;
    }
    writeWavHeader(gFile, 0);

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

    // ---- Find best microphone device (prefer built‑in) ----
    {
        // Enumerate all audio devices
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

            // Check input-channel count
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

            // Transport type
            AudioObjectPropertyAddress tAddr = {
                kAudioDevicePropertyTransportType,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            UInt32 transport = 0;
            UInt32 ts = sizeof(transport);
            AudioObjectGetPropertyData(dev, &tAddr, 0, NULL, &ts, &transport);

            // Sample rate
            AudioObjectPropertyAddress fmtAddr = {
                kAudioDevicePropertyStreamFormat,
                kAudioObjectPropertyScopeInput,
                kAudioObjectPropertyElementMain
            };
            AudioStreamBasicDescription asbd = {};
            UInt32 fs = sizeof(asbd);
            AudioObjectGetPropertyData(dev, &fmtAddr, 0, NULL, &fs, &asbd);

            // Device name (C string)
            char devName[256] = "";
            {
                AudioObjectPropertyAddress nAddr = {
                    kAudioDevicePropertyDeviceName,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain
                };
                UInt32 ns = sizeof(devName) - 1;
                AudioObjectGetPropertyData(dev, &nAddr, 0, NULL, &ns, &devName);
            }

            // Score: built‑in >> matches sys rate >> high rate
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

        gMicID = bestDevice;
        gMicChannels = bestChan;

        if (!gMicID) {
            fprintf(stderr, "warning: no input device found — mic will be silent\n");
        } else {
            printf("mic: %s (%u ch, %.0f Hz)\n",
                   bestName, (unsigned)bestChan, bestRate);

            if (bestRate != gSampleRate) {
                fprintf(stderr,
                    "warning: mic rate (%.0f Hz) differs from sys rate (%.0f Hz)\n"
                    "         — R channel may have dropouts\n",
                    bestRate, gSampleRate);
            }

            OSStatus err = AudioDeviceCreateIOProcID(gMicID, micIOProc, NULL, &gMicIOProcID);
            if (err != noErr) {
                fprintf(stderr, "warning: could not open mic device — mic will be silent\n");
                gMicID = 0;
                gMicChannels = 0;
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

    printf("recording  ⇢  %s   [Ctrl+C to stop]\n", outputPath);
    fflush(stdout);

    signal(SIGINT,  onSignal);
    signal(SIGTERM, onSignal);

    // ---- Write loop (replaces the old sleep loop) ----
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

    // ---- Patch WAV header ----
    writeWavHeader(gFile, gDataSize);
    fclose(gFile);

    printf("done — %zu bytes  →  %s\n", gDataSize, outputPath);
    return 0;

cleanup:
    ringDestroy(&gSysRing);
    ringDestroy(&gMicRing);
    fclose(gFile);
    return 1;
}
