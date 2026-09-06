# wipEout port

Status: ship slice on branch `wipeout-port` (2026-09-06). Track, scenery
and sky load from the original PSX data and render through a pure-Zig
software rasterizer at 320x240, shipped over the Kitty graphics protocol by a
standalone probe. A single player ship flies with the original's physics,
track collision, jump handling and rescue, under keyboard control or a
simple autopilot, and a replay harness shows the trajectory matches the
reference build to within 0.01 units over a full lap. The game runs inside
the marlin client as `!wipeout` with the original HUD and an optional CRT
pass, pausing on Escape and resuming where it left off, including across
marlin restarts through an on-disk snapshot. Seven AI opponents race with
the original's controller and collide with each other and the player;
pickups, all six weapons, particles and the rescue droid are in. No audio.

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
| `src/wipeout/assets.zig` | Asset root resolution, file loading from the tree or the bundle, bundle URL |
| `src/wipeout/bundle.zig` | The single-file asset bundle: xz over a small path/offset table plus file data |
| `src/wipeout/render.zig` | Software renderer: near clipping, edge-function rasterizer, depth, blend, fade |
| `src/wipeout/track.zig` | TRV/TRF/TRS/TTF loaders, section numbering, index-linked sections |
| `src/wipeout/object.zig` | PRM model parser and drawer |
| `src/wipeout/scene.zig` | Sky dome plus static scenery per circuit |
| `src/wipeout/defs.zig` | Teams, pilots, per-class handling attributes, per-circuit settings |
| `src/wipeout/input.zig` | Game actions with held and edge-triggered state |
| `src/wipeout/rng.zig` | Deterministic xorshift owned by game state |
| `src/wipeout/ship.zig` | Ship state, player flight model, track collision, jump and rescue, models and shadow |
| `src/wipeout/camera.zig` | External chase camera and cockpit view |
| `src/wipeout/race.zig` | The race: field, camera, pickups, weapons, particles, droid; per-step update and draw order |
| `src/wipeout/weapon.zig` | Mines, missiles, rockets, electro-bolts, shields, turbo: firing, homing, hits |
| `src/wipeout/particle.zig` | Additive sprite pool for trails and impacts |
| `src/wipeout/droid.zig` | Rescue droid: intro, idle above the jump, tow after a fall |
| `src/wipeout/ui.zig` | Bitmap text from the three font textures, screen anchors |
| `src/wipeout/hud.zig` | Lap counter and times, wrong-way warning, speedo |
| `src/wipeout/post.zig` | CRT post pass (the original's fragment shader on the CPU) and nearest upscale |
| `src/wipeout/save.zig` | Options and best-times tables (the original's factory defaults), save file |
| `src/wipeout/menu.zig` | Page stack with buttons and toggles, vertical/horizontal/fixed layouts, cursor blink |
| `src/wipeout/game.zig` | The state machine: title, main menu and race setup, pause, results, points, hall of fame, championship |
| `src/wipeout/session.zig` | A running game: assets loaded once, circuit loaded on demand, fixed-step clock, save file, RGB output |
| `src/wipeout/snapshot.zig` | Bytewise game snapshot with header, default path, read/write |
| `src/wipeout/autopilot.zig` | Heading controller for hands-off laps and replays |
| `src/wipeout/parzlib.zig` | Banded multi-threaded zlib encoder producing one valid stream |
| `src/wipeout/root.zig` | Module root, camera angle helpers |
| `src/client/wipeout_effect.zig` | The game inside marlin: a session plus the terminal key mapping |
| `src/testing/wipeout_probe.zig` | Fly-through probe: Kitty output, dry-run metrics, PPM snapshots, scripted whole-game runs |
| `scripts/wipeout_pack.py` | Builds `assets/wipeout.pak` from an extracted data tree |
| `assets/wipeout.pak` | The bundle the client downloads on first run (3.4 MB) |

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

If presentation falls more than a whole frame behind, the schedule
resynchronises to now and reports the skipped slots as dropped, rather than
presenting every missed frame back to back and burying the terminal
further. `--log-frames FILE` writes per-frame render, deflate and write
times plus payload size as CSV, which is the first thing to look at when a
live run stutters: a write time that spikes while render stays flat means
the terminal or PTY stalled, not the renderer.

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

The port reads only graphics: the common models and textures and the
fourteen track directories, 184 files and 11.2 MB of the original data.
Music (122 MB), sound effects and the intro video are never touched.

Those files ship as one bundle, `assets/wipeout.pak`, built by

```
scripts/wipeout_pack.py <data-root> assets/wipeout.pak
```

from a tree laid out like the reference build (`<data-root>/wipeout/...`).
The container is a path/offset/size table followed by the file bytes, xz
compressed as a whole (3.4 MB; zstd would be 3.9, deflate 6.3). Zig's
standard library decompresses xz, so the loader is pure Zig. Opening the
bundle inflates it into memory once (about 11 MB, well under a second)
and serves files as slices; a frame rendered from the bundle is byte
identical to one rendered from the tree.

The data root is `$MARLIN_WIPEOUT_DATA`, else `$XDG_DATA_HOME/marlin/wipeout-data`,
else `~/.local/share/marlin/wipeout-data`. An extracted tree there wins
(the parity harness and the probe use one); otherwise `wipeout.pak` in
the root is opened. With neither, `!wipeout` downloads the bundle from
raw GitHub (`MARLIN_WIPEOUT_URL` overrides the location) on a worker
thread with progress in the status line, resumable through a `.part`
file, and starts the game when it lands.

The assets are Sony's 1995 game data; bundling them here means this
repository redistributes them.

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

## Driving

```
./zig-out/bin/wipeout-probe --drive --fps 60
./zig-out/bin/wipeout-probe --drive --fps 60 --pilot 6 --rapier --track 3
./zig-out/bin/wipeout-probe --autopilot --fps 60      # hands-off lap
```

Arrow keys steer and pitch, `x` or space is thrust, `z` and `c` are the
left and right airbrakes, `v` toggles the cockpit view, Tab toggles the
autopilot (which yields to any held key), `q` or Escape quits.
Key releases come from the Kitty keyboard protocol (flags 1, 2 and 8), which
Ghostty and Kitty support; without it, keys cannot be held. The race starts
immediately; `--intro` keeps the countdown hover, during which building
thrust to between 680 and 700 gives the original's start boost and holding
more stalls the engine.

The ship module is a translation of the reference flight model: hover force
against the base face, resistance and skid, wall collisions at nose and wing
tips with the junction special cases, jump detection by projecting onto the
ramp face, flying gravity, and rescue back to the track. The physics step
is the presentation frame (1/60 s at 60 fps); every rate is per second so
the model is rate-independent within the original's tolerances. Known gaps
against the original: the rescue tow starts immediately instead of waiting
for the droid to arrive, exhaust plume vertices are not animated, ship to
ship collision and pickups are absent because there is only one ship, and
the autopilot is a two-sections-ahead heading controller rather than the
original AI.

Ship state references the track by section and face index and holds no
pointers, so it is snapshot-ready by construction.

Track directories map to circuits as in the original definition table:
track01 and 06 are Terramax, 02 and 03 Altima VII, 04 and 05 Karbonis V,
12 and 07 Korodera, 08 and 11 Arridos IV, 09 and 13 Silverstream, 10 and 14
Firestar (Venom layout first, Rapier second).

## Parity harness

The reference is built headless from its own sources with a small driver
that replaces the platform layer: a controllable clock stepping 1/60 s, the
null renderer, and a recorded per-frame action bitmask fed through the
input bindings. It lives outside this repository, next to the reference
sources, because it is C:

```
~/Work/wipeout-rewrite/harness/parity_main.c   driver
~/Work/wipeout-rewrite/harness/build.sh        clang -O2 -ffp-contract=off
```

A run records the autopilot's decisions from the Zig side and replays them
into both implementations, then diffs the ship per frame:

```
./zig-out/bin/wipeout-probe --autopilot --intro --dry-run --fps 60 --seconds 60 \
    --record-input /tmp/input.txt --ship-log /tmp/zig.csv
~/Work/wipeout-rewrite/harness/parity ~/Work/wipeout-rewrite/ /tmp/input.txt /tmp/ref.csv 3600 0 0 2
scripts/wipeout_parity.py /tmp/zig.csv /tmp/ref.csv
```

The last three harness arguments are pilot, race class and circuit index
(2 is Terramax, whose Venom layout is track01). The countdown is kept on
both sides and the autopilot holds thrust off until "go", which keeps the
reference's start-stall code off its random path.

Result on track01, 3600 frames (one lap and a third of the next):

| Window | Position error max | Angle error max |
|---|---|---|
| Countdown (390 frames) | 0 (bit-identical) | 0 |
| 0–10 s racing | 0.0020 units | 1e-6 rad |
| 10–30 s | 0.0020 | 1e-6 |
| 30–60 s | 0.0073 | 1e-6 |

Section, mode and flying flags never disagree. Getting here required
mirroring the reference's evaluation types: it computes scalar factors
such as `0.015625 * 30 * system_tick()` in double and narrows to float on
assignment, and the port's constants and per-step scalars now follow the
same order and widths (see `f()` in `ship.zig` and the f64 conversion
chains in `defs.zig`). Before that the two diverged chaotically after 20 s
when a last-bit difference flipped which side of the centre line the ship
was on. The residual is the difference between Apple's libm and Zig's
sine, cosine and arc-cosine, one ulp per call, and it does not compound
into different decisions over the run.

## Inside marlin

`!wipeout [track 1-14] [pilot 0-7] [rapier|venom] [nointro]` loads the
circuit and shows it as a pixel effect. While it is up the client is in
game mode: every key press and release goes to the ship (the same bindings
as the probe, plus `p` for the CRT pass and Tab for the autopilot, shown as
"AUTO" on the HUD) and Escape or Ctrl-C pauses the game and hands the
terminal back. `!wipeout` again resumes the same race; a different track or pilot
starts a new one. The race object is owned by the App, not by the effect
engine, so running another screensaver in between does not lose it, and
the effect engine keeps state alive when hidden as marlin's other pixel
effects already do.

Integration points, all in the client:

- `visual_effect.Kind.wipeout`: a pixel kind marked `playable()`. It is
  reachable only through `!wipeout`: `/animate` and `/screensaver` refuse
  it with a pointer to the command, it is left out of the effect usage
  lists, and it can never be the idle screensaver. On a terminal without
  Kitty graphics `!wipeout` declines rather than falling back to cells.
- Full-screen takeover: the game runs in the screensaver slot, which the
  TUI draws last over the whole window with the cursor hidden. It never
  uses the interleaved mode that `/animate` paints into gaps between text.
- `pixel_effects.Engine`: a borrowed `wipeout_game` pointer, a fixed
  320x240 framebuffer, and a draw that letterboxes the image into the
  largest centered 4:3 cell rectangle instead of stretching it.
- `tui.App`: `game_mode` gates key routing ahead of the screensaver
  dismissal in `dispatchEvent`; `game_active` selects a 16 ms tier in the
  animation thread. The game steps on wall time in fixed 1/60 s steps, at
  most four per tick, so ticker jitter changes smoothness, not speed.
- `commands.zig`: the `!wipeout` entry and its argument parsing.

## Opponents

`race.zig` holds the field as the original's `ships_init`/`ships_update`
do: a shuffled grid with the player at the back in two-ship rows, every
ship updated each step, pairwise collision tests, and an insertion sort by
progress that writes race positions. The AI controller in `ship.zig` is a
translation of the reference: each opponent picks a lateral strategy
(hold centre, left or right, block the player's side, avoid it, zig-zag)
and a target speed from how many sections it is from the player, with the
same rubber band: well ahead it eases to half throttle, well behind it gets
the circuit's extra catch-up speed, and the staggered launch off the grid
follows the circuit's spread settings. Ships steer along the centre line
plus that offset; airborne they aim two sections ahead. Collision uses the
four-vertex hulls from `alcol.prm` and the original's edge-through-face
test and momentum exchange.

Difficulty scales the original opponent tuning: `easy` 0.75, `normal`
0.88 (the default, deliberately below the original), `hard` 1.0.
`!wipeout trial` races alone. When the player finishes, the ship is handed
to the AI at a gentle cruise as the original does, and the results page
appears.

## Pickups and weapons

Pickup pads are the base faces flagged in the track data (thirteen on
track01). Their state, armed, collected, cooldown, lives in the race and
the face colours are derived from it each step: a rainbow cycle while
armed, white when taken, dark during the one-second cooldown. The player
draws a weapon from the original's weighted table (projectiles only while
shielded); AI ships always receive a mine, as in the reference, and choose
what to actually fire in their decision code: mines or a shield when
blocking just ahead of the player, rockets, a missile or an electro-bolt
when just behind, after the original's 1.1 s delay.

`weapon.zig` keeps a pool of sixty-four in-flight weapons. Mines drop five
at a time and spin in place, projectiles launch on the original's
trajectory and hug the track surface, missiles and bolts home on their
target, and each has the reference's duration, drag and hit effect: a
mine or missile scrubs the player's speed and shakes the camera, an
electro-bolt jitters the victim and cuts its thrust at random, a shield
absorbs everything for its duration, turbo is an instant shove. Trails and
impacts are additive sprite particles from `effects.cmp`. Keys: `f` or
Enter fires; the HUD shows the held weapon's icon and a reticle over a
missile or bolt target.

The rescue droid flies the original's intro over the grid, waits above the
first jump, and when the player falls off comes in under the remote
camera, tows the ship back, and returns to its post. Camera shake is an
NDC offset in the renderer, as the original's `screen` uniform.

Render-time animation on shared models (mine lights, shield colours, the
droid's lamps) mutates primitive colours on the loaded object each frame;
it is derived from time and never persisted.

## HUD

`hud.zig` draws what the original's in-race HUD shows for a single ship:
lap counter, the running lap time with completed laps above it, the
"WRONG WAY" warning, and the speedo whose thirteen coloured bars track
speed with a red overlay for thrust, under the facia texture. Text comes
from the original's three bitmap fonts with their glyph metrics; the
digits, colon and full stop are the only punctuation. The "LAP RECORD"
slot shows the best lap of the current session because there are no
saved highscores yet. Race position and the weapon icon wait for
opponents and weapons.

Crossing the line on the final lap ends the race, as in the original's
ship update. The reference hands the ship to the AI and cycles attract
cameras; here the ship simply stops taking input and coasts to a halt,
and the HUD draws the results page (lap times, race time, best lap) dimmed
over the scene. Thrust on that page starts a new race on the same circuit;
Escape leaves as usual, and the finished race is what gets saved.

## CRT pass

`post.zig` evaluates the original's CRT fragment shader per pixel:
barrel curvature, colour fringing with a slow horizontal wobble,
vignette, scanlines, flicker and an alternate-column mask. The shader
runs at window resolution over the 240p image in the original, so at 1x it
degenerates into fat bars; the port evaluates it at 2x (640x480). The pass
runs across six row-band threads (about 3 ms for 640x480). Its output is
quantised to 6 bits per channel, invisible under the mask but it takes the
deflated frame from 70% to 46% of raw. Encoding uses `parzlib.zig`: the
frame is cut into six row bands, each deflated on its own thread as a raw
stream ending in a sync flush (byte aligned, last block non-final), and the
fragments are joined under one zlib header with an Adler-32 trailer, which
any decoder, the terminal included, reads as a single stream. The pixel
engine uses it for every compressible frame over 200k pixels, so the
other large effects benefit too. Result for CRT at 2x, 60 fps, headless:
render 7.8 ms, deflate 3.8 ms, 59.8 fps achieved. The cost that remains
is bandwidth: about 24 MB/s deflated (32 MB/s as base64) through the PTY,
against roughly 2 MB/s for plain 240p. It is off by default; `p` toggles it
in game and `!wipeout crt` starts with it on.

## Menus and game flow

`game.State` is the original's `main_menu.c`, `ingame_menus.c` and the
flow parts of `game.c`/`race.c` as one plain-data state machine over a
`menu.Menu` page stack. A bare `!wipeout` opens the title screen; Enter
leads to the main menu (START GAME / OPTIONS / QUIT) with the rotating
menu models from `msdos.prm`, `leeg.prm`, `teams.prm`, `pilot.prm`,
`alopt.prm` and `pad1.prm`, then racing class, race type (championship,
single race, time trial), team, pilot and circuit, with the circuit
thumbnail from `track.cmp`. Options cover internal view roll, screen
shake, the CRT pass and opponent strength; best times shows the five
entries and lap record per class and circuit.

In a race Enter pauses (CONTINUE / RESTART / QUIT, with confirmations).
Finishing shows race statistics with the pilot portrait, then for a
championship the race points and the championship table, then the hall
of fame when the time beats one of the five entries. Points per finishing
rank are 9/7/5/3/2/1/0/0; finishing outside the top three fails to
qualify and costs a life (three per championship, then GAME OVER). The
next championship race starts from the previous finishing order with the
player at the back, as the original. Winning the last circuit unlocks the
Rapier class or the bonus circuit and shows the congratulations scroller.

`!wipeout <track> [pilot] [rapier] [trial] ...` still skips the menus and
starts that race directly.

The probe drives all of this headless:

```
./zig-out/bin/wipeout-probe --game "10:menu_start,50:menu_select,90:shot" --shots /tmp/wg
```

where entries are `frame:action` (any `input.Action` name), `+name` and
`-name` to hold and release, `shot` to write a PPM, and `hall` to open
the hall of fame entry as a test hook.

## Save and resume

Options and best times live in `$XDG_STATE_HOME/marlin/wipeout-save.bin`
(else under `~/.local/state/marlin/`), written whenever they change.
Escape (and marlin exit) writes the whole game state, menus and race
alike, to `wipeout-race.bin` next to it. A bare `!wipeout` with no game
in memory restores it: assets reload, the circuit the state wants loads,
and the state, RNG and step count are copied in. Naming a track, pilot or
class, or passing `new`, starts fresh instead. The snapshot is the state
structs behind a header with magic, version and size; any mismatch is
treated as no snapshot, so a build that changes a struct simply starts
at the title. Everything in it references the track by index, which is
why the design insisted on that from the first commit.

## Snapshots

```
./zig-out/bin/wipeout-probe --snapshot /tmp/frame.ppm --frame 200
```

writes one 320x240 PPM without touching the terminal, which is how the
renderer was verified without a live session.

## Next slices

1. Polish: attract cameras after the race, pause on focus loss.
