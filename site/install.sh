#!/bin/sh
# marlin installer, https://marlin.wtf
#
# What this does (the whole thing, no surprises):
#   1. figures out your OS/arch
#   2. downloads the latest marlin release binary
#   3. drops it in ~/.local/bin (or $MARLIN_INSTALL_DIR)
#   4. tells you if that's not on your PATH
# No sudo. No config written. Uninstall = rm one file.
#
# NOTE: marlin is pre-release (M2 of 6). Releases don't exist yet, so
# right now this script just tells you that. It will do the real thing
# the day there's a binary worth curling.

set -eu

RELEASE_BASE="https://github.com/jespern/marlin/releases/latest/download"
INSTALL_DIR="${MARLIN_INSTALL_DIR:-$HOME/.local/bin}"

main() {
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case "$arch" in
        arm64|aarch64) arch="aarch64" ;;
        x86_64|amd64)  arch="x86_64"  ;;
        *) err "unsupported architecture: $arch" ;;
    esac
    case "$os" in
        darwin|linux) : ;;
        *) err "unsupported OS: $os (marlin swims in unixy waters)" ;;
    esac

    artifact="marlin-${arch}-${os}"

    # --- pre-release honesty gate ------------------------------------
    echo "marlin is still pre-release: there is no binary to install yet."
    echo "watch https://marlin.wtf or the repo for the first release."
    echo ""
    echo "(when it exists, this script will fetch: ${RELEASE_BASE}/${artifact})"
    exit 1
    # ------------------------------------------------------------------

    # The real flow, ready for release day:
    mkdir -p "$INSTALL_DIR"
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    echo "downloading ${artifact}..."
    curl -fsSL "${RELEASE_BASE}/${artifact}" -o "$tmp"
    chmod +x "$tmp"
    mv "$tmp" "$INSTALL_DIR/marlin"
    trap - EXIT
    echo "installed: $INSTALL_DIR/marlin"

    case ":$PATH:" in
        *":$INSTALL_DIR:"*) ;;
        *)
            echo ""
            echo "note: $INSTALL_DIR is not on your PATH. add this to your shell rc:"
            echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
            ;;
    esac

    echo ""
    echo "next: export OPENROUTER_API_KEY=... && marlin run \"hello fish\""
}

err() {
    echo "error: $1" >&2
    exit 1
}

main "$@"
