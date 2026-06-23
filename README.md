# rec — macOS System Audio + Microphone Recorder

Single-binary tool to **capture**, **mix**, **transcribe**, and **summarize**
system audio + microphone on macOS 14.2+.  One command gives you a compressed
stereo audio file (mic left, system right), a speaker-labeled transcript,
and an AI-generated markdown summary.

- **No external audio dependencies** — CoreAudio capture, built-in AAC encoding via `afconvert`
- **No kernel extensions** — uses process tap + aggregate device
- **Lock-free ring buffers** — real-time safe audio IOProc threads
- **Zero runtime deps for capture + mix** — only needs `yap` for transcription
  and `pi` for summarization

## Quick start

```sh
swift run rec -d 10             # record 10 seconds → ~/Documents/Recordings/
play ~/Documents/Recordings/2026-06-23_*.m4a
```

Or install the built binary somewhere on your `PATH`:

```sh
swift build -c release
cp .build/release/rec ~/bin/
rec -d 10
```

## Requirements

- **macOS 14.2+** (Sonoma or later)
- **Xcode Command Line Tools** (`xcode-select --install`)
- **yap** — on-device speech transcription (`brew install yap`)
- **pi** — AI-powered summarization (`npm install -g @earendil-works/pi-coding-agent`)
- **afconvert** — built-in, always available on macOS (no brew install needed)

All other dependencies are built-in macOS frameworks (CoreAudio, AudioToolbox, Accelerate).

## Build

```sh
swift build -c release
# binary is at .build/release/rec
```

## Usage

### Full pipeline

```sh
rec                                          # capture (Ctrl+C) → mix → transcribe → summarize
rec -d 30                                    # capture for 30 seconds
rec -d 10 -o meeting                         # session name for fallback filename
rec -d 10 -m                                 # interactively select microphone
rec -d 10 --srt --censor                     # SRT subtitles with censoring
rec -d 15 --vtt --locale fr-FR               # WebVTT in French
rec --output-dir ~/Desktop                   # custom output directory
rec --keep-temp                              # preserve scratch WAVs after run
```

### Subcommands

```sh
rec capture -d 10                            # just capture raw WAVs
rec capture -d 5 -m                          # capture with interactive mic selection
rec mix sys.wav mic.wav mix.m4a             # mix to AAC stereo (or .wav)
rec transcribe --json                        # transcribe existing WAVs
rec summarize                                # create summary from latest transcript
```

### Completions

Generate shell completions and source in your `.zshrc` or `.bashrc`:

```sh
rec --generate-completion-script zsh > ~/.zsh/completions/_rec
rec --generate-completion-script bash > ~/.bash_completion.d/rec
```

## Output layout

Scratch WAVs live in a temporary directory (`$TMPDIR/rec.<uuid>/`) and are
cleaned up on success.  Final deliverables go to `~/Documents/Recordings/`
(iCloud-synced by default).

| Stage | Temp file | Final file |
|-------|-----------|------------|
| Capture | `sys.wav`, `mic.wav` | — |
| Mix | `mix.wav` | — |
| Encode | — | `YYYY-MM-DD_title.m4a` |
| Transcribe | `transcript.txt` | — (embedded in markdown) |
| Summarize | — | `YYYY-MM-DD_title.md` |

### Naming

- **With AI summary**: `2026-06-23_meeting_notes.m4a` + `.md` (title from pi)
- **Session name fallback** (`-o meeting`): `2026-06-23_meeting.m4a`
- **Timestamp fallback**: `2026-06-23_143022.m4a`

### Configuration

| Option | Env var | Default |
|--------|---------|---------|
| `--output-dir <path>` | `REC_DIR` | `~/Documents/Recordings/` |
| `--keep-temp` | — | scratch cleaned on success |

## How it works

1. **System audio**: Creates a **process tap** (`AudioHardwareCreateProcessTap`)
   that captures every application's audio output, wrapped in a private
   **aggregate device** so CoreAudio presents it as a regular input device.
2. **Microphone**: Opens the default input device (or user-selected with `-m`).
   A second I/O procedure is registered on the chosen device.
3. **Ring buffers**: Both IOProcs write Float32 samples into separate
   lock‑free SPSC ring buffers (backed by C11 `_Atomic` for real-time safety).
4. **Write loop**: A polling loop drains each ring buffer independently
   and writes raw PCM to its own WAV file.
5. **Mix**: Reads both WAVs, detects clock drift by sample-count ratio,
   resamples mic to match system rate (linear interpolation), stretches
   mic to match system duration, and mixes to stereo (mic left, system right).
6. **Encode**: Encodes to AAC in M4A container via `afconvert` (built into macOS).
7. **Transcribe**: Runs `yap transcribe` on each source, merges segments
   chronologically with speaker labels (Me / Them), applies drift correction.
8. **Summarize**: Sends transcript to `pi -p` for AI title + summary,
   writes markdown with both summary and full transcript.

## Permissions

macOS may prompt for **Audio Capture** permission the first time you run
the tool (System Settings → Privacy & Security → Audio Capture).
For microphone recording, macOS will also prompt for **Microphone** access.

## Speaker labels

| Source | In transcript | In markdown |
|--------|---------------|-------------|
| Microphone | `Me:` | **Me:** |
| System audio | `Them:` | **Them:** |

## Output formats

| Flag | Format | Description |
|------|--------|-------------|
| (default) | `txt` | Plain text, `Me`/`Them` labels, no timestamps |
| `--srt` | SRT | SubRip subtitles with `[Me]`/`[Them]` prefix |
| `--vtt` | WebVTT | WebVTT format for browsers |
| `--json` | JSON | Full merged data with word timestamps |

## Project structure

```
Sources/
  CBridge/             C/ObjC bridge (separate target for SPM)
    RingBuffer.c/.h     Lock-free SPSC ring buffer (C11 _Atomic)
    TapBridge.m/.h      CoreAudio process tap wrapper (ObjC)
  rec/                 Swift sources
    main.swift          CLI entry + full pipeline orchestration
    Capture.swift       CoreAudio capture engine
    Mixer.swift         WAV mixing + drift correction
    Transcribe.swift    yap-based transcription with speaker labels
    Summarize.swift     pi-based AI summarization
    Encode.swift        AAC encoding via afconvert
    Errors.swift        Error types
    Types.swift         Shared types + output directory helpers
```

## License

MIT
