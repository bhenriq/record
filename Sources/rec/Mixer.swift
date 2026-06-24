// Mixer.swift — drift-correct and mix system + mic WAVs to stereo output
//
// Reads two WAV files (system stereo, mic mono), detects clock drift,
// resamples to match rates, corrects drift, and mixes to a stereo output:
//   left channel  = microphone
//   right channel = system audio (summed to mono)

import Foundation
import Accelerate

// MARK: - WAV reading

struct WavFile {
    let sampleRate: Float64
    let channels: UInt16
    let bitsPerSample: UInt16
    let samples: [Float]       // interleaved floats, normalized to [-1, 1]
    let frameCount: Int

    /// Read a WAV file and return decoded float samples.
    static func read(path: String) throws -> WavFile {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw RecError.wavReadFailed(path)
        }

        let bytes = [UInt8](data)
        guard bytes.count > 44 else { throw RecError.wavReadFailed("\(path): file too small") }

        // Parse header
        let riff = String(bytes: bytes[0..<4], encoding: .ascii) ?? ""
        guard riff == "RIFF" else { throw RecError.wavReadFailed("\(path): not a RIFF file") }

        let wave = String(bytes: bytes[8..<12], encoding: .ascii) ?? ""
        guard wave == "WAVE" else { throw RecError.wavReadFailed("\(path): not a WAVE file") }

        let fmtTag: UInt16 = bytes.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt16.self) }
        let channels: UInt16 = bytes.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }
        let sampleRate: UInt32 = bytes.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
        let bitsPerSample: UInt16 = bytes.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }

        guard fmtTag == 1 else { throw RecError.wavReadFailed("\(path): only PCM supported, got format \(fmtTag)") }

        // Find data chunk
        var offset = 12
        var dataChunk: [UInt8] = []
        while offset + 8 <= bytes.count {
            let chunkID = String(bytes: bytes[offset..<offset+4], encoding: .ascii) ?? ""
            let chunkSize: UInt32 = bytes.withUnsafeBytes { $0.load(fromByteOffset: offset + 4, as: UInt32.self) }
            if chunkID == "data" {
                let start = offset + 8
                let end = min(start + Int(chunkSize), bytes.count)
                dataChunk = Array(bytes[start..<end])
                break
            }
            offset += 8 + Int(chunkSize)
        }

        guard !dataChunk.isEmpty else { throw RecError.wavReadFailed("\(path): no data chunk found") }

        // Convert to float
        let totalSamples: Int
        let floatSamples: [Float]

        switch bitsPerSample {
        case 16:
            totalSamples = dataChunk.count / 2
            var floats = [Float](repeating: 0, count: totalSamples)
            dataChunk.withUnsafeBytes { src in
                let s16 = src.bindMemory(to: Int16.self)
                vDSP_vflt16(s16.baseAddress!, 1, &floats, 1, vDSP_Length(totalSamples))
                var scale = Float(32768.0)
                vDSP_vsdiv(floats, 1, &scale, &floats, 1, vDSP_Length(totalSamples))
            }
            floatSamples = floats
        case 24:
            // 24-bit PCM: 3 bytes per sample, little-endian, signed
            totalSamples = dataChunk.count / 3
            var floats = [Float](repeating: 0, count: totalSamples)
            for i in 0..<totalSamples {
                let byte0 = Int32(dataChunk[i * 3])
                let byte1 = Int32(dataChunk[i * 3 + 1])
                let byte2 = Int32(dataChunk[i * 3 + 2])
                var sample: Int32 = (byte2 << 16) | (byte1 << 8) | byte0
                if sample & 0x800000 != 0 { sample |= Int32(bitPattern: 0xFF000000) }  // sign extend
                floats[i] = Float(sample) / Float(0x7FFFFF)
            }
            floatSamples = floats
        case 32:
            totalSamples = dataChunk.count / 4
            var floats = [Float](repeating: 0, count: totalSamples)
            dataChunk.withUnsafeBytes { src in
                let s32 = src.bindMemory(to: Int32.self)
                vDSP_vflt32(s32.baseAddress!, 1, &floats, 1, vDSP_Length(totalSamples))
                var scale = Float(2147483648.0)
                vDSP_vsdiv(floats, 1, &scale, &floats, 1, vDSP_Length(totalSamples))
            }
            floatSamples = floats
        default:
            throw RecError.wavReadFailed("\(path): unsupported bits per sample: \(bitsPerSample)")
        }

        return WavFile(
            sampleRate: Float64(sampleRate),
            channels: channels,
            bitsPerSample: bitsPerSample,
            samples: floatSamples,
            frameCount: totalSamples / Int(channels)
        )
    }

    /// Number of frames.
    var frames: Int { frameCount }

    /// Duration in seconds.
    var duration: Double { Double(frameCount) / sampleRate }
}

