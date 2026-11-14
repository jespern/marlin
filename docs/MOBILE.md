# Mobile companion

Marlin starts its phone companion automatically with the daemon: a small web
app on `http://127.0.0.1:8377/` that shows every session, streams replies, and
answers approvals. On the machine itself it needs no login. To use it from a
phone, put an HTTPS reverse proxy in front of it, give it a name, and pair the
phone once.

```toml
[web]
enabled = true               # default
listen = "0.0.0.0"           # default 127.0.0.1; see below
hosts = ["marlin.example.com"]
proxy = "192.168.1.1"        # the reverse proxy; nothing else on the LAN may connect
push = true                  # default
```

- `listen` is the address the bridge binds. Loopback by default. Use
  `"0.0.0.0"` with `proxy` so the proxy can reach it while loopback keeps
  working; a single LAN address would stop loopback.
- `hosts` are the names the bridge answers to besides loopback. The first is
  the address the Web tab and the phone app advertise; add the proxy's port
  when it is not 443 (`"marlin.example.com:8443"`). Only the name is matched.
  A request under one of these names must come from a paired device.
- `proxy`, when set, is the only non-loopback address allowed to connect.
  It is the address the proxy connects *from*, which on a box with several
  addresses may not be the one you browse to: the Web tab logs
  `refused <addr>: not the [web] proxy` for anyone else, so check there.
  Its `X-Forwarded-For` names the real client in the access log, and
  `X-Forwarded-Proto: https` marks the device cookie `Secure`.

Restart the daemon after changing these (`/reboot` when its work can safely
finish). The old `tailscale = true` switch is gone and ignored if present.

## Trust model

- **Loopback is trusted**, as before: a loopback peer asking for `localhost`
  or `127.0.0.1` needs no login. A proxy on the same machine forwarding a
  phone's request does not count: that request names a public host.
- **Everything else must be paired.** Unpaired devices get only the app shell,
  `/connection`, and `/pair`; every API, event stream, and push route answers
  `403 unpaired`.
