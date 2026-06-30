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

### Menu Bar App

Build and install the menu bar companion by adding `--include-menu`:

```sh
./setup.sh build --include-menu       # build rec CLI + Rec.app
./setup.sh install --include-menu      # build + install both
```

`Rec.app` is installed to `/Applications/`. Launch from Spotlight as **Rec**.

If you get permission errors, re-run with `sudo`:

```sh
sudo ./setup.sh install --include-menu
```

## Usage

### Full pipeline

```sh
rec                                          # capture (Ctrl+C) → mix → transcribe → summarize
rec -d 30                                    # capture for 30 seconds
rec -d 10 -m                                 # interactively select microphone
rec -d 15 -l fr-FR                           # specify locale
rec -o ~/Desktop                             # custom output directory
rec -k                                       # preserve scratch WAVs after run
rec -g 6                                     # boost mic by 6dB
rec --pidfile ~/.rec/current.json            # write JSON status file (for menu bar app)

If no speech is detected, the transcript will be empty and the
pipeline stops before summarization, saving state so you can
resume with `rec resume` after re-recording or re-transcribing.
```

### Step-by-step mode

Run the pipeline one step at a time, inspecting or manipulating intermediate
files between steps.  Each invocation runs one step and exits — re-run to
get to the next step.

```sh
rec -s -d 30                 # Step 1: Capture only, then pause
rec resume                   # Step 2: Mix
rec resume                   # Step 3: Transcribe
rec resume                   # Step 4: Summarize
rec resume                   # Step 5: Finalize + cleanup
```

Multiple concurrent sessions are supported with named sessions:

```sh
rec -s -d 60 -S meeting-notes   # start a named session
rec resume -S meeting-notes     # resume that specific session
```

State is stored in `~/.rec/state.json` (or `~/.rec/sessions/<name>.json`)
and removed automatically after the finalize step.

If the transcript is empty (no speech detected), summarization is
skipped and the session state stays at the current step. Run
`rec resume` again after re-recording or re-transcribing to
continue.

### Subcommands

```sh
rec capture -d 10 sys.wav mic.wav            # capture to explicit WAV paths
rec capture -d 5 -m meeting_sys.wav meeting_mic.wav  # with mic selection
rec mix sys.wav mic.wav mix.m4a             # mix to AAC stereo (or .wav)
rec transcribe sys.wav mic.wav transcript.txt  # transcribe with speaker labels
rec summarize transcript.txt ~/Desktop/notes.md  # create summary with explicit output path
rec resume [-S <session>]                    # continue stepwise pipeline
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
- **Timestamp fallback**: `2026-06-23_143022.m4a`

### Configuration

| Option | Env var | Default |
|--------|---------|---------|
| `-o, --output-dir <path>` | `REC_DIR` | `~/Documents/Recordings/` |
| `-k, --keep-temp` | — | scratch cleaned on success |
| `-g <dB>` | — | 0 dB (no boost) |
| `-s, --stepwise` | — | off |
| `-S, --session <name>` | — | unnamed session |

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

   If the transcript is empty (no speech detected), this step is
   skipped entirely. The pipeline stops, saves its state, and waits
   for you to run `rec resume` after re-recording or re-transcribing.

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
Format is inferred from output file extension: `.txt`, `.srt`, `.vtt`, `.json`.

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
    Stepwise.swift      Stepwise session state persistence
    Encode.swift        AAC encoding via afconvert
    Errors.swift        Error types
    Types.swift         Shared types + output directory helpers
```

## Menu Bar App (RecMenu)

A lightweight menu bar companion that lets you start and stop `rec` recordings
with a single click. The icon shows:
- **Gray dot** — idle (no recording)
- **Red dot (pulsing)** — recording in progress
- **Orange dot** — processing (mixing / transcribing / summarizing)
- **Brown dot with !** — error

### Build & Install

```sh
# Build + install both CLI and menu bar app:
sudo ./setup.sh install --include-menu

# Or build the .app bundle without installing:
./setup.sh build --include-menu

# Or use the script directly:
./Scripts/build-menu-app.sh
```

Then launch **Rec** from Spotlight or `/Applications/`. It will
appear in the menu bar (no Dock icon).

### How it works

The menu bar app:
1. Locates the `rec` binary on your PATH or at common install locations.
2. When you click **Start**, it launches `rec` with `--pidfile` to write a
   JSON status file to `~/.rec/current.json`.
3. It polls that pidfile every 0.5s to update the icon (capturing → mixing →
   transcribing → summarizing → done).
4. When you click **Stop**, it sends SIGINT to `rec`, which gracefully stops
   capture and continues the pipeline (mix → transcribe → summarize).
5. On launch, it checks for orphaned pidfiles and re-attaches if `rec` is
   still running.

### Troubleshooting

If the icon shows an error state:
- Make sure `rec` is installed and on your PATH.
- Check `~/.rec/current.json` for error details.
- Run `rec` from the terminal to see full error output.

## License

MIT
