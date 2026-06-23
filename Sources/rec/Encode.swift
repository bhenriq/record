// Encode.swift — compressed audio encoding (MP3 via lame, M4A via afconvert)

import Foundation

/// Result of encoding a WAV to a compressed format.
enum AudioEncodeResult {
    case mp3(path: String)
    case m4a(path: String)
    case skipped(reason: String)
}

/// Try to encode a WAV to a compressed audio format.
/// - Tries `lame` first for MP3
/// - Falls back to `afconvert` for M4A (always available on macOS)
/// - If neither works, returns `.skipped`
func encodeAudio(wavPath: String, outputBase: String) -> AudioEncodeResult {
    guard FileManager.default.fileExists(atPath: wavPath) else {
        return .skipped(reason: "WAV not found: \(wavPath)")
    }

    // Try lame for MP3
    if hasTool("lame") {
        let mp3Path = "\(outputBase).mp3"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["lame", "-h", "-b", "128", wavPath, mp3Path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return .mp3(path: mp3Path)
            }
        } catch {
            // lame failed, fall through
        }
    }

    // Fall back to afconvert for M4A (built into macOS)
    let m4aPath = "\(outputBase).m4a"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "afconvert", "-f", "m4af", "-d", "aac", "-b", "128000",
        wavPath, m4aPath
    ]

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return .m4a(path: m4aPath)
        }
    } catch {}

    return .skipped(reason: "no encoder available (install lame or use afconvert)")
}

private func hasTool(_ name: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["which", name]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}
