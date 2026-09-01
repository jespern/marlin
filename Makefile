.PHONY: build install test test-install

ZIG ?= zig
MARLIN_INSTALL_TARGET ?=

build:
	$(ZIG) build -Doptimize=ReleaseFast

install: build
	MARLIN_INSTALL_TARGET="$(MARLIN_INSTALL_TARGET)" scripts/install-dev.sh zig-out/bin/marlin

test:
	$(ZIG) build test

test-install:
	@mkdir -p .zig-cache/tmp
	TMPDIR="$(CURDIR)/.zig-cache/tmp" scripts/test-install-dev.sh
