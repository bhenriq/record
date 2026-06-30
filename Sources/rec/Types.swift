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
    private var _sysRate: Float64 = 0
    private var _micRate: Float64 = 0
    private let _startTime = Date()
    private var _done = false

    var sysFrames: UInt64 { lockedRead { _sysFrames } }
    var micFrames: UInt64 { lockedRead { _micFrames } }
    var sysRms: Float { lockedRead { _sysRms } }
    var micRms: Float { lockedRead { _micRms } }
    var elapsedSec: Double { -_startTime.timeIntervalSinceNow }
    var done: Bool { lockedRead { _done } }

    /// Drift percentage based on frame counts, normalized by sample rate.
    /// Returns 0 if fewer than ~0.5s of audio have been captured.
    var driftPercent: Double {
        let s = Double(sysFrames), m = Double(micFrames)
        let sr = _sysRate > 0 ? _sysRate : 48000
        let mr = _micRate > 0 ? _micRate : 48000
        let sysSec = s / sr
        let micSec = m / mr
        guard sysSec > 1.0, micSec > 1.0 else { return 0 }
        return abs(sysSec - micSec) / max(sysSec, micSec) * 100
    }

    func update(sysFrames: UInt64, micFrames: UInt64, sysRms: Float, micRms: Float) {
        lock.lock()
        _sysFrames = sysFrames
        _micFrames = micFrames
        _sysRms = sysRms
        _micRms = micRms
        lock.unlock()
    }

    func setRates(sys: Float64, mic: Float64) {
        lock.lock()
        _sysRate = sys
        _micRate = mic
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

// MARK: - Time anchors for drift correction

/// A single time anchor point captured during recording.
/// Records the wall-clock time and cumulative frame counts for both
/// system and microphone at a moment in time.
struct TimeAnchor: Codable {
    let wallSec: TimeInterval     // seconds since capture start
    let sysFrames: UInt64         // total frames written to sys WAV so far
    let micFrames: UInt64         // total frames written to mic WAV so far
}

/// A set of time anchors with sample rates, used to map audio sample
/// offsets to real wall-clock time via interpolation.
struct TimeAnchorSet: Codable {
    let sysRate: Float64
    let micRate: Float64
    let anchors: [TimeAnchor]

    /// Map a system-audio time offset (seconds into the system WAV) to
    /// wall time (seconds since capture start).
    func systemTimeToWall(_ t: Double) -> TimeInterval {
        let sampleOffset = UInt64(t * sysRate)
        return interpolateFrames(sampleOffset, keyPath: \.sysFrames)
    }

    /// Map a mic-audio time offset (seconds into the mic WAV) to
    /// wall time (seconds since capture start).
    func micTimeToWall(_ t: Double) -> TimeInterval {
        let sampleOffset = UInt64(t * micRate)
        return interpolateFrames(sampleOffset, keyPath: \.micFrames)
    }

    /// The wall time at which the very first audio frames were captured.
    var startWallSec: TimeInterval {
        anchors.first?.wallSec ?? 0
    }

    /// Duration of the recording in wall-clock seconds.
    var duration: TimeInterval {
        (anchors.last?.wallSec ?? 0) - startWallSec
    }

    // MARK: - Interpolation

    private func interpolateFrames(_ target: UInt64, keyPath: KeyPath<TimeAnchor, UInt64>) -> TimeInterval {
        guard anchors.count >= 2 else {
            // With a single anchor, assume no drift
            return anchors.first?.wallSec ?? 0
        }

        // Find the insertion point
        var lo = 0
        var hi = anchors.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if anchors[mid][keyPath: keyPath] < target {
                lo = mid + 1
            } else {
                hi = mid
            }
        }

        let idx = lo

        if idx == 0 {
            // Before first anchor → extrapolate backward from first two
            let a0 = anchors[0]
            let a1 = anchors[1]
            let f0 = Double(a0[keyPath: keyPath])
            let f1 = Double(a1[keyPath: keyPath])
            let frameDelta = f1 - f0
            guard frameDelta > 0 else { return a0.wallSec }
            let fraction = (Double(target) - f0) / frameDelta
            return a0.wallSec + fraction * (a1.wallSec - a0.wallSec)
        } else if idx >= anchors.count {
            // Past last anchor → extrapolate forward from last two
            let a0 = anchors[anchors.count - 2]
            let a1 = anchors[anchors.count - 1]
            let f0 = Double(a0[keyPath: keyPath])
            let f1 = Double(a1[keyPath: keyPath])
            let frameDelta = f1 - f0
            guard frameDelta > 0 else { return a1.wallSec }
            let fraction = (Double(target) - f0) / frameDelta
            // Clamp to avoid extreme extrapolation
            let result = a0.wallSec + fraction * (a1.wallSec - a0.wallSec)
            return max(result, a0.wallSec)
        } else {
            // Between anchors — linear interpolation
            let a0 = anchors[idx - 1]
            let a1 = anchors[idx]
            let f0 = Double(a0[keyPath: keyPath])
            let f1 = Double(a1[keyPath: keyPath])
            let frameDelta = f1 - f0
            guard frameDelta > 0 else { return a0.wallSec }
            let fraction = (Double(target) - f0) / frameDelta
            return a0.wallSec + fraction * (a1.wallSec - a0.wallSec)
        }
    }
}

/// Default anchor file name written alongside scratch WAVs.
let kAnchorFileName = "anchors.json"

// MARK: - Save / load anchors

/// Write time anchors to a JSON file.
func saveAnchors(_ anchors: TimeAnchorSet, to path: String) throws {
    let data = try JSONEncoder().encode(anchors)
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

/// Load time anchors from a JSON file.
func loadAnchors(from path: String) -> TimeAnchorSet? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(TimeAnchorSet.self, from: data)
}

/// Threshold above which drift is flagged (0.5%).
let kDriftThreshold: Double = 0.5
