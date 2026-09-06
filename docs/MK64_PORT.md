# Mario Kart 64 in Marlin

Branch: `mk64-zig-port`. First drivable foundation, September 6, 2026.

The target is the actual Mario Kart 64 game, implemented in Zig and rendered
inside Marlin. The current implementation is a **Luigi Raceway race/time-trial prototype**.
It loads original course geometry, textures, collision lists, racing path and
Mario's rear-view angle frames from the user's ROM. Grounded Mario/100cc handling now
uses original acceleration bands, braking, steering stages, friction and surface
loss tables. Hop impulses, drift steering and mini-turbo charge/timing are also ported.
Full original physics, original opponent AI and character stats, the remaining items, menus, full kart animation, audio and the other courses are still outstanding. This is not yet a
complete or gameplay-equivalent port.

## Run

Build with `zig build`, then use the resulting Marlin binary:

```sh
./zig-out/bin/marlin mk64
```

Inside that build's TUI:

```text
!mk
/screensaver mariokart
```

`!mk` starts normal play. `/screensaver mariokart` starts autopilot with the keys
overlay and repeats races after a three-second finish screen. Driving keys take
control; Escape/Q returns to the same Marlin session. Focus loss still pauses,
and P resumes autopilot. This is a manually launched full-screen game, not an
idle `/config screensaver` effect.

Both download the asset bundle on first launch and use a verified local cache
afterward; no ROM is needed.
An optional absolute bundle or USA ROM path overrides it, including quoted paths
with spaces. `MARLIN_MK64_ASSETS` takes precedence over the legacy
`MARLIN_MK64_ROM` variable. The selected source is remembered in this client.
`/mk64` remains an alias for normal play; `!s mariokart` launches autopilot.
See [the asset format and regeneration guide](MK64_ASSETS.md) to add resources.

Use a terminal supporting both Kitty graphics and Kitty keyboard key-release
events, such as Ghostty or Kitty. The game checks both capabilities and refuses
to start if either is unavailable. Text-only terminal rendering is not provided.

- **W / Up:** accelerate.
- **S / Down:** brake.
- **A / Left, D / Right:** steer.
- **Space:** press to hop; hold through a turn to drift. Countersteer, then
  steer back into the slide twice; release Space when the HUD says DRIFT READY
  to trigger a mini-turbo. Holding Space does not repeatedly hop.
- **O:** toggle autopilot. It follows the course path using the same keyboard
  inputs available to you; it is a demonstration driver, not original opponent AI.
- **T:** start a rolling drift demonstration on Luigi Raceway's left bend. This
  relocates/resets the race for the demonstration, performs a fixed key sequence,
  releases a mini-turbo, then continues with path-following autopilot.
- The race HUD shows live speed in the original controller's km/h scale.
- **H:** toggle the key overlay; **G:** toggle the saved ghost.
- The optional second HUD row shows the actual W/A/S/D/Space inputs used for simulation.
  Press any driving key to take control immediately. Pause/focus loss stops the
  demonstration without consuming its input sequence; R resets to manual mode.
- **P:** pause/resume; focus loss also pauses and clears held controls. Autopilot
  and the demo sequence survive focus-pause; driving input while paused is ignored.
- **Hold E:** trail a ready banana or shell behind the kart for defense.
  **Release E / Shift+E:** use forward/backward. Mushrooms also use on release.
  Press after roulette finishes; holding an empty slot does not arm a later pickup.
- **M:** switch between eight-kart race (the default) and time trial. Switching
  starts a new countdown. Race mode never reads or writes time-trial ghosts.
- **C:** cycle 100cc → 150cc → custom 200cc → 50cc. Changing class starts a
  fresh countdown; R and T retain the selected class. The HUD shows the class.
- **R:** restart the three-lap trial and countdown.
- **Escape / Q / Ctrl-C:** exit; `/mk64` returns to the same agent session.

The daemon continues working while the game owns the terminal. Game state is
client-local. Eligible best times and their visual ghosts persist across launches. A remote daemon does
not receive the ROM; rendering and game execution happen at the attached client.

## Eight-kart race

The starting grid contains Mario (you), Luigi, Yoshi, Toad, DK, Wario, Peach and
Bowser. CPU sprites and animated wheel palettes are loaded from the ROM.
Position is ordered by signed course progress with sub-path-point interpolation;
completed racers retain their finish order. The finish panel shows the field at
the moment you finish, marking unfinished opponents RACING. R retries the race.

