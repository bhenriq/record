// Transcribe.swift — transcribe system + mic WAVs with speaker labels
//
// Uses `yap` for on-device speech recognition, then merges the two
// transcriptions into a single interleaved output with speaker labels.
// Output formats: txt, srt, vtt, json.

import Foundation

// MARK: - Yap JSON output structures

struct YapTranscript: Codable {
    var metadata: YapMetadata
    var segments: [YapSegment]
}

struct YapMetadata: Codable {
    let created: String
    var duration: Double?
    let language: String?
}

struct YapSegment: Codable {
    let id: Int
    var start: Double
    var end: Double
    let text: String
    var words: [YapWord]?
}

struct YapWord: Codable {
    let text: String
    var start: Double
    var end: Double
}

// MARK: - Merged transcript

struct MergedSegment: Codable {
    var id: Int
    let start: Double
    let end: Double
    let speaker: String
    let text: String
}

struct MergedResult: Codable {
    let metadata: MergedMetadata
    let segments: [MergedSegment]
}

struct MergedMetadata: Codable {
    let created: String
    let duration: Double
    let language: String
    let sources: [String]
}

// MARK: - Transcription

struct TranscribeConfig {
    var baseName = "output"
    var format: TranscriptFormat = .txt
    var locale: String?
    var outputDir = "."

    /// Explicit path overrides (if non-nil, used instead of computed paths)
    var systemWavOverride: String?
    var micWavOverride: String?
    var transcriptOverride: String?
    var anchorsPath: String?    // path to time-anchor JSON for drift correction

    var systemWav: String { systemWavOverride ?? "\(outputDir)/\(baseName)_sys.wav" }
    var micWav: String { micWavOverride ?? "\(outputDir)/\(baseName)_mic.wav" }
    var outputPath: String { transcriptOverride ?? "\(outputDir)/\(baseName)_transcript.\(format.rawValue)" }
}

