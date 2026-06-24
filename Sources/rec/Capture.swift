// Capture.swift — CoreAudio system audio + microphone capture engine
//
// Creates a process tap + aggregate device to capture all system audio,
// opens the microphone device, and writes two separate WAV files.

import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import CBridge

// MARK: - AudioBufferList helpers

private extension UnsafePointer where Pointee == AudioBufferList {
    /// Iterate audio buffers in the list.
    var buffers: [AudioBuffer] {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: self))
        return (0..<abl.count).map { abl[$0] }
    }
}

// MARK: - Ring buffer reference from C

// These are declared in RingBuffer.h / RingBuffer.c:
//   void ring_init(RingBuffer *r, uint32_t minSize)
//   void ring_destroy(RingBuffer *r)
//   uint32_t ring_available(const RingBuffer *r)
//   void ring_write(RingBuffer *r, const float *samples, uint32_t count)
//   uint32_t ring_read(RingBuffer *r, float *samples, uint32_t maxCount)

// MARK: - Constants

private let kRingBufSamples: UInt32 = 512 * 1024   // 512k floats ≈ 2.7s at 48kHz stereo
private let kMaxTickFrames: UInt32 = 16384
private let kTickIntervalUS: useconds_t = 10000     // 10 ms polling
private let kMaxChannelCount: UInt32 = 8

// MARK: - Global capture state

/// Shared capture engine instance.  Global so that the C-function-pointer IOProcs
/// (which cannot capture context) can access it via `CaptureEngine.shared`.
@available(macOS 14.2, *)
final class CaptureEngine {
    static let shared = CaptureEngine()

    // Ring buffers (C structs, must be mutable for ring_write/ring_read)
    var sysRing = RingBuffer()
    var micRing = RingBuffer()

    // File handles
    var sysFile: FileHandle?
    var micFile: FileHandle?
    var sysDataSize: Int = 0
    var micDataSize: Int = 0

    // Device IDs
    var tapID: AudioObjectID = 0
    var aggID: AudioObjectID = 0
    var micID: AudioObjectID = 0
    var sysProcID: AudioDeviceIOProcID?
    var micProcID: AudioDeviceIOProcID?

    // Format info
    var sampleRate: Float64 = 48000
    var micChannels: UInt32 = 0
    var micRate: Float64 = 0

    // Control
    var running = true
    var hasMic = false

    private init() {}

    // MARK: - Device info

    struct DeviceInfo {
        let id: AudioObjectID
        let name: String
        let channels: UInt32
        let rate: Float64
    }

    // MARK: - IOProc callbacks (C function pointers, no captures)

    /// System audio IOProc — called from real-time audio thread.
    /// Writes stereo Float32 samples into sysRing.
    static let sysIOProc: AudioDeviceIOProc = { (_, _, inputData, _, _, _, _) -> OSStatus in
        guard inputData.pointee.mNumberBuffers > 0 else { return noErr }
        let engine = CaptureEngine.shared
        for buf in inputData.buffers {
            guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = buf.mDataByteSize / UInt32(MemoryLayout<Float>.size)
            ring_write(&engine.sysRing, samples, count)
        }
        return noErr
    }

    /// Microphone IOProc — called from real-time audio thread.
    /// Mixes multi-channel to mono, writes Float32 samples into micRing.
    static let micIOProc: AudioDeviceIOProc = { (_, _, inputData, _, _, _, _) -> OSStatus in
        guard inputData.pointee.mNumberBuffers > 0 else { return noErr }
        let engine = CaptureEngine.shared
        guard engine.hasMic else { return noErr }
        for buf in inputData.buffers {
            guard let data = buf.mData, buf.mDataByteSize > 0 else { continue }
            let totalSamples = buf.mDataByteSize / UInt32(MemoryLayout<Float>.size)
            let frames = totalSamples / engine.micChannels
            if engine.micChannels == 1 {
                let samples = data.assumingMemoryBound(to: Float.self)
                ring_write(&engine.micRing, samples, frames)
            } else {
                // Use only channel 0 (primary mic element on MacBooks).
                // Averaging all channels attenuates the signal unnecessarily
                // when beamforming elements differ in sensitivity.
                let ptr = data.assumingMemoryBound(to: Float.self)
                for f in 0..<frames {
                    var sample = ptr[Int(f * engine.micChannels)]  // channel 0 only
                    ring_write(&engine.micRing, &sample, 1)
                }
            }
        }
        return noErr
    }
}

// MARK: - Audio device helpers