Seven deterministic CPU drivers use the same throttle, steering, hop and drift
controller as the player. Each has a distinct decision profile: launch delay,
cruising throttle target, corner caution, preferred line and drift frequency.
Luigi/Yoshi lead, Peach/DK form the midfield, and Wario/Bowser/Toad are more
forgiving. These are prototype difficulty profiles, not original character stats.
Drivers lift to regulate pace and choose passing lines around nearby karts,
including the player. Controller limits and physics remain identical. The validated left
bend mini-turbo sequence is enabled at 100cc within its tested entry-speed
window, with Luigi attempting it every second lap and Yoshi every third lap.
Other CPUs/classes currently path-follow without scripted mini-turbos.
There is no rubber-banding or original opponent AI.
The full-race probe requires at least a ten-second CPU finishing spread and
a top-four finish for the baseline path-following player, as well as all eight
finishing with valid laps. All racers currently use
Mario's class tuning; character-specific weight and acceleration remain pending.

Kart contacts exchange bounded, equal-mass velocity impulses. Movement on the
next simulation tick goes through the existing floor/wall checks, rather than
teleporting karts apart. This is a collision adapter, not original kart collision
response. Finished karts stop participating in contacts. All CPUs freeze on
pause/focus loss and the whole race freezes when the player finishes.

Sprites are distance-scaled and depth-tested, using the currently supported
near-rear angle bank. Full front/side/pitch animation remains incomplete.
T switches to isolated drift practice; M returns to race. O can drive the player
kart in races too. Race results never overwrite time-trial records.

## Item boxes, roulette and weapons

Race mode uses the original 18 Luigi Raceway item-box locations in three rows.
A shared box respawns after three simulation seconds. Inventory holds one item;
a 45-tick roulette cycles ROM HUD icons before revealing its result. The seeded
prototype distribution is 50% mushroom, 25% banana, 15% green shell and 10% red shell, with no
position weighting. Restart resets the seed, making races reproducible.

Hold **E** to trail a ready banana, green shell or red shell behind the kart.
Release **E** to use forward, or use **Shift+E** for backward release. Mushrooms
boost on release in either direction and cannot serve as guards. Trailing items
intercept one incoming shell before kart collision; both items are consumed.
A second shell can still hit. Guards have a rear collision volume, not all-around
immunity, and are hidden/disabled where the trailing position is obstructed.

The slot reads GUARD while trailing. SHELL BLOCKED confirms interception; a
RED SHELL INCOMING warning appears for a live red shell targeting you within
350 world units on a similar elevation. Holding an empty/rolling slot cannot
accidentally fire a newly acquired item on release. Pause/focus loss cancels a
manual hold without consuming the item; reset/mode/class changes clear it.
Autopilot and Luigi/Yoshi may hold defense against an incoming red shell after
a reaction delay; easier CPUs retain their existing item-use behavior.
The H key overlay shows E HOLD while guarding and briefly shows E or SHIFT+E
after an item activation, including autopilot activations.
Forward bananas are tossed a short distance, while backward bananas drop behind
the kart. Green shells travel straight without homing, reverse off walls and
expire after ten seconds or six bounces. Bananas expire after thirty seconds.
Red shells lock once onto a nearby eligible kart ahead, follow the course path
and steer toward the target when close with clear sight. Turn rate is capped;
they break on walls and expire after ten seconds. A missed close pass destroys
the shell instead of allowing a U-turn. Backward red shells travel straight.
Finished targets are released without acquiring a new target. There is no
original red-shell actor AI yet. Trailing-item interception is a prototype
collision adapter; released item-vs-item interception remains pending.

These trajectories and simplified wall responses are adapters, not original
actor physics. At most 32 actors can exist; if full, the held item is retained.
Shell movement uses four collision substeps per tick and both item types respect
floor height and kart elevation. Owners are protected for the first 30 ticks.

Hits cut speed and cancel boosts/drift, suppress control for 45 ticks and grant
150 ticks of hit immunity. Karts wobble during recovery and flash while immune.
This prevents repeated instant hits; the original spin animation/status system
is not fully ported. Finished karts are excluded. World items currently use
cropped ROM HUD-icon billboards; actor meshes, original bounce normals, banana
animation and sound remain pending. Boxes use the ROM question-mark texture with
a translucent coloured border; original rotating cube geometry is also pending.

