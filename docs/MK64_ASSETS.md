# Mario Kart assets

The 235.4 KiB bundle lives under `assets/mk.pak`, outside the executable.
On first launch, `marlin mk64`, `!mk` and `/screensaver mariokart` download it from
`https://raw.githubusercontent.com/jespern/marlin/main/assets/mk.pak`.
The expected SHA256 and URL are pinned in `src/mk64/cache.zig`. A valid cached file
needs no network. Downloads are bounded, validated and atomically installed;
a corrupt cache is repaired on the next successful download. Failures offer retry
or a local `MARLIN_MK64_ASSETS` override and do not install incomplete data.

Cache: `$XDG_CACHE_HOME/marlin/assets/<sha256>/mk.pak`, falling back to
`~/.cache/marlin/assets/<sha256>/mk.pak`. Explicit bundle/ROM paths bypass downloads.
The renamed raw URL is not live until this asset file is published to `main`.
See [ASSETS.md](ASSETS.md) for shared cache policy and publishing.

## Regenerate or extend

```sh
zig build mk64-import -- '/Users/jespern/Downloads/Mario Kart 64 (USA).z64' /tmp/luigi.mkassets
shasum -a 256 /tmp/luigi.mkassets
```

The importer validates the supported USA ROM SHA1, extracts through the same
course/kart/HUD loaders used during development, encodes the bundle, reloads it,
and compares every consumed resource against direct ROM loading before writing.
Output is deterministic. The ROM and intermediate decoded assets stay outside
Git; the generated `.mkassets` file belongs in the repository alongside its recipe.
Copy the result to `assets/mk.pak` and update
`digest_hex` in `src/mk64/cache.zig`. Run `zig build mk64-test` and `zig build`.
Publish the new asset to `main` before distributing a binary pinned to it.
Pin the raw URL to the published commit so older clients retain their exact bundle. Each changed bundle gets
a new cache entry automatically; users need not delete their cache.

To expand the asset set:

1. Add the ROM references and decoding to `course.zig`, `kart.zig` or `hud.zig`.
2. Update the `Data` schema, importer and reconstruction in `assets.zig` when
   adding a new resource type or changing fixed dimensions. Variable course
   triangle, collision, texture and path counts are exported automatically.
3. Bump the `MKAS0001` version for wire schema changes. Keep a reader for the old
   version only if external-bundle compatibility is needed; otherwise old files
   fail explicitly with `UnsupportedAssetVersion` and can be regenerated.
4. Extend `verifyRom` to cover new resources, regenerate, run tests and rebuild.
   Update this inventory and review the binary size/diff along with the recipe.

Changing asset contents alone needs regeneration, not a format version bump.
A future second course needs an explicit course collection/selection schema;
this v1 intentionally represents one course. It is not an opaque ROM slice dump.

An explicit bundle path or `MARLIN_MK64_ASSETS=/absolute/file.mkassets` permits
trying regenerated assets without rebuilding. A USA ROM path is also accepted
for development and imported in memory. `MARLIN_MK64_ROM` remains a fallback.
No external source is opened when neither override is set.

## Format v1

Eight ASCII bytes `MKAS0001`, u32 little-endian decoded length, one zlib stream,
then SHA256 of the entire preceding file. Decoded fields follow `Data` declaration
order: numbers are explicitly little-endian, booleans are 0/1 bytes, arrays have
fixed lengths, slices have u32 counts. No struct padding, pointers or ABI data.
Positions and UVs retain their exact f32 values. The header length and allocation
budget bound decoding; the reader checks checksum, version, finite geometry,
texture ranges, palette coverage and required nonempty course data.

Resources are visual triangles and materials; referenced complete texture tiles
with remapped offsets; collision positions and surface tags; ordered path points;
120 CI8 kart frames with only referenced palette colours across four wheel phases;
shared drift sparks; font, item icons, box texture and lap/time labels. HUD and
palette colours use lossless RGBA5551. Unused ROM segments, code, audio, views,
intermediate vertices and collision UV/material/colour fields are excluded.
Repeated frame palette colours and geometry compress in the shared zlib stream.
The 303 KiB Python experiment used a different, incompatible format; it is not
used by the game or production import process.

## Verification

`mk64-import` compares paths, visual positions/UVs/colours/materials and sampled
tile bytes, collision positions/surfaces, all frame indices and their used palette
colours across four phases, particles and every HUD pixel. This is resource parity
with the existing port, not a claim of original N64 gameplay fidelity.

`zig build mk64-test` loads the repository bundle without a ROM and checks damaged,
truncated, unsupported and oversized data. `zig build test` checks TUI dispatch.
The following PTY smoke checks seed isolated caches from the repository fixture
and run with ROM/asset overrides removed; they require no network. Cache tests
cover first fetch, offline reuse, failed download and corrupt-cache repair:

```sh
python3 scripts/mk64_tui_smoke.py zig-out/bin/marlin
python3 scripts/mk64_terminal_smoke.py zig-out/bin/marlin
```
