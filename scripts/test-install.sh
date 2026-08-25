#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/marlin-installer-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_file() {
    [ -f "$1" ] || fail "expected file: $1"
}

assert_contains() {
    grep -Fq "$2" "$1" || fail "expected '$2' in $1"
}

make_release() {
    release_dir=$1
    artifact=$2
    version=$3
    mkdir -p "$release_dir"
    sed "s/@VERSION@/$version/" "$ROOT/scripts/testdata/installer/fake-marlin.sh" > "$release_dir/$artifact"
    chmod 755 "$release_dir/$artifact"
    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(sha256sum "$release_dir/$artifact" | awk '{ print $1 }')
    else
        digest=$(shasum -a 256 "$release_dir/$artifact" | awk '{ print $1 }')
    fi
    printf '%s  %s\n' "$digest" "$artifact" > "$release_dir/$artifact.sha256"
}

make_curl_mock() {
    mock_dir=$1
    mkdir -p "$mock_dir"
    cp "$ROOT/scripts/testdata/installer/curl-mock.sh" "$mock_dir/curl"
    chmod 755 "$mock_dir/curl"
}

test_installs_and_configures_zsh() {
    case_root="$TEST_ROOT/install"
    home="$case_root/home"
    release="$case_root/release"
    mocks="$case_root/mocks"
    mkdir -p "$home"
    make_release "$release" marlin-aarch64-darwin 1.2.3
    make_curl_mock "$mocks"

    HOME="$home" \
    SHELL=/bin/zsh \
    PATH="$mocks:/usr/bin:/bin" \
    MARLIN_OS=darwin \
    MARLIN_ARCH=aarch64 \
    MARLIN_RELEASE_BASE=https://example.test/releases/latest/download \
    MARLIN_MOCK_RELEASE_DIR="$release" \
    MARLIN_ADD_TO_PATH=1 \
        sh "$ROOT/site/install.sh" > "$case_root/output"

    assert_file "$home/.local/bin/marlin"
    [ "$("$home/.local/bin/marlin" version)" = "marlin 1.2.3" ] || \
        fail "installed binary did not run"
    assert_contains "$home/.zshrc" 'export PATH="$HOME/.local/bin:$PATH"'
    assert_contains "$case_root/output" 'Verified SHA-256 checksum.'
    assert_contains "$case_root/output" 'Installed marlin 1.2.3'

    # Reinstalling is safe and does not duplicate the profile entry.
    HOME="$home" \
    SHELL=/bin/zsh \
    PATH="$mocks:/usr/bin:/bin" \
    MARLIN_OS=darwin \
    MARLIN_ARCH=aarch64 \
    MARLIN_RELEASE_BASE=https://example.test/releases/latest/download \
    MARLIN_MOCK_RELEASE_DIR="$release" \
    MARLIN_ADD_TO_PATH=1 \
        sh "$ROOT/site/install.sh" > "$case_root/reinstall-output"
    [ "$(grep -Fc '# Marlin' "$home/.zshrc")" -eq 1 ] || \
        fail "reinstall duplicated the PATH entry"
}

test_checksum_failure_preserves_existing_binary() {
    case_root="$TEST_ROOT/checksum"
    home="$case_root/home"
    release="$case_root/release"
    mocks="$case_root/mocks"
    mkdir -p "$home/.local/bin"
    printf '#!/bin/sh\nprintf "old marlin\\n"\n' > "$home/.local/bin/marlin"
    chmod 755 "$home/.local/bin/marlin"
    make_release "$release" marlin-x86_64-linux 2.0.0
    printf '0000000000000000000000000000000000000000000000000000000000000000\n' \
        > "$release/marlin-x86_64-linux.sha256"
    make_curl_mock "$mocks"

    if HOME="$home" \
        SHELL=/bin/bash \
        PATH="$mocks:/usr/bin:/bin" \
        MARLIN_OS=linux \
        MARLIN_ARCH=x86_64 \
        MARLIN_RELEASE_BASE=https://example.test/releases/latest/download \
        MARLIN_MOCK_RELEASE_DIR="$release" \
        MARLIN_ADD_TO_PATH=0 \
            sh "$ROOT/site/install.sh" > "$case_root/output" 2>&1; then
        fail "bad checksum was accepted"
    fi

    [ "$("$home/.local/bin/marlin")" = "old marlin" ] || \
        fail "failed install replaced the existing binary"
    assert_contains "$case_root/output" 'checksum verification failed'
}

test_installs_pinned_release_assets() {
    case_root="$TEST_ROOT/pinned"
    home="$case_root/home"
    release="$case_root/release"
    mocks="$case_root/mocks"
    url_log="$case_root/urls"
    mkdir -p "$home"
    make_release "$release" marlin-x86_64-linux 3.4.5
    make_curl_mock "$mocks"

    HOME="$home" \
    SHELL=/bin/sh \
    PATH="$mocks:/usr/bin:/bin" \
    MARLIN_OS=linux \
    MARLIN_ARCH=x86_64 \
    MARLIN_VERSION=v3.4.5 \
    MARLIN_MOCK_RELEASE_DIR="$release" \
    MARLIN_MOCK_URL_LOG="$url_log" \
    MARLIN_ADD_TO_PATH=0 \
        sh "$ROOT/site/install.sh" > "$case_root/output"

    [ "$("$home/.local/bin/marlin" version)" = "marlin 3.4.5" ] || \
        fail "pinned release binary did not run"
    assert_contains "$url_log" \
        'https://github.com/jespern/marlin/releases/download/v3.4.5/marlin-x86_64-linux'
    assert_contains "$url_log" \
        'https://github.com/jespern/marlin/releases/download/v3.4.5/marlin-x86_64-linux.sha256'
}

test_rejects_unsupported_platform() {
    case_root="$TEST_ROOT/platform"
    mkdir -p "$case_root/home" "$case_root/mocks"
    make_curl_mock "$case_root/mocks"

    if HOME="$case_root/home" \
        PATH="$case_root/mocks:/usr/bin:/bin" \
        MARLIN_OS=plan9 \
        MARLIN_ARCH=x86_64 \
            sh "$ROOT/site/install.sh" > "$case_root/output" 2>&1; then
        fail "unsupported OS was accepted"
    fi
    assert_contains "$case_root/output" 'unsupported OS: plan9'
}

test_installs_and_configures_zsh
test_checksum_failure_preserves_existing_binary
test_installs_pinned_release_assets
test_rejects_unsupported_platform

printf 'installer tests passed\n'
