// main.swift — CLI entry point for rec
//
// Subcommands:
//   rec [options]               — full pipeline (capture → mix → transcribe → summarize)
//   rec capture [options]       — just capture
//   rec mix <sys> <mic> <out>   — just mix (.wav or .m4a)
//   rec transcribe [options]    — just transcribe
//   rec summarize [options]     — just summarize
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

struct GlobalOptions {
    var baseName = ""
    var duration = 0
    var interactiveMic = false
    var format: TranscriptFormat = .txt
    var censor = false
    var locale: String?
    var outputDir: String?
    var keepTemp = false
}

func printUsage() {
    print("""
Usage: rec [options]                     Full pipeline: capture -> mix -> transcribe -> summarize
       rec capture [options]             Just capture
       rec mix <sys.wav> <mic.wav> <out> Mix tracks to stereo (.wav or .m4a)
       rec transcribe [options]          Just transcribe existing WAVs
       rec summarize [options]           Create markdown summary from transcript

Full-pipeline options:
  -o <name>       Session name (used in fallback filename)
  -d <secs>       Recording duration (default: until Ctrl+C)
  -m              Interactively select microphone
  --txt           Plain text transcript (default)
  --srt           SRT subtitle format
  --vtt           WebVTT subtitle format
  --json          JSON with word timestamps
  --censor        Redact sensitive words in transcript
  --locale <L>    Locale for speech recognition (e.g. fr-FR)
  --output-dir <D> Output directory for finalized files (default: ~/Documents/Recordings/)
  --keep-temp     Preserve scratch WAV files after successful run
  -h, --help      Show this help

Examples:
  rec -d 30
  rec -d 10 -m --srt
  rec capture -d 5 -m
  rec mix sys.wav mic.wav mix.m4a
  rec transcribe --json
  rec summarize
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
    local global_opts="-o -d -m --txt --srt --vtt --json --censor --locale --output-dir --keep-temp -h --help"

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$subcmds $global_opts" -- "$cur") )
        return 0
    fi

    case "${COMP_WORDS[1]}" in
        capture)
            COMPREPLY=( $(compgen -W "-o -d -m --output-dir --keep-temp" -- "$cur") )
            ;;
        mix)
            COMPREPLY=( $(compgen -f -- "$cur") )
            ;;
        transcribe)
            COMPREPLY=( $(compgen -W "-o --txt --srt --vtt --json --censor --locale" -- "$cur") )
            ;;
        summarize)
            COMPREPLY=( $(compgen -W "-o" -- "$cur") )
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
                {-o,-output}'[output base name]:filename:' \\
                {-d,-duration}'[recording duration]:seconds:' \\
                '-m[interactive mic selection]' \\
                '--output-dir[output directory]:directory:_files -/' \\
                '--keep-temp[preserve scratch WAVs]'
            ;;
        mix)
            _arguments -s \\
                '1:system WAV file:_files -g "*.wav"' \\
                '2:mic WAV file:_files -g "*.wav"' \\
                '3:output file:_files'
            ;;
        transcribe)
            _arguments -s \\
                {-o,-output}'[output base name]:filename:' \\
                '--txt[plain text format]' \\
                '--srt[SRT subtitle format]' \\
                '--vtt[WebVTT subtitle format]' \\
                '--json[JSON format]' \\
                '--censor[enable word censoring]' \\
                '--locale[locale]:locale:'
            ;;
        summarize)
            _arguments -s \\
                {-o,-output}'[output base name]:filename:'
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
            // Full pipeline
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
    var opts = GlobalOptions()
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-o":           opts.baseName = args[safe: i + 1] ?? ""; i += 2
        case "-d":           opts.duration = Int(args[safe: i + 1] ?? "0") ?? 0; i += 2
        case "-m":           opts.interactiveMic = true; i += 1
        case "--txt":        opts.format = .txt; i += 1
        case "--srt":        opts.format = .srt; i += 1
        case "--vtt":        opts.format = .vtt; i += 1
        case "--json":       opts.format = .json; i += 1
        case "--censor":     opts.censor = true; i += 1
        case "--locale":     opts.locale = args[safe: i + 1]; i += 2
        case "--output-dir": opts.outputDir = args[safe: i + 1]; i += 2
        case "--keep-temp":  opts.keepTemp = true; i += 1
        case "-h", "--help": printUsage(); return
        default:
            print("rec: unknown option \(arg)", to: &stderr); printUsage()
            exit(1)
        }
    }

    let finalDir = resolveOutputDir(flag: opts.outputDir)
    let tempDir: String

    do {
        tempDir = try createTempDir()
    } catch {
        print("Error: cannot create temp directory: \(error)", to: &stderr)
        exit(1)
    }

    // Ensure final dir exists
    try? FileManager.default.createDirectory(atPath: finalDir, withIntermediateDirectories: true)

    var success = false
    var mixedWav = ""  // set after mix step
    defer {
        if !success && !opts.keepTemp {
            print("  (scratch files left in \(tempDir))", to: &stderr)
        }
        if success && !opts.keepTemp {
            cleanupTempDir(tempDir)
        }
    }

    let sysWav  = "\(tempDir)/sys.wav"
    let micWav  = "\(tempDir)/mic.wav"
    let mixWav  = "\(tempDir)/mix.wav"
    let transcriptTxt = "\(tempDir)/transcript.txt"

    do {
        // ======== Step 1: Capture ========
        print("=== Step 1: Capture ===", to: &stderr)
        try CaptureEngine.capture(sysWavPath: sysWav, micWavPath: micWav, duration: opts.duration, interactiveMic: opts.interactiveMic)

        // ======== Step 2: Mix (WAV only — encoding happens after summarize) ========
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
        trConfig.format = opts.format
        trConfig.censor = opts.censor
        trConfig.locale = opts.locale
        trConfig.systemWavOverride = sysWav
        trConfig.micWavOverride = micWav
        trConfig.transcriptOverride = transcriptTxt
        do {
            try transcribe(config: trConfig)
        } catch {
            print("Transcription failed: \(error)", to: &stderr)
            print("  Install yap: brew install yap", to: &stderr)
            print("  Then run:    rec transcribe", to: &stderr)
        }

        // ======== Step 4: Summarize ========
        print("\n=== Step 4: Summarize ===", to: &stderr)
        var generatedTitle = ""
        do {
            var summaryConfig = SummarizeConfig()
            summaryConfig.outputDir = finalDir
            summaryConfig.transcriptOverride = transcriptTxt
            generatedTitle = try summarize(config: summaryConfig)
        } catch {
            print("Summarization skipped: \(error)", to: &stderr)
            print("  Install pi: npm install -g @earendil-works/pi-coding-agent", to: &stderr)
            print("  Then run:   rec summarize", to: &stderr)
        }

        // ======== Step 5: Encode to final .m4a with proper name ========
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
        } else if !opts.baseName.isEmpty {
            finalStem = "\(dateStr)_\(opts.baseName)"
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "HHmmss"
            let timeStr = fmt.string(from: Date())
            finalStem = "\(dateStr)_\(timeStr)"
        }

        let finalAudioExt = "m4a"
        let finalAudioPath = "\(finalDir)/\(finalStem).\(finalAudioExt)"

        if !mixedWav.isEmpty && FileManager.default.fileExists(atPath: mixedWav) {
            if encodeToAAC(wavPath: mixedWav, outputPath: finalAudioPath) {
                print("Encoded: \(finalAudioPath) (AAC)", to: &stderr)
            } else {
                // Fallback: copy WAV
                let fallbackWav = "\(finalDir)/\(finalStem).wav"
                try? FileManager.default.copyItem(atPath: mixedWav, toPath: fallbackWav)
                print("Encoding failed, copied WAV: \(fallbackWav)", to: &stderr)
            }
        }

        success = true

        print("\nAll done.", to: &stderr)
        print("  Audio:      \(finalAudioPath)", to: &stderr)
        if !generatedTitle.isEmpty {
            let safeTitle = generatedTitle
                .lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "_", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            print("  Summary:    \(finalDir)/\(dateStr)_\(safeTitle).md", to: &stderr)
        } else {
            print("  Summary:    (skipped — install pi for AI summaries)", to: &stderr)
        }
        if opts.keepTemp {
            print("  Scratch:    \(tempDir)", to: &stderr)
        }
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
    }
}

// MARK: - Subcommands

@available(macOS 14.2, *)
func runCapture(_ args: [String]) {
    var baseName = "output"
    var duration = 0
    var interactiveMic = false
    var outputDir: String?
    var keepTemp = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-o": baseName = args[safe: i + 1] ?? "output"; i += 2
        case "-d": duration = Int(args[safe: i + 1] ?? "0") ?? 0; i += 2
        case "-m": interactiveMic = true; i += 1
        case "--output-dir": outputDir = args[safe: i + 1]; i += 2
        case "--keep-temp": keepTemp = true; i += 1
        case "-h", "--help":
            print("Usage: rec capture [-o base] [-d secs] [-m] [--output-dir D] [--keep-temp]")
            print("  Record system audio + microphone to separate WAV files")
            return
        default:
            print("rec capture: unknown option \(args[i])", to: &stderr); exit(1)
        }
    }

    let outDir: String
    if let dir = outputDir {
        outDir = (dir as NSString).expandingTildeInPath
    } else {
        guard let tmp = try? createTempDir() else {
            print("Error: cannot create temp directory", to: &stderr)
            exit(1)
        }
        outDir = tmp
    }
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    let sysPath = "\(outDir)/\(baseName)_system.wav"
    let micPath = "\(outDir)/\(baseName)_mic.wav"

    do {
        try CaptureEngine.capture(sysWavPath: sysPath, micWavPath: micPath, duration: duration, interactiveMic: interactiveMic)
        if !keepTemp && outputDir == nil {
            print("  (scratch WAVs in \(outDir); use --keep-temp to preserve)", to: &stderr)
        }
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
    }
}

func runMix(_ args: [String]) {
    guard args.count >= 3 else {
        print("Usage: rec mix <system.wav> <mic.wav> <output.wav|.m4a>", to: &stderr)
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
    var config = TranscribeConfig()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-o": config.baseName = args[safe: i + 1] ?? "output"; i += 2
        case "--txt": config.format = .txt; i += 1
        case "--srt": config.format = .srt; i += 1
        case "--vtt": config.format = .vtt; i += 1
        case "--json": config.format = .json; i += 1
        case "--censor": config.censor = true; i += 1
        case "--locale": config.locale = args[safe: i + 1]; i += 2
        case "-h", "--help":
            print("Usage: rec transcribe [-o base] [--txt|--srt|--vtt|--json] [--censor] [--locale L]")
            return
        default:
            print("rec transcribe: unknown option \(args[i])", to: &stderr); exit(1)
        }
    }
    do {
        try transcribe(config: config)
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
    }
}

func runSummarize(_ args: [String]) {
    var config = SummarizeConfig()
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-o": config.baseName = args[safe: i + 1] ?? "output"; i += 2
        case "-h", "--help":
            print("Usage: rec summarize [-o base]")
            print("  Create a markdown summary with transcript from an existing transcript file.")
            return
        default:
            print("rec summarize: unknown option \(args[i])", to: &stderr); exit(1)
        }
    }
    do {
        _ = try summarize(config: config)
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
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
