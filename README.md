# record — macOS System Audio + Microphone Recorder

All-in-one toolchain to **record**, **mix**, and **transcribe** system audio
and microphone on macOS.  One command gives you a mono MP3 *and* a
speaker-labeled transcript.

- `rec` — unified entry point (capture → mix → transcribe)
- `./capture` — low-level recorder (produces two separate WAV files)
- `rec mix` / `rec transcribe` — post-processing subcommands

Uses only **CoreAudio** — no third-party drivers, no kernel extensions, no
BlackHole, no Soundflower.

## Quick start

```sh
rec -d 10             # record 10 seconds → MP3 + transcript
play output.mp3       # listen back
cat output_transcript.txt
```

## Requirements

- **macOS 14.2+** (Sonoma or later)
- Xcode Command Line Tools (`xcode-select --install`)
- **SoX** or **ffmpeg** for post-processing (`brew install sox`)
- **yap** for speech transcription (`brew install yap`)
- **jq** for JSON merging (`brew install jq`)

## Build

```sh
make
```

Or directly:

```sh
cc -o capture capture.m -framework CoreAudio -framework Foundation
```

## Usage

### `rec` — full pipeline

```sh
rec                                          # capture (Ctrl+C) → mix → transcribe
rec -d 30                                    # capture for 30 seconds
rec -d 30 -o meeting                         # custom base name
rec -d 10 -m                                 # interactively select microphone
rec -d 10 --srt --censor                     # SRT subtitles with censoring
rec -d 15 --vtt --locale fr-FR               # WebVTT in French
```

Runs all three stages in sequence:
1. **Capture** — record system + mic to separate WAV files
2. **Mix** — align clock drift, mix to mono MP3 (`{base}.mp3`)
3. **Transcribe** — speech-to-text with speaker labels (`{base}_transcript.*`)

### Subcommands

You can run any stage individually:

```sh
rec capture -d 10 -m                         # just capture
rec mix output_system.wav output_mic.wav out.mp3   # just mix
rec transcribe -o output --srt --censor      # just transcribe
```

### `./capture` — low-level recorder

```sh
./capture                               # record to output_system.wav + output_mic.wav
./capture -o recording                  # custom base name
./capture -d 10                         # record for 10 seconds
./capture -o test -d 5                  # both
./capture -m                            # interactively select microphone
./capture -m -o test -d 10              # interactive mic + custom options
```

| Option | Description |
|--------|-------------|
| `-o base` | Output file base name (default: `output`) |
| `-d secs` | Recording duration in seconds (default: until Ctrl+C) |
| `-m`      | Interactively select the microphone input device |

When `-m` is used, the tool lists all available audio input devices in
alphabetical order and prompts you to pick one by number:

```
Available input devices:
  1. BlackHole 2ch (2 ch, 48000 Hz)
  2. iPhone B Microphone (1 ch, 48000 Hz)
  3. MacBook Air Microphone (1 ch, 48000 Hz)
  4. OpenSwim Pro by Shokz (1 ch, 16000 Hz)
  5. System Audio Recorder (2 ch, 48000 Hz)

Select microphone [1-5]:
```

Without `-m`, the default system input device is used automatically.

If no microphone is available (e.g. Mac Mini with no input device), the
mic file will contain silence and a warning is printed.

## Mixing — `rec mix` / `mix.sh`

Produces a mono MP3 from the two WAV files, correcting clock drift automatically:

```sh
rec mix output_system.wav output_mic.wav output.mp3
# or: ./mix.sh output_system.wav output_mic.wav output.mp3
```

`mix.sh` (and `rec mix`) automatically:

1. **Detects clock drift** by comparing the sample counts of both tracks
2. **Corrects drift** using SoX's `tempo -s` (pitch-preserving, optimised for speech)
3. **Mixes equally** — system and microphone at the same level
4. **Encodes to MP3** at 128 kbps, 48 kHz, mono

## Transcription — `rec transcribe` / `transcribe.sh`

Creates a speaker-labeled transcript from the two WAV files:

