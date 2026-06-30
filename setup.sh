#!/bin/sh
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_NAME="rec"
INSTALL_DIR="/usr/local/bin"
MENU_APP_DIR="/Applications"
SCRATCH_DIR="${TMPDIR:-/tmp}/rec-build-$$"

usage() {
    cat <<EOF
usage: setup.sh <command> [options]

Commands:
  build [--include-menu]       Build rec (and optionally the menu bar app)
  install [--include-menu]     Build + install rec (and optionally Rec.app)
  uninstall                    Remove rec from $INSTALL_DIR
  -h, --help                   Show this help

Options:
  --include-menu               Also build / install the menu bar app (Rec.app)

Examples:
  ./setup.sh build                    # just build rec CLI
  ./setup.sh build --include-menu     # build rec CLI + menu bar app
  ./setup.sh install                  # build + install rec CLI
  ./setup.sh install --include-menu   # build + install both
  ./setup.sh uninstall                # remove rec CLI
EOF
}

cleanup() {
    rm -rf "$SCRATCH_DIR" 2>/dev/null || true
}
trap cleanup EXIT

build() {
    local include_menu=false
    for arg in "$@"; do
        case "$arg" in
            --include-menu) include_menu=true ;;
        esac
    done

    echo "==> Generating commit hash..."
    local commit=$(cd "$PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || echo "unknown")
    echo "public let recVersion = \"$commit\"" > "$PROJECT_DIR/Sources/rec/Version.swift"

    echo "==> Building rec (release)..."
    (cd "$PROJECT_DIR" && swift build -c release --scratch-path "$SCRATCH_DIR")

    if $include_menu; then
        echo "==> Building Rec.app (menu bar)..."
        "$PROJECT_DIR/Scripts/build-menu-app.sh"
        echo "==> Rec.app built at ${TMPDIR:-/tmp}/Rec.app"
    fi

    echo "==> Build done."
}

install_bin() {
    local include_menu=false
    for arg in "$@"; do
        case "$arg" in
            --include-menu) include_menu=true ;;
        esac
    done

    build "$@"

    local src="$SCRATCH_DIR/release/$BIN_NAME"
    if [ ! -f "$src" ]; then
        echo "Error: built binary not found at $src" >&2
        exit 1
    fi

    echo "==> Installing rec to $INSTALL_DIR/$BIN_NAME..."
    if cp "$src" "$INSTALL_DIR/$BIN_NAME" 2>/dev/null; then
        echo "==> rec installed."
    else
        echo "Permission denied. Re-run with:" >&2
        echo "  sudo setup.sh install $([ "$include_menu" = true ] && echo '--include-menu')" >&2
        exit 1
    fi

    if $include_menu; then
        local app_bundle="${TMPDIR:-/tmp}/Rec.app"
        if [ ! -d "$app_bundle" ]; then
            echo "Error: Rec.app not found at $app_bundle (build may have failed)" >&2
            exit 1
        fi
        echo "==> Installing Rec.app to $MENU_APP_DIR..."
        rm -rf "$MENU_APP_DIR/Rec.app" 2>/dev/null || true
        if cp -R "$app_bundle" "$MENU_APP_DIR/" 2>/dev/null; then
            echo "==> Rec.app installed to $MENU_APP_DIR/"
        else
            echo "Permission denied. Re-run with:" >&2
            echo "  sudo setup.sh install $([ "$include_menu" = true ] && echo '--include-menu')" >&2
            exit 1
        fi
    fi

    echo "==> Done."
}

uninstall_bin() {
    local dst="$INSTALL_DIR/$BIN_NAME"
    if [ -f "$dst" ]; then
        if rm "$dst" 2>/dev/null; then
            echo "==> Removed $dst"
        else
            echo "Permission denied. Re-run with:" >&2
            echo "  sudo setup.sh uninstall" >&2
            exit 1
        fi
    fi

    local menu_app="$MENU_APP_DIR/Rec.app"
    if [ -d "$menu_app" ]; then
        if rm -rf "$menu_app" 2>/dev/null; then
            echo "==> Removed $menu_app"
        else
            echo "Permission denied. Re-run with:" >&2
            echo "  sudo setup.sh uninstall" >&2
            exit 1
        fi
    fi

    if [ ! -f "$dst" ] && [ ! -d "$menu_app" ]; then
        echo "Nothing to uninstall." >&2
    else
        echo "==> Done."
    fi
}

case "${1:-}" in
    build)
        shift
        build "$@"
        ;;
    install)
        shift
        install_bin "$@"
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
