// AppDelegate.swift — Menu bar companion for rec
//
// A lightweight macOS menu bar app that:
//   - Shows a status dot (gray idle, red recording, orange processing)
//   - Click toggles recording on/off
//   - Polls rec's pidfile for real-time status
//
// Built with AppKit — no external dependencies beyond macOS SDK.

import AppKit
import Foundation
import UserNotifications

// MARK: - Debug log

private let debugLogURL = URL(fileURLWithPath: "\(NSHomeDirectory())/.rec/debug.log")

private func debugLog(_ message: String) {
    let line = "\(Date()) [RecMenu] \(message)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: debugLogURL.path) {
            if let fh = try? FileHandle(forWritingTo: debugLogURL) {
                fh.seekToEndOfFile()
                fh.write(data)
                fh.closeFile()
            }
        } else {
            try? data.write(to: debugLogURL)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private let statusItem = NSStatusBar.system.statusItem(withLength: 22)
    private let controller = RecController()

    // Menu items we need to update dynamically
    private var toggleMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var elapsedMenuItem: NSMenuItem!

    // Current state
    private var currentState: RecState = .idle

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug log to file
        debugLog("applicationDidFinishLaunching")
        debugLog("recBinaryPath=\(String(describing: controller.recBinaryPathDebug))")
        debugLog("pidfilePath=\(controller.pidfilePathDebug)")
        
        // Request notification permissions (for orphan adoption alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        // --- Status item setup ---
        updateIcon(state: .idle)

        // --- Menu setup ---
        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        elapsedMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        elapsedMenuItem.isEnabled = false
        elapsedMenuItem.isHidden = true
        menu.addItem(elapsedMenuItem)

        menu.addItem(NSMenuItem.separator())

        toggleMenuItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
        toggleMenuItem.target = self
        toggleMenuItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(title: "Open Recordings Folder…", action: #selector(openRecordingsFolder), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        // --- Wire up controller ---
        controller.onStateChange = { [weak self] state in
            self?.handleStateChange(state)
        }

        // --- Check for orphaned recording on launch ---
        controller.checkForOrphaned()

        NSLog("RecMenu: applicationDidFinishLaunching complete, isActive=\(controller.state.isActive)")
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        debugLog("toggleRecording: state=\(controller.state)")
        switch controller.state {
        case .idle:
            controller.start()
        case .recording:
            controller.stop()
        case .processing, .error:
            controller.stop()
        }
    }

    @objc private func openRecordingsFolder(_ sender: Any?) {
        let url = URL(fileURLWithPath: "\(NSHomeDirectory())/Documents/Recordings")
        NSWorkspace.shared.open(url)
    }

    // MARK: - State handling

    private func handleStateChange(_ state: RecState) {
        debugLog("handleStateChange => \(state)")
        currentState = state
        updateIcon(state: state)

        switch state {
        case .idle:
            statusMenuItem.title = "Ready"
            toggleMenuItem.title = "Start Recording"
            elapsedMenuItem.isHidden = true

        case .recording:
            statusMenuItem.title = "Recording…"
            toggleMenuItem.title = "Stop Recording"
            elapsedMenuItem.isHidden = false
            controller.startElapsedTimer { [weak self] elapsed in
                self?.elapsedMenuItem.title = elapsed
            }

        case .processing(let step):
            statusMenuItem.title = "Processing: \(step)"
            toggleMenuItem.title = "Stop"
            elapsedMenuItem.isHidden = true

        case .error(let msg):
            statusMenuItem.title = "Error: \(msg.prefix(40))"
            toggleMenuItem.title = "Dismiss"
            elapsedMenuItem.isHidden = true
        }
    }

    // MARK: - Icon rendering

    private func updateIcon(state: RecState) {
        statusItem.button?.image = Self.renderIcon(state: state)
    }

    /// Programmatically draw the status icon as an NSImage.
    private static func renderIcon(state: RecState) -> NSImage {
        let size = CGSize(width: 18, height: 18)
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 6
            let dotRect = CGRect(x: center.x - radius, y: center.y - radius,
                                 width: radius * 2, height: radius * 2)

            switch state {
            case .idle:
                ctx.setFillColor(NSColor.placeholderTextColor.cgColor)
                ctx.fillEllipse(in: dotRect)

            case .recording:
                // Solid red dot — no pulse, no inner white dot
                ctx.setFillColor(NSColor(red: 0.75, green: 0.12, blue: 0.12, alpha: 1.0).cgColor)
                ctx.fillEllipse(in: dotRect)

            case .processing:
                ctx.setFillColor(NSColor.systemOrange.cgColor)
                ctx.fillEllipse(in: dotRect)

            case .error:
                ctx.setFillColor(NSColor.systemBrown.cgColor)
                ctx.fillEllipse(in: dotRect)
                let exclamation = "!" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: 11),
                    .foregroundColor: NSColor.white
                ]
                let exSize = exclamation.size(withAttributes: attrs)
                exclamation.draw(
                    at: CGPoint(x: center.x - exSize.width / 2, y: center.y - exSize.height / 2),
                    withAttributes: attrs
                )
            }

            return true
        }
    }
}

// MARK: - State enum

enum RecState: Equatable {
    case idle
    case recording
    case processing(String)
    case error(String)

    static func == (lhs: RecState, rhs: RecState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.recording, .recording): return true
        case (.processing, .processing): return true
        case (.error, .error): return true
        default: return false
        }
    }
}
