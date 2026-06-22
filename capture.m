// capture.m — minimal macOS system-audio loopback recorder
//
// Uses CoreAudio's Process Tap API (macOS 14.2+) to capture whatever is
// playing through the system's speakers.  Output is a 48 kHz 16‑bit stereo
// WAV file.
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
#include <math.h>

// ---------------------------------------------------------------------------
// Globals
// ---------------------------------------------------------------------------
static AudioObjectID               gTapID = 0;
static AudioObjectID               gAggID = 0;
static AudioDeviceIOProcID         gIOProcID = NULL;
static FILE                       *gFile = NULL;
static size_t                      gDataSize = 0;
static Float64                     gSampleRate = 48000.0;
static volatile sig_atomic_t       gRunning = 1;

static void onSignal(int sig) { (void)sig; gRunning = 0; }

// ---------------------------------------------------------------------------
// WAV header helpers
// ---------------------------------------------------------------------------
static void writeWavHeader(FILE *fp, size_t dataSize) {
    uint16_t channels     = 2;
    uint16_t bitsPerSamp  = 16;
    uint16_t blockAlign   = channels * (bitsPerSamp / 8);
    uint32_t byteRate     = (uint32_t)(gSampleRate * blockAlign);
    uint32_t chunkSize    = (uint32_t)dataSize + 36;

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
// CoreAudio IOProc  –  called on a realtime thread
// ---------------------------------------------------------------------------
static OSStatus ioProc(AudioObjectID           inDevice,
                       const AudioTimeStamp   *inNow,
                       const AudioBufferList  *inInputData,
                       const AudioTimeStamp   *inInputTime,
                       AudioBufferList        *outOutputData,
                       const AudioTimeStamp   *inOutputTime,
                       void                   *inClientData) {
    (void)inDevice;
    (void)inNow;
    (void)inInputTime;
    (void)outOutputData;
    (void)inOutputTime;
    (void)inClientData;

    if (!gFile || !inInputData) return kAudioHardwareNoError;

    for (UInt32 i = 0; i < inInputData->mNumberBuffers; i++) {
        const AudioBuffer *buf = &inInputData->mBuffers[i];
        if (!buf->mData || buf->mDataByteSize == 0) continue;

        UInt32 sampleCount = buf->mDataByteSize / sizeof(float);
        float  *samples   = (float *)buf->mData;

        // Buffered local conversion (avoids per-sample fwrite in RT thread)
        // We convert Float32 → SInt16 and write directly.
        // For simplicity we use a small stack buffer when possible.
        #define CONV_BUF_FRAMES 8192
        int16_t conv[CONV_BUF_FRAMES * 2]; // stereo
        UInt32  frames     = sampleCount / 2; // stereo
        UInt32  written    = 0;

        while (written < frames) {
            UInt32 batch = (frames - written) < CONV_BUF_FRAMES
                         ? (frames - written) : CONV_BUF_FRAMES;
            for (UInt32 j = 0; j < batch * 2; j++) {
                float s = samples[written * 2 + j];
                // Clamp to [-1, 1]
                if      (s >  1.0f) s =  1.0f;
                else if (s < -1.0f) s = -1.0f;
                conv[j] = (int16_t)(s * 32767.0f);
            }
            size_t n = fwrite(conv, sizeof(int16_t), batch * 2, gFile);
            gDataSize += n * sizeof(int16_t);
            written += batch;
        }
    }

    return kAudioHardwareNoError;
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
            printf("  Record system audio (speaker output) on macOS 14.2+\n");
            return 0;
        }
    }

    // ---- Open output file ----
    gFile = fopen(outputPath, "wb");
    if (!gFile) { fprintf(stderr, "error: cannot create '%s'\n", outputPath); return 1; }
    writeWavHeader(gFile, 0);
    fflush(gFile);

    // ---- Create the process tap ----
    @autoreleasepool {
        CATapDescription *tapDesc = [[CATapDescription alloc]
            initStereoGlobalTapButExcludeProcesses:@[]];
        tapDesc.name = @"com.record.capture";
        tapDesc.UUID = [NSUUID UUID];

        OSStatus err = AudioHardwareCreateProcessTap(tapDesc, &gTapID);
        if (err != noErr) {
            fprintf(stderr, "error: AudioHardwareCreateProcessTap failed (%d)\n", err);
            fclose(gFile);
            return 1;
        }

        // ---- Create aggregate device that wraps the tap ----
        NSString *tapUID = tapDesc.UUID.UUIDString;
        NSString *aggUID = [[NSUUID UUID] UUIDString];
        NSDictionary *aggDesc = @{
            @"name":        @"System Audio Recorder",
            @"uid":         aggUID,
            @"private":     @YES,
            @"taps":        @[@{@"uid": tapUID}],
            @"tapautostart": @NO,
        };

        err = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggDesc, &gAggID);
        if (err != noErr) {
            fprintf(stderr, "error: AudioHardwareCreateAggregateDevice failed (%d)\n", err);
            AudioHardwareDestroyProcessTap(gTapID);
            fclose(gFile);
            return 1;
        }

        // ---- Detect sample rate from the aggregate device ----
        AudioObjectPropertyAddress addr = {
            kAudioDevicePropertyStreamFormat,
            kAudioObjectPropertyScopeInput,
            kAudioObjectPropertyElementMain
        };
        AudioStreamBasicDescription asbd = {};
        UInt32 size = sizeof(asbd);
        err = AudioObjectGetPropertyData(gAggID, &addr, 0, NULL, &size, &asbd);
        if (err == noErr && asbd.mSampleRate > 0) {
            gSampleRate = asbd.mSampleRate;
        }
        printf("device sample rate: %.0f Hz\n", gSampleRate);

        // ---- Register IOProc ----
        err = AudioDeviceCreateIOProcID(gAggID, ioProc, NULL, &gIOProcID);
        if (err != noErr) {
            fprintf(stderr, "error: AudioDeviceCreateIOProcID failed (%d)\n", err);
            AudioHardwareDestroyAggregateDevice(gAggID);
            AudioHardwareDestroyProcessTap(gTapID);
            fclose(gFile);
            return 1;
        }

        // ---- Start ----
        err = AudioDeviceStart(gAggID, gIOProcID);
        if (err != noErr) {
            fprintf(stderr, "error: AudioDeviceStart failed (%d)\n", err);
            AudioDeviceDestroyIOProcID(gAggID, gIOProcID);
            AudioHardwareDestroyAggregateDevice(gAggID);
            AudioHardwareDestroyProcessTap(gTapID);
            fclose(gFile);
            return 1;
        }
    } // @autoreleasepool – release ObjC objects, the native IDs remain valid

    printf("recording  ⇢  %s   [Ctrl+C to stop]\n", outputPath);
    fflush(stdout);

    signal(SIGINT,  onSignal);
    signal(SIGTERM, onSignal);

    if (duration > 0) {
        for (int i = 0; i < duration && gRunning; i++) sleep(1);
    } else {
        while (gRunning) sleep(1);
    }

    // ---- Stop & tear down ----
    AudioDeviceStop(gAggID, gIOProcID);
    AudioDeviceDestroyIOProcID(gAggID, gIOProcID);
    AudioHardwareDestroyAggregateDevice(gAggID);
    AudioHardwareDestroyProcessTap(gTapID);

    // ---- Patch WAV header ----
    writeWavHeader(gFile, gDataSize);
    fclose(gFile);

    printf("done — %zu bytes  →  %s\n", gDataSize, outputPath);
    return 0;
}
