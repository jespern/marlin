#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/marlin-dev-install-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

make_marlin() {
    path=$1
    version=$2
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
#!/bin/sh
if [ "\${1:-}" = version ]; then
    printf 'marlin %s\\n' '$version'
    exit 0
fi
printf 'fake marlin %s\\n' '$version'
EOF
    chmod 755 "$path"
}

assert_version() {
    actual=$("$1" version)
    [ "$actual" = "marlin $2" ] || fail "expected $1 to report marlin $2, got: $actual"
}

test_installs_over_active_regular_binary() {
    case_root=$TEST_ROOT/regular
    candidate=$case_root/build/marlin
    destination=$case_root/bin/marlin
    make_marlin "$candidate" dev
    make_marlin "$destination" release

    PATH="$case_root/bin:/usr/bin:/bin" \
        "$ROOT/scripts/install-dev.sh" "$candidate" > "$case_root/output"

    assert_version "$destination" dev
    resolved_destination=$(CDPATH= cd -- "$(dirname "$destination")" && pwd -P)/$(basename "$destination")
    grep -Fq "Installed marlin dev at $resolved_destination" "$case_root/output" || \
        fail "regular install did not report its destination"
}

test_preserves_homebrew_style_symlink() {
    case_root=$TEST_ROOT/symlink
    candidate=$case_root/build/marlin
    cellar=$case_root/Cellar/marlin/1.0/bin/marlin
    active=$case_root/bin/marlin
    make_marlin "$candidate" dev
    make_marlin "$cellar" release
    mkdir -p "$(dirname "$active")"
    ln -s ../Cellar/marlin/1.0/bin/marlin "$active"

    PATH="$case_root/bin:/usr/bin:/bin" \
        "$ROOT/scripts/install-dev.sh" "$candidate" > "$case_root/output"

    [ -L "$active" ] || fail "Homebrew-style active path stopped being a symlink"
    assert_version "$active" dev
    assert_version "$cellar" dev
    resolved_active=$(CDPATH= cd -- "$(dirname "$active")" && pwd -P)/$(basename "$active")
    grep -Fq "Active path remains symlinked through $resolved_active" "$case_root/output" || \
        fail "symlink install did not explain the active path"
}

test_first_install_uses_local_bin() {
    case_root=$TEST_ROOT/first
    candidate=$case_root/build/marlin
    home=$case_root/home
    make_marlin "$candidate" dev

    HOME="$home" PATH="/usr/bin:/bin" \
        "$ROOT/scripts/install-dev.sh" "$candidate" > "$case_root/output"

    assert_version "$home/.local/bin/marlin" dev
}

test_explicit_target_and_non_marlin_refusal() {
    case_root=$TEST_ROOT/explicit
    candidate=$case_root/build/marlin
    destination=$case_root/bin/marlin
    make_marlin "$candidate" dev
    mkdir -p "$(dirname "$destination")"
    printf '#!/bin/sh\nprintf "not marlin\\n"\n' > "$destination"
    chmod 755 "$destination"

    if MARLIN_INSTALL_TARGET="$destination" \
        "$ROOT/scripts/install-dev.sh" "$candidate" > "$case_root/output" 2>&1; then
        fail "non-marlin destination was replaced"
    fi
    [ "$($destination)" = "not marlin" ] || fail "refused destination was modified"
    grep -Fq "refusing to replace a non-marlin executable" "$case_root/output" || \
        fail "non-marlin refusal was not explained"
}

test_installs_over_active_regular_binary
test_preserves_homebrew_style_symlink
test_first_install_uses_local_bin
test_explicit_target_and_non_marlin_refusal

printf 'developer installer tests passed\n'
