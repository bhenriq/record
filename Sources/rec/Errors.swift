// Errors.swift — error types used across the toolchain

import Foundation

enum RecError: Error, CustomStringConvertible {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(String, OSStatus)
    case fileCreationFailed(String)
    case noInputDevice
    case invalidMicSelection
    case wavReadFailed(String)
    case toolNotFound(String)
    case transcriptionFailed(String)
    case summarizationFailed(String)
    case invalidArgument(String)
    case general(String)

    var description: String {
        switch self {
        case .tapCreationFailed(let s):
            return "AudioHardwareCreateProcessTap failed (\(s))"
        case .aggregateCreationFailed(let s):
            return "AudioHardwareCreateAggregateDevice failed (\(s))"
        case .ioProcCreationFailed(let s):
            return "AudioDeviceCreateIOProcID failed (\(s))"
        case .deviceStartFailed(let name, let s):
            return "AudioDeviceStart (\(name)) failed (\(s))"
        case .fileCreationFailed(let path):
            return "cannot create file: \(path)"
        case .noInputDevice:
            return "no audio input devices found"
        case .invalidMicSelection:
            return "invalid microphone selection"
        case .wavReadFailed(let path):
            return "cannot read WAV file: \(path)"
        case .toolNotFound(let name):
            return "'\(name)' not found. Install: brew install \(name)"
        case .transcriptionFailed(let msg):
            return "transcription failed: \(msg)"
        case .summarizationFailed(let msg):
            return "summarization failed: \(msg)"
        case .invalidArgument(let msg):
            return msg
        case .general(let msg):
            return msg
        }
    }
}

// MARK: - Stderr output stream

struct StderrStream: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

var stderr = StderrStream()
