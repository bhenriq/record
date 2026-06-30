// main.swift — CLI entry point for rec
//
// Subcommands:
//   rec [options]                         Full pipeline (capture → mix → transcribe → summarize)
//   rec capture [options] <sys.wav> <mic.wav>   Capture raw WAVs
//   rec mix <sys.wav> <mic.wav> <out>           Mix to stereo (.wav or .m4a)
//   rec transcribe [options] <sys.wav> <mic.wav> <out>  Transcribe with speaker labels
//   rec summarize <input.txt> <output.md>        AI summary in markdown
//   rec resume [options]                         Resume stepwise pipeline
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
    case resume
}

func printUsage() {
    print("""
rec - macOS System Audio + Microphone Recorder

Usage:
  rec [options]                          Full pipeline (capture → mix → transcribe → summarize)
  rec capture [options] <sys.wav> <mic.wav>
  rec mix <sys.wav> <mic.wav> <out>
  rec transcribe [options] <sys.wav> <mic.wav> <out>
  rec summarize <input.txt> <output.md>
  rec resume                                   Resume stepwise pipeline

Options:
  -d <secs>       Recording duration (default: until Ctrl+C)
  -m              Interactively select microphone
  -g <dB>         Microphone gain in dB (e.g. -g 6, default: 0)
  -l, --locale <L>       Locale (e.g. fr-FR)
  -o, --output-dir <path> Output directory (default: ~/Documents/Recordings/)
  -k, --keep-temp         Preserve scratch WAVs after run
  -s, --stepwise          Run pipeline step by step
  -S, --session <name>    Session name (for stepwise mode)
  -h, --help              Show this help
  --pidfile <path>        Write JSON pidfile for menu-bar companion tracking

If no speech is detected, the transcript will be empty and the
pipeline stops before summarization. State is saved so you can
resume with 'rec resume' after re-recording or re-transcribing.

Drift between system and microphone clocks is tracked automatically
with per-second time anchors and corrected during transcription via
piecewise interpolation — no configuration needed.

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

    local subcmds="capture mix transcribe summarize resume"
    local global_opts="-d -m -g -l --locale -o --output-dir -k --keep-temp -s --stepwise -S --session -h --help"

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$subcmds $global_opts" -- "$cur") )
        return 0
    fi

    case "${COMP_WORDS[1]}" in
        capture)
            COMPREPLY=( $(compgen -W "-d -m" -- "$cur") )
            ;;
        mix)
            COMPREPLY=( $(compgen -W "-g" -- "$cur") )
            ;;
        transcribe)
            COMPREPLY=( $(compgen -W "-l --locale" -- "$cur") )
            ;;
        summarize)
            COMPREPLY=( $(compgen -f -- "$cur") )
            ;;
        resume)
            COMPREPLY=( $(compgen -W "-S --session" -- "$cur") )
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
        'resume:Resume stepwise pipeline'
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
                {-g,-mic-gain}'[microphone gain in dB]:dB:' \\
                '1:system WAV file:_files -g "*.wav"' \\
                '2:mic WAV file:_files -g "*.wav"' \\
                '3:output file:_files'
            ;;
        transcribe)
            _arguments -s \\
                {-l,--locale}'[locale]:locale:' \\
                '1:system WAV file:_files -g "*.wav"' \\
                '2:mic WAV file:_files -g "*.wav"' \\
                '3:output file:_files'
            ;;
        summarize)
            _arguments -s \\
                '1:transcript file:_files -g "*.txt"' \\
                '*:output markdown:_files -g "*.md"'
            ;;
        resume)
            _arguments -s \\
                {-S,--session}'[session name]:name:'
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

    // Handle -v / --version
    if args.count > 1, args[1] == "-v" || args[1] == "--version" {
        print("rec \(recVersion)")
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
        case "resume":      command = .resume
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
            case .resume:
                runResume(args: Array(args.dropFirst(2)))
            }
        } else {
            runFullPipeline(Array(args.dropFirst(1)))
        }
    } else {
        print("Error: rec requires macOS 14.2 or later", to: &stderr)
        exit(1)
    }
}

// MARK: - Step functions (shared by full pipeline and stepwise resume)

@available(macOS 14.2, *)
func stepCapture(sysWav: String, micWav: String, duration: Int, interactiveMic: Bool, tempDir: String, keepTemp: inout Bool, anchorsPath: String? = nil) throws {
    print("=== Step 1: Capture ===", to: &stderr)
    let capStatus = CaptureStatus()
    try CaptureEngine.capture(sysWavPath: sysWav, micWavPath: micWav, duration: duration, interactiveMic: interactiveMic, status: capStatus, anchorsPath: anchorsPath)

    let driftPct = capStatus.driftPercent
    if driftPct > kDriftThreshold {
        print("⚠  Drift was \(String(format: "%.2f", driftPct))% — raw WAVs preserved in \(tempDir) for manual correction.", to: &stderr)
        keepTemp = true
    }
}

@available(macOS 14.2, *)
func stepMix(sysWav: String, micWav: String, mixWav: String, micGain: Float) throws {
    print("\n=== Step 2: Mix ===", to: &stderr)
    let sysWavFile = try WavFile.read(path: sysWav)
    let micWavFile = try WavFile.read(path: micWav)
    let result = try mix(system: sysWavFile, mic: micWavFile, micGain: micGain)
    try result.writeWav(path: mixWav)
    print("Done: \(mixWav)", to: &stderr)
}

@available(macOS 14.2, *)
func stepTranscribe(sysWav: String, micWav: String, transcriptTxt: String, locale: String?, anchorsPath: String? = nil) throws {
    print("\n=== Step 3: Transcribe ===", to: &stderr)
    var trConfig = TranscribeConfig()
    trConfig.format = .txt
    trConfig.locale = locale
    trConfig.systemWavOverride = sysWav
    trConfig.micWavOverride = micWav
    trConfig.transcriptOverride = transcriptTxt
    trConfig.anchorsPath = anchorsPath
    try transcribe(config: trConfig)
}

/// Check if the transcript file is empty (no speech detected).
private func isTranscriptEmpty(_ path: String) -> Bool {
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
        return true
    }
    return content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

@available(macOS 14.2, *)
func stepSummarize(transcriptTxt: String, summaryMd: String) -> String {
    print("\n=== Step 4: Summarize ===", to: &stderr)

    // Check for empty transcript before engaging pi
    if isTranscriptEmpty(transcriptTxt) {
        print("Transcript is empty \u{2014} no speech detected. Skipping summarization.", to: &stderr)
        print("You can resume with 'rec resume' after re-recording or re-transcribing.", to: &stderr)
        return ""
    }

    var generatedTitle = ""
    do {
        generatedTitle = try summarize(transcriptPath: transcriptTxt, outputPath: summaryMd)
    } catch let error as RecError {
        switch error {
        case .toolNotFound("pi"):
            print("Summarization skipped: pi not found", to: &stderr)
            print("  Install: npm install -g @earendil-works/pi-coding-agent", to: &stderr)
        case .toolNotFound:
            print("Summarization skipped: \(error)", to: &stderr)
        default:
            print("Summarization skipped: \(error)", to: &stderr)
        }
    } catch {
        print("Summarization skipped: \(error)", to: &stderr)
    }
    return generatedTitle
}

@available(macOS 14.2, *)
func stepFinalize(finalDir: String, mixedWav: String, summaryMd: String, generatedTitle: String, keepTemp: Bool, tempDir: String) -> Bool {
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
    var hadAudio = false
    let finalAudioPath = "\(finalDir)/\(finalStem).m4a"
    if !mixedWav.isEmpty && FileManager.default.fileExists(atPath: mixedWav) {
        if encodeToAAC(wavPath: mixedWav, outputPath: finalAudioPath) {
            print("Encoded: \(finalAudioPath) (AAC)", to: &stderr)
            hadAudio = true
        } else {
            let fallbackWav = "\(finalDir)/\(finalStem).wav"
            try? FileManager.default.copyItem(atPath: mixedWav, toPath: fallbackWav)
            print("Encoding failed, copied WAV: \(fallbackWav)", to: &stderr)
        }
    }

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

    return hadAudio
}

// MARK: - Full pipeline

@available(macOS 14.2, *)
func runFullPipeline(_ args: [String]) {
    var duration = 0
    var interactiveMic = false
    var locale: String?
    var outputDir: String?
    var keepTemp = false
    var micGainDB: Float = 0
    var stepwise = false
    var session: String?
    var pidfilePath: String?
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-d":                duration = Int(args[safe: i + 1] ?? "0") ?? 0; i += 2
        case "-m":                interactiveMic = true; i += 1
        case "-g":                micGainDB = Float(args[safe: i + 1] ?? "0") ?? 0; i += 2
        case "-l", "--locale":    locale = args[safe: i + 1]; i += 2
        case "-o", "--output-dir": outputDir = args[safe: i + 1]; i += 2
        case "-k", "--keep-temp": keepTemp = true; i += 1
        case "-s", "--stepwise":  stepwise = true; i += 1
        case "-S", "--session":   session = args[safe: i + 1]; i += 2
        case "--pidfile":         pidfilePath = args[safe: i + 1]; i += 2
        case "-h", "--help":      printUsage(); return
        default:
            print("rec: unknown option \(arg)", to: &stderr); printUsage()
            exit(1)
        }
    }

    if session != nil && !stepwise {
        print("rec: --session/-S requires --stepwise/-s", to: &stderr)
        exit(1)
    }

    // Resolve pidfile path once args are fully parsed
    let thePidfile = pidfilePath ?? defaultPidfilePath

    // In stepwise mode, check for existing session
    if stepwise, let _ = loadStepwiseState(session: session) {
        let hint = session.map { " -S \($0)" } ?? ""
        if isatty(STDIN_FILENO) != 0 {
            print("A stepwise session already exists. Restart? [y/N] ", terminator: "", to: &stderr)
            Darwin.fflush(__stderrp)
            if let response = readLine(), response.lowercased() == "y" {
                removeStepwiseState(session: session)
            } else {
                print("Use 'rec resume\(hint)' to continue.", to: &stderr)
                exit(1)
            }
        } else {
            print("A stepwise session already exists. Use 'rec resume\(hint)' to continue, or delete the state file to start fresh.", to: &stderr)
            exit(1)
        }
    }

    let micGain = pow(10, micGainDB / 20)  // convert dB to linear
    let finalDir = resolveOutputDir(flag: outputDir)
    let tempDir: String

    do {
        tempDir = try createTempDir()
    } catch {
        print("Error: cannot create temp directory: \(error)", to: &stderr)
        exit(1)
    }

    try? FileManager.default.createDirectory(atPath: finalDir, withIntermediateDirectories: true)

    let sysWav  = "\(tempDir)/sys.wav"
    let micWav  = "\(tempDir)/mic.wav"
    let mixWav  = "\(tempDir)/mix.wav"
    let transcriptTxt = "\(tempDir)/transcript.txt"
    let summaryMd = "\(tempDir)/summary.md"
    let anchorsPath = "\(tempDir)/\(kAnchorFileName)"

    // In stepwise mode, save initial state and run one step at a time.
    // The defer only fires on normal (non-stepwise) runs — stepwise cleanup
    // is handled by runResume after finalize.
    if stepwise {
        let initialState = StepwiseState(
            step: -1,
            duration: duration,
            interactiveMic: interactiveMic,
            micGainDB: micGainDB,
            locale: locale,
            outputDir: outputDir,
            keepTemp: keepTemp,
            tempDir: tempDir,
            sysWav: sysWav,
            micWav: micWav,
            mixWav: mixWav,
            transcriptTxt: transcriptTxt,
            summaryMd: summaryMd,
            anchorsPath: anchorsPath,
            generatedTitle: ""
        )
        do {
            try saveStepwiseState(initialState, session: session)
        } catch {
            print("Error: cannot save stepwise state: \(error)", to: &stderr)
            exit(1)
        }
    }

    var success = false
    var mixedWav_ = ""
    var currentKeepTemp = keepTemp

    // Write initial pidfile before capture starts
    if pidfilePath != nil {
        let pf = RecPidfile(
            pid: ProcessInfo.processInfo.processIdentifier,
            startTime: Date(),
            command: "full",
            state: .capturing,
            tempDir: tempDir,
            outputDir: outputDir,
            session: session
        )
        try? writePidfile(path: thePidfile, pf)
    }

    defer {
        if pidfilePath != nil {
            // On success: remove pidfile. On error: write error state.
            if success {
                removePidfile(path: thePidfile)
            } else {
                updatePidfileState(path: thePidfile, state: .error, errorMessage: "pipeline failed")
            }
        }
        if stepwise {
            // Keep temp dir alive across invocations for stepwise mode
            if !success {
                print("  (scratch files left in \(tempDir))", to: &stderr)
            }
        } else {
            if !success && !currentKeepTemp {
                print("  (scratch files left in \(tempDir))", to: &stderr)
            }
            if success && !currentKeepTemp {
                cleanupTempDir(tempDir)
            }
        }
    }

    do {
        // ======== Step 1: Capture ========
        try stepCapture(sysWav: sysWav, micWav: micWav, duration: duration, interactiveMic: interactiveMic, tempDir: tempDir, keepTemp: &currentKeepTemp, anchorsPath: anchorsPath)

        if stepwise {
            updatePidfileState(path: thePidfile, state: .done)
            var state = loadStepwiseState(session: session)!
            state.step = 0
            state.keepTemp = currentKeepTemp
            try saveStepwiseState(state, session: session)
            let hint = session.map { " -S \($0)" } ?? ""
            print("✓ Step 1/4: Capture complete.", to: &stderr)
            print("→ Run 'rec resume\(hint)' to continue.", to: &stderr)
            return  // exit — next step via resume
        }

        updatePidfileState(path: thePidfile, state: .mixing)

        // ======== Step 2: Mix ========
        try stepMix(sysWav: sysWav, micWav: micWav, mixWav: mixWav, micGain: micGain)
        mixedWav_ = mixWav

        updatePidfileState(path: thePidfile, state: .transcribing)

        // ======== Step 3: Transcribe ========
        try stepTranscribe(sysWav: sysWav, micWav: micWav, transcriptTxt: transcriptTxt, locale: locale, anchorsPath: anchorsPath)

        // ======== Check for empty transcript ========
        if isTranscriptEmpty(transcriptTxt) {
            print("Transcript is empty \u{2014} no speech detected.", to: &stderr)
            print("Stopping before summarization phase.", to: &stderr)
            updatePidfileState(path: thePidfile, state: .done)
            // Save stepwise state so user can resume with 'rec resume'
            let savedState = StepwiseState(
                step: 2,            // transcribe done
                duration: duration,
                interactiveMic: interactiveMic,
                micGainDB: micGainDB,
                locale: locale,
                outputDir: outputDir,
                keepTemp: currentKeepTemp,
                tempDir: tempDir,
                sysWav: sysWav,
                micWav: micWav,
                mixWav: mixWav,
                transcriptTxt: transcriptTxt,
                summaryMd: summaryMd,
                anchorsPath: anchorsPath,
                generatedTitle: ""
            )
            try saveStepwiseState(savedState, session: session)
            let hint = session.map { " -S \($0)" } ?? ""
            print("→ State saved. Run 'rec resume\(hint)' to continue after fixing the transcript.", to: &stderr)
            return
        }

        updatePidfileState(path: thePidfile, state: .summarizing)

        // ======== Step 4: Summarize ========
        let generatedTitle = stepSummarize(transcriptTxt: transcriptTxt, summaryMd: summaryMd)

        // If summarization failed and transcript wasn't empty, save state for resume
        if generatedTitle.isEmpty {
            print("Summarization did not complete. You can retry later.", to: &stderr)
            updatePidfileState(path: thePidfile, state: .done)
            let savedState = StepwiseState(
                step: 2,            // transcribe done
                duration: duration,
                interactiveMic: interactiveMic,
                micGainDB: micGainDB,
                locale: locale,
                outputDir: outputDir,
                keepTemp: currentKeepTemp,
                tempDir: tempDir,
                sysWav: sysWav,
                micWav: micWav,
                mixWav: mixWav,
                transcriptTxt: transcriptTxt,
                summaryMd: summaryMd,
                anchorsPath: anchorsPath,
                generatedTitle: ""
            )
            try saveStepwiseState(savedState, session: session)
            let hint = session.map { " -S \($0)" } ?? ""
            print("→ State saved. Run 'rec resume\(hint)' to retry summarization and finalize.", to: &stderr)
            return
        }

        updatePidfileState(path: thePidfile, state: .finalizing)

        // ======== Step 5: Finalize ========
        _ = stepFinalize(finalDir: finalDir, mixedWav: mixedWav_, summaryMd: summaryMd, generatedTitle: generatedTitle, keepTemp: currentKeepTemp, tempDir: tempDir)

        success = true
    } catch {
        print("Error: \(error)", to: &stderr)
        if pidfilePath != nil {
            updatePidfileState(path: thePidfile, state: .error, errorMessage: "\(error)")
        }
        exit(1)
    }
}

// MARK: - Resume stepwise session

@available(macOS 14.2, *)
func runResume(args: [String]) {
    // Parse -S/--session from args
    var session: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-S", "--session":
            session = args[safe: i + 1]; i += 2
        case "-h", "--help":
            print("""
Usage: rec resume [options]

Continues a stepwise recording pipeline from where it left off.

Options:
  -S, --session <name>    Session name to resume (default: unnamed session)

If the transcript is empty (no speech detected), summarization is
skipped and the session state stays at the current step so you can
re-record or re-transcribe, then run 'rec resume' again.

Examples:
  rec resume
  rec resume -S meeting-notes
""")
            return
        default:
            print("rec resume: unknown option \(args[i])", to: &stderr)
            exit(1)
        }
    }

    guard var state = loadStepwiseState(session: session) else {
        let hint = session.map { " for session '\($0)'" } ?? ""
        print("No stepwise session found\(hint). Start one with 'rec -s'.", to: &stderr)
        exit(1)
    }

    guard FileManager.default.fileExists(atPath: state.tempDir) else {
        print("Temporary directory no longer exists: \(state.tempDir)", to: &stderr)
        print("The session cannot be resumed. Removing state.", to: &stderr)
        removeStepwiseState(session: session)
        exit(1)
    }

    let sessionFlag = session.map { " -S \($0)" } ?? ""
    let micGain = pow(10, state.micGainDB / 20)
    let finalDir = resolveOutputDir(flag: state.outputDir)

    try? FileManager.default.createDirectory(atPath: finalDir, withIntermediateDirectories: true)

    do {
        switch state.step {
        case -1:
            // Run capture
            var keepTemp = state.keepTemp
            try stepCapture(sysWav: state.sysWav, micWav: state.micWav, duration: state.duration, interactiveMic: state.interactiveMic, tempDir: state.tempDir, keepTemp: &keepTemp, anchorsPath: state.anchorsPath)
            state.step = 0
            state.keepTemp = keepTemp
            try saveStepwiseState(state, session: session)
            print("✓ Step 1/4: Capture complete.", to: &stderr)
            print("→ Run 'rec resume\(sessionFlag)' to continue.", to: &stderr)

        case 0:
            // Run mix
            try stepMix(sysWav: state.sysWav, micWav: state.micWav, mixWav: state.mixWav, micGain: micGain)
            state.step = 1
            try saveStepwiseState(state, session: session)
            print("✓ Step 2/4: Mix complete.", to: &stderr)
            print("→ Run 'rec resume\(sessionFlag)' to continue.", to: &stderr)

        case 1:
            // Run transcribe
            try stepTranscribe(sysWav: state.sysWav, micWav: state.micWav, transcriptTxt: state.transcriptTxt, locale: state.locale, anchorsPath: state.anchorsPath)
            state.step = 2
            try saveStepwiseState(state, session: session)
            print("✓ Step 3/4: Transcribe complete.", to: &stderr)
            print("→ Run 'rec resume\(sessionFlag)' to continue.", to: &stderr)

        case 2:
            // Check for empty transcript before engaging summarization
            if isTranscriptEmpty(state.transcriptTxt) {
                print("Transcript is empty — no speech detected.", to: &stderr)
                print("Skipping summarization. State remains at current step.", to: &stderr)
                print("You can re-record or re-transcribe, then run 'rec resume\(sessionFlag)' again.", to: &stderr)
                return  // don't advance state
            }

            // Run summarize
            state.generatedTitle = stepSummarize(transcriptTxt: state.transcriptTxt, summaryMd: state.summaryMd)
            guard !state.generatedTitle.isEmpty else {
                print("Summarization did not complete. State remains at current step.", to: &stderr)
                print("Run 'rec resume\(sessionFlag)' again to retry.", to: &stderr)
                try saveStepwiseState(state, session: session)
                return  // don't advance state
            }
            state.step = 3
            try saveStepwiseState(state, session: session)
            print("✓ Step 4/4: Summarize complete.", to: &stderr)
            print("→ Run 'rec resume\(sessionFlag)' to continue to finalize.", to: &stderr)

        case 3:
            // Finalize — last step, clean up state afterwards
            _ = stepFinalize(finalDir: finalDir, mixedWav: state.mixWav, summaryMd: state.summaryMd, generatedTitle: state.generatedTitle, keepTemp: state.keepTemp, tempDir: state.tempDir)
            removeStepwiseState(session: session)
            if !state.keepTemp {
                cleanupTempDir(state.tempDir)
            }

        default:
            print("Unknown step \(state.step) in session state.", to: &stderr)
            exit(1)
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
    var pidfilePath: String?

    // Extract flags before positional args
    var positional: [String] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-d": duration = Int(args[safe: i + 1] ?? "0") ?? 0; i += 2
        case "-m": interactiveMic = true; i += 1
        case "--pidfile": pidfilePath = args[safe: i + 1]; i += 2
        case "-h", "--help":
            print("""
Usage: rec capture [options] <sys.wav> <mic.wav>

Captures system audio and microphone to two WAV files.
Both output paths are required positional arguments.

Flags:
  -d <secs>       Recording duration (default: until Ctrl+C)
  -m              Interactively select microphone input device
  --pidfile <path> Write JSON pidfile for menu-bar companion tracking

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

    let thePidfile = pidfilePath ?? defaultPidfilePath

    // Write pidfile when --pidfile is given
    if pidfilePath != nil {
        let pf = RecPidfile(
            pid: ProcessInfo.processInfo.processIdentifier,
            startTime: Date(),
            command: "capture",
            state: .capturing,
            tempDir: (sysPath as NSString).deletingLastPathComponent,
            outputDir: nil,
            session: nil
        )
        try? writePidfile(path: thePidfile, pf)
    }

    let capStatus = CaptureStatus()
    do {
        try CaptureEngine.capture(sysWavPath: sysPath, micWavPath: micPath, duration: duration, interactiveMic: interactiveMic, status: capStatus)
    } catch {
        print("Error: \(error)", to: &stderr)
        if pidfilePath != nil {
            updatePidfileState(path: thePidfile, state: .error, errorMessage: "\(error)")
        }
        exit(1)
    }

    if pidfilePath != nil {
        removePidfile(path: thePidfile)
    }

    // Warn about drift
    let driftPct = capStatus.driftPercent
    if driftPct > kDriftThreshold {
        print("⚠  Drift was \(String(format: "%.2f", driftPct))% — consider remixing with rec mix", to: &stderr)
    }
}

func runMix(_ args: [String]) {
    var micGainDB: Float = 0

    // Extract flags before positional args
    var positional: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-h", "--help":
            print("""
Usage: rec mix [options] <system.wav> <mic.wav> <output.wav|.m4a>

Reads two WAV files, resamples to match sample rates, detects and
corrects clock drift, and produces a stereo mix:
  left channel  = microphone
  right channel = system audio (summed to mono)

Output format is auto-detected from extension:
  .wav → stereo WAV (16-bit PCM)
  .m4a → AAC in M4A container

Flags:
  -g <dB>    Microphone gain in dB (default: 0)

Examples:
  rec mix sys.wav mic.wav mix.wav
  rec mix -g 6 sys.wav mic.wav mix.m4a
""")
            return
        case "-g":
            micGainDB = Float(args[safe: i + 1] ?? "0") ?? 0; i += 2
        default:
            positional.append(args[i])
            i += 1
        }
    }

    let micGain = pow(10, micGainDB / 20)  // convert dB to linear

    guard positional.count >= 3 else {
        print("Usage: rec mix [options] <system.wav> <mic.wav> <output.wav|.m4a>", to: &stderr)
        print("Run 'rec mix --help' for details.", to: &stderr)
        exit(1)
    }
    let sysPath = positional[0]
    let micPath = positional[1]
    let outPath = positional[2]

    do {
        try mixToFile(sysPath: sysPath, micPath: micPath, outputPath: outPath, micGain: micGain)
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
    }
}