- **Pairing** trades a 6-digit code for a long-lived cookie. Codes come from
  the daemon, last five minutes, work once, and are burned after five wrong
  guesses. Each device gets a random 256-bit token; only its SHA-256 is
  stored, in `$XDG_STATE_HOME/marlin/web/pairing.json` (default
  `~/.local/state`, mode 0600). The cookie is `HttpOnly`, `SameSite=Lax`,
  lasts 400 days (Chrome's cap), and renews whenever the app opens.
- Host and Origin checks still reject DNS-rebinding and cross-site requests.
- This is a full-control companion for your own machine, not a multi-user
  service: a paired phone can do anything the terminal can, except shell
  sessions, which are never exposed over the web.

## Pairing a phone

1. In Marlin, open `/web` and press `p` (or run `/web pair`). The code appears
   beside the address with the time left.
2. On the phone, open `https://<host>/`. The app shows a code field; type the
   code. It submits on the sixth digit.
3. Add to Home Screen. If the Home Screen app ever asks for a code, pair again
   from inside it: iOS can keep its cookies apart from Safari's.

`/web` lists paired devices as `#n name date`. `/web unpair <n>` forgets one:
its next request is refused, and its open event streams close immediately.

A new address means a new web app origin: after moving hosts, add the app to
the Home Screen again and re-enable notifications.

## Example: OPNsense with Tailscale on the firewall

One name that works on the home Wi-Fi and away. The phone runs Tailscale only
when away; OPNsense is a Tailscale subnet router for the LAN, so the same LAN
addresses are reachable either way. The Mac itself runs no Tailscale.

1. **Marlin** (`~/.config/marlin/config.toml` on the Mac):

   ```toml
   [web]
   listen = "0.0.0.0"
   hosts = ["marlin.example.com"]
   proxy = "<OPNsense LAN IP>"
   ```

   Give the Mac a static DHCP lease so its address does not move.

2. **Certificate and proxy: Caddy on OPNsense.** Install `os-caddy`
   (System → Firmware → Plugins). Under Services → Caddy Web Server:
   - General: enable; set the ACME email; DNS Provider: Cloudflare, with an
     API token limited to *Zone → DNS → Edit* on that one zone. DNS-01
     validation needs no inbound port, so nothing is exposed to the internet.
   - Reverse Proxy → Domains: `marlin.example.com`, port 443, with the DNS-01
     challenge enabled.
   - Handlers: for that domain, upstream `<Mac LAN IP>`, port `8377`.
     Caddy passes the original Host and sets `X-Forwarded-For` and
     `X-Forwarded-Proto`; event streams (SSE) flush without buffering.
   - The OPNsense web GUI usually holds 443 (and 80). Rather than move it,
     give Caddy other ports in its General settings (HTTPS 8443, HTTP 8080:
     DNS-01 needs neither 80 nor 443) and put the port in Marlin's `hosts`:
     `hosts = ["marlin.example.com:8443"]`. The phone URL becomes
     `https://marlin.example.com:8443/`.

3. **DNS on the LAN.** Services → Unbound DNS → Overrides: host `marlin`,
   domain `example.com`, IP `<OPNsense LAN IP>` (where Caddy listens).
   Rebind protection only filters upstream answers, never these overrides.

4. **DNS away from home.** In the Tailscale admin console → DNS, add a
   split-DNS nameserver `<OPNsense LAN IP>` restricted to `example.com`. The
   phone then asks OPNsense through the subnet route and gets the same LAN
   answer. (Alternatively, publish the private address as a public A record
   in Cloudflare, unproxied: no split DNS, but the LAN address is public.)

5. **Firewall.** Allow the LAN and the Tailscale interface to reach the
   OPNsense LAN address on Caddy's HTTPS port. With `proxy` set, the Mac's port 8377 refuses
   everyone but OPNsense anyway.

Check from the Mac: `curl -s https://marlin.example.com[:port]/connection` answers
`{"host":"marlin.example.com[:port]","push_enabled":true,"paired":false}`, and the
Web tab log shows each request with the client's real address.

## Phone notifications

Push requires the Home Screen app (iOS 16.4 or later) over HTTPS. The embedded
helper uses no hosted relay and no Apple developer account. `/web` and
`marlin web` inspect the attached daemon's companion.

Open the Home Screen app, open its session drawer, and tap **Enable
notifications**. Permission is requested from this tap; it cannot be granted
from the laptop. **Disable notifications** revokes the server subscription and
unsubscribes the browser. Browser permission can separately be changed in
iPhone Settings.

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
network must permit these services. Sending a push does not depend on the
proxy or the phone's network; opening Marlin does.

## Layout and reconnect behavior

The app fits the visual viewport's height and vertical offset on phones, keeps
scrolling inside the transcript, and removes the bottom safe-area inset while
the keyboard is open. The composer is below the status strip. Resizing preserves
reading position unless the transcript was already at the bottom. The drawer
shows the canonical address; the mobile header reports connecting, offline,
and reconnecting states. Returning to the app opens a fresh SSE stream and
replays session history with the existing sequence deduplication.

## Verification

Run `zig build test` and `zig build e2e`. For the browser check, install
Playwright separately (`npm install playwright-core` in a scratch directory)
and run `node scripts/test-mobile-browser.cjs` from the repository root, with
`MARLIN_PLAYWRIGHT_MODULE` pointing to its `playwright-core` module and
`MARLIN_CHROMIUM_PATH` to a Chromium/Chrome executable if needed. It drives an
isolated real daemon and web bridge: layout and reconnect; pairing over raw
HTTP (unpaired refusals, wrong and single-use codes, cookie flags, renewal);
pairing through the real code screen under a public name; and unpairing,
including the revoked device's open stream closing. Push tests use a receiving
crypto peer and real helper subprocesses with isolated persistent state. A
real iPhone is still required to validate OS permission, APNs delivery, and
keyboard animation behavior end to end.

## Web tab

The Web tab pins the service state, the advertised address with any live
pairing code, and the keys (`p` pairs a phone) above the paired devices and the
latest 128 log entries. Arrow keys or the mouse wheel scroll; `r` refreshes,
and Escape returns to the session with its draft intact. Status refreshes once
per second while the tab is open. HTTP access entries carry the client
address, a timestamp, the method, and the route; never prompt bodies, cookies,
or push subscription keys.

`marlin web` prints the managed companion's status and paired-device count and
exits. Configure `[web] port = 8377` to change the listener port (1–65535). A
bind/startup failure (including an invalid `listen` or `proxy` address)
appears in the log and leaves the daemon usable; resolve the error and restart
Marlin to retry. The child process boundary isolates HTTP failures from the
daemon and is fully managed by it. A separate login service is not installed.
