// main.swift — CLI entry point for rec
//
// Subcommands:
//   rec [options]           — full pipeline (capture → mix → transcribe)
//   rec capture [options]   — just capture
//   rec mix <sys> <mic> <out> — just mix
//   rec transcribe [options] — just transcribe
//   rec summarize [options]  — just summarize
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
    var baseName = "output"
    var duration = 0
    var interactiveMic = false
    var format: TranscriptFormat = .txt
    var censor = false
    var locale: String?
}

func printUsage() {
    print("""
Usage: rec [options]                     Full pipeline: capture -> mix -> transcribe
       rec capture [options]             Just capture
       rec mix <sys.wav> <mic.wav> <out> Just mix tracks to stereo
       rec transcribe [options]          Just transcribe existing WAVs
       rec summarize [options]           Create markdown summary from transcript

Full-pipeline options:
  -o <name>       Output base name (default: output)
  -d <secs>       Recording duration (default: until Ctrl+C)
  -m              Interactively select microphone
  --txt           Plain text transcript (default)
  --srt           SRT subtitle format
  --vtt           WebVTT subtitle format
  --json          JSON with word timestamps
  --censor        Redact sensitive words in transcript
  --locale <L>    Locale for speech recognition (e.g. fr-FR)
  -h, --help      Show this help

Examples:
  rec -d 30 -o meeting
  rec -d 10 -m --srt
  rec capture -d 5 -m
  rec mix sys.wav mic.wav out.wav
  rec transcribe -o meeting --json
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
    local global_opts="-o -d -m --txt --srt --vtt --json --censor --locale -h --help"

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$subcmds $global_opts" -- "$cur") )
        return 0
    fi

    case "${COMP_WORDS[1]}" in
        capture)
            COMPREPLY=( $(compgen -W "-o -d -m" -- "$cur") )
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
                '-m[interactive mic selection]'
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
        case "-o":    opts.baseName = args[safe: i + 1] ?? "output"; i += 2
        case "-d":    opts.duration = Int(args[safe: i + 1] ?? "0") ?? 0; i += 2
        case "-m":    opts.interactiveMic = true; i += 1
        case "--txt": opts.format = .txt; i += 1
        case "--srt": opts.format = .srt; i += 1
        case "--vtt": opts.format = .vtt; i += 1
        case "--json": opts.format = .json; i += 1
        case "--censor": opts.censor = true; i += 1
        case "--locale": opts.locale = args[safe: i + 1]; i += 2
        case "-h", "--help": printUsage(); return
        default:
            print("rec: unknown option \(arg)", to: &stderr); printUsage()
            exit(1)
        }
    }

    do {
        // Step 1: Capture
        print("=== Step 1: Capture ===", to: &stderr)
        try CaptureEngine.capture(baseName: opts.baseName, duration: opts.duration, interactiveMic: opts.interactiveMic)

        // Step 2: Mix + encode
        print("\n=== Step 2: Mix ===", to: &stderr)
        do {
            let sysWav = try WavFile.read(path: "\(opts.baseName)_system.wav")
            let micWav = try WavFile.read(path: "\(opts.baseName)_mic.wav")
            let result = try mix(system: sysWav, mic: micWav)
            let wavPath = "\(opts.baseName).wav"
            try result.writeWav(path: wavPath)
            print("Done: \(wavPath)", to: &stderr)

            // Encode to compressed format (MP3 or M4A)
            switch encodeAudio(wavPath: wavPath, outputBase: opts.baseName) {
            case .mp3(let path):
                print("Encoded: \(path) (MP3)", to: &stderr)
            case .m4a(let path):
                print("Encoded: \(path) (AAC)", to: &stderr)
            case .skipped(let reason):
                print("Skipped encoding: \(reason)", to: &stderr)
                print("  Install lame: brew install lame", to: &stderr)
            }
        } catch {
            print("Mix failed, continuing to transcribe: \(error)", to: &stderr)
            print("  (mix is optional — the WAV files are still available)", to: &stderr)
        }

        // Step 3: Transcribe
        print("\n=== Step 3: Transcribe ===", to: &stderr)
        var trConfig = TranscribeConfig()
        trConfig.baseName = opts.baseName
        trConfig.format = opts.format
        trConfig.censor = opts.censor
        trConfig.locale = opts.locale
        do {
            try transcribe(config: trConfig)
        } catch {
            print("Transcription failed: \(error)", to: &stderr)
            print("  Install yap: brew install yap", to: &stderr)
            print("  Then run:    rec transcribe -o \(opts.baseName)", to: &stderr)
        }

        // Step 4: Summarize (optional, requires pi)
        print("\n=== Step 4: Summarize ===", to: &stderr)
        var summaryConfig = SummarizeConfig()
        summaryConfig.baseName = opts.baseName
        do {
            try summarize(config: summaryConfig)
        } catch {
            print("Summarization skipped: \(error)", to: &stderr)
            print("  Install pi: npm install -g @earendil-works/pi-coding-agent", to: &stderr)
            print("  Then run:   rec summarize -o \(opts.baseName)", to: &stderr)
        }

        print("\nAll done.", to: &stderr)
        print("  Audio:      \(opts.baseName).wav", to: &stderr)
        print("  Transcript: \(opts.baseName)_transcript.\(opts.format.rawValue)", to: &stderr)
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
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-o": baseName = args[safe: i + 1] ?? "output"; i += 2
        case "-d": duration = Int(args[safe: i + 1] ?? "0") ?? 0; i += 2
        case "-m": interactiveMic = true; i += 1
        case "-h", "--help":
            print("Usage: rec capture [-o base] [-d secs] [-m]")
            print("  Record system audio + microphone to separate WAV files")
            return
        default:
            print("rec capture: unknown option \(args[i])", to: &stderr); exit(1)
        }
    }
    do {
        try CaptureEngine.capture(baseName: baseName, duration: duration, interactiveMic: interactiveMic)
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
    }
}

func runMix(_ args: [String]) {
    guard args.count >= 3 else {
        print("Usage: rec mix <system.wav> <mic.wav> <output.wav>", to: &stderr)
        exit(1)
    }
    let sysPath = args[0]
    let micPath = args[1]
    let outPath = args[2]

    do {
        let sysWav = try WavFile.read(path: sysPath)
        let micWav = try WavFile.read(path: micPath)
        let result = try mix(system: sysWav, mic: micWav)
        try result.writeWav(path: outPath)
        print("Done: \(outPath)", to: &stderr)
        print("  \(result.frameCount) frames, \(Int(result.sampleRate)) Hz", to: &stderr)
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
        try summarize(config: config)
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
