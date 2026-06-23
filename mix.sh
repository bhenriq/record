#!/usr/bin/env bash
# mix.sh — post-process separate system + mic tracks into mono MP3
#
# Automatically corrects clock drift by measuring the exact sample counts
# and stretching the mic track to match the system track's duration.
# Then mixes system and mic equally into a single mono MP3 at 128 kbps.
#
# Usage:
#   ./mix.sh output_system.wav output_mic.wav output.mp3

set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage: $0 <system.wav> <mic.wav> <output.mp3>" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 output_system.wav output_mic.wav output.mp3" >&2
    echo "  $0 recording_system.wav recording_mic.wav recording.mp3" >&2
    exit 1
fi

SYS="$1"
MIC="$2"
OUT="$3"
DRIFT_THRESHOLD=0.0001   # 0.01% — skip correction below this

# Check which tools are available
HAVE_SOX=0
HAVE_FFMPEG=0

if command -v sox &>/dev/null; then
    HAVE_SOX=1
elif command -v ffmpeg &>/dev/null; then
    HAVE_FFMPEG=1
else
    echo "Error: need either 'sox' or 'ffmpeg' installed." >&2
    echo "  Install with: brew install sox" >&2
    echo "  Or:          brew install ffmpeg" >&2
    exit 1
fi

echo "System: $SYS"
echo "Mic:    $MIC"
echo "Output: $OUT"
echo ""

# ---- Read metadata ----
if [ "$HAVE_SOX" -eq 1 ]; then
    SYS_RATE=$(soxi -r "$SYS")
    MIC_RATE=$(soxi -r "$MIC")
    SYS_SAMPLES=$(soxi -s "$SYS")
    MIC_SAMPLES=$(soxi -s "$MIC")
else
    SYS_RATE=$(ffprobe -v error -show_entries stream=sample_rate -of default=noprint_wrappers=1:nokey=1 "$SYS")
    MIC_RATE=$(ffprobe -v error -show_entries stream=sample_rate -of default=noprint_wrappers=1:nokey=1 "$MIC")
    SYS_SAMPLES=$(ffprobe -v error -show_entries stream=nb_samples -of default=noprint_wrappers=1:nokey=1 "$SYS")
    MIC_SAMPLES=$(ffprobe -v error -show_entries stream=nb_samples -of default=noprint_wrappers=1:nokey=1 "$MIC")
fi

SYS_SECS=$(echo "scale=3; $SYS_SAMPLES / $SYS_RATE" | bc -l)
MIC_SECS=$(echo "scale=3; $MIC_SAMPLES / $MIC_RATE" | bc -l)

echo "  rate: ${SYS_RATE} Hz   samples: ${SYS_SAMPLES}   duration: ${SYS_SECS}s"
echo "  rate: ${MIC_RATE} Hz   samples: ${MIC_SAMPLES}   duration: ${MIC_SECS}s"

# ---- Drift correction ----
RATIO=$(echo "scale=10; $SYS_SAMPLES / $MIC_SAMPLES" | bc -l)
DRIFT=$(echo "scale=10; if ($RATIO > 1) $RATIO - 1 else 1 - $RATIO" | bc -l)

NEEDS_CORRECTION=$(echo "$DRIFT > $DRIFT_THRESHOLD" | bc -l)

if [ "$NEEDS_CORRECTION" = "1" ]; then
    echo ""
    echo "  ⚠  Clock drift detected: ${DRIFT} (ratio ${RATIO})"
    echo "     Correcting by stretching/compressing mic track..."

    TEMPO=$(echo "scale=10; 1 / $RATIO" | bc -l)
    MIC_ALIGNED="/tmp/mix_mic_$$.wav"
    if [ "$HAVE_SOX" -eq 1 ]; then
        sox "$MIC" "$MIC_ALIGNED" tempo -s "$TEMPO"
    else
        ffmpeg -i "$MIC" -filter:a "atempo=${TEMPO}" -y "$MIC_ALIGNED"
    fi
    MIC_FINAL="$MIC_ALIGNED"

    echo "  Drift correction applied (tempo factor: $TEMPO)"
else
    echo "  ✓ No significant drift detected"
    MIC_FINAL="$MIC"
fi

echo ""

# ---- Mix to mono & encode to MP3 ----
# Equal mix: system at 50%, mic at 50%.
# System is stereo, so sys[L]*0.25 + sys[R]*0.25 = system_mono * 0.5
# Mic is mono: mic * 0.5

if [ "$HAVE_SOX" -eq 1 ]; then
    echo "Mixing to mono MP3 with SoX (128k)..."

    # -M merges: ch1=sysL  ch2=sysR  ch3=mic
    # remix sums channels with custom weights, then SoX outputs mono
    # -C 128 sets MP3 bitrate
    sox -M "$SYS" "$MIC_FINAL" -C 128 "$OUT" \
        remix 1v0.25,2v0.25,3v0.5

    echo "Done: $OUT"
else
    echo "Mixing to mono MP3 with ffmpeg (128k)..."

    ffmpeg -i "$SYS" -i "$MIC_FINAL" \
        -filter_complex "[0:a]pan=mono|c0=0.5*FL+0.5*FR[sys]; \
                         [1:a]aformat=sample_rates=${SYS_RATE}[mic]; \
                         [sys][mic]amix=inputs=2:duration=first:weights=0.5 0.5[a]" \
        -map "[a]" -c:a libmp3lame -b:a 128k -y "$OUT"

    echo "Done: $OUT"
fi

# ---- Cleanup ----
if [ "$NEEDS_CORRECTION" = "1" ] && [ -n "${MIC_ALIGNED:-}" ]; then
    rm -f "$MIC_ALIGNED"
fi
