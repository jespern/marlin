#!/bin/sh
# Install a source build over the Marlin currently selected by PATH.

set -eu

candidate=${1:-zig-out/bin/marlin}

err() {
    printf 'error: %s\n' "$1" >&2
    exit 1
}

[ -f "$candidate" ] || err "build output not found: $candidate"
[ -x "$candidate" ] || err "build output is not executable: $candidate"

candidate_version=$("$candidate" version 2>/dev/null) || err "build output failed its version check"
case "$candidate_version" in
    marlin\ *) ;;
    *) err "build output is not a marlin binary" ;;
esac

if [ -n "${MARLIN_INSTALL_TARGET:-}" ]; then
    target=$MARLIN_INSTALL_TARGET
else
    target=$(command -v marlin 2>/dev/null || true)
    if [ -z "$target" ]; then
        target=${HOME:?HOME is required}/.local/bin/marlin
    fi
fi

case "$target" in
    /*) ;;
    *) target=$(CDPATH= cd -- "$(dirname -- "$target")" && pwd -P)/$(basename -- "$target") ;;
esac
# Canonical directory when it exists (macOS puts TMPDIR behind /var -> /private/var).
if target_dir=$(CDPATH= cd -- "$(dirname -- "$target")" 2>/dev/null && pwd -P); then
    target=$target_dir/$(basename -- "$target")
fi

resolve_target() {
    path=$1
    hops=0
    while [ -L "$path" ]; do
        hops=$((hops + 1))
        [ "$hops" -le 40 ] || err "too many symlinks resolving $1"
        link=$(readlink "$path") || err "could not read symlink: $path"
        case "$link" in
            /*) path=$link ;;
            *) path=$(dirname -- "$path")/$link ;;
        esac
    done
    dir=$(CDPATH= cd -- "$(dirname -- "$path")" && pwd -P) || \
        err "destination directory does not exist: $(dirname -- "$path")"
    printf '%s/%s\n' "$dir" "$(basename -- "$path")"
}

if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    mkdir -p "$(dirname -- "$target")" || err "could not create destination directory: $(dirname -- "$target")"
fi

destination=$(resolve_target "$target")
destination_dir=$(dirname -- "$destination")

# A regular file sitting where Homebrew keeps its symlinks is a clobbered
# link: some earlier copy replaced `brew`'s symlink with a real binary, and
# every later `brew upgrade` will fail to link over it. Refuse to keep that
# alive; point at the two ways out.
brew_prefix=$( { command -v brew >/dev/null 2>&1 && brew --prefix; } 2>/dev/null || true)
brew_bin=$( [ -n "$brew_prefix" ] && CDPATH= cd -- "$brew_prefix/bin" 2>/dev/null && pwd -P || true)
if [ -n "$brew_bin" ] && [ "$destination_dir" = "$brew_bin" ] && [ ! -L "$target" ] && [ -f "$destination" ]; then
    err "$destination is a regular file in Homebrew's bin directory, where Homebrew expects its own symlink.
Either remove it and relink the formula:
    rm '$destination' && brew link marlin
or install the development build somewhere Homebrew does not manage:
    MARLIN_INSTALL_TARGET=\$HOME/.local/bin/marlin make install"
fi

if [ -e "$destination" ]; then
    [ -f "$destination" ] || err "destination is not a regular file: $destination"
    installed_version=$("$destination" version 2>/dev/null) || \
        err "refusing to replace a non-marlin executable: $destination"
    case "$installed_version" in
        marlin\ *) ;;
        *) err "refusing to replace a non-marlin executable: $destination" ;;
    esac
fi

staged=$(mktemp "$destination_dir/.marlin-dev-install.XXXXXX") || \
    err "could not create a temporary file in $destination_dir"
trap 'rm -f "$staged"' EXIT HUP INT TERM

cp "$candidate" "$staged"
chmod 755 "$staged"
staged_version=$("$staged" version 2>/dev/null) || err "staged binary failed its version check"
[ "$staged_version" = "$candidate_version" ] || err "staged binary version check changed unexpectedly"

mv -f "$staged" "$destination"
trap - EXIT HUP INT TERM
hash -r 2>/dev/null || true

printf 'Installed %s at %s\n' "$candidate_version" "$destination"
if [ "$target" != "$destination" ]; then
    printf 'Active path remains symlinked through %s\n' "$target"
fi
printf 'A running daemon keeps its current executable until `marlin reboot`.\n'
