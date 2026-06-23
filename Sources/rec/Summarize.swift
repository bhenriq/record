// Summarize.swift — create markdown summary from transcript via pi
//
// Reads a txt transcript, calls `pi -p` to generate a title + summary,
// then writes a markdown file with the summary followed by the full transcript.

import Foundation

struct SummarizeConfig {
    var baseName = "output"

    var transcriptPath: String { "\(baseName)_transcript.txt" }
}

/// Run the summarization pipeline.
func summarize(config: SummarizeConfig) throws {
    let transcriptPath = config.transcriptPath

    guard FileManager.default.fileExists(atPath: transcriptPath) else {
        throw RecError.general("transcript not found: \(transcriptPath)")
    }

    guard let transcriptData = FileManager.default.contents(atPath: transcriptPath),
          let transcript = String(data: transcriptData, encoding: .utf8),
          !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
        throw RecError.general("transcript is empty: \(transcriptPath)")
    }

    guard which("pi") != nil else {
        throw RecError.toolNotFound("pi")
    }

    guard which("jq") != nil else {
        throw RecError.toolNotFound("jq")
    }

    print("Reading transcript: \(transcriptPath)", to: &stderr)
    print("Generating summary and title with pi...", to: &stderr)

    // ---- Call pi -p ----
    let piOutput = try runPi(input: transcript)

    // ---- Parse JSON from pi output ----
    let jsonStr = extractJson(from: piOutput)

    guard let jsonData = jsonStr.data(using: .utf8) else {
        throw RecError.summarizationFailed("could not parse pi output as UTF-8")
    }

    struct PiResult: Codable {
        let title: String
        let summary: String
    }

    let result: PiResult
    do {
        result = try JSONDecoder().decode(PiResult.self, from: jsonData)
    } catch {
        throw RecError.summarizationFailed("could not parse JSON from pi output: \(error.localizedDescription)\nRaw output: \(piOutput.prefix(500))")
    }

    guard !result.title.isEmpty else {
        throw RecError.summarizationFailed("empty title from pi")
    }
    guard !result.summary.isEmpty else {
        throw RecError.summarizationFailed("empty summary from pi")
    }

    // Sanitize title for filename
    let filenameTitle = result.title
        .lowercased()
        .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    let safeTitle = filenameTitle.isEmpty ? "transcript" : filenameTitle

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    let dateStr = dateFormatter.string(from: Date())

    let dateFormatterLong = DateFormatter()
    dateFormatterLong.dateFormat = "MMMM dd, yyyy"

    let mdFileName = "\(dateStr)_\(safeTitle).md"

    print("Title: \(result.title)", to: &stderr)
    print("Output: \(mdFileName)", to: &stderr)

    // ---- Build markdown ----
    var md = "# \(result.title)\n\n"
    md += "**Date:** \(dateFormatterLong.string(from: Date()))\n\n"
    md += "---\n\n"
    md += "\(result.summary)\n\n"
    md += "---\n\n"
    md += "## Transcript\n\n"

    // Bold speaker labels
    let boldTranscript = transcript
        .components(separatedBy: .newlines)
        .map { line -> String in
            if line.hasPrefix("Me:") || line.hasPrefix("Them:") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    return "**\(parts[0]):** \(parts[1].trimmingCharacters(in: .whitespaces))"
                }
            }
            return line
        }
        .joined(separator: "\n")

    md += boldTranscript + "\n"

    try md.write(toFile: mdFileName, atomically: true, encoding: .utf8)
    print("Done: \(mdFileName)", to: &stderr)
}

// MARK: - pi subprocess

private func runPi(input: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/local/bin/pi")
    process.arguments = ["-p"]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Build prompt
    let prompt = """
    Read this conversation transcript and output a JSON object with exactly two keys:
    - "title": a short title (5 words or less) for this conversation
    - "summary": a concise 2-3 paragraph summary

    Output ONLY valid JSON, no other text or markdown formatting.
    Example: {"title": "Team Standup Notes", "summary": "The team discussed progress on the project."}

    Transcript:
    \(input)
    """

    try process.run()

    // Write input
    stdinPipe.fileHandleForWriting.write(prompt.data(using: .utf8)!)
    stdinPipe.fileHandleForWriting.closeFile()

    process.waitUntilExit()

    let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: outputData, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
        throw RecError.summarizationFailed(errMsg)
    }

    return output
}

// MARK: - JSON extraction helper

/// Extract JSON object from text that may contain markdown code fences or other text.
private func extractJson(from text: String) -> String {
    // Try to find JSON between ```json and ``` markers
    if let jsonStart = text.range(of: "```json"),
       let jsonEnd = text.range(of: "```", range: jsonStart.upperBound..<text.endIndex) {
        return String(text[jsonStart.upperBound..<jsonEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // Try to find JSON between ``` markers
    if let fenceStart = text.range(of: "```"),
       let fenceEnd = text.range(of: "```", range: fenceStart.upperBound..<text.endIndex) {
        let candidate = String(text[fenceStart.upperBound..<fenceEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("{") || candidate.hasPrefix("[\"") {
            return candidate
        }
    }
    // Try to find a JSON object directly
    if let braceStart = text.firstIndex(of: "{"),
       let braceEnd = text.lastIndex(of: "}"),
       braceEnd > braceStart {
        return String(text[braceStart...braceEnd])
    }
    // Fallback: return the whole thing trimmed
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Helper

private func which(_ name: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = [name]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data.trimmingTrailingWhitespace(), encoding: .utf8)
}

private extension Data {
    func trimmingTrailingWhitespace() -> Data {
        guard count > 0 else { return self }
        var end = count - 1
        while end >= 0 && self[end] <= 32 { end -= 1 }
        return self[0...end]
    }
}
