// main.swift — Menu bar companion for rec
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

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Constants

    private static let menuIconSize: CGFloat = 18

    // MARK: - Properties

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let iconView = StatusIconView(frame: NSRect(x: 0, y: 0, width: menuIconSize + 4, height: menuIconSize + 4))
    private let controller = RecController()
    private var pulseTimer: Timer?

    // Menu items we need to update dynamically
    private var toggleMenuItem: NSMenuItem!
    private var statusMenuItem: NSMenuItem!
    private var elapsedMenuItem: NSMenuItem!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permissions (for orphan adoption alerts)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        // --- Status item setup ---
        if let button = statusItem.button {
            button.addSubview(iconView)
            // Center the icon view in the button
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: Self.menuIconSize + 4),
                iconView.heightAnchor.constraint(equalToConstant: Self.menuIconSize + 4),
            ])
        }

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
        toggleMenuItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Open Recordings Folder…", action: #selector(openRecordingsFolder), keyEquivalent: "o"))
        menu.addItem(NSMenuItem(title: "Show Last Recording…", action: #selector(showLastRecording), keyEquivalent: "l"))

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu

        // --- Wire up controller ---
        controller.onStateChange = { [weak self] state in
            self?.handleStateChange(state)
        }

        // Start pulse animation timer (runs always, icon draws based on state)
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.iconView.needsDisplay = true
        }

        // Check for orphaned recording on launch
        controller.checkForOrphaned()
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        switch controller.state {
        case .idle:
            controller.start()
        case .recording:
            controller.stop()
        case .processing, .error:
            // Tap again during processing: stop/clear
            controller.stop()
        }
    }

    @objc private func openRecordingsFolder(_ sender: Any?) {
        let url = URL(fileURLWithPath: "\(NSHomeDirectory())/Documents/Recordings")
        NSWorkspace.shared.open(url)
    }

    @objc private func showLastRecording(_ sender: Any?) {
        let url = URL(fileURLWithPath: "\(NSHomeDirectory())/Documents/Recordings")
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }

    // MARK: - State handling

    private func handleStateChange(_ state: RecState) {
        iconView.state = state

        switch state {
        case .idle:
            statusMenuItem.title = "Ready"
            toggleMenuItem.title = "Start Recording"
            elapsedMenuItem.isHidden = true
            iconView.isPulsing = false

        case .recording:
            statusMenuItem.title = "Recording…"
            toggleMenuItem.title = "Stop Recording"
            elapsedMenuItem.isHidden = false
            iconView.isPulsing = true
            // Start an elapsed-time ticker
            controller.startElapsedTimer { [weak self] elapsed in
                self?.elapsedMenuItem.title = elapsed
            }

        case .processing(let step):
            statusMenuItem.title = "Processing: \(step)"
            toggleMenuItem.title = "Stop"
            elapsedMenuItem.isHidden = true
            iconView.isPulsing = false

        case .error(let msg):
            statusMenuItem.title = "Error: \(msg.prefix(40))"
            toggleMenuItem.title = "Dismiss"
            elapsedMenuItem.isHidden = true
            iconView.isPulsing = false
        }
    }
}

// MARK: - Status Icon View

/// A small colored circle drawn in the menu bar.
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

class StatusIconView: NSView {
    var state: RecState = .idle { didSet { needsDisplay = true } }
    var isPulsing = false

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius: CGFloat = 5
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        let isPulsePhase = isPulsing && (Int(Date().timeIntervalSince1970 * 2) % 2 == 0)

        switch state {
        case .idle:
            ctx.setFillColor(NSColor.placeholderTextColor.cgColor)
            ctx.fillEllipse(in: rect)

        case .recording:
            if isPulsePhase {
                ctx.setFillColor(NSColor.red.withAlphaComponent(0.5).cgColor)
            } else {
                ctx.setFillColor(NSColor.red.cgColor)
            }
            ctx.fillEllipse(in: rect)
            // Draw a small inner dot for recording look
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3))

        case .processing:
            ctx.setFillColor(NSColor.systemOrange.cgColor)
            ctx.fillEllipse(in: rect)

        case .error:
            ctx.setFillColor(NSColor.systemBrown.cgColor)
            ctx.fillEllipse(in: rect)
            // Draw exclamation mark
            let exclamation = "!" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 10),
                .foregroundColor: NSColor.white
            ]
            let size = exclamation.size(withAttributes: attrs)
            exclamation.draw(
                at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                withAttributes: attrs
            )
        }
    }
}

// MARK: - Entry point

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
