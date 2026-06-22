# record — Minimal macOS System-Audio Loopback Recorder

Captures whatever is playing through your Mac's speakers and saves it as a
48 kHz 16‑bit stereo **WAV** file.

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
./capture                   # record to output.wav, stop with Ctrl+C
./capture -o test.wav       # custom output file
./capture -d 10             # record for 10 seconds
./capture -o test.wav -d 5  # both
```

## How it works

1. Creates a **process tap** (`AudioHardwareCreateProcessTap`) that captures
   every application's audio output.
2. Wraps the tap in a **private aggregate device** so CoreAudio presents it
   as a regular input device.
3. Registers an **I/O procedure** (`AudioDeviceCreateIOProcID`) on that
   aggregate device to receive raw Float32 audio.
4. Converts the float samples to 16‑bit integers and writes them to a WAV
   file.

## Permissions

macOS may prompt for **Audio Capture** permission the first time you run
the tool.  If it fails with a permissions error, check **System Settings →
Privacy & Security → Audio Capture**.

## File format

| Property       | Value          |
|----------------|----------------|
| Sample rate    | 48 000 Hz      |
| Channels       | 2 (stereo)     |
| Bit depth      | 16             |
| Encoding       | PCM (WAV)      |

## License

MIT