func runTranscribe(_ args: [String]) {
    var format: TranscriptFormat = .txt
    
    var locale: String?

    // Extract flags before positional args
    var positional: [String] = []
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-l", "--locale": locale = args[safe: i + 1]; i += 2
        case "-h", "--help":
            print("""
Usage: rec transcribe [options] <sys.wav> <mic.wav> <out>

Transcribes system and mic WAVs independently using yap, then merges
segments chronologically with speaker labels (Me / Them).

Drift correction uses per-second time anchors (from `anchors.json`)
when available in the same directory as the WAV files, falling back
to a WAV-duration ratio otherwise.

Output format is inferred from the output file extension:
  .txt → plain text   .srt → SubRip   .vtt → WebVTT   .json → JSON

Flags:
  -l, --locale <L>    Locale for speech recognition (e.g. fr-FR)

Examples:
  rec transcribe sys.wav mic.wav transcript.txt
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
    config.locale = locale
    config.systemWavOverride = sysWav
    config.micWavOverride = micWav
    config.transcriptOverride = outPath
    // No anchors path for standalone `rec transcribe` — user would need to provide one

    do {
        try transcribe(config: config)
    } catch {
        print("Error: \(error)", to: &stderr)
        exit(1)
    }
}

func runSummarize(_ args: [String]) {
    if args.contains("-h") || args.contains("--help") {
        print("""
Usage: rec summarize <input.txt> <output.md>

Creates a markdown file with an AI-generated title and summary (via pi)
followed by the full transcript with bold speaker labels.

Both paths are required.

Examples:
  rec summarize transcript.txt ~/Desktop/notes.md
""")
        return
    }

    guard args.count >= 2 else {
        print("Usage: rec summarize <input.txt> <output.md>", to: &stderr)
        exit(1)
    }

    let transcriptPath = args[0]
    let outputPath = args[1]

    do {
        _ = try summarize(transcriptPath: transcriptPath, outputPath: outputPath)
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