@available(macOS 14.2, *)
extension CaptureEngine {
    /// Enumerate all input audio devices.
    static func enumerateInputDevices() -> [DeviceInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize)
        guard dataSize > 0 else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var devices = [AudioObjectID](repeating: 0, count: deviceCount)
        dataSize = UInt32(devices.count * MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &devices)

        var result: [DeviceInfo] = []
        for dev in devices {
            guard dev != kAudioObjectUnknown else { continue }

            // Check input channels
            var inAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(dev, &inAddr, 0, nil, &bufSize)
            guard bufSize > 0 else { continue }

            let bufListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(bufSize))
            AudioObjectGetPropertyData(dev, &inAddr, 0, nil, &bufSize, bufListPtr)
            var inCh: UInt32 = 0
            let abl = UnsafeMutableAudioBufferListPointer(bufListPtr)
            for j in 0..<abl.count {
                inCh += abl[j].mNumberChannels
            }
            bufListPtr.deallocate()
            guard inCh > 0 else { continue }

            // Device name
            var nAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name = [CChar](repeating: 0, count: 256)
            var ns = UInt32(name.count)
            AudioObjectGetPropertyData(dev, &nAddr, 0, nil, &ns, &name)

            // Sample rate
            var fmtAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var asbd = AudioStreamBasicDescription()
            var fs = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            AudioObjectGetPropertyData(dev, &fmtAddr, 0, nil, &fs, &asbd)

            result.append(DeviceInfo(
                id: dev,
                name: String(cString: name),
                channels: inCh,
                rate: asbd.mSampleRate
            ))
        }
        return result
    }

    /// Get the default input device.
    static func defaultInputDevice() -> DeviceInfo? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var devID: AudioObjectID = 0
        var ds = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &ds, &devID)
        guard err == noErr, devID != 0 else { return nil }

        // Get channel count
        var inAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var bufSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(devID, &inAddr, 0, nil, &bufSize)
        guard bufSize > 0 else { return nil }

        let bufListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(bufSize))
        AudioObjectGetPropertyData(devID, &inAddr, 0, nil, &bufSize, bufListPtr)
        var inCh: UInt32 = 0
        let abl = UnsafeMutableAudioBufferListPointer(bufListPtr)
        for j in 0..<abl.count {
            inCh += abl[j].mNumberChannels
        }
        bufListPtr.deallocate()
        guard inCh > 0 else { return nil }

        // Name
        var nAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name = [CChar](repeating: 0, count: 256)
        var ns = UInt32(name.count)
        AudioObjectGetPropertyData(devID, &nAddr, 0, nil, &ns, &name)

        // Rate
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var fs = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioObjectGetPropertyData(devID, &fmtAddr, 0, nil, &fs, &asbd)

        return DeviceInfo(id: devID, name: String(cString: name), channels: inCh, rate: asbd.mSampleRate)
    }
}

// MARK: - Setup / teardown

@available(macOS 14.2, *)
extension CaptureEngine {
    /// Set up the process tap + aggregate device.
    func setupTap() throws {
        let tapUUID = UUID().uuidString
        let aggUUID = UUID().uuidString

        // Create process tap via ObjC bridge
        let name = "com.record.capture"
        var tapID: AudioObjectID = 0
        let err = TapBridgeCreate(name, tapUUID, &tapID)
        guard err == noErr else {
            throw RecError.tapCreationFailed(err)
        }
        self.tapID = tapID

        // Create aggregate device wrapping the tap
        let aggDesc: [String: Any] = [
            "name": "System Audio Recorder",
            "uid": aggUUID,
            "private": true,
            "taps": [["uid": tapUUID]],
            "tapautostart": false,
        ]
        var aggID: AudioObjectID = 0
        let aggErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
        guard aggErr == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw RecError.aggregateCreationFailed(aggErr)
        }
        self.aggID = aggID