// MARK: - Mixer

struct MixResult {
    /// Stereo interleaved float samples.
    let samples: [Float]
    let frameCount: Int
    let sampleRate: Float64
}

/// Mix system and mic WAVs to stereo (mic left, system right).
/// Handles drift correction, sample rate conversion, and mic gain boost.
/// - Parameter micGain: Gain multiplier applied to mic samples (default 1.0).
///   Use 2.0 for +6dB, 0.5 for -6dB, etc.
func mix(system: WavFile, mic: WavFile, micGain: Float = 1.0) throws -> MixResult {
    let driftThreshold = 0.0001

    print("System: \(system.frames) frames, \(Int(system.sampleRate)) Hz, \(String(format: "%.2f", system.duration))s", to: &stderr)
    print("Mic:    \(mic.frames) frames, \(Int(mic.sampleRate)) Hz, \(String(format: "%.2f", mic.duration))s", to: &stderr)

    // Determine output sample rate (use system rate)
    let outRate = system.sampleRate

    // ---- Resample mic to match system sample rate ----
    var micFloats = mic.samples
    var micRate = mic.sampleRate

    if abs(micRate - outRate) > 1 {
        print("  Resampling mic from \(Int(micRate)) Hz to \(Int(outRate)) Hz...", to: &stderr)
        let ratio = outRate / micRate
        let newFrameCount = Int(Double(mic.frames) * ratio)
        var resampled = [Float](repeating: 0, count: newFrameCount * Int(mic.channels))

        // Simple linear interpolation resampling
        for ch in 0..<Int(mic.channels) {
            for i in 0..<newFrameCount {
                let srcPos = Double(i) / ratio
                let srcIdx = Int(srcPos)
                let frac = srcPos - Double(srcIdx)
                let nextIdx = min(srcIdx + 1, mic.frames - 1)
                let a = mic.samples[srcIdx * Int(mic.channels) + ch]
                let b = mic.samples[nextIdx * Int(mic.channels) + ch]
                resampled[i * Int(mic.channels) + ch] = Float(Double(a) * (1 - frac) + Double(b) * frac)
            }
        }
        micFloats = resampled
        micRate = outRate
    }

    // ---- Downmix system to mono ----
    var sysMono: [Float]
    if system.channels == 1 {
        sysMono = system.samples
    } else {
        sysMono = [Float](repeating: 0, count: system.frames)
        for f in 0..<system.frames {
            var sum: Float = 0
            for c in 0..<Int(system.channels) {
                sum += system.samples[f * Int(system.channels) + c]
            }
            sysMono[f] = sum / Float(system.channels)
        }
    }

    // ---- Downmix mic to mono ----
    var micMono: [Float]
    let micFrames = micFloats.count / Int(mic.channels)
    if mic.channels == 1 {
        micMono = micFloats
    } else {
        micMono = [Float](repeating: 0, count: micFrames)
        for f in 0..<micFrames {
            var sum: Float = 0
            for c in 0..<Int(mic.channels) {
                sum += micFloats[f * Int(mic.channels) + c]
            }
            micMono[f] = sum / Float(mic.channels)
        }
    }

    // ---- Detect clock drift ----
    let ratio = Double(sysMono.count) / Double(micMono.count)
    let drift = abs(ratio - 1.0)

    if drift > driftThreshold {
        print("  Clock drift detected: \(String(format: "%.6f", drift)) (ratio \(String(format: "%.6f", ratio)))", to: &stderr)
        print("  Correcting by stretching microphone track...", to: &stderr)

        // Stretch mic to match system duration using linear resampling
        let newMicCount = Int(Double(micMono.count) * ratio)
        var stretched = [Float](repeating: 0, count: newMicCount)
        let stretchRatio = Double(newMicCount) / Double(micMono.count)

        for i in 0..<newMicCount {
            let srcPos = Double(i) / stretchRatio
            let idx = Int(srcPos)
            let frac = srcPos - Double(idx)
            if idx + 1 < micMono.count {
                stretched[i] = Float(Double(micMono[idx]) * (1 - frac) + Double(micMono[idx + 1]) * frac)
            } else if idx < micMono.count {
                stretched[i] = micMono[idx]
            }
        }
        micMono = stretched
    } else {
        print("  No significant drift detected", to: &stderr)
    }

    // ---- Apply mic gain ----
    if abs(micGain - 1.0) > 0.001 {
        let dB = 20 * log10(micGain)
        print("  Mic gain: \(String(format: "%.1f", dB)) dB", to: &stderr)
        var gain = micGain
        vDSP_vsmul(micMono, 1, &gain, &micMono, 1, vDSP_Length(micMono.count))
    }

    // ---- Mix to stereo: mic left, system right ----
    let outFrames = max(sysMono.count, micMono.count)
    var stereo = [Float](repeating: 0, count: outFrames * 2)

    for f in 0..<outFrames {
        // Left channel = mic (padded with silence if shorter)
        if f < micMono.count {
            stereo[f * 2] = micMono[f]
        }
        // Right channel = system (padded with silence if shorter)
        if f < sysMono.count {
            stereo[f * 2 + 1] = sysMono[f]
        }
    }

    return MixResult(samples: stereo, frameCount: outFrames, sampleRate: outRate)
}