The mushroom follows the original 80-tick timer, 400-unit boost target, 0.5 rise/
0.1 decay and throttle-at-top-speed behavior through the existing force adapter.
Original mushroom surface/status interactions, sound and camera effects remain
unported. Mushroom power is separate from mini-turbo charge.

CPUs and player autopilot collect the same boxes, wait for straights and delay
weapon use longer than mushroom use. They drop bananas backward and fire shells
forward. Red shells have a longer use delay and limited homing; green shells
have no homing. The varied CPU pace profiles remain.
Pause/focus loss freezes all item clocks; restart/class/mode changes clear all
inventory and actors. Time trial remains item-free and its records are isolated.

## Time trial and HUD

A three-second countdown freezes the kart before GO. The HUD uses lap/time
labels and the debug font extracted from the ROM, with live race/lap clocks,
splits, speed, drift readiness and a three-lap finish panel. The layout and
countdown are Zig adapters; Lakitu and original start boosts are not implemented.
Mario defaults to 100cc. The 50/100/150cc presets use original Mario throttle
caps (290/310/320), drift lateral constants (28/28/35) and drift drag
constants (-10/-15/-20). Other class-specific original behavior is not yet
fully ported. Custom 200cc uses a 370 throttle cap and 150cc drift constants;
it is not an original N64 mode. Extra/Mirror and Battle are not selectable.

Finish detection follows the original forward Z-plane crossing near path zero.
Additional ordered quarter-course gates and net progress prevent short loops
from counting as laps. These safeguards are an adapter, not a complete port of
original checkpoint logic. Times are quantized to 60-Hz simulation ticks; pauses
and countdown time are excluded.

An unassisted valid new best saves automatically. Enabling O makes the whole run
assisted even after manual takeover; T enters practice. Neither can save a best.
R restores eligibility. Ghosts store 60-Hz position, facing and wheel poses,
play back against the race clock, and have no collision or control influence.
They are visual recordings, not original N64 input-replay ghosts.

Best times and ghosts are isolated per class. The versioned, SHA-256 checked
files are `luigi-50cc-v1.ghost`, `luigi-100cc-v1.ghost`,
`luigi-150cc-v1.ghost` and `luigi-200cc-v1.ghost` under
`$XDG_STATE_HOME/marlin/mk64`, or `~/.local/state/marlin/mk64`.
`MARLIN_MK64_STATE_DIR` overrides that directory. Writes replace the file
atomically; invalid files are ignored. Recording is bounded to ten minutes;
longer runs cannot save a best.

## Implementation

Everything under `src/mk64/` and the MK64 terminal client is Zig. There is no
emulator, external game executable, GPU backend, C game library or runtime
dependency on the decompilation checkout. Marlin's existing general dependencies
are unchanged.

| Module | Responsibility |
| --- | --- |
| `src/mk64/rom.zig` | Exact US ROM SHA-1 validation, bounded big-endian reads, MIO0 decompression |
| `src/mk64/course.zig` | Course table, compact vertices, packed display lists, textures, sentinel-terminated path and original collision lists |
| `src/mk64/render.zig` | 320×240 CPU rendering, near clipping, perspective-correct UVs, depth, RGBA5551/IA16, wrap/mirror/clamp |
| `src/mk64/kart.zig` | 15 CI8 Mario angles, four wheel-palette phases, ROM drift textures, projected/depth-tested kart and particles |
| `src/mk64/presentation.zig` | Persistent chase camera, wheel clock, and drift particle simulation |
| `src/mk64/handling.zig`, `handling_tables.zig` | Grounded Mario/100cc controller equations and original steering tables at 60 Hz |
| `src/mk64/autopilot.zig` | Path-following driver and fixed drift demonstration shared by terminal and probes |
| `src/mk64/drift.zig` | Hop impulse, drift charge and mini-turbo state; floor-relative vertical adapter |
| `src/mk64/game.zig` | One simulation step per 60-Hz frame, floor/wall contact adapter, directional lap progress |
| `src/mk64/items.zig`, `item_positions.zig` | Shared box respawns, mushroom inventory and original course spawn positions |
| `src/mk64/race.zig`, `characters.zig` | Seven input-driven CPUs, grid, race ordering, contact impulses and ROM sprite offsets |
| `src/mk64/trial.zig`, `hud.zig`, `ghost.zig` | Countdown, ordered lap validation, ROM HUD and persistent visual best-run ghost |
| `src/client/mk64.zig` | Keyboard, focus, resize, frame pacing, compression, Kitty presentation and teardown |

