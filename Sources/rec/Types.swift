// Types.swift — shared types for the rec toolchain

import Foundation

/// Output format for transcripts.
enum TranscriptFormat: String {
    case txt
    case srt
    case vtt
    case json
}

/// Represents a segment in a merged transcript.
struct TranscriptSegment: Codable {
    let id: Int
    let start: Double
    let end: Double
    let speaker: String
    let text: String
}

/// Merged transcript output from yap + merge logic.
struct MergedTranscript: Codable {
    let metadata: TranscriptMetadata
    let segments: [TranscriptSegment]
}

struct TranscriptMetadata: Codable {
    let created: String
    let duration: Double
    let language: String
    let sources: [String]
}

// MARK: - Output directory resolution

/// Resolve the output directory for final deliverables.
/// Order of precedence: `--output-dir` flag > `REC_DIR` env var > default `~/Documents/Recordings/`
func resolveOutputDir(flag: String?) -> String {
    if let dir = flag, !dir.isEmpty {
        return (dir as NSString).expandingTildeInPath
    }
    if let envDir = ProcessInfo.processInfo.environment["REC_DIR"], !envDir.isEmpty {
        return (envDir as NSString).expandingTildeInPath
    }
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent("Documents/Recordings").path
}

/// Create a temporary directory for scratch files during a recording session.
/// The directory is created in the system temp dir with a `rec.` prefix.
func createTempDir() throws -> String {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("rec.\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    return tmpDir.path
}

/// Remove a temporary directory if it exists.
func cleanupTempDir(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}
