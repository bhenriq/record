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

// MARK: - Live capture status

/// Thread-safe shared state updated by the capture writer loop and read by the display.
class CaptureStatus {
    private let lock = NSLock()
    private var _sysFrames: UInt64 = 0
    private var _micFrames: UInt64 = 0
    private var _sysRms: Float = 0
    private var _micRms: Float = 0
    private let _startTime = Date()
    private var _done = false

    var sysFrames: UInt64 { lockedRead { _sysFrames } }
    var micFrames: UInt64 { lockedRead { _micFrames } }
    var sysRms: Float { lockedRead { _sysRms } }
    var micRms: Float { lockedRead { _micRms } }
    var elapsedSec: Double { -_startTime.timeIntervalSinceNow }
    var done: Bool { lockedRead { _done } }

    /// Drift percentage based on frame counts.
    /// Returns 0 if fewer than 100 frames have been captured (too early to be meaningful).
    var driftPercent: Double {
        let s = Double(sysFrames), m = Double(micFrames)
        guard s > 100, m > 100 else { return 0 }
        return abs(s - m) / max(s, m) * 100
    }

    func update(sysFrames: UInt64, micFrames: UInt64, sysRms: Float, micRms: Float) {
        lock.lock()
        _sysFrames = sysFrames
        _micFrames = micFrames
        _sysRms = sysRms
        _micRms = micRms
        lock.unlock()
    }

    func markDone() { lockedWrite { _done = true } }

    private func lockedRead<T>(_ fn: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return fn()
    }

    private func lockedWrite(_ fn: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        fn()
    }
}

/// Threshold above which drift is flagged (0.5%).
let kDriftThreshold: Double = 0.5
