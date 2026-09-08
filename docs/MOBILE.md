# Mobile companion

Marlin starts its phone companion automatically with the daemon. Opt in persistently
in `~/.config/marlin/config.toml`:

```toml
[web]
enabled = true
tailscale = true
push = true
```

All three switches default to false. `enabled` starts a daemon-owned companion
process; no separate terminal or `marlin web` command is needed. It stays up
when you detach a TUI, and stops when the daemon shuts down or reboots. `tailscale` runs `tailscale serve --bg` each
time the web bridge starts. On macOS, Marlin also finds the CLI bundled in
`/Applications/Tailscale.app` and forces CLI mode. Install and sign in to Tailscale on both devices,
and enable HTTPS/Serve in the tailnet. The bridge still binds only loopback;
Host and Origin checks remain in place. This is a full-control companion for
your own machine and tailnet, not a public or multi-user service.

Open the **Web** tab (or type `/web`) for the HTTPS hostname and live access log,
then use Safari's **Add to Home Screen**. Use this hostname instead of a LAN or
Tailscale IP. It survives IP changes; it does not keep the laptop online.
The web process and Tailscale must be running to open the app, and the daemon
must be awake and online to send notifications. After changing configuration,
restart/reboot the daemon when its current work can safely finish. No launch-at-login service is installed by these switches.

## Phone notifications

Push requires Node.js 22 or later on the daemon/web host's PATH. The embedded
helper uses only Node built-ins; no npm dependencies, hosted relay, public
listener, or Apple developer account is needed. This first implementation
runs beside the daemon, including on remote hosts. `/web` and `marlin web`
inspect the attached daemon’s companion; use that host’s Tailscale URL.

On iOS 16.4 or later, open the Home Screen app, open its session drawer, and tap
**Enable notifications**. Permission is requested from this tap; it cannot be
granted from the laptop. **Disable notifications** revokes the server
subscription and unsubscribes the browser. Browser permission can separately
be changed in iPhone Settings.

The policy is daemon-owned:

- Completion and failure produce one event per finished turn; automatic
  continuations and user-interrupted turns are excluded.
- Approval requests say “Marlin needs you,” including Claude Code approvals.
- Any focused Marlin terminal with interaction in the last two minutes
  suppresses phone pushes. Focus-in counts as interaction; quiet reading
  beyond two minutes counts as inactivity.
- Clients renew 30-second leases every 10 seconds. Unfocus/disconnect releases
  terminal presence; a suspended or crashed client cannot suppress forever.
- Viewing the session in the connected phone app suppresses its notifications.
  Leaving that session or hiding the app releases its presence.
- Suppressed events are discarded, not delivered later. Questions use ordinary
  completion notifications; there is no punctuation-based question detector.

Notifications carry only a generic status and session id; tapping opens that
session. All received pushes display a notification as required by Safari.
Subscription endpoints and VAPID private keys live under
`$XDG_STATE_HOME/marlin/push` (default `~/.local/state/marlin/push`) with private
file permissions. Preserve this directory across upgrades. Losing its VAPID
key requires disabling/re-enabling phone notifications. Push subscriptions are
limited to 32; delivery is bounded, expires after five minutes at the push
service, and removes subscriptions rejected with HTTP 404/410. Transient
failures are logged, not retried indefinitely. Delivery in flight can race with
refocusing the terminal, as with any network notification.

Push delivery uses the browser vendor's HTTPS endpoint (Apple, Google, Mozilla,
or Microsoft); redirects and other destinations are rejected. The desktop's
network must permit these services. Sending a push does not require the phone
to be on the tailnet, but opening Marlin does.

## Layout and reconnect behavior

The app fits the visual viewport's height and vertical offset on phones, keeps
scrolling inside the transcript, and removes the bottom safe-area inset while
the keyboard is open. The composer is below the status strip. Resizing preserves
reading position unless the transcript was already at the bottom. The drawer
shows the canonical address; the mobile header reports connecting, offline,
and reconnecting states. Returning to the app opens a fresh SSE stream and
replays session history with the existing sequence deduplication.

## Verification

Run `zig build test`, `zig build e2e`, and `zig build mobile-test` (the last
requires Node). Push tests use a receiving crypto peer and real helper
subprocesses with isolated persistent state. For a browser check, install
Playwright separately and run `node scripts/test-mobile-browser.cjs` with
`MARLIN_PLAYWRIGHT_MODULE` pointing to its `playwright-core` module if needed,
and `MARLIN_CHROMIUM_PATH` pointing to a Chromium/Chrome executable.
The browser test uses an isolated real Marlin daemon/web bridge. A real iPhone
is still required to validate OS permission, APNs delivery, and keyboard
animation behavior end to end.

## Web tab

The Web tab keeps the service state and canonical address above the latest 128
log entries. Arrow keys or the mouse wheel scroll; `r` refreshes, and Escape
returns to the session with its draft intact. Status refreshes once per second
while the tab is open. HTTP access entries include a timestamp, method, and
route, never query strings, prompt bodies, or push subscription keys.

`marlin web` now prints the managed companion’s status and exits. Configure
`[web] port = 8377` to change the listener port (1–65535); the old `--port`
argument is rejected. A bind/startup failure appears in the log and leaves
the daemon usable; resolve the error and restart Marlin to retry. The child
process boundary isolates HTTP failures from the daemon and is fully managed
by it. A separate login service is not installed.
