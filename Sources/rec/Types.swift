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
