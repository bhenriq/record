#!/usr/bin/env bash
# mix.sh — thin wrapper around `rec mix`
# See `rec mix --help` for details.

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/rec"
rec mix "$@"