        // Read system sample rate
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(aggID, &addr, 0, nil, &sz, &asbd) == noErr, asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        }

        // Register system IOProc
        var procID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcID(aggID, Self.sysIOProc, nil, &procID)
        guard procErr == noErr else {
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            throw RecError.ioProcCreationFailed(procErr)
        }
        sysProcID = procID
    }

    /// Open the microphone device.
    func setupMic(device: DeviceInfo? = nil) throws {
        var devInfo: DeviceInfo

        if let device = device {
            devInfo = device
        } else if let defaultDev = Self.defaultInputDevice() {
            devInfo = defaultDev
        } else {
            // Fallback: pick the first input device with the highest "score"
            let devices = Self.enumerateInputDevices()
            guard !devices.isEmpty else {
                print("warning: no input device found — microphone will be silent", to: &stderr)
                return
            }
            // Prefer built-in mic with matching rate
            var best = devices[0]
            var bestScore = 0
            for d in devices {
                var score = 0
                if d.name.localizedCaseInsensitiveContains("built") || d.name.localizedCaseInsensitiveContains("macbook") {
                    score += 100
                }
                if abs(d.rate - sampleRate) < 1 { score += 50 }
                if d.rate >= 48000 { score += 10 }
                if score > bestScore { best = d; bestScore = score }
            }
            devInfo = best
        }

        micID = devInfo.id
        micChannels = devInfo.channels
        micRate = devInfo.rate
        hasMic = true

        var procID: AudioDeviceIOProcID?
        let err = AudioDeviceCreateIOProcID(micID, Self.micIOProc, nil, &procID)
        guard err == noErr else {
            print("warning: could not open microphone — mic will be silent", to: &stderr)
            hasMic = false
            return
        }
        micProcID = procID

        print("mic: \(devInfo.name) (\(devInfo.channels) ch, \(Int(devInfo.rate)) Hz)", to: &stderr)
    }

    /// Start both devices.
    func startAudio() throws {
        var err = AudioDeviceStart(aggID, sysProcID)
        guard err == noErr else {
            throw RecError.deviceStartFailed("system audio", err)
        }
        print("system audio started (\(Int(sampleRate)) Hz)", to: &stderr)

        if hasMic, let micProcID = micProcID {
            err = AudioDeviceStart(micID, micProcID)
            if err != noErr {
                print("warning: could not start microphone — mic will be silent", to: &stderr)
                hasMic = false
            } else {
                print("microphone started", to: &stderr)
            }
        }
    }

    /// Clean up CoreAudio objects.
    func teardown() {
        if let procID = sysProcID {
            AudioDeviceStop(aggID, procID)
            AudioDeviceDestroyIOProcID(aggID, procID)
        }
        if let procID = micProcID {
            AudioDeviceStop(micID, procID)
            AudioDeviceDestroyIOProcID(micID, procID)
        }
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID) }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        sysProcID = nil
        micProcID = nil
        aggID = 0
        tapID = 0
    }
}

// MARK: - WAV writing

@available(macOS 14.2, *)
extension CaptureEngine {
    /// Write a WAV header to fileHandle (must be writable).
    static func writeWavHeader(_ fh: FileHandle, dataSize: Int, sampleRate: Float64, channels: UInt16) {
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * (bitsPerSample / 8)
        var byteRate = UInt32(sampleRate * Float64(blockAlign))
        var chunkSize = UInt32(dataSize) + 36

        var header = Data()
        // RIFF header
        header.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: &chunkSize) { header.append(contentsOf: $0) }
        header.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        header.append(contentsOf: "fmt ".utf8)
        var fmtLen = UInt32(16)
        var fmtTag = UInt16(1)  // PCM
        var ch = channels
        withUnsafeBytes(of: &fmtLen) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &fmtTag) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &ch) { header.append(contentsOf: $0) }
        var sr = UInt32(sampleRate)
        withUnsafeBytes(of: &sr) { header.append(contentsOf: $0) }
        withUnsafeBytes(of: &byteRate) { header.append(contentsOf: $0) }
        var ba = blockAlign
        withUnsafeBytes(of: &ba) { header.append(contentsOf: $0) }
        var bps = bitsPerSample
        withUnsafeBytes(of: &bps) { header.append(contentsOf: $0) }
        // data chunk
        header.append(contentsOf: "data".utf8)
        var d32 = UInt32(dataSize)
        withUnsafeBytes(of: &d32) { header.append(contentsOf: $0) }

        fh.seek(toFileOffset: 0)
        fh.write(header)
    }

    /// Open a WAV file for writing (writes dummy header, to be patched later).
    func openWavFiles(sysPath: String, micPath: String) throws {
        FileManager.default.createFile(atPath: sysPath, contents: nil)
        sysFile = FileHandle(forWritingAtPath: sysPath)
        guard sysFile != nil else { throw RecError.fileCreationFailed(sysPath) }

        Self.writeWavHeader(sysFile!, dataSize: 0, sampleRate: sampleRate, channels: 2)

        FileManager.default.createFile(atPath: micPath, contents: nil)
        micFile = FileHandle(forWritingAtPath: micPath)
        guard micFile != nil else { throw RecError.fileCreationFailed(micPath) }

        Self.writeWavHeader(micFile!, dataSize: 0, sampleRate: micRate > 0 ? micRate : sampleRate, channels: 1)
    }
}