```sh
rec transcribe                                   # output_transcript.txt
rec transcribe -o recording                      # custom base name
rec transcribe -o recording --srt                # SRT subtitles
rec transcribe -o recording --vtt                # WebVTT subtitles
rec transcribe -o recording --json               # full merged JSON
rec transcribe --censor                          # redact sensitive words
rec transcribe --locale fr-FR                    # specify locale
```

How it works:

1. **Transcribes each source independently** with `yap transcribe --json --word-timestamps`
2. **Corrects clock drift** using the same sample‑count ratio as the mixer
3. **Merges chronologically** — all segments from both speakers are
   interleaved by timestamp and labeled `[System]` or `[Mic]`

### Output formats

| Format | Description | Example |
|--------|-------------|---------|
| `txt` (default) | Plain text with `[Speaker MM:SS.X]` prefix | `[Mic 00:01.2] Hi there` |
| `srt` | SubRip subtitles with speaker prefix | `[System] Welcome everyone` |
| `vtt` | WebVTT format, suitable for browsers | `[Mic] Thanks for having me` |
| `json` | Full merged data structure with speaker on every segment/word | Machine-readable |

### Dependencies

- **yap** — on-device speech transcription (`brew install yap`)
- **jq** — JSON processor (`brew install jq`)
- **sox** or **ffmpeg** — for sample-count metadata (already needed by the mixer)

## Manual SoX alternative

```sh
# Align mic to system duration
TEMPO=$(echo "scale=10; $(soxi -s output_system.wav) / $(soxi -s output_mic.wav)" | bc -l)
sox output_mic.wav mic_aligned.wav tempo -s $(echo "scale=10; 1/$TEMPO" | bc -l)

# Mix to mono (equal parts) and encode to MP3
sox -M output_system.wav mic_aligned.wav -C 128 output.mp3 remix 1v0.25,2v0.25,3v0.5

rm -f mic_aligned.wav
```

## How it works

1. **System audio**: Creates a **process tap** (`AudioHardwareCreateProcessTap`)
   that captures every application's audio output, wrapped in a private
   **aggregate device** so CoreAudio presents it as a regular input device.
2. **Microphone**: By default, opens the system's default input device
   (`kAudioHardwarePropertyDefaultInputDevice`). When `-m` is given, all
   input devices are enumerated and the user selects one interactively.
   A second **I/O procedure** is registered on the chosen device.
3. **Ring buffers**: Both IOProcs write Float32 samples into separate
   lock‑free SPSC ring buffers — no file I/O on the real‑time threads.
4. **Write loop**: A polling loop drains each ring buffer independently
   and writes the raw PCM data to its own WAV file.  No mixing, no sample‑rate
   conversion, no inter‑channel synchronization.
5. **Post‑processing**: The separate tracks are aligned via sample‑count
   ratio and mixed to a mono MP3 with SoX or ffmpeg.

## Permissions

macOS may prompt for **Audio Capture** permission the first time you run
the tool.  If it fails with a permissions error, check **System Settings →
Privacy & Security → Audio Capture**.

For microphone recording, macOS will also prompt for **Microphone** access.

## File formats

| File          | Sample rate       | Channels | Encoding |
|---------------|-------------------|----------|----------|
| Raw system    | Aggregate device  | 2        | PCM WAV  |
| Raw mic       | Mic's native rate | 1        | PCM WAV  |
| Mix output    | 48 000 Hz         | 1        | MP3 128k |

## Zsh completions

Source `rec` in your `.zshrc` to enable tab completions for all subcommands
and flags:

```sh
# .zshrc
export REC_HOME=/path/to/record  # adjust to your setup
source $REC_HOME/rec
```

After `compinit`, pressing `Tab` after `rec ` offers subcommands (`capture`,
`mix`, `transcribe`) and pipeline flags.  Typing `rec capture -` and pressing
`Tab` shows capture-specific options, etc.

## Files

| File | Purpose |
|------|---------|
| `rec` | Unified entry point (functions + zsh completions) |
| `capture.m` | CoreAudio recorder (Objective-C source) |
| `capture` | Compiled binary |
| `mix.sh` | Thin wrapper around `rec mix` |
| `transcribe.sh` | Thin wrapper around `rec transcribe` |
| `Makefile` | Builds `capture` from source |

## License

MIT
