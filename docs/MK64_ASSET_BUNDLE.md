# Minimal asset bundle investigation

Historical experiment: see [MK64_ASSETS.md](MK64_ASSETS.md) for the implemented
pure-Zig importer, embedded bundle and regeneration workflow.

The current port can replace its ROM dependency with an offline asset import.
The ROM is a data source: no ROM machine code executes. Course, kart and HUD
loading are concentrated in `src/mk64/course.zig`, `kart.zig` and `hud.zig`.
The game does not yet load the experimental bundle described here.

## Measured result

Using the supported USA ROM (SHA1 `579c48e211ae952530ffc8738709f078d5dd215e`):

- ROM: 12,582,912 bytes (12 MiB).
- Experimental bundle: 310,087 bytes (302.8 KiB), 97.5% smaller.
- Compressed resources: 252,446 bytes; header, JSON directory and checksum: 57,641 bytes.
- Packed resources before compression: 818,655 bytes across 267 entries.

| Resources | Packed bytes | Compressed bytes |
| --- | ---: | ---: |
| Course geometry, materials, textures and path | 230,549 | 66,066 |
| Collision geometry and surface tags | 15,818 | 10,043 |
| Eight characters' kart frames and palettes | 544,384 | 168,916 |
| Shared drift particles | 1,280 | 761 |
| HUD | 26,624 | 6,660 |

This covers the current Luigi Raceway prototype, not the complete original game.
Future courses, items, animations or audio require additional resources.

## Inventory and exclusions

The audit exports assets through the actual Zig loaders, then packs their decoded
results. It preserves visual triangle order, collision order and path order.

- Course: 3,014 visual triangles, 5,367 distinct position/UV/colour vertices,
  42 materials and 631 path points. Positions use signed 16-bit coordinates;
  UVs use signed 16-bit values scaled by 1/32, exactly as the source data.
- Textures: retain complete tiles referenced by visual triangles, merge overlapping
  byte spans and remap material offsets. This retains 131,072 of the 133,120 bytes
  loaded today. It does not attempt to identify individual unsampled texels.
- Collision: 1,502 triangles, 884 distinct positions and original surface tags.
  Remove colours, UVs, materials and vertex flags, which collision consumers do
  not use. The filtered collision triangle list is already computed by the loader.
- Karts: 15 near-rear CI8 frames per character, 120 frames total. Keep only palette
  indices referenced by those frames. Store common body colours once per character
  and wheel colours per frame for all four animation phases. Do not expand every
  frame into four complete RGBA palettes in the file.
- Particles: shared 16x16 and 32x32 I8 drift sparks, once each.
- HUD: font atlas, question-mark box, mushroom/banana/green-shell/red-shell icons,
  lap 1/2/3 and time labels. Encode decoded colours losslessly as RGBA5551.
  The whole font atlas is retained, rather than trimming individual glyphs.

Exclude ROM code, boot data, unused courses, audio, unused character views,
unused common-segment assets, packed display lists, path sentinel/capacity and
intermediate vertex arrays. Behaviour, font mapping and item spawn coordinates
already implemented as Zig constants remain in source.

## Reproduce

Run from the branch worktree. Keep generated files outside the repository:

```sh
zig build mk64-probe -- '/Users/jespern/Downloads/Mario Kart 64 (USA).z64' /tmp/mk64-asset-audit.json 0 asset-audit
python3 scripts/mk64_asset_audit.py /tmp/mk64-asset-audit.json /tmp/luigi.mkassets
```

The JSON audit is a temporary decoded interchange file. Python is measurement
and format-experiment tooling only; the production importer should be pure Zig.
The script writes a bundle and a readable `.manifest.json` sidecar. It reopens
its output, verifies the file checksum and decompresses every section, checking
byte equality and resource SHA256. Numeric packing and colour conversions assert
exact representability; referenced texture bytes are checked after remapping.
These checks establish resource round-trip fidelity, not gameplay/render parity.

## Experimental format

`MKASXP01` magic, little-endian u32 JSON directory length, UTF-8 JSON directory,
independently zlib-compressed resource payloads, then SHA256 of all preceding
bytes. Directory offsets are relative to the payload start. Each entry records
name, encoding, count, offset, compressed and decoded lengths, and decoded SHA256.
Identical payloads can share storage; this sample has 267 unique payloads.
Multibyte packed fields are explicitly little-endian except original course
texture bytes, which preserve their big-endian texture encoding.

This deliberately inspectable experimental directory costs roughly 56 KiB.
A production version can use a compact binary directory with stable resource IDs,
explicit versioning and optional compression. Do not serialize Zig structs or
pointers directly: padding, ABI and allocator ownership must not enter the format.

## Implementation path

1. Implement an offline Zig importer using the same three existing loaders and
   the measured packing rules. Emit a versioned bundle with deterministic output.
2. Implement a bounded Zig reader: validate versions, lengths, decompression limits,
   checksums, required resources, geometry indices, palette references and texture
   ranges before allocation/use. Reconstruct the current Course/Sprite/Hud types
   initially, so the renderer and handling need no simultaneous rewrite.
3. Introduce a shared asset-loading entry point for standalone play, `!mk` and
   `/screensaver mariokart`. After a successful import, those paths should run
   entirely from the bundle without reopening or requiring the ROM.
4. Compare ROM-loaded and bundle-loaded pixels across course views, all characters,
   wheel phases, particles and HUD states; compare deterministic race/ghost results.
   Check truncated, corrupted and incompatible bundles fail cleanly.

The measured file is available locally at `/tmp/luigi.mkassets`. No extracted
assets are added to the repository. Runtime asset loading remains unchanged.
