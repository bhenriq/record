// Encode.swift — compressed audio encoding via afconvert (AAC/M4A)
//
// Uses afconvert (built into macOS) for lossy compression.
// No external dependencies.

import Foundation

/// Encode a WAV file to AAC in M4A container.
/// - Returns: true on success, false on failure.
func encodeToAAC(wavPath: String, outputPath: String) -> Bool {
    guard FileManager.default.fileExists(atPath: wavPath) else {
        print("  WAV not found: \(wavPath)", to: &stderr)
        return false
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "afconvert", "-f", "m4af", "-d", "aac", "-b", "128000",
        wavPath, outputPath
    ]

    let pipe = Pipe()
    process.standardError = pipe

    do {
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return true
        }
        let err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("  afconvert failed: \(err.trimmingCharacters(in: .whitespacesAndNewlines))", to: &stderr)
        return false
    } catch {
        print("  afconvert error: \(error.localizedDescription)", to: &stderr)
        return false
    }
}