// MARK: - WAV writing

extension MixResult {
    /// Write as stereo WAV file.
    func writeWav(path: String) throws {
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 2
        let blockAlign = channels * (bitsPerSample / 8)
        var byteRate = UInt32(sampleRate * Float64(blockAlign))
        let dataSize = frameCount * Int(blockAlign)
        var chunkSize = UInt32(dataSize) + 36

        // Convert float samples to SInt16
        var intSamples = [Int16](repeating: 0, count: frameCount * 2)
        for i in 0..<samples.count {
            var s = samples[i]
            s = max(-1.0, min(1.0, s))
            intSamples[i] = Int16(s * 32767.0)
        }

        var header = Data()
        header.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: &chunkSize) { header.append(contentsOf: $0) }
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        var fmtLen = UInt32(16)
        var fmtTag = UInt16(1)
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
        header.append(contentsOf: "data".utf8)
        var d32 = UInt32(dataSize)
        withUnsafeBytes(of: &d32) { header.append(contentsOf: $0) }

        var wavData = header
        wavData.append(contentsOf: Data(bytes: &intSamples, count: intSamples.count * MemoryLayout<Int16>.size))

        try wavData.write(to: URL(fileURLWithPath: path))
    }

}

// MARK: - Extension-based output

/// Mix system and mic WAVs and write to a file, auto-detecting output format
/// from the file extension.
/// - `.wav` → stereo WAV
/// - `.m4a` → AAC in M4A container
/// - Other → WAV (with a warning)
func mixToFile(sysPath: String, micPath: String, outputPath: String, micGain: Float = 1.0) throws {
    let sysWav = try WavFile.read(path: sysPath)
    let micWav = try WavFile.read(path: micPath)
    let result = try mix(system: sysWav, mic: micWav, micGain: micGain)

    let ext = (outputPath as NSString).pathExtension.lowercased()

    switch ext {
    case "m4a":
        // Mix to temp WAV, then encode
        let tempWav = "\(NSTemporaryDirectory())rec_mix_temp_\(ProcessInfo().globallyUniqueString).wav"
        defer { try? FileManager.default.removeItem(atPath: tempWav) }
        try result.writeWav(path: tempWav)
        if encodeToAAC(wavPath: tempWav, outputPath: outputPath) {
            print("Done: \(outputPath) (AAC)", to: &stderr)
        } else {
            // Fallback: copy WAV with .wav extension
            let fallback = (outputPath as NSString).deletingPathExtension + ".wav"
            try result.writeWav(path: fallback)
            print("Encoding failed, wrote WAV: \(fallback)", to: &stderr)
        }
    default:
        // .wav or unknown → write WAV
        try result.writeWav(path: outputPath)
        print("Done: \(outputPath)", to: &stderr)
    }

    print("  \(result.frameCount) frames, \(Int(result.sampleRate)) Hz", to: &stderr)
}

