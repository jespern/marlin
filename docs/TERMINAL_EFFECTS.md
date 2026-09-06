# Terminal effects

Optional animations and screensavers for the Marlin TUI. Automatic activation
is off by default. These effects run in the client.

Terminal-native effects share one finite-animation/full-screen-saver surface.
  Cell effects paint the grid: `matrix` rain, `strings` dancing sine curves, a
  forward `stars` field, and color-cycling `plasma`. Pixel effects render a
  framebuffer over the Kitty graphics protocol (Kitty, Ghostty, WezTerm):
  `tetris`, a full-screen neon arcade cabinet with beveled blocks, a ghost
  landing, next-piece preview, score, lines, and level around a bot whose pieces
  spawn centered and unrotated, then visibly follow reachable rotate, shift, and
  descent routes—including late slides beneath overhangs; `pacman`, a self-playing take on feiss' 1024-byte js1k entry on a maze
  generated to fit your window with the arcade's rules (mirrored, no dead
  ends, a ghost house in the middle, wrap-around tunnels, four energizers
  that turn the ghosts blue and edible, bonus fruit, arcade scoring under a
  "1UP" / "HIGH SCORE" header, three lives, "READY!" and "GAME OVER"; a new
  maze every board), a spinning `tunnel`, `metaballs`, a synthwave `horizon`, `demo`, a
  24-second sequence of those three, and `shadowbox`, a paper-cutout
  landscape after Jani Ylikangas' js1k entry that follows the real sun over
  your machine: it locates you from your time zone and computes the sun's
  true altitude and azimuth, so days run long in summer and short in
  winter, sunrise lands where and when it should, and a Nordic midsummer
  night keeps its twilight. `/screensaver shadowbox cycle` runs today's
  whole day every two minutes and `/screensaver shadowbox 18.5` pins an
  hour (`MARLIN_SHADOWBOX_HOUR` does the same from the environment);
  `MARLIN_SHADOWBOX_LATLON=lat,lon` overrides the place. Without graphics,
  Tetris and Pac-Man draw cell fallbacks and the other pixel effects start as a
  cell sibling; either way the
  status line says so. Run `/animate <effect>` over gaps in the current UI
  (opaque for the pixel kinds), or `/screensaver [effect]` for the
  continuous form. Tetris is deliberately manual-only: start it with
  `/screensaver tetris` (or `/animate tetris`); it cannot be selected for idle
  activation. Normal-mode `gs` starts the configured effect and returns to
  insert mode on wake. A key or paste wakes it and is consumed; mouse activity
  is ignored. Automatic activation is off by default; `/config screensaver 10m
  strings` enables it, `/config screensaver tunnel` changes only the effect,
  and `off` disables it. The equivalent TOML keys are `[ui] screensaver_after`
  and `screensaver_effect`.

Return to the [README](../README.md).
