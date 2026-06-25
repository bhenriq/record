// Stepwise.swift — state persistence for step-by-step pipeline execution

import Foundation

// MARK: - Stepwise state

/// Serializable state saved between stepwise invocations.
/// `step` tracks the last completed step index:
///   -1 = nothing done yet
///    0 = capture done
///    1 = mix done
///    2 = transcribe done
///    3 = summarize done (next would be finalize)
struct StepwiseState: Codable {
    var step: Int
    var duration: Int
    var interactiveMic: Bool
    var micGainDB: Float
    var locale: String?
    var outputDir: String?
    var keepTemp: Bool
    var tempDir: String
    var sysWav: String
    var micWav: String
    var mixWav: String
    var transcriptTxt: String
    var summaryMd: String
    var generatedTitle: String
}

// MARK: - State file paths

private let kRecDir = "\(NSHomeDirectory())/.rec"
private let kSessionsDir = "\(kRecDir)/sessions"

func stepwiseStatePath(session: String?) -> String {
    if let name = session, !name.isEmpty {
        return "\(kSessionsDir)/\(name).json"
    }
    return "\(kRecDir)/state.json"
}

// MARK: - Save / load / remove

func saveStepwiseState(_ state: StepwiseState, session: String?) throws {
    let dir = (session != nil && !session!.isEmpty) ? kSessionsDir : kRecDir
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(state)
    try data.write(to: URL(fileURLWithPath: stepwiseStatePath(session: session)), options: .atomic)
}

func loadStepwiseState(session: String?) -> StepwiseState? {
    let path = stepwiseStatePath(session: session)
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
    return try? JSONDecoder().decode(StepwiseState.self, from: data)
}

func removeStepwiseState(session: String?) {
    try? FileManager.default.removeItem(atPath: stepwiseStatePath(session: session))
}