/// Run the full transcription pipeline.
func transcribe(config: TranscribeConfig) throws {
    let sysPath = config.systemWav
    let micPath = config.micWav

    let sysExists = FileManager.default.fileExists(atPath: sysPath)
    let micExists = FileManager.default.fileExists(atPath: micPath)

    guard sysExists || micExists else {
        throw RecError.general("neither \(sysPath) nor \(micPath) found")
    }

    print("Inputs:", to: &stderr)
    if sysExists { print("  system:  \(sysPath)", to: &stderr) }
    if micExists { print("  mic:     \(micPath)", to: &stderr) }
    print("  format:  \(config.format.rawValue)", to: &stderr)

    // Check for yap
    guard which("yap") != nil else {
        throw RecError.toolNotFound("yap")
    }

    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("rec_transcribe_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let sysJsonPath = tmpDir.appendingPathComponent("system.json").path
    let micJsonPath = tmpDir.appendingPathComponent("mic.json").path
    let mergedJsonPath = tmpDir.appendingPathComponent("merged.json").path

    // ---- Phase 1: transcribe ----
    if sysExists {
        print("  transcribing system audio...", to: &stderr)
        try runYap(input: sysPath, output: sysJsonPath, locale: config.locale)
    }
    if micExists {
        print("  transcribing microphone...", to: &stderr)
        try runYap(input: micPath, output: micJsonPath, locale: config.locale)
    }

    // ---- Phase 2: load time anchors or compute drift ratio ----
    var anchors: TimeAnchorSet?
    if let anchorsPath = config.anchorsPath, let loaded = loadAnchors(from: anchorsPath) {
        anchors = loaded
        print("  time anchors: \(loaded.anchors.count) points (sys \(Int(loaded.sysRate)) Hz, mic \(Int(loaded.micRate)) Hz)", to: &stderr)
        if loaded.anchors.count > 2 {
            let total = loaded.duration
            let sysSec = Double(loaded.anchors.last!.sysFrames) / loaded.sysRate
            let drift = abs(total - sysSec) / max(total, sysSec) * 100
            if drift > 0.05 {
                print("  drift from anchors: \(String(format: "%.3f", drift))%", to: &stderr)
            } else {
                print("  no significant drift", to: &stderr)
            }
        }
    }

    var ratio: Double = 1.0
    if sysExists && micExists {
        if anchors == nil {
            // Fallback: compute ratio from WAV durations (same as mix phase)
            let sysWavFile = try WavFile.read(path: sysPath)
            let micWavFile = try WavFile.read(path: micPath)
            let sysSec = Double(sysWavFile.frames) / sysWavFile.sampleRate
            let micSec = Double(micWavFile.frames) / micWavFile.sampleRate
            if micSec > 0 {
                ratio = sysSec / micSec
                let drift = abs(ratio - 1.0)
                if drift > 0.0001 {
                    print("  drift correction (WAV ratio): ratio=\(String(format: "%.6f", ratio)) (\(String(format: "%.2f", drift * 100))%)", to: &stderr)
                } else {
                    print("  no significant drift detected", to: &stderr)
                }
            }
        }
        // When anchors are available, ratio is not used — timestamps are
        // mapped via anchor interpolation instead.
    }

    // ---- Phase 3: merge ----
    if sysExists && micExists {
        let sysData = try Data(contentsOf: URL(fileURLWithPath: sysJsonPath))
        let micData = try Data(contentsOf: URL(fileURLWithPath: micJsonPath))
        let sysYap = try JSONDecoder().decode(YapTranscript.self, from: sysData)
        let micYap = try JSONDecoder().decode(YapTranscript.self, from: micData)

        let merged = mergeTranscripts(system: sysYap, mic: micYap, ratio: ratio, anchors: anchors)
        let mergedData = try JSONEncoder().encode(merged)
        try mergedData.write(to: URL(fileURLWithPath: mergedJsonPath))
    } else if sysExists {
        try FileManager.default.copyItem(atPath: sysJsonPath, toPath: mergedJsonPath)
    } else if micExists {
        // Load mic JSON and adjust timestamps
        var micYap = try JSONDecoder().decode(YapTranscript.self, from: try Data(contentsOf: URL(fileURLWithPath: micJsonPath)))
        if let anchors = anchors {
            // Map mic timestamps via anchor interpolation
            if micYap.metadata.duration != nil {
                micYap.metadata.duration! = anchors.micTimeToWall(micYap.metadata.duration!) - anchors.startWallSec
            }
            for i in micYap.segments.indices {
                let newStart = anchors.micTimeToWall(micYap.segments[i].start) - anchors.startWallSec
                let newEnd = anchors.micTimeToWall(micYap.segments[i].end) - anchors.startWallSec
                micYap.segments[i].start = newStart
                micYap.segments[i].end = newEnd
                if let words = micYap.segments[i].words {
                    for j in words.indices {
                        micYap.segments[i].words![j].start = anchors.micTimeToWall(micYap.segments[i].words![j].start) - anchors.startWallSec
                        micYap.segments[i].words![j].end = anchors.micTimeToWall(micYap.segments[i].words![j].end) - anchors.startWallSec
                    }
                }
            }
        } else {
            // Fallback: adjust by ratio
            if micYap.metadata.duration != nil { micYap.metadata.duration! *= ratio }
            for i in micYap.segments.indices {
                micYap.segments[i].start *= ratio
                micYap.segments[i].end *= ratio
                if let words = micYap.segments[i].words {
                    for j in words.indices {
                        micYap.segments[i].words![j].start *= ratio
                        micYap.segments[i].words![j].end *= ratio
                    }
                }
            }
        }
        let mergedData = try JSONEncoder().encode(micYap)
        try mergedData.write(to: URL(fileURLWithPath: mergedJsonPath))
    }

    // ---- Phase 4: format output ----
    let mergedData = try Data(contentsOf: URL(fileURLWithPath: mergedJsonPath))
    try formatOutput(data: mergedData, config: config, ratio: ratio, anchors: anchors)
}

// MARK: - Yap subprocess

private func runYap(input: String, output: String, locale: String?) throws {
    var args = ["transcribe", "--json", "--word-timestamps"]
    if let locale = locale { args += ["--locale", locale] }
    args += [input, "--output-file", output]

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["yap"] + args

    // Discard stdout (yap writes JSON there, but we use --output-file).
    // Keep stderr visible so the user sees progress bars.
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.standardError

    do {
        try process.run()
    } catch {
        throw RecError.general("'yap' not found. Install: brew install yap")
    }
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw RecError.transcriptionFailed("yap exited with code \(process.terminationStatus)")
    }
}

// MARK: - Merge logic

