// main.swift — CLI entry point for rec
//
// Subcommands:
//   rec [options]                         Full pipeline (capture → mix → transcribe → summarize)
//   rec capture [options] <sys.wav> <mic.wav>   Capture raw WAVs
//   rec mix <sys.wav> <mic.wav> <out>           Mix to stereo (.wav or .m4a)
//   rec transcribe [options] <sys.wav> <mic.wav> <out>  Transcribe with speaker labels
//   rec summarize <input.txt> [output.md]       AI summary in markdown
//
// Also supports:
//   --generate-completion-script bash|zsh

import Foundation

// MARK: - Argument parsing

enum Command {
    case capture
    case mix
    case transcribe
    case summarize
}

func printUsage() {
    print("""
rec - macOS System Audio + Microphone Recorder

Usage:
  rec [options]                          Full pipeline (capture → mix → transcribe → summarize)
  rec capture [options] <sys.wav> <mic.wav>
  rec mix <sys.wav> <mic.wav> <out>
  rec transcribe [options] <sys.wav> <mic.wav> <out>
  rec summarize <input.txt> [output.md]

Options:
  -d <secs>       Recording duration (default: until Ctrl+C)
  -m              Interactively select microphone
  --txt|--srt|--vtt|--json  Transcript format (default: txt)
  --censor        Redact sensitive words
  --locale <L>    Locale (e.g. fr-FR)
  --output-dir <path>  Output directory (default: ~/Documents/Recordings/)
  --keep-temp     Preserve scratch WAVs after run
  -h, --help      Show this help

Run 'rec <subcommand> --help' for detailed help.
""")
}

// MARK: - Completion script generation

func generateCompletionScript(shell: String) {
    switch shell {
    case "bash":
        print("""
_rec() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    local subcmds="capture mix transcribe summarize"
    local global_opts="-d -m --txt --srt --vtt --json --censor --locale --output-dir --keep-temp -h --help"

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$subcmds $global_opts" -- "$cur") )
        return 0
    fi

    case "${COMP_WORDS[1]}" in
        capture)
            COMPREPLY=( $(compgen -W "-d -m" -- "$cur") )
            ;;
        mix)
            COMPREPLY=( $(compgen -f -- "$cur") )
            ;;
        transcribe)
            COMPREPLY=( $(compgen -W "--txt --srt --vtt --json --censor --locale" -- "$cur") )
            ;;
        summarize)
            COMPREPLY=( $(compgen -f -- "$cur") )
            ;;
    esac
}
complete -F _rec rec
""")
    case "zsh":
        print("""
#compdef rec

_rec() {
    local -a subcmds
    subcmds=(
        'capture:Record system audio and microphone'
        'mix:Mix system and mic tracks into stereo'
        'transcribe:Transcribe recordings with speaker labels'
        'summarize:Create markdown summary from transcript via pi'
    )

    if (( CURRENT == 2 )); then
        _describe 'command' subcmds
        return
    fi

    case "$words[2]" in
        capture)
            _arguments -s \\
                {-d,-duration}'[recording duration]:seconds:' \\
                '-m[interactive mic selection]' \\
        mix)
            _arguments -s \\
                '1:system WAV file:_files -g "*.wav"' \\
                '2:mic WAV file:_files -g "*.wav"' \\
                '3:output file:_files'
            ;;
        transcribe)
            _arguments -s \\
                '--txt[plain text format]' \\
                '--srt[SRT subtitle format]' \\
                '--vtt[WebVTT subtitle format]' \\
                '--json[JSON format]' \\
                '--censor[enable word censoring]' \\
                '--locale[locale]:locale:' \\
                '1:system WAV file:_files -g "*.wav"' \\
                '2:mic WAV file:_files -g "*.wav"' \\
                '3:output file:_files'
            ;;
        summarize)
            _arguments -s \\
                '1:transcript file:_files -g "*.txt"' \\
                '*:output markdown:_files -g "*.md"'
            ;;
    esac
}

_rec "$@"
""")
    default:
        print("unsupported shell: \(shell)", to: &stderr)
    }
}

// MARK: - Main dispatch

