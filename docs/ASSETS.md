# Optional asset store

Assets Marlin needs only sometimes are downloaded on demand instead of being
embedded in the executable. `src/asset_store.zig` does the work: HTTP, length
limits, SHA256 verification, semantic validation, cache resolution, migration
and atomic install. Each consumer supplies a filename, URL, expected digest,
byte limit and validator.

The one consumer today is the screenshot rasterizer, which fetches Ghostty's
default font (JetBrains Mono, the files and digests Ghostty pins) the first
time a screenshot needs it. See `default_font` in `src/client/screenshot.zig`.

The cache is `$XDG_CACHE_HOME/marlin/assets/<sha256>/<filename>` or
`~/.cache/marlin/assets/<sha256>/<filename>`. Relative XDG paths are ignored.
Every cached file is checked before use. Invalid files are cache misses, repaired
only by a successful download. A downloaded body must satisfy the size bound,
pinned SHA256 and the consumer's validator before it is atomically renamed.
Unique temporary names prevent concurrent launches sharing partial files.
Failures and cancellation leave no installed partial file. The expected
checksum is enforced even for a mirror URL. Never silently accept new bytes.

A source checkout running `zig-out/bin/marlin` (or `zig build run` from the
checkout root) uses `<checkout>/assets/<filename>` when the cache is empty, held
to the same digest and validator as a download and installed into the cache from
there.

## The console ports

The wipEout and Mario Kart 64 ports left `main` after v0.2.1 and live on the
`console-ports` branch, with their sources, docs and packing scripts.
`assets/mk.pak` and `assets/wo.pak` stay on `main` for now: releases up to
v0.2.1 download them from `main/assets/` on first use. Remove them once those
releases no longer matter.