The supported US `.z64` hash is
`579c48e211ae952530ffc8738709f078d5dd215e`. Other revisions and byte orders fail
validation. Runtime offsets refer to that exact revision. The decompilation at
`~/Work/mk64` is the behavioral reference, particularly `src/racing/memory.c`,
`src/racing/collision.c`, `courses/luigi_raceway/`, and `assets/karts/mario_kart.json`.

Luigi Raceway loads 5,936 vertices, 3,014 visual triangles, 133,120 texture bytes
and **631 path points**. The metadata's 730 is reserved capacity, not the path
length; the loader stops at the original `-32768` sentinel. Collision uses the
original section display lists and excludes vertices flagged non-collidable.

The renderer implements the subset needed for this course, not the full N64
graphics pipeline. Lighting/culling/render-mode commands are currently ignored;
texture alpha is cut out, with no translucent blending or N64 antialiasing.
Sky is a placeholder gradient, and the balloon, animated billboard and other
dynamic objects are absent. The full-course display list is rendered instead
of the original visibility selection. These are explicit fidelity tasks.

The handling slice follows `src/player_controller.c`: normal
`player_accelerate_alternative`, B braking in `func_800323E4`, steering stages
in `func_80033AE0`, and grounded longitudinal force/friction integration.
Throttle and velocity are separate; momentum persists through steering, and
four surface samples affect traction. Keyboard keys map to the original full deadzoned stick range. Hop and drift
use the original steering resistance branches (hop 3/6, grounded drift 6/9
at speed); normal turn flags are cleared while hopping/drifting. Strong
countersteering sets DRIFT_OUTSIDE and suppresses yaw below counter 100,
while retaining lateral force. The earlier 24/53 keyboard workaround has been
removed because it could not reach the original outside-steering threshold.

Physics runs at 60 Hz, matching the original single-player simulation rate.
Presentation now targets 60 FPS, rendering each simulation step. The fixed-step
accumulator preserves game speed when rendering or terminal writes take longer;
visible FPS still depends on terminal throughput.

Contact points, slope/slip estimation and planar force projection remain
adapters. The grounded, no-status Mario/100cc drift lateral force and drag
branches are now ported for pavement (base lateral grip 28, drag -15).
Full normal-driving lateral forces, off-road lateral grip modifiers, suspension,
triple-A/B button-combo boosts, status effects and original collision response
remain incomplete. Hop height follows a
floor-relative adapter rather than full airborne terrain collision; it cannot
clear barriers or jump off ledges. Drift uses the original doubled, clamped and
smoothed displacement angle, steering maps and countersteer charge rules. The
mini-turbo effect lasts 31 simulation ticks and adds the original smoothed boost
force. The sprite now selects a ROM angle frame from the slip angle using the
original near-rear 0x208-unit spacing and mirrored views. The four original wheel palettes now animate using the speed-indexed table at
30 Hz. Drift particles use the ROM's 16×16 and 32×32 I8 textures, original
white/yellow/orange charge colours, 3-tick emission spacing, 8-tick lifetime,
vertical rise, growth and alpha decay. They are projected in world space and
depth-tested against the road; raster blending and tyre placement remain
adapters. Pitch-bank selection and other particle/status effects remain pending. This
slice is not a claim of gameplay equivalence.

The normal single-player chase camera now follows `func_8001E45C` and
`func_8001CCEC`: bounded angle tracking, 12°/16° drift offsets, offset recovery,
50-unit trailing distance, 9.5-unit height above the kart centre, 70-unit lookahead,
0.4 horizontal follow, and separate vertical smoothing. A 6-unit body-centre
adapter connects it to the floor-based kart model. Camera obstruction uses the
existing collision mesh to shorten the sight line and keep the eye above the
floor; the original camera collision volumes, status-effect branches and shake
are not fully ported. The kart now projects from its world position rather than
remaining at a fixed screen coordinate; its angle includes the camera offset.
All presentation clocks pause and reset with the race.

## Validation

