#!/usr/bin/env bash
# transcribe.sh — transcribe system + mic recordings with speaker labels
#
# Uses yap (Apple on‑device speech recognition) to transcribe both the
# system audio and microphone WAV files produced by ./capture, then merges
# them into a single interleaved transcript with speaker attribution.
#
# Clock drift between the two independent recordings is corrected using
# the same sample‑count ratio approach as mix.sh.
#
# Usage:
#   ./transcribe.sh                          # output_transcript.txt
#   ./transcribe.sh -o recording             # custom base name
#   ./transcribe.sh -o recording --srt       # SRT subtitles
#   ./transcribe.sh -o recording --vtt       # WebVTT subtitles
#   ./transcribe.sh -o recording --json      # full merged JSON
#   ./transcribe.sh --censor                 # enable word censoring
#   ./transcribe.sh --locale fr-FR           # specify locale
#
# Output is written to {base}_transcript.{txt,srt,vtt,json}.

set -euo pipefail

# ---- Config ----
BASE="output"
FORMAT="txt"
YAP_OPTS=()

# ---- Parse arguments ----
while [ $# -gt 0 ]; do
    case "$1" in
        -o) BASE="$2"; shift 2 ;;
        --txt) FORMAT="txt"; shift ;;
        --srt) FORMAT="srt"; shift ;;
        --vtt) FORMAT="vtt"; shift ;;
        --json) FORMAT="json"; shift ;;
        --censor) YAP_OPTS+=(--censor); shift ;;
        --locale) YAP_OPTS+=(--locale "$2"); shift 2 ;;
        --help|-h)
            sed -n '3,17p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; echo "Usage: $0 [-o base] [--txt|--srt|--vtt|--json] [--censor] [--locale L]" >&2; exit 1 ;;
    esac
done

SYS="${BASE}_system.wav"
MIC="${BASE}_mic.wav"
OUT="${BASE}_transcript.${FORMAT}"

# ---- Check dependencies ----
command -v yap >/dev/null 2>&1 || { echo "Error: 'yap' not found. Install with: brew install yap" >&2; exit 1; }
command -v jq  >/dev/null 2>&1 || { echo "Error: 'jq' not found. Install with: brew install jq" >&2; exit 1; }

HAVE_SOX=0
command -v sox >/dev/null 2>&1 && HAVE_SOX=1
HAVE_FFMPEG=0
command -v ffprobe >/dev/null 2>&1 && HAVE_FFMPEG=1

if [ "$HAVE_SOX" -eq 0 ] && [ "$HAVE_FFMPEG" -eq 0 ]; then
    echo "Error: need 'sox' or 'ffmpeg' for metadata (sample counts)." >&2
    echo "  Install with: brew install sox" >&2
    exit 1
fi

# ---- Check source files ----
SYS_EXISTS=0
MIC_EXISTS=0
[ -f "$SYS" ] && SYS_EXISTS=1
[ -f "$MIC" ] && MIC_EXISTS=1

if [ "$SYS_EXISTS" -eq 0 ] && [ "$MIC_EXISTS" -eq 0 ]; then
    echo "Error: neither $SYS nor $MIC found." >&2
    exit 1
fi

echo "Inputs:" >&2
[ "$SYS_EXISTS" -eq 1 ] && echo "  system:  $SYS" >&2
[ "$MIC_EXISTS" -eq 1 ] && echo "  mic:     $MIC" >&2
echo "  format:  $FORMAT" >&2
echo "  output:  $OUT" >&2

# ---- Temp files ----
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

SYS_JSON="$TMPDIR/system.json"
MIC_JSON="$TMPDIR/mic.json"
MERGED_JSON="$TMPDIR/merged.json"

# ---- Phase 1: Transcribe with yap ----
if [ "$SYS_EXISTS" -eq 1 ]; then
    echo "  transcribing system audio..." >&2
    yap transcribe --json --word-timestamps "${YAP_OPTS[@]}" "$SYS" -o "$SYS_JSON" >/dev/null
fi

if [ "$MIC_EXISTS" -eq 1 ]; then
    echo "  transcribing microphone..." >&2
    yap transcribe --json --word-timestamps "${YAP_OPTS[@]}" "$MIC" -o "$MIC_JSON" >/dev/null
fi

# ---- Phase 2: Compute drift ratio ----
RATIO="1.0"
if [ "$SYS_EXISTS" -eq 1 ] && [ "$MIC_EXISTS" -eq 1 ]; then
    if [ "$HAVE_SOX" -eq 1 ]; then
        SYS_SAMPLES=$(soxi -s "$SYS")
        MIC_SAMPLES=$(soxi -s "$MIC")
    else
        SYS_SAMPLES=$(ffprobe -v error -show_entries stream=nb_samples -of default=noprint_wrappers=1:nokey=1 "$SYS")
        MIC_SAMPLES=$(ffprobe -v error -show_entries stream=nb_samples -of default=noprint_wrappers=1:nokey=1 "$MIC")
    fi

    if [ "$MIC_SAMPLES" -ne 0 ]; then
        RATIO=$(echo "scale=10; $SYS_SAMPLES / $MIC_SAMPLES" | bc -l)
        DRIFT=$(echo "scale=10; if ($RATIO > 1) $RATIO - 1 else 1 - $RATIO" | bc -l)
        DRIFT_THRESHOLD=0.0001
        NEEDS_CORRECTION=$(echo "$DRIFT > $DRIFT_THRESHOLD" | bc -l)
        if [ "$NEEDS_CORRECTION" = "1" ]; then
            echo "  drift correction: ratio=${RATIO} (${DRIFT})" >&2
        else
            echo "  no significant drift detected" >&2
        fi
    fi