// MARK: - Writing loop

@available(macOS 14.2, *)
extension CaptureEngine {
    /// Main capture loop — polls ring buffers and writes to WAV files.
    /// - Parameter status: Optional shared status object for live display. Updated every ~500ms.
    func captureLoop(duration: Int, status: CaptureStatus? = nil) throws {
        let maxFrames = kMaxTickFrames
        let sysBuf = UnsafeMutablePointer<Float>.allocate(capacity: Int(maxFrames * 2))
        let micBuf = UnsafeMutablePointer<Float>.allocate(capacity: Int(maxFrames))
        let convSys = UnsafeMutablePointer<Int16>.allocate(capacity: Int(maxFrames * 2))
        let convMic = UnsafeMutablePointer<Int16>.allocate(capacity: Int(maxFrames))
        defer {
            sysBuf.deallocate()
            micBuf.deallocate()
            convSys.deallocate()
            convMic.deallocate()
        }

        let startTime = Date()
        let maxDuration: TimeInterval = duration > 0 ? TimeInterval(duration) : .infinity
        var lastStatusUpdate: Date = .distantPast
        var lastSysRms: Float = 0
        var lastMicRms: Float = 0

        while running && Date().timeIntervalSince(startTime) < maxDuration {
            // ---- Write system audio (stereo interleaved) ----
            let sysAvail = ring_available(&sysRing)
            let sysFrames = min(sysAvail / 2, maxFrames)

            if sysFrames > 0 {
                let read = ring_read(&sysRing, sysBuf, sysFrames * 2)
                // Compute RMS for volume display
                var sumSq: Float = 0
                vDSP_measqv(sysBuf, 1, &sumSq, vDSP_Length(read))
                lastSysRms = sqrt(sumSq)
                // Float32 → SInt16
                for i in 0..<Int(read) {
                    var s = sysBuf[i]
                    s = max(-1.0, min(1.0, s))
                    convSys[i] = Int16(s * 32767.0)
                }
                let data = Data(bytesNoCopy: convSys, count: Int(read) * MemoryLayout<Int16>.size, deallocator: .none)
                sysFile?.write(data)
                sysDataSize += Int(read) * MemoryLayout<Int16>.size
            }

            // ---- Write microphone audio (mono) ----
            let micAvail = ring_available(&micRing)
            let micFrames = min(micAvail, maxFrames)

            if micFrames > 0, let _ = micFile {
                let read = ring_read(&micRing, micBuf, micFrames)
                // Compute RMS for volume display
                var sumSq: Float = 0
                vDSP_measqv(micBuf, 1, &sumSq, vDSP_Length(read))
                lastMicRms = sqrt(sumSq)
                for i in 0..<Int(read) {
                    var s = micBuf[i]
                    s = max(-1.0, min(1.0, s))
                    convMic[i] = Int16(s * 32767.0)
                }
                let data = Data(bytesNoCopy: convMic, count: Int(read) * MemoryLayout<Int16>.size, deallocator: .none)
                micFile?.write(data)
                micDataSize += Int(read) * MemoryLayout<Int16>.size
            }

            // ---- Overflow protection ----
            if ring_available(&sysRing) > kRingBufSamples * 9 / 10 {
                let drop = min(kMaxTickFrames * 2, ring_available(&sysRing) - kRingBufSamples / 2)
                ring_read(&sysRing, sysBuf, drop)
            }
            if ring_available(&micRing) > kRingBufSamples * 9 / 10 {
                let drop = min(kMaxTickFrames, ring_available(&micRing) - kRingBufSamples / 2)
                ring_read(&micRing, micBuf, drop)
            }

            // ---- Periodic status update (every ~500ms) ----
            let now = Date()
            if now.timeIntervalSince(lastStatusUpdate) >= 0.5 {
                let elapsed = now.timeIntervalSince(startTime)
                let sysFr = UInt64(sysDataSize / 4)       // 2 ch × 2 bytes = 4 bytes/frame
                let micFr = UInt64(micDataSize / 2)        // 1 ch × 2 bytes = 2 bytes/frame
                status?.update(sysFrames: sysFr, micFrames: micFr, sysRms: lastSysRms, micRms: lastMicRms)

                if isatty(STDERR_FILENO) != 0 {
                    let sysBar = rmsBar(lastSysRms)
                    let micBar = rmsBar(lastMicRms)
                    let driftPct = status?.driftPercent ?? 0
                    print("\r  sys: \(sysBar)  mic: \(micBar)  drift \(String(format: "%5.2f", driftPct))%  \(String(format: "%.0f", elapsed))s    ", terminator: "", to: &stderr)
                    Darwin.fflush(__stderrp)
                }
                lastStatusUpdate = now
            }

            usleep(kTickIntervalUS)
        }

        // Clear status line when done
        if isatty(STDERR_FILENO) != 0 {
            print("\r\(String(repeating: " ", count: 70))\r", terminator: "", to: &stderr)
            Darwin.fflush(__stderrp)
        }
    }
}

