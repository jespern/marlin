# wipEout port

Status: foundation slice on branch `wipeout-port` (2026-09-06). Track, scenery
and sky load from the original PSX data and render through a pure-Zig
software rasterizer at 320x240, shipped over the Kitty graphics protocol by a
standalone probe. No game logic, input, HUD, audio, or snapshots yet.

## Goals

- 100% Zig. No vendored C, no GPU. The reference C implementation
  (`~/Work/wipeout-rewrite`) is used only as a behavioural oracle.
- Runs inside the terminal via Kitty graphics, keeping the original look:
  per-vertex distance fade, PSX 2x vertex-colour modulation, nearest
  texture sampling, and later the CRT post effect, all reproduced in
  software.
- Full state recoverability: every piece of runtime state lives in plain
  structs that reference assets by index, never by pointer, so a game can be
  snapshotted bytewise and resumed after a marlin restart.
- Identical physics: same formulas and constants as the original, run at a
  fixed 30 Hz step (the PSX rate) instead of the rewrite's variable delta.
- Out of scope: intro video, music, sound effects.

## Layout

| File | Role |
|---|---|
| `src/wipeout/math.zig` | `Vec2/3/4`, column-major `Mat4`, `Rgba`, angle helpers, GLSL `smoothstep` |
| `src/wipeout/bytes.zig` | Bounds-checked cursor for the mixed big/little-endian formats |
| `src/wipeout/image.zig` | TIM decoding (4/8/16 bpp), LZSS, CMP bundles |
| `src/wipeout/assets.zig` | Asset root resolution and file loading |
| `src/wipeout/render.zig` | Software renderer: near clipping, edge-function rasterizer, depth, blend, fade |
| `src/wipeout/track.zig` | TRV/TRF/TRS/TTF loaders, section numbering, index-linked sections |
| `src/wipeout/object.zig` | PRM model parser and drawer |
| `src/wipeout/scene.zig` | Sky dome plus static scenery per circuit |
| `src/wipeout/root.zig` | Module root, per-circuit sky offsets, camera angle helpers |
| `src/testing/wipeout_probe.zig` | Fly-through probe: Kitty output, dry-run metrics, PPM snapshots |

Build steps: `zig build wipeout-test` (unit tests) and `zig build`, which
installs `zig-out/bin/wipeout-probe`.

Run the installed binary directly rather than through `zig build
wipeout-probe`, so the build runner is not competing for the CPU.

Frames alternate between two Kitty image ids: each frame is placed as a
new image and the previous id is deleted afterwards in the same flush, so
the terminal never shows a gap. Pacing sleeps to 2 ms before the deadline
and spins the rest, since sleep wake-up jitter alone can cross a terminal
refresh boundary. At 60 fps a 240p frame costs about 8 ms of work, so
`--fps 60` is a valid choice on a 60 Hz terminal and halves the judder that
a 30 fps stream shows when its cadence drifts against the refresh.

Frame pacing is pipelined: the frame for deadline N is rendered and encoded
right after frame N-1 is presented, so only the terminal write happens at
the deadline. Sporadic 40-80 ms scheduling stalls were observed in dry runs
with no change in rendering work (macOS moving the thread or preempting
it); with the pipeline any stall shorter than the ~25 ms of slack per 30 fps
frame never reaches the screen. Requesting user-interactive thread QoS was
tried and made stalls worse under load, so it is not used. The report
prints the worst frame and the number of frames over 20 ms.

```
zig build
./zig-out/bin/wipeout-probe --track 1 --seconds 15
./zig-out/bin/wipeout-probe --width 640 --height 480
```

## Assets

The data root defaults to `$XDG_DATA_HOME/marlin/wipeout-data` (else
`~/.local/share/marlin/wipeout-data`), overridable with `MARLIN_WIPEOUT_DATA`
or `--assets`. It must contain the original `wipeout/` tree (`track01/`…
`track14/`, `common/`, `textures/`). Only the PSX circuits are supported; the
2097 and N64 code paths are intentionally omitted.

