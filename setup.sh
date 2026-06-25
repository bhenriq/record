#!/bin/sh
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_NAME="rec"
INSTALL_DIR="/usr/local/bin"

usage() {
    cat <<EOF
usage: setup.sh <command>

Commands:
  build              Build rec (swift build -c release)
  install            Build + install rec to $INSTALL_DIR
  uninstall          Remove rec from $INSTALL_DIR
  -h, --help         Show this help

Examples:
  ./setup.sh build       # just build
  ./setup.sh install     # build + copy to $INSTALL_DIR/$BIN_NAME
  ./setup.sh uninstall   # remove from $INSTALL_DIR/$BIN_NAME
EOF
}

build() {
    echo "==> Building rec (release)..."
    (cd "$PROJECT_DIR" && swift build -c release)
    echo "==> Build done."
}

install_bin() {
    local src="$PROJECT_DIR/.build/release/$BIN_NAME"
    if [ -f "$src" ]; then
        echo "==> Binary already built, skipping build."
    else
        build
    fi
    echo "==> Installing to $INSTALL_DIR/$BIN_NAME..."
    if cp "$src" "$INSTALL_DIR/$BIN_NAME" 2>/dev/null; then
        echo "==> Done.  Run: $BIN_NAME --help"
    else
        echo "Permission denied. Re-run with:" >&2
        echo "  sudo setup.sh install" >&2
        exit 1
    fi
}

uninstall_bin() {
    local dst="$INSTALL_DIR/$BIN_NAME"
    if [ ! -f "$dst" ]; then
        echo "Not installed ($dst not found)." >&2
        exit 0
    fi
    echo "==> Removing $dst..."
    if rm "$dst" 2>/dev/null; then
        echo "==> Done."
    else
        echo "Permission denied. Re-run with:" >&2
        echo "  sudo setup.sh uninstall" >&2
        exit 1
    fi
}

case "${1:-}" in
    build)
        build
        ;;
    install)
        install_bin
        ;;
    uninstall)
        uninstall_bin
        ;;
    -h|--help|"")
        usage
        ;;
    *)
        echo "Unknown command: $1" >&2
        echo "" >&2
        usage
        exit 1
        ;;
esac
