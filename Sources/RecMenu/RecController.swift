// RecController.swift — Manages the rec subprocess and pidfile status polling

import AppKit
import Foundation
import UserNotifications

// MARK: - Debug log

private let controllerLogURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.rec/controller.log")
private let dateFmt: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

private func clog(_ message: String) {
    let line = "\(dateFmt.string(from: Date())) \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: controllerLogURL.path) {
            if let fh = try? FileHandle(forWritingTo: controllerLogURL) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            try? data.write(to: controllerLogURL)
        }
    }
}

// MARK: - Pidfile type (mirrors rec's RecPidfile)

private struct RecPidfileStatus: Codable {
    let pid: Int32
    let startTime: Date
    let command: String
    var state: String
    var tempDir: String
    var outputDir: String?
    var session: String?
    var errorMessage: String?
}

// MARK: - RecController

class RecController {

    enum State: Equatable {
        case idle
        case recording
        case processing(String)
        case error(String)

        var isActive: Bool { self != .idle }
    }

    // MARK: - Callbacks

    var onStateChange: ((RecState) -> Void)?

    // MARK: - Properties

    private(set) var state: State = .idle {
        didSet {
            guard oldValue != state else { return }
            clog("state \(oldValue) -> \(state)")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onStateChange?(self.state.toRecState())
            }
        }
    }

    private var process: Process?
    private var pidfileTimer: Timer?
    private var elapsedTimer: Timer?
    private var elapsedCallback: ((String) -> Void)?
    private let pidfilePath: String
    /// Debug accessor for AppDelegate logging
    var pidfilePathDebug: String { pidfilePath }
    private let recBinaryPath: String?
    /// Debug accessor for AppDelegate logging
    var recBinaryPathDebug: String? { recBinaryPath }
    private var startTime: Date?
    /// PID from pidfile — used to stop orphaned recordings where process is nil
    private var trackedPID: pid_t?

    // MARK: - Init

    init() {
        pidfilePath = "\(NSHomeDirectory())/.rec/current.json"
        recBinaryPath = Self.findRecBinary()
    }

    // MARK: - Public API

    /// Start a new recording.
    func start() {
        guard let binary = recBinaryPath else {
            state = .error("rec binary not found on PATH")
            return
        }
        guard case .idle = state else { return }

        startTime = Date()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--pidfile", pidfilePath]
        // Ensure Homebrew binaries are on PATH (yap etc.)
        var env = ProcessInfo.processInfo.environment
        if let existingPath = env["PATH"] {
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(existingPath)"
        } else {
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        }
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        // Capture rec stderr for debugging
        let stderrPath = "\(NSHomeDirectory())/.rec/rec-stderr.log"
        if !FileManager.default.fileExists(atPath: stderrPath) {
            FileManager.default.createFile(atPath: stderrPath, contents: nil)
        }
        if let stderrFH = FileHandle(forWritingAtPath: stderrPath) {
            stderrFH.seekToEndOfFile()
            proc.standardError = stderrFH
            clog("rec stderr -> \(stderrPath)")
        } else {
            proc.standardError = FileHandle.nullDevice
        }
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleTermination()
            }
        }

        clog("starting rec binary=\(binary) pidfile=\(pidfilePath)")
        do {
            try proc.run()
            process = proc
            trackedPID = proc.processIdentifier
            clog("rec started PID=\(proc.processIdentifier)")
            state = .recording
            startPidfileWatcher()
        } catch {
            clog("rec failed to start: \(error)")
            state = .error("Failed to launch rec: \(error.localizedDescription)")
        }
    }

    /// Stop the current recording (sends SIGINT for graceful stop).
    func stop() {
        clog("stop called, state=\(state)")
        switch state {
        case .recording:
            process?.interrupt()
            if process == nil, let pid = trackedPID {
                kill(pid, SIGINT)
            }
        case .processing:
            process?.terminate()
            if process == nil, let pid = trackedPID {
                kill(pid, SIGTERM)
            }
            cleanup()
            state = .idle
        case .error:
            cleanup()
            state = .idle
        case .idle:
            break
        }
    }

    /// Start a timer that reports elapsed recording time.
    func startElapsedTimer(callback: @escaping (String) -> Void) {
        elapsedCallback = callback
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let start = self.startTime else { return }
            let elapsed = Date().timeIntervalSince(start)
            let m = Int(elapsed) / 60
            let s = Int(elapsed) % 60
            callback(String(format: "%02d:%02d", m, s))
        }
    }

    /// Check if there's an orphaned recording from a previous launch.
    func checkForOrphaned() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pidfilePath)),
              let pidfile = try? JSONDecoder().decode(RecPidfileStatus.self, from: data)
        else { return }

        // Check if process is alive (kill with signal 0)
        if kill(pidfile.pid, 0) == 0 {
            // Process is alive — adopt it
            startTime = pidfile.startTime
            trackedPID = pidfile.pid
            state = .recording
            startPidfileWatcher()
            // Notify user via UserNotifications
            let content = UNMutableNotificationContent()
            content.title = "Recording in Progress"
            content.body = "Adopted recording started at \(Self.formatDate(pidfile.startTime))"
            let request = UNNotificationRequest(
                identifier: "rec-orphan-adopted",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        } else {
            // Stale pidfile — clean up
            try? FileManager.default.removeItem(atPath: pidfilePath)
        }
    }

    // MARK: - Private

    private func startPidfileWatcher() {
        clog("starting pidfile watcher")
        pidfileTimer?.invalidate()
        pidfileTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollPidfile()
        }
    }

    private func pollPidfile() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: pidfilePath)),
              let pidfile = try? JSONDecoder().decode(RecPidfileStatus.self, from: data)
        else {
            // Pidfile gone → pipeline finished or never started
            clog("poll: no pidfile, active=\(state.isActive)")
            if state.isActive {
                cleanup()
                state = .idle
            }
            return
        }
        clog("poll: state=\(pidfile.state)")

        // Keep track of the PID so we can stop even if the Process object is lost
        trackedPID = pidfile.pid

        switch pidfile.state {
        case "capturing":
            if state != .recording {
                startTime = pidfile.startTime
            }
            state = .recording

        case "mixing":
            state = .processing("mixing")

        case "transcribing":
            state = .processing("transcribing")

        case "summarizing":
            state = .processing("summarizing")

        case "finalizing":
            state = .processing("finalizing")

        case "done":
            cleanup()
            state = .idle

        case "error":
            state = .error(pidfile.errorMessage ?? "rec pipeline error")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.cleanup()
                if case .error = self?.state {
                    self?.state = .idle
                }
            }

        default:
            break
        }
    }

    private func handleTermination() {
        clog("handleTermination called")
        pollPidfile()
        if state.isActive {
            clog("handleTermination: still active, cleaning up")
            cleanup()
            state = .idle
        }
    }

    private func cleanup() {
        clog("cleanup called")
        pidfileTimer?.invalidate()
        pidfileTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        process = nil
        trackedPID = nil
        startTime = nil
    }

    // MARK: - Helpers

    /// Find the `rec` binary by checking common paths and $PATH.
    /// System-wide paths are preferred over user-local ones.
    private static func findRecBinary() -> String? {
        let candidates = [
            // System-wide installs (preferred)
            "/usr/local/bin/rec",
            "/opt/homebrew/bin/rec",
            // User-local installs
            "\(NSHomeDirectory())/.local/bin/rec",
            "\(NSHomeDirectory())/bin/rec",
            "\(NSHomeDirectory())/.brew/bin/rec",
            // Development builds
            "\(NSHomeDirectory())/Documents/Recordings/.build/release/rec",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        // Fall back to `which rec`
        return Self.which("rec")
    }

    private static func which(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["which", name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    private static func formatDate(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt.string(from: d)
    }
}

// MARK: - State conversion

extension RecController.State {
    func toRecState() -> RecState {
        switch self {
        case .idle:                    return .idle
        case .recording:               return .recording
        case .processing(let step):    return .processing(step)
        case .error(let msg):          return .error(msg)
        }
    }
}
