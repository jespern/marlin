# Optional asset store

The optional games share `src/asset_store.zig` for HTTP, length limits, SHA256
verification, semantic validation, cache resolution, migration and atomic install.
Each consumer supplies a filename, URL, expected digest, byte limit and validator.
`assets/mk.pak` and `assets/wo.pak` sit side by side outside the executable.

The cache is `$XDG_CACHE_HOME/marlin/assets/<sha256>/<filename>` or
`~/.cache/marlin/assets/<sha256>/<filename>`. Relative XDG paths are ignored.
Every cached bundle is checked before use. Invalid files are cache misses, repaired
only by a successful download. A downloaded body must satisfy the size bound,
pinned SHA256 and the game's format validator before it is atomically renamed.
Unique temporary names prevent concurrent launches sharing partial files.
Failures and cancellation leave no installed partial file. Old verified caches
are copied into the new layout; explicit development sources remain supported.

A source checkout running `zig-out/bin/marlin` uses `<checkout>/assets/<filename>`
when the cache is empty, held to the same digest and validator as a download and
installed into the cache from there. Development builds therefore work before the
bundles are published, and a checkout with a stale or edited bundle falls back to
the network like any other miss.

Both games use the same download routine. The wipEout UI retains its worker thread,
atomic byte progress and cooperative cancellation between reads. MK uses the same
routine during terminal handoff. Small bundles restart interrupted transfers;
they do not use the voice-model downloader's resumable-file trust policy.
The voice downloader is unchanged.

Keep the format readers separate: MK has a typed, zlib-compressed resource schema;
WO has an xz-compressed file directory. Both already use bounded Zig decoders.
Changing those containers would add migration and fidelity risk without improving
HTTP/cache consistency. Their respective validators run before installation.

## Regenerate and publish

- MK: run `zig build mk64-import -- ROM /tmp/mk.pak`, which verifies ROM parity,
  then replace `assets/mk.pak`. Update `digest_hex` in `src/mk64/cache.zig`.
- WO: run `python3 scripts/wipeout_pack.py DATA_ROOT /tmp/wo.pak`, then replace
  `assets/wo.pak`. Update `spec.sha256` in `src/wipeout/assets.zig`.
- Compute digests with `shasum -a 256 assets/*.pak`. Run `zig build test`,
  `zig build mk64-test wipeout-test` and the game smoke checks.
- Publish the asset commit before distributing binaries that refer to it. Pin
  release download URLs to that Git commit instead of mutable `main` when changing
  bundle contents, so older releases retain an immutable source. The expected
  checksum is enforced even for a mirror URL. Never silently accept new bytes.

This rename currently points development URLs at `main/assets/mk.pak` and
`main/assets/wo.pak`; those URLs require publishing the renamed files. No remote
write is performed by this change. Container bytes and digests are unchanged.

Game commands remain usable, but are omitted from general help and the initial
command/effect menus. Typing their prefixes still offers completion.
