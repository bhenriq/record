# record — macOS System Audio + Microphone Recorder

Captures **system audio** (speaker output) and **microphone** simultaneously
and saves them as a single 48 kHz 16‑bit **WAV** file.

**Channel layout:**

| Channel | Content |
|---------|---------|
| L       | System audio (stereo mixed to mono) |
| R       | Microphone (mono) |

Uses only **CoreAudio** — no third-party drivers, no kernel extensions, no
BlackHole, no Soundflower.

## Requirements

- **macOS 14.2+** (Sonoma or later)
- Xcode Command Line Tools (`xcode-select --install`)

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
./capture                               # record to output.wav, stop with Ctrl+C
./capture -o test.wav                   # custom output file
./capture -d 10                         # record for 10 seconds
./capture -o test.wav -d 5              # both
./capture -m                            # interactively select microphone
./capture -m -o test.wav -d 10          # interactive mic + custom options
```

### Options

| Option | Description |
|--------|-------------|
| `-o file` | Output WAV file (default: `output.wav`) |
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

If no microphone is available (e.g. Mac Mini with no input device), the R
channel will be silence and a warning is printed.

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
4. **Write loop**: A polling loop drains both ring buffers, mixes system
   audio to mono, interleaves L=sys R=mic, converts to SInt16, and appends
   to the WAV file.
5. **Clock drift**: The system tap serves as the reference clock. If the
   microphone ring buffer has fewer frames (slower clock), the R channel is
   padded with silence; if it has more (faster clock), excess samples
   accumulate and are trimmed at a watermark. This handles built‑in,
   Bluetooth, and USB devices without external sample‑rate conversion.

## Permissions

macOS may prompt for **Audio Capture** permission the first time you run
the tool.  If it fails with a permissions error, check **System Settings →
Privacy & Security → Audio Capture**.

For microphone recording, macOS will also prompt for **Microphone** access.

## File format

| Property       | Value          |
|----------------|----------------|
| Sample rate    | 48 000 Hz *    |
| Channels       | 2 (split)      |
| Bit depth      | 16             |
| Encoding       | PCM (WAV)      |

\* Sample rate is read from the system audio aggregate device. The
microphone's native rate is accepted as‑is; any rate mismatch is handled
by the ring‑buffer drift compensation.

## License

MIT
