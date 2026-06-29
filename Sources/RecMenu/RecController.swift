// RecController.swift — Manages the rec subprocess and pidfile status polling

import AppKit
import Foundation
import UserNotifications

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
    private let recBinaryPath: String?
    private var startTime: Date?

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
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleTermination()
            }
        }

        do {
            try proc.run()
            process = proc
            state = .recording
            startPidfileWatcher()
        } catch {
            state = .error("Failed to launch rec: \(error.localizedDescription)")
        }
    }

    /// Stop the current recording (sends SIGINT for graceful stop).
    func stop() {
        switch state {
        case .recording:
            process?.interrupt() // SIGINT → graceful stop, pipeline continues
            // Don't change state — pidfile watcher will pick up processing/done
        case .processing:
            // Still processing — can't stop gracefully, but we can kill
            process?.terminate() // SIGTERM
            cleanup()
        case .error:
            cleanup()
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
            if state.isActive {
                cleanup()
                state = .idle
            }
            return
        }

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
            // Don't clean up yet — let user see the error
            // Clean up after a delay or on next action
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
        pollPidfile()
        if state.isActive {
            cleanup()
            state = .idle
        }
    }

    private func cleanup() {
        pidfileTimer?.invalidate()
        pidfileTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        process = nil
        startTime = nil
    }

    // MARK: - Helpers

    /// Find the `rec` binary by checking common paths and $PATH.
    private static func findRecBinary() -> String? {
        let candidates = [
            "/usr/local/bin/rec",
            "/opt/homebrew/bin/rec",
            "\(NSHomeDirectory())/.local/bin/rec",
            "\(NSHomeDirectory())/bin/rec",
            "\(NSHomeDirectory())/.brew/bin/rec",
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
