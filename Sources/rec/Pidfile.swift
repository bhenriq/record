// Pidfile.swift — JSON process tracking for the menu bar companion
//
// When rec is launched with --pidfile <path>, it writes a small JSON
// status file that the menu bar app polls to determine:
//   - Whether a recording is in progress
//   - What pipeline stage it's in (capturing, mixing, transcribing, etc.)
//   - When it started
//
// The file is deleted when the pipeline finishes successfully or is cleaned up.

import Foundation

/// Pipeline stage published via the pidfile.
enum PipelineState: String, Codable {
    case capturing
    case mixing
    case transcribing
    case summarizing
    case finalizing
    case done       // written just before file is deleted
    case error
}

/// Contents of the pidfile written by `rec --pidfile <path>`.
struct RecPidfile: Codable {
    let pid: Int32
    let startTime: Date
    let command: String       // "full", "capture"
    var state: PipelineState
    var tempDir: String
    var outputDir: String?
    var session: String?
    var errorMessage: String?
}

/// Write the pidfile. Creates parent directories if needed.
func writePidfile(path: String, _ pidfile: RecPidfile) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let data = try JSONEncoder().encode(pidfile)
    try data.write(to: url, options: .atomic)
}

/// Update the state field of an existing pidfile in-place.
/// Silently does nothing if the file can't be read (e.g. already deleted).
func updatePidfileState(path: String, state: PipelineState, errorMessage: String? = nil) {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          var pidfile = try? JSONDecoder().decode(RecPidfile.self, from: data)
    else { return }
    pidfile.state = state
    if let msg = errorMessage { pidfile.errorMessage = msg }
    // Don't leave a stale pidfile for 'done' — delete instead
    if state == .done {
        try? FileManager.default.removeItem(atPath: path)
        return
    }
    try? writePidfile(path: path, pidfile)
}

/// Remove the pidfile.
func removePidfile(path: String?) {
    guard let path = path, !path.isEmpty else { return }
    try? FileManager.default.removeItem(atPath: path)
}

/// Default pidfile location used by the menu bar app.
let defaultPidfilePath = "\(NSHomeDirectory())/.rec/current.json"