func run() {
    let args = CommandLine.arguments

    // Handle --generate-completion-script
    if args.count > 2, args[1] == "--generate-completion-script" {
        generateCompletionScript(shell: args[2])
        return
    }

    // Handle -h / --help
    if args.count == 2, args[1] == "-h" || args[1] == "--help" {
        printUsage()
        return
    }

    // Determine command
    let command: Command?

    if args.count > 1 {
        switch args[1] {
        case "capture":     command = .capture
        case "mix":         command = .mix
        case "transcribe":  command = .transcribe
        case "summarize":   command = .summarize
        default:            command = nil
        }
    } else {
        command = nil
    }

    if #available(macOS 14.2, *) {
        if let cmd = command {
            switch cmd {
            case .capture:
                runCapture(Array(args.dropFirst(2)))
            case .mix:
                runMix(Array(args.dropFirst(2)))
            case .transcribe:
                runTranscribe(Array(args.dropFirst(2)))
            case .summarize:
                runSummarize(Array(args.dropFirst(2)))
            }
        } else {
            runFullPipeline(Array(args.dropFirst(1)))
        }
    } else {
        print("Error: rec requires macOS 14.2 or later", to: &stderr)
        exit(1)
    }
}

// MARK: - Full pipeline

@available(macOS 14.2, *)
func runFullPipeline(_ args: [String]) {
    var duration = 0
    var interactiveMic = false
    var format: TranscriptFormat = .txt
    var censor = false
    var locale: String?
    var outputDir: String?
    var keepTemp = false
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-d":           duration = Int(args[safe: i + 1] ?? "0") ?? 0; i += 2
        case "-m":           interactiveMic = true; i += 1
        case "--txt":        format = .txt; i += 1
        case "--srt":        format = .srt; i += 1
        case "--vtt":        format = .vtt; i += 1
        case "--json":       format = .json; i += 1
        case "--censor":     censor = true; i += 1
        case "--locale":     locale = args[safe: i + 1]; i += 2
        case "--output-dir": outputDir = args[safe: i + 1]; i += 2
        case "--keep-temp":  keepTemp = true; i += 1
        case "-h", "--help": printUsage(); return
        default:
            print("rec: unknown option \(arg)", to: &stderr); printUsage()
            exit(1)
        }
    }

    let finalDir = resolveOutputDir(flag: outputDir)
    let tempDir: String

    do {
        tempDir = try createTempDir()
    } catch {
        print("Error: cannot create temp directory: \(error)", to: &stderr)
        exit(1)
    }

    try? FileManager.default.createDirectory(atPath: finalDir, withIntermediateDirectories: true)

    var success = false
    var mixedWav = ""
    defer {
        if !success && !keepTemp {
            print("  (scratch files left in \(tempDir))", to: &stderr)
        }
        if success && !keepTemp {
            cleanupTempDir(tempDir)
        }
    }

    let sysWav  = "\(tempDir)/sys.wav"
    let micWav  = "\(tempDir)/mic.wav"
    let mixWav  = "\(tempDir)/mix.wav"
    let transcriptTxt = "\(tempDir)/transcript.txt"
    let summaryMd = "\(tempDir)/summary.md"

    do {
        // ======== Step 1: Capture ========
        print("=== Step 1: Capture ===", to: &stderr)
        try CaptureEngine.capture(sysWavPath: sysWav, micWavPath: micWav, duration: duration, interactiveMic: interactiveMic)

        // ======== Step 2: Mix ========
        print("\n=== Step 2: Mix ===", to: &stderr)
        let sysWavFile = try WavFile.read(path: sysWav)
        let micWavFile = try WavFile.read(path: micWav)
        let result = try mix(system: sysWavFile, mic: micWavFile)
        try result.writeWav(path: mixWav)
        mixedWav = mixWav
        print("Done: \(mixWav)", to: &stderr)

        // ======== Step 3: Transcribe ========
        print("\n=== Step 3: Transcribe ===", to: &stderr)
        var trConfig = TranscribeConfig()
        trConfig.format = format
        trConfig.censor = censor
        trConfig.locale = locale
        trConfig.systemWavOverride = sysWav
        trConfig.micWavOverride = micWav
        trConfig.transcriptOverride = transcriptTxt
        do {
            try transcribe(config: trConfig)
        } catch {
            print("Transcription failed: \(error)", to: &stderr)
            print("  Install yap: brew install yap", to: &stderr)
        }

        // ======== Step 4: Summarize ========
        print("\n=== Step 4: Summarize ===", to: &stderr)
        var generatedTitle = ""
        do {
            generatedTitle = try summarize(transcriptPath: transcriptTxt, outputPath: summaryMd)
        } catch {
            print("Summarization skipped: \(error)", to: &stderr)
            print("  Install pi: npm install -g @earendil-works/pi-coding-agent", to: &stderr)
        }

        // ======== Step 5: Finalize — name and move files ========
        let dateStr: String = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: Date())
        }()

        let finalStem: String
        if !generatedTitle.isEmpty {
            let safeTitle = generatedTitle
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            finalStem = safeTitle.isEmpty ? dateStr : "\(dateStr)_\(safeTitle)"
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "HHmmss"
            let timeStr = fmt.string(from: Date())
            finalStem = "\(dateStr)_\(timeStr)"
        }

        // Move markdown to final dir
        if FileManager.default.fileExists(atPath: summaryMd) {
            let finalMd = "\(finalDir)/\(finalStem).md"
            try? FileManager.default.moveItem(atPath: summaryMd, toPath: finalMd)
        }

        // Encode audio to final dir
        let finalAudioPath = "\(finalDir)/\(finalStem).m4a"
        if !mixedWav.isEmpty && FileManager.default.fileExists(atPath: mixedWav) {
            if encodeToAAC(wavPath: mixedWav, outputPath: finalAudioPath) {
                print("Encoded: \(finalAudioPath) (AAC)", to: &stderr)
            } else {
                let fallbackWav = "\(finalDir)/\(finalStem).wav"
                try? FileManager.default.copyItem(atPath: mixedWav, toPath: fallbackWav)
                print("Encoding failed, copied WAV: \(fallbackWav)", to: &stderr)
            }
        }

        success = true

        print("\nAll done.", to: &stderr)
        print("  Audio:   \(finalAudioPath)", to: &stderr)
        if !generatedTitle.isEmpty {
            print("  Summary: \(finalDir)/\(finalStem).md", to: &stderr)
        } else {
            print("  Summary: (skipped — install pi for AI summaries)", to: &stderr)
        }
        if keepTemp {
            print("  Scratch: \(tempDir)", to: &stderr)
        }
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
    }
}

