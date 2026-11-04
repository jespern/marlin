.PHONY: build install test test-install trim-cache

ZIG ?= zig
MARLIN_INSTALL_TARGET ?=
ZIG_CACHE_MAX_MB ?= 2048

build: trim-cache
	$(ZIG) build -Doptimize=fast

install: build
	MARLIN_INSTALL_TARGET="$(MARLIN_INSTALL_TARGET)" scripts/install-dev.sh zig-out/bin/marlin

test: trim-cache
	$(ZIG) build test

test-install:
	@mkdir -p .zig-cache/tmp
	TMPDIR="$(CURDIR)/.zig-cache/tmp" scripts/test-install-dev.sh

# Zig never prunes .zig-cache. Past the cap, wipe it whole rather than
# trimming entries: a wipe is always safe and costs one full rebuild.
trim-cache:
	@if [ -d .zig-cache ]; then \
		size_mb=$$(du -sm .zig-cache | cut -f1); \
		if [ "$$size_mb" -gt "$(ZIG_CACHE_MAX_MB)" ]; then \
			echo "zig cache is $${size_mb} MB (cap $(ZIG_CACHE_MAX_MB) MB); wiping"; \
			rm -rf .zig-cache; \
		fi; \
	fi
