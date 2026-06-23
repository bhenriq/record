#!/usr/bin/env bash
# transcribe.sh — thin wrapper around `rec transcribe`
# See `rec transcribe --help` for details.

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/rec"
rec transcribe "$@"