// MARK: - Subcommands

@available(macOS 14.2, *)
func runCapture(_ args: [String]) {
    var duration = 0
    var interactiveMic = false

    // Extract flags before positional args
    var positional: [String] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-d": duration = Int(args[safe: i + 1] ?? "0") ?? 0; i += 2
        case "-m": interactiveMic = true; i += 1
        case "-h", "--help":
            print("""
Usage: rec capture [options] <sys.wav> <mic.wav>

Captures system audio and microphone to two WAV files.
Both output paths are required positional arguments.

Flags:
  -d <secs>       Recording duration (default: until Ctrl+C)
  -m              Interactively select microphone input device

Examples:
  rec capture -d 10 sys.wav mic.wav
  rec capture -d 5 -m meeting_sys.wav meeting_mic.wav
""")
            return
        default:
            positional.append(args[i])
            i += 1
        }
    }

    guard positional.count >= 2 else {
        print("Usage: rec capture [options] <sys.wav> <mic.wav>", to: &stderr)
        print("Both output WAV paths are required.", to: &stderr)
        exit(1)
    }

    let sysPath = positional[0]
    let micPath = positional[1]

    // Create parent directory if needed
    try? FileManager.default.createDirectory(
        atPath: (sysPath as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )

    do {
        try CaptureEngine.capture(sysWavPath: sysPath, micWavPath: micPath, duration: duration, interactiveMic: interactiveMic)
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
    }
}

func runMix(_ args: [String]) {
    if args.contains("-h") || args.contains("--help") {
        print("""
Usage: rec mix <system.wav> <mic.wav> <output.wav|.m4a>

Reads two WAV files, resamples to match sample rates, detects and
corrects clock drift, and produces a stereo mix:
  left channel  = microphone
  right channel = system audio (summed to mono)

Output format is auto-detected from extension:
  .wav → stereo WAV (16-bit PCM)
  .m4a → AAC in M4A container

Examples:
  rec mix sys.wav mic.wav mix.wav
  rec mix sys.wav mic.wav mix.m4a
""")
        return
    }
    guard args.count >= 3 else {
        print("Usage: rec mix <system.wav> <mic.wav> <output.wav|.m4a>", to: &stderr)
        print("Run 'rec mix --help' for details.", to: &stderr)
        exit(1)
    }
    let sysPath = args[0]
    let micPath = args[1]
    let outPath = args[2]

    do {
        try mixToFile(sysPath: sysPath, micPath: micPath, outputPath: outPath)
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
    }
}