fi

# ---- Phase 3: Merge segments ----
# jq filter that merges two JSON transcriptions, scales mic timestamps
# by the drift ratio, labels each segment with its source speaker, and
# sorts everything chronologically.
JQ_MERGE='
def fmt_time(s):
  (s / 3600 | floor) as $h |
  ((s % 3600) / 60 | floor) as $m |
  (s % 60 | floor) as $sec |
  ((s - (s | floor)) * 1000 | floor) as $ms |
  (if $h < 10 then "0" else "" end) + ($h | tostring) + ":" +
  (if $m < 10 then "0" else "" end) + ($m | tostring) + ":" +
  (if $sec < 10 then "0" else "" end) + ($sec | tostring) + "," +
  (if $ms < 100 then (if $ms < 10 then "00" else "0" end) else "" end) + ($ms | tostring);

def scale_time(s; r): s * r;

{
  metadata: {
    created: (.[0].metadata.created),
    duration: ([.[0].metadata.duration, (.[1].metadata.duration * ($ratio | tonumber))] | max),
    language: (.[0].metadata.language),
    sources: ["system", "mic"]
  },
  segments: (
    ([.[0].segments[] | . + {speaker: "System"}] +
     [.[1].segments[] | . + {speaker: "Mic",
       start: (.start * ($ratio | tonumber)),
       end:   (.end   * ($ratio | tonumber)),
       words: [.words[] | {
         text: .text,
         start: (.start * ($ratio | tonumber)),
         end:   (.end   * ($ratio | tonumber))
       }]
     }]) |
    sort_by(.start) |
    to_entries | map(.value.id = (.key + 1) | .value)
  )
}
'

JQ_PASSTHROUGH='
{
  metadata: .metadata + {sources: [$source]},
  segments: [.segments[] | . + {speaker: $source}]
}
'

if [ "$SYS_EXISTS" -eq 1 ] && [ "$MIC_EXISTS" -eq 1 ]; then
    jq -s --arg ratio "$RATIO" "$JQ_MERGE" "$SYS_JSON" "$MIC_JSON" > "$MERGED_JSON"
elif [ "$SYS_EXISTS" -eq 1 ]; then
    jq --arg source "System" "$JQ_PASSTHROUGH" "$SYS_JSON" > "$MERGED_JSON"
else
    jq --arg source "Mic" "$JQ_PASSTHROUGH" "$MIC_JSON" > "$MERGED_JSON"
fi

# ---- Phase 4: Format output ----
case "$FORMAT" in
    json)
        cat "$MERGED_JSON" > "$OUT"
        ;;

    txt)
        jq -r '.segments[] | [.speaker, (.start | tostring), .text] | @tsv' "$MERGED_JSON" |
        awk -F'\t' '
        function fmt_time(s) {
            h = int(s / 3600)
            m = int((s % 3600) / 60)
            sec = int(s % 60)
            dec = int((s - int(s)) * 10)
            return sprintf("%02d:%02d.%d", m, sec, dec)
        }
        {
            printf("[%s %s] %s\n", $1, fmt_time($2 + 0), $3)
        }' > "$OUT"
        ;;

    srt)
        jq -r '.segments[] | [.id, (.start | tostring), (.end | tostring), .speaker, .text] | @tsv' "$MERGED_JSON" |
        awk -F'\t' '
        function fmt_srt(s) {
            h = int(s / 3600)
            m = int((s % 3600) / 60)
            sec = int(s % 60)
            ms = int((s - int(s)) * 1000)
            return sprintf("%02d:%02d:%02d,%03d", h, m, sec, ms)
        }
        {
            id = $1
            start = fmt_srt($2 + 0)
            end_ = fmt_srt($3 + 0)
            speaker = $4
            text = $5
            printf("%d\n%s --> %s\n[%s] %s\n\n", id, start, end_, speaker, text)
        }' > "$OUT"
        ;;

    vtt)
        printf "WEBVTT\n\n" > "$OUT"
        jq -r '.segments[] | [.id, (.start | tostring), (.end | tostring), .speaker, .text] | @tsv' "$MERGED_JSON" |
        awk -F'\t' '
        function fmt_vtt(s) {
            h = int(s / 3600)
            m = int((s % 3600) / 60)
            sec = int(s % 60)
            ms = int((s - int(s)) * 1000)
            return sprintf("%02d:%02d:%02d.%03d", h, m, sec, ms)
        }
        {
            start = fmt_vtt($2 + 0)
            end_ = fmt_vtt($3 + 0)
            speaker = $4
            text = $5
            printf("%s --> %s\n[%s] %s\n\n", start, end_, speaker, text)
        }' >> "$OUT"
        ;;
esac

echo "Done: $OUT" >&2