A first-run downloader is planned but not written. Core graphics data is
about 20 MB; the music and intro video that we skip make up the rest of the
142 MB bundle.

## Renderer notes

The GL path in the original is two small shaders. The game shader is
reproduced per pixel: `texture × vertex colour × 2`, alpha discard, and a
`smoothstep(64000, 48000, distance)` alpha fade computed per vertex in world
space. Back faces are culled by default, matching `GL_CULL_FACE`; sky is
drawn with depth writes off. Textures are sampled nearest with clamp, which
is exactly what the original does in its 240p and 480p modes.

Coverage uses fixed-point edge functions at 1/16 pixel with the top-left
fill rule, so an edge shared by two triangles is owned by exactly one of
them and meshes are watertight: no dotted seams where hill faces meet and
no double-blended pixels on shared edges of translucent geometry.

Scenery and track are drawn with back-face culling off and ships with it
on, as in the original race loop; the scenery winding is not consistent.
Vertices go to world space first and then through view-projection, in the
shader's order, rather than through a pre-multiplied MVP.

### Seams between meshes

The scenery objects and the track do not share boundary vertices; they abut
with sub-pixel gaps (measured about 0.06 px at typical distances). Exact
point sampling therefore leaves isolated sky-coloured pixels along hill and
track boundaries, which at 240p scaled to a window read as fat blue dots.
The renderer dilates every triangle by `edge_dilation` sixteenths of a
pixel and lets the depth test resolve the overlap. Over a 6000-frame lap of
track01 at 60 fps:

| Dilation | Pixels covered by no triangle | Transparent-texel discards |
|---|---|---|
| 0 | 23,260 | 7,675 |
| 1/16 px | 1,820 | 7,222 |
| 2/16 px (default) | 1,534 | 7,193 |
| 4/16 px | 1,479 | 7,190 |

The discards are texels whose PSX colour is 0x0000, which the format
defines as transparent; the original shader drops them identically. Render
cost is unchanged.

Diagnostics for this live in the probe: `--scan-cracks DIR` flies a lap
headless and dumps the frames with the most uncovered pixels together with
their coordinates and the mesh ids on either side; `--probe-pixel X,Y` with
`--snapshot` prints every triangle touching one pixel with its edge
distances and depth-test outcome. Boost pads are tinted blue by the game
data itself and are not holes.

Not yet ported: the CRT post effect, 2D HUD text, additive-blend particles
(the blend mode exists, nothing uses it), and mipmaps (unneeded at 240p).

## Measurements (Apple Silicon, ReleaseFast, track01 fly-through, dry run)

| Buffer | Render | Deflate | Wire at 30 fps |
|---|---|---|---|
| 320x240 | 4.8 ms | 2.9 ms | 2.2 MiB/s |
| 640x480 | 11.6 ms | 6.4 ms | 6.4 MiB/s |

Both fit a 33 ms frame with room for game logic. 480p transport has not been
verified against a live terminal yet; run `zig build wipeout-probe --
--width 640 --height 480` in Kitty or Ghostty and watch for dropped frames.

## Probe camera

The fly-through moves at a constant world-unit speed along the section
centre line (default 6000 units/s; track01 is about 586,000 units per lap)
and looks at a point a fixed distance further along the same line, so
neither position nor heading jumps at section boundaries. Both are lightly
smoothed. Earlier versions moved at a constant number of sections per
second, which pulsed with section length and snapped the heading every
boundary.

## Snapshots

```
./zig-out/bin/wipeout-probe --snapshot /tmp/frame.ppm --frame 200
```

writes one 320x240 PPM without touching the terminal, which is how the
renderer was verified without a live session.

## Next slices

1. Game state struct and fixed-step loop: ship physics, track collision,
   camera modes, translated from the reference with a parity harness that
   replays recorded inputs through both implementations.
2. Modal game input in the client (Kitty key press/release), and the game
   as a pixel effect engine so pausing keeps state alive.
3. Snapshot/restore with a version tag and asset hash.
4. HUD, menus, AI opponents, weapons, particles.
5. CRT post pass and first-run asset download.