func runTranscribe(_ args: [String]) {
    var format: TranscriptFormat = .txt
    var censor = false
    var locale: String?

    // Extract flags before positional args
    var positional: [String] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--txt":    format = .txt; i += 1
        case "--srt":    format = .srt; i += 1
        case "--vtt":    format = .vtt; i += 1
        case "--json":   format = .json; i += 1
        case "--censor": censor = true; i += 1
        case "--locale": locale = args[safe: i + 1]; i += 2
        case "-h", "--help":
            print("""
Usage: rec transcribe [options] <sys.wav> <mic.wav> <out>

Transcribes system and mic WAVs independently using yap, then merges
segments chronologically with speaker labels (Me / Them).

Output format is inferred from the output file extension:
  .txt → plain text   .srt → SubRip   .vtt → WebVTT   .json → JSON

Flags:
  --censor        Redact sensitive words in transcript
  --locale <L>    Locale for speech recognition (e.g. fr-FR)

Examples:
  rec transcribe sys.wav mic.wav transcript.txt
  rec transcribe sys.wav mic.wav captions.srt --censor
""")
            return
        default:
            positional.append(args[i])
            i += 1
        }
    }

    guard positional.count >= 3 else {
        print("Usage: rec transcribe [options] <sys.wav> <mic.wav> <out>", to: &stderr)
        exit(1)
    }

    let sysWav = positional[0]
    let micWav = positional[1]
    let outPath = positional[2]

    // Infer format from output extension
    let ext = (outPath as NSString).pathExtension.lowercased()
    if let inferred = TranscriptFormat(rawValue: ext) {
        format = inferred
    }

    var config = TranscribeConfig()
    config.format = format
    config.censor = censor
    config.locale = locale
    config.systemWavOverride = sysWav
    config.micWavOverride = micWav
    config.transcriptOverride = outPath

    do {
        try transcribe(config: config)
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
    }
}

func runSummarize(_ args: [String]) {
    // Only positional args: <input.txt> [output.md]
    if args.contains("-h") || args.contains("--help") {
        print("""
Usage: rec summarize <input.txt> [output.md]

Creates a markdown file with an AI-generated title and summary (via pi)
followed by the full transcript with bold speaker labels.

If output.md is omitted, the file is named after the AI title and placed
in ~/Documents/Recordings/ (or $REC_DIR).

Examples:
  rec summarize transcript.txt
  rec summarize transcript.txt ~/Desktop/notes.md
""")
        return
    }

    guard !args.isEmpty else {
        print("Usage: rec summarize <input.txt> [output.md]", to: &stderr)
        exit(1)
    }

    let transcriptPath = args[0]
    let outputPath: String

    if args.count >= 2 {
        outputPath = args[1]
    } else {
        // No output path given — will be AI-named into default dir
        // We write to a temp location first, then rename after getting the title
        let tempDir = (try? createTempDir()) ?? NSTemporaryDirectory()
        outputPath = "\(tempDir)/_summarize_temp.md"
    }

    let title: String
    do {
        title = try summarize(transcriptPath: transcriptPath, outputPath: outputPath)
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
    }

    // If no output path was given, rename the temp file with AI title
    if args.count < 2 {
        let dateStr: String = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: Date())
        }()
        let safeTitle = title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let finalStem = safeTitle.isEmpty ? dateStr : "\(dateStr)_\(safeTitle)"
        let finalDir = resolveOutputDir(flag: nil)
        try? FileManager.default.createDirectory(atPath: finalDir, withIntermediateDirectories: true)
        let finalPath = "\(finalDir)/\(finalStem).md"
        try? FileManager.default.moveItem(atPath: outputPath, toPath: finalPath)
        // Clean up temp dir
        let tempDir = (outputPath as NSString).deletingLastPathComponent
        if tempDir != NSTemporaryDirectory().trimmingCharacters(in: .whitespaces) {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
        print("Done: \(finalPath)", to: &stderr)
    }
}

// MARK: - Helper

extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0 && index < count else { return nil }
        return self[index]
    }
}

// MARK: - Entry

run()
