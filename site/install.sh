#!/bin/sh
# marlin installer, https://marlin.wtf
#
# Installs one release binary in ~/.local/bin (or $MARLIN_INSTALL_DIR),
# verifies its checksum, and offers to add that directory to the user's PATH.
# No sudo and no system-wide writes. Uninstall with: rm ~/.local/bin/marlin

set -eu

RELEASE_BASE="${MARLIN_RELEASE_BASE:-https://github.com/jespern/marlin/releases/latest/download}"
INSTALL_DIR="${MARLIN_INSTALL_DIR:-${HOME:?HOME is required}/.local/bin}"
ADD_TO_PATH="${MARLIN_ADD_TO_PATH:-ask}"

main() {
    require curl

    os=$(detect_os)
    arch=$(detect_arch)
    artifact="marlin-${arch}-${os}"

    mkdir -p "$INSTALL_DIR"
    if [ -d "$INSTALL_DIR/marlin" ]; then
        err "$INSTALL_DIR/marlin is a directory"
    fi

    work_dir=$(mktemp -d "$INSTALL_DIR/.marlin-install.XXXXXX") || \
        err "could not create a temporary directory in $INSTALL_DIR"
    trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
    candidate="$work_dir/$artifact"
    checksum_file="$work_dir/$artifact.sha256"

    printf 'Downloading %s...\n' "$artifact"
    download "$RELEASE_BASE/$artifact" "$candidate"
    download "$RELEASE_BASE/$artifact.sha256" "$checksum_file"
    verify_checksum "$candidate" "$checksum_file"

    chmod 755 "$candidate"
    version_output=$("$candidate" version 2>/dev/null) || \
        err "downloaded binary failed its version check"
    case "$version_output" in
        marlin\ *) ;;
        *) err "downloaded file is not a marlin binary" ;;
    esac

    # The candidate is created beside the destination, so this rename is
    # atomic even when reinstalling over an older Marlin binary.
    mv -f "$candidate" "$INSTALL_DIR/marlin"
    trap - EXIT HUP INT TERM
    rm -rf "$work_dir"
    hash -r 2>/dev/null || true

    printf 'Installed %s at %s/marlin\n' "$version_output" "$INSTALL_DIR"

    if ! installed_marlin_is_active; then
        printf '\n'
        configure_path
    fi

    printf '\nNext: export OPENROUTER_API_KEY=... && marlin run "hello fish"\n'
}

detect_os() {
    case "${MARLIN_OS:-$(uname -s)}" in
        Darwin|darwin) printf 'darwin' ;;
        Linux|linux) printf 'linux' ;;
        *) err "unsupported OS: ${MARLIN_OS:-$(uname -s)}" ;;
    esac
}

detect_arch() {
    case "${MARLIN_ARCH:-$(uname -m)}" in
        arm64|aarch64) printf 'aarch64' ;;
        x86_64|amd64) printf 'x86_64' ;;
        *) err "unsupported architecture: ${MARLIN_ARCH:-$(uname -m)}" ;;
    esac
}

download() {
    url=$1
    destination=$2
    if ! curl -fsSL "$url" -o "$destination"; then
        err "download failed: $url"
    fi
}

verify_checksum() {
    file=$1
    checksum_path=$2
    expected=$(awk 'NR == 1 { print $1 }' "$checksum_path" | tr '[:upper:]' '[:lower:]')
    [ -n "$expected" ] || err "release checksum is empty"

    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{ print $1 }')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{ print $1 }')
    else
        err "sha256sum or shasum is required to verify the download"
    fi

    [ "$expected" = "$actual" ] || err "checksum verification failed"
    printf 'Verified SHA-256 checksum.\n'
}

installed_marlin_is_active() {
    active=$(command -v marlin 2>/dev/null || true)
    [ "$active" = "$INSTALL_DIR/marlin" ]
}

configure_path() {
    shell_name=$(basename "${SHELL:-sh}")
    case "$shell_name" in
        fish)
            profile="${HOME:?HOME is required}/.config/fish/config.fish"
            path_command=$(path_command_for fish)
            ;;
        zsh)
            profile="${ZDOTDIR:-${HOME:?HOME is required}}/.zshrc"
            path_command=$(path_command_for sh)
            ;;
        bash)
            if [ -f "${HOME:?HOME is required}/.bashrc" ]; then
                profile="$HOME/.bashrc"
            else
                profile="$HOME/.profile"
            fi
            path_command=$(path_command_for sh)
            ;;
        *)
            profile="${HOME:?HOME is required}/.profile"
            path_command=$(path_command_for sh)
            ;;
    esac

    if [ -f "$profile" ] && grep -Fqx "$path_command" "$profile"; then
        printf 'PATH is already configured in %s.\n' "$profile"
        print_path_activation "$path_command"
        return
    fi

    case "$ADD_TO_PATH" in
        1|yes|true) add_path=yes ;;
        0|no|false) add_path=no ;;
        ask)
            add_path=no
            if ( : <>/dev/tty ) 2>/dev/null; then
                printf 'Add %s to PATH in %s? [Y/n] ' "$INSTALL_DIR" "$profile" >/dev/tty
                if IFS= read -r answer </dev/tty; then
                    case "$answer" in
                        n|N|no|NO) ;;
                        *) add_path=yes ;;
                    esac
                fi
            fi
            ;;
        *) err "MARLIN_ADD_TO_PATH must be ask, 1, or 0" ;;
    esac

    if [ "$add_path" = yes ]; then
        mkdir -p "$(dirname "$profile")"
        if [ -e "$profile" ] && [ ! -f "$profile" ]; then
            err "shell profile is not a regular file: $profile"
        fi
        touch "$profile"
        printf '\n# Marlin\n%s\n' "$path_command" >> "$profile"
        printf 'Added %s to PATH in %s.\n' "$INSTALL_DIR" "$profile"
    else
        printf '%s is not on your PATH.\n' "$INSTALL_DIR"
    fi

    print_path_activation "$path_command"
}

path_command_for() {
    shell_kind=$1
    if [ "$INSTALL_DIR" = "${HOME:?HOME is required}/.local/bin" ]; then
        bin_expression='$HOME/.local/bin'
    else
        bin_expression=$INSTALL_DIR
    fi

    if [ "$shell_kind" = fish ]; then
        printf 'fish_add_path "%s"' "$bin_expression"
    else
        printf 'export PATH="%s:$PATH"' "$bin_expression"
    fi
}

print_path_activation() {
    path_command=$1
    printf 'Restart your shell or run:\n\n  %s\n' "$path_command"
}

require() {
    command -v "$1" >/dev/null 2>&1 || err "$1 is required"
}

err() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

main "$@"