private func mergeTranscripts(system sys: YapTranscript, mic: YapTranscript, ratio: Double, anchors: TimeAnchorSet? = nil) -> MergedResult {
    let created = sys.metadata.created
    let duration: Double
    if let anchors = anchors {
        // Use wall-clock duration from anchors when available
        duration = anchors.duration
    } else {
        let sysDuration = sys.metadata.duration ?? 0
        let micDurationAdjusted = (mic.metadata.duration ?? 0) * ratio
        duration = max(sysDuration, micDurationAdjusted)
    }
    let language: String
    if let lang = sys.metadata.language, !lang.isEmpty {
        language = lang
    } else {
        language = "unknown"
    }

    var segments: [MergedSegment] = []

    // System segments get "System" speaker
    for seg in sys.segments {
        if let anchors = anchors {
            let newStart = anchors.systemTimeToWall(seg.start) - anchors.startWallSec
            let newEnd = anchors.systemTimeToWall(seg.end) - anchors.startWallSec
            segments.append(MergedSegment(
                id: 0, start: newStart, end: newEnd,
                speaker: "System", text: seg.text
            ))
        } else {
            segments.append(MergedSegment(
                id: 0, start: seg.start, end: seg.end,
                speaker: "System", text: seg.text
            ))
        }
    }

    // Mic segments get "Mic" speaker with adjusted timestamps
    for seg in mic.segments {
        if let anchors = anchors {
            let newStart = anchors.micTimeToWall(seg.start) - anchors.startWallSec
            let newEnd = anchors.micTimeToWall(seg.end) - anchors.startWallSec
            segments.append(MergedSegment(
                id: 0, start: newStart, end: newEnd,
                speaker: "Mic", text: seg.text
            ))
        } else {
            segments.append(MergedSegment(
                id: 0,
                start: seg.start * ratio,
                end: seg.end * ratio,
                speaker: "Mic",
                text: seg.text
            ))
        }
    }

    // Sort by start time, reassign IDs
    segments.sort { $0.start < $1.start }
    for i in segments.indices {
        segments[i].id = i + 1
    }

    return MergedResult(
        metadata: MergedMetadata(
            created: created,
            duration: duration,
            language: language,
            sources: ["system", "mic"]
        ),
        segments: segments
    )
}

// MARK: - Format output

private func formatOutput(data: Data, config: TranscribeConfig, ratio: Double, anchors: TimeAnchorSet? = nil) throws {
    let decoder = JSONDecoder()

    switch config.format {
    case .json:
        try data.write(to: URL(fileURLWithPath: config.outputPath))

    case .txt:
        let merged = try decoder.decode(MergedResult.self, from: data)
        var lines: [String] = []
        var prevSpeaker: String?

        for seg in merged.segments {
            let label = seg.speaker == "System" ? "Them" : "Me"
            if label == prevSpeaker {
                // Append to last line
                if let last = lines.last {
                    let lastContent = last.split(separator: ":", maxSplits: 1).dropFirst().joined()
                    lines[lines.count - 1] = "\(label): \(lastContent.trimmingCharacters(in: .whitespaces)) \(seg.text)"
                }
            } else {
                lines.append("\(label): \(seg.text)")
            }
            prevSpeaker = label
        }
        try lines.joined(separator: "\n").write(toFile: config.outputPath, atomically: true, encoding: .utf8)

    case .srt:
        let merged = try decoder.decode(MergedResult.self, from: data)
        var output = ""
        for seg in merged.segments {
            output += "\(seg.id)\n"
            output += "\(formatSrtTime(seg.start)) --> \(formatSrtTime(seg.end))\n"
            output += "[\(seg.speaker)] \(seg.text)\n\n"
        }
        try output.write(toFile: config.outputPath, atomically: true, encoding: .utf8)

    case .vtt:
        let merged = try decoder.decode(MergedResult.self, from: data)
        var output = "WEBVTT\n\n"
        for seg in merged.segments {
            output += "\(formatVttTime(seg.start)) --> \(formatVttTime(seg.end))\n"
            output += "[\(seg.speaker)] \(seg.text)\n\n"
        }
        try output.write(toFile: config.outputPath, atomically: true, encoding: .utf8)
    }

    print("Done: \(config.outputPath)", to: &stderr)
}

private func formatSrtTime(_ seconds: Double) -> String {
    let h = Int(seconds) / 3600
    let m = (Int(seconds) % 3600) / 60
    let s = Int(seconds) % 60
    let ms = Int((seconds - Double(Int(seconds))) * 1000)
    return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
}

private func formatVttTime(_ seconds: Double) -> String {
    let h = Int(seconds) / 3600
    let m = (Int(seconds) % 3600) / 60
    let s = Int(seconds) % 60
    let ms = Int((seconds - Double(Int(seconds))) * 1000)
    return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
}

// MARK: - Helper

private func which(_ name: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [name]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data.trimmingTrailingWhitespace(), encoding: .utf8)
}

private extension Data {
    func trimmingTrailingWhitespace() -> Data {
        guard count > 0 else { return self }
        var end = count - 1
        while end >= 0 && self[end] <= 32 { end -= 1 }
        return self[0...end]
    }
}
