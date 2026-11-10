# Development builds

Building Marlin needs Zig 0.17.

## SQLite and local builds

SQLite remains Marlin's canonical store: WAL, indexed session/block queries,
migrations, hierarchy, and content-addressed blobs would otherwise become a
home-grown database layer around JSONL. Searchable rendered text is projected
into a compact side table; FTS5 powers transcript search when available, with a
bounded scan fallback for system SQLite builds that omit it. Raw blobs and
binary attachments are never indexed.

For fast local iteration, `zig build` and `zig build test` link the system
SQLite library. Official release builds compile the vendored amalgamation into
the binary. To reproduce that configuration locally:

```sh
zig build -Doptimize=safe -Dembedded-sqlite=true
```

To temporarily replace the Marlin selected by your current `PATH` with this
checkout's `-Doptimize=fast` build:

```sh
make install
marlin reboot       # activate it in an already-running daemon
```

The install is sanity-checked and atomically replaces the resolved executable.
That means an install.sh binary in `~/.local/bin` is replaced directly; a
Homebrew entry keeps its public symlink and replaces the currently linked keg
binary. Homebrew may overwrite that development build during a later upgrade or
reinstall. If Homebrew's public path holds a regular file instead of its
symlink (an old clobbered install), the installer refuses and prints the
`rm … && brew link marlin` that repairs it. For a development build that survives Homebrew upgrades, use an
explicit `~/.local/bin` target and keep that directory before Homebrew in
`PATH`. To choose an explicit destination instead of the active `PATH` entry:

```sh
make install MARLIN_INSTALL_TARGET="$HOME/.local/bin/marlin"
```

The script refuses to overwrite an existing executable that does not identify
itself as Marlin. `make install` only activates the new client executable; a
running daemon keeps its old executable until `marlin reboot` succeeds. If a
turn or approval prevents a normal reboot, resolve it first rather than forcing
an install-time shutdown.

Run `make test-install` to exercise the developer installer without touching
your real installation.
