// main.swift — Entry point for RecMenu
//
// This file is named main.swift so Swift treats it as the program entry point.
// We manually set up the NSApplication delegate and call NSApplicationMain.

import AppKit

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
