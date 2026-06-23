# record — macOS System Audio + Microphone Recorder

Captures **system audio** (speaker output) and **microphone** simultaneously
and saves them as two separate 16‑bit **WAV** files:

- `{base}_system.wav` — system audio (stereo, at the aggregate device rate)
- `{base}_mic.wav`    — microphone (mono, at the mic's native rate)

The two tracks are **not mixed in real time**.  Each is recorded
independently at its own sample rate, which avoids the crackling and
clock‑drift artifacts that plague real-time mixing.  Use the included
`mix.sh` script to align and merge them into a mono MP3 afterwards.

Uses only **CoreAudio** — no third-party drivers, no kernel extensions, no
BlackHole, no Soundflower.

## Requirements

- **macOS 14.2+** (Sonoma or later)
- Xcode Command Line Tools (`xcode-select --install`)
- **SoX** or **ffmpeg** for post-processing (`brew install sox`)

## Build

```sh
make
```

Or directly:

```sh
cc -o capture capture.m -framework CoreAudio -framework Foundation
```

## Usage

```sh
./capture                               # record to output_system.wav + output_mic.wav
./capture -o recording                  # custom base name
./capture -d 10                         # record for 10 seconds
./capture -o test -d 5                  # both
./capture -m                            # interactively select microphone
./capture -m -o test -d 10              # interactive mic + custom options
```

### Options

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

## Post‑processing

After recording, use the included `mix.sh` script to produce a mono MP3:

```sh
./mix.sh output_system.wav output_mic.wav output.mp3
```

`mix.sh` automatically:

1. **Detects clock drift** by comparing the sample counts of both tracks
2. **Corrects drift** using SoX's `tempo -s` (pitch-preserving, optimised for speech)
3. **Mixes equally** — system and microphone at the same level
4. **Encodes to MP3** at 128 kbps, 48 kHz, mono

For a quick example:

```sh
./capture -d 10          # record 10 seconds
./mix.sh output_system.wav output_mic.wav output.mp3
play output.mp3          # listen back
```

### Manual SoX alternative

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

## License

MIT