// MARK: - High-level capture entry point

@available(macOS 14.2, *)
extension CaptureEngine {
    /// Run capture: set up tap + mic, record, tear down.
    /// - Parameters:
    ///   - sysWavPath: Path for the system audio WAV file.
    ///   - micWavPath:  Path for the microphone WAV file.
    ///   - duration:    Recording duration in seconds (0 = until Ctrl+C).
    ///   - interactiveMic: If true, show a menu to choose the mic device.
    ///   - status:    Optional shared status object for live display.
    static func capture(sysWavPath: String, micWavPath: String, duration: Int = 0, interactiveMic: Bool = false, status: CaptureStatus? = nil) throws {
        let engine = CaptureEngine.shared

        // Init ring buffers
        ring_init(&engine.sysRing, kRingBufSamples)
        ring_init(&engine.micRing, kRingBufSamples)
        defer {
            ring_destroy(&engine.sysRing)
            ring_destroy(&engine.micRing)
        }

        // Set up process tap
        try engine.setupTap()
        defer { engine.teardown() }

        // Set up microphone
        if interactiveMic {
            let devices = Self.enumerateInputDevices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            guard !devices.isEmpty else {
                print("error: no audio input devices found", to: &stderr)
                throw RecError.noInputDevice
            }
            print("\nAvailable input devices:", to: &stderr)
            for (i, dev) in devices.enumerated() {
                print("  \(i + 1). \(dev.name) (\(dev.channels) ch, \(Int(dev.rate)) Hz)", to: &stderr)
            }
            print("\nSelect microphone [1-\(devices.count)]: ", terminator: "", to: &stderr)
            Darwin.fflush(__stderrp)
            guard let line = readLine(), let choice = Int(line), choice >= 1, choice <= devices.count else {
                print("error: invalid selection", to: &stderr)
                throw RecError.invalidMicSelection
            }
            try engine.setupMic(device: devices[choice - 1])
        } else {
            try engine.setupMic()
        }

        // Open output files
        try engine.openWavFiles(sysPath: sysWavPath, micPath: micWavPath)

        // Start audio
        try engine.startAudio()

        // Signal handling
        signal(SIGINT) { _ in CaptureEngine.shared.running = false }
        signal(SIGTERM) { _ in CaptureEngine.shared.running = false }

        // Print initial recording message (status line will overwrite this on ttys)
        if isatty(STDERR_FILENO) != 0 {
            print("\r  Ctrl+C to stop  |  sys: ..........  mic: ..........  drift  0.00%  \(String(repeating: " ", count: 10))\r", terminator: "", to: &stderr)
            Darwin.fflush(__stderrp)
        } else {
            print("recording  ⇢  \(sysWavPath)  and  \(micWavPath)   [Ctrl+C to stop]", to: &stderr)
        }

        // Main loop (runs on current thread, blocks until done)
        try engine.captureLoop(duration: duration, status: status)

        // Clean up WAV files
        engine.sysFile?.closeFile()
        engine.micFile?.closeFile()

        // Re-open to patch headers
        if let fh = FileHandle(forWritingAtPath: sysWavPath) {
            Self.writeWavHeader(fh, dataSize: engine.sysDataSize, sampleRate: engine.sampleRate, channels: 2)
            fh.closeFile()
        }
        if let fh = FileHandle(forWritingAtPath: micWavPath) {
            Self.writeWavHeader(fh, dataSize: engine.micDataSize, sampleRate: engine.micRate > 0 ? engine.micRate : engine.sampleRate, channels: 1)
            fh.closeFile()
        }

        print("done — system: \(engine.sysDataSize) bytes, mic: \(engine.micDataSize) bytes", to: &stderr)
        print("  system: \(sysWavPath)", to: &stderr)
        print("  mic:    \(micWavPath)", to: &stderr)
    }
}

// MARK: - Display helpers

/// Build a 10-character bar from RMS amplitude (0..1).
private func rmsBar(_ rms: Float) -> String {
    let clamped = min(max(rms, 0), 1)
    let filled = Int(clamped * 20)
    let empty = 20 - filled
    return String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: empty)
}