```sh
zig build mk64-test
zig build test

# ROM-backed image and 73-view renderer timing sweep:
zig build mk64-probe -- "$MARLIN_MK64_ROM" /tmp/luigi.ppm 0

# Drive straight for 300 ticks, then capture Mario and the chase camera:
zig build mk64-probe -- "$MARLIN_MK64_ROM" /tmp/drive.ppm 0 300

# Fixed left/right drift sequences must charge, boost, stay off grass and keep moving:
zig build mk64-probe -- "$MARLIN_MK64_ROM" /tmp/drift-ready.ppm 0 drift-test

# Real TUI command handoff and same-session return, with an isolated daemon:
python3 scripts/mk64_tui_smoke.py zig-out/bin/marlin "$MARLIN_MK64_ROM"

# PTY demo/autopilot/input-HUD regression (simulated terminal responses):
python3 scripts/mk64_terminal_smoke.py zig-out/bin/marlin "$MARLIN_MK64_ROM"

# Independently compile original C routines for local-force/yaw/charge/steering fixtures:
python3 scripts/mk64_drift_reference.py ~/Work/mk64

# Trial countdown, three splits and exact ghost save/reload (writes beside image):
zig build mk64-probe -- "$MARLIN_MK64_ROM" /tmp/trial.ppm 0 trial-test

# Item-row and inventory HUD preview:
zig build mk64-probe -- "$MARLIN_MK64_ROM" /tmp/items.ppm 0 item-view

# Eight-kart completion, grid order, pause, contact, item use and CPU turbo checks:
zig build mk64-probe -- "$MARLIN_MK64_ROM" /tmp/race.ppm 0 race-test cc100

# Class probes also check three laps and ghost round trips:
zig build mk64-probe -- "$MARLIN_MK64_ROM" /tmp/200cc.ppm 0 trial-test cc200
# Substitute cc50 or cc150 to check those classes.

# Test driver must complete three laps on the actual collision mesh:
zig build mk64-probe -- "$MARLIN_MK64_ROM" /tmp/lap.ppm 0 lap-test
```

Acceleration tests include exact float-bit fixtures from the original normal
C branch compiled with host `cc -O0`, covering band crossings, slopes and
clamping. Runtime and tests require no C game code. Separate response tests
check road/grass terminal speed and braking. Hop/drift tests cover landing,
held-key rearming, charge cancellation, turbo duration and full keyboard-driven
left/right slides through boost release. The ROM-backed lap test checks three complete laps at the 60-Hz tick rate.

The drift probe uses rolling entries at path 460 (left) and 380 (right), with
fixed 20/25/10/25/10-tick inward/outward key phases and then ordinary path
following. It never reads charge state to choose drift inputs. Both sequences
show ready and boost, keep all tyre samples off grass, and gain over 0.5 world
units/tick after release. Observed speeds are 4.81→5.88 and 4.20→5.31. A duplicate simulation with
identical recovery inputs and the boost force disabled measures a boost-only
gain of 0.72/0.69 units per tick (about 8–9 km/h). The left demo peaks around
71 km/h versus 66 km/h at steady cruise; the larger release-to-peak rise also
includes recovering speed lost during the drift. The saved
image captures the left drift when ready. These are specific tested maneuvers,
not a guarantee of full-course original handling parity.

The reference script compiles unmodified original steering-stage functions,
yaw application, drift force and charge routines, plus original camera angle/offset logic, with identity matrix/audio
stubs. Zig tests compare steering traces, local forces and yaw gate outputs;
camera entry/recovery angle traces and wheel timing also have regression coverage.
This validates those routines independently of the race adapter. It does not
compare complete rendered gameplay against an N64/emulator recording.

The lap probe also checks that the projected kart stays in view throughout
all three laps with the new camera.

The lap test has a bounded runtime and fails if the controller gets stuck. It
is a test driver following the original racing path, not the game's opponent AI.
Render-only timings on the development machine are approximately 3 ms/frame;
they do not establish end-to-end frame rate or latency in a real terminal.

## Next porting work

1. Complete original lateral/suspension forces, slope/slip integration,
   airborne terrain collision and wall response, replacing the remaining
   grounded contact and force adapters.
2. Complete kart pitch-bank selection and camera collision/status effects; complete original Lakitu/start behavior and checkpoint/HUD fidelity.
   Validate against the original game.
3. Port original opponent AI/character stats, items and dynamic course objects, then expand to menus and
   other courses. Audio and save-state support remain separate work.

## Asset bundle investigation

See [MK64_ASSET_BUNDLE.md](MK64_ASSET_BUNDLE.md) for the measured minimal resource
inventory, experimental 303 KiB bundle and plan for a pure-Zig importer/loader.
That experiment is superseded by the shipped [Zig bundle format](MK64_ASSETS.md).
