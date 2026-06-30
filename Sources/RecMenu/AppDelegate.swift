// AppDelegate.swift — Menu bar companion for rec
//
// A lightweight macOS menu bar app that:
//   - Shows a status dot (gray idle, red recording, orange processing)
//   - Click toggles recording on/off
//   - Polls rec's pidfile for real-time status
//   - Requests microphone and screen-recording permissions on first launch
//
// All dependencies are built-in macOS frameworks (AppKit, AVFoundation,
// CoreGraphics, UserNotifications). No third-party dependencies.

import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import UserNotifications

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private let statusItem = NSStatusBar.system.statusItem(withLength: 22)
    private let controller = RecController()

    // Menu items we need to update dynamically
    private var toggleMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var elapsedMenuItem: NSMenuItem!
    private var elapsedTextField: NSTextField!

    // Current state
    private var currentState: RecState = .idle

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {

        
        // Request notification permissions (for orphan adoption alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        // --- Status item setup ---
        updateIcon(state: .idle)

        // --- Menu setup ---
        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // Custom view for live-updating elapsed time inside the menu
        let elapsedView = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        elapsedTextField = NSTextField(labelWithString: "00:00")
        elapsedTextField.frame = NSRect(x: 15, y: 2, width: 90, height: 18)
        elapsedTextField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        elapsedTextField.textColor = NSColor.secondaryLabelColor
        elapsedView.addSubview(elapsedTextField)
        elapsedMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        elapsedMenuItem.isEnabled = false
        elapsedMenuItem.isHidden = true
        elapsedMenuItem.view = elapsedView
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

        // --- Proactively request permissions needed for recording ---
        // This ensures permission prompts appear at first launch (before the
        // user clicks "Start Recording") so there's no surprise delay later.

        // Microphone: for capturing the user's voice.
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            NSLog("RecMenu: microphone access \(granted ? "granted" : "denied")")
        }

        // Screen Recording: required by CoreAudio's process tap to capture
        // system audio from other apps (e.g. browser meetings, video calls).
        // This triggers the system permission prompt if not already granted.
        CGRequestScreenCaptureAccess()

        NSLog("RecMenu: applicationDidFinishLaunching complete, isActive=\(controller.state.isActive)")
    }

    // MARK: - Actions

    @objc private func toggleRecording() {

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
                guard let self = self else { return }
                self.elapsedTextField.stringValue = elapsed
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
