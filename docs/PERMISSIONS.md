# Permissions and secret boundary

Status: **active M3.5 plan**. This work precedes M4. Workspace snapshots,
drift detection, undo, and write leases remain deferred to M4.5; permissions
must not quietly depend on them.

Current progress:

- **Landed in the working tree:** the central tool-subprocess environment
  builder strips provider credentials and configured secret-name patterns;
  both `bash` and ripgrep-backed search use it. Unit and end-to-end tests prove
  the boundary without changing the existing approval transcript.
- **Landed in the working tree:** typed capability names plus lexical path
  assessment for exact-workspace, outside-workspace, and protected targets.
  This is preview/policy input only; symlink-safe enforcement remains at the
  future I/O integration boundary.
- **Landed in the working tree:** the runtime-verified macOS Seatbelt
  adapter. The canary proves four legs on the running OS before the backend
  is claimed: workspace write allowed, sibling write denied, protected-
  directory read denied, protected-file read denied. All profile parameters
  are symlink-resolved first — Seatbelt `subpath` filters match real paths,
  and TMPDIR/workspace spellings routinely sit behind the `/tmp` and `/var`
  symlinks (an unresolved parameter silently never matches).
- **Landed in the working tree:** the auto-inside policy for shell. A bash
  call that will execute under the verified Seatbelt backend runs without a
  per-call prompt; an explicit deny policy still wins, and a session that
  never verified a backend keeps legacy ask behavior. Scope is deliberately
  shell-only: direct write/edit tools bypass the kernel sandbox, so they
  keep asking until symlink-safe direct-tool enforcement lands.
- **Next:** rich once/session escalation grants and symlink-safe direct-tool
  enforcement behind the default-off capability flag.

## Product contract

Marlin approves capabilities, not command prefixes. Every tool call continues
through the existing daemon approval gate, but the request describes the
operation and scope being granted. A grant is either for one operation or the
current session; there are no durable global grants in M3.5.

The initial capability vocabulary is deliberately small:

| Capability | Default | Example scope |
|---|---|---|
| `fs.read` | allow | workspace or ordinary external path |
| `fs.read_protected` | deny, explicit escalation | protected path outside the workspace |
| `fs.write_workspace` | allow when sandbox verified | canonical session cwd |
| `fs.write_outside` | ask | one external root |
| `process.exec` | allow when sandbox verified | one sandboxed shell call |
| `network.fetch` | allow for the built-in GET tool | one URL/host |
| `env.secret` | deny | one named environment variable |

`--yolo` may bypass approval prompts, but it must not bypass protected-path,
secret-environment, or sandbox boundaries. Those require an explicit
capability escalation even in a yolo session.

Capability permissions are enabled by default (`MARLIN_PERMISSIONS=0` opts
out until TOML config lands). Default-on is safe ahead of the full exit
matrix because every enforcement-affecting surface is canary-gated and fails
closed: on a platform whose sandbox did not prove itself at daemon startup,
behavior is byte-identical to legacy ask (the e2e suite pins this). The
outstanding exit items — rich escalation grants and symlink-safe direct-tool
enforcement — are UX and direct-tool gaps that the flag neither fixes nor
worsens; direct tools keep their legacy policy either way.
Secret-environment isolation is a daemon boundary and remains active
independently of this flag.

`/sandbox on|off` toggles the shell sandbox per session; the config flag only
seeds each session's default. Off means prompts return AND approved shell
calls run unwrapped — the two travel together so "off" is never silent yolo.
The toggle is client-initiated only (the model has no path to it), is
rejected mid-turn, refuses to enable without a verified backend, and is
in-memory like the session approval mode: a daemon restart returns the
session to the configured default. The daemon probes the sandbox at every
startup regardless of the flag so a later toggle-on needs no re-probe; the
TUI shows the effective state (sandboxed / sandbox off / no sandbox) at the
far right of the status line, alongside the DNS-blocklist indicator.

The exact canonical launch directory is the authority boundary. With a verified
platform sandbox, file operations and shell commands inside it run without
per-call approval. This includes destructive operations and repo-local secrets:
without M4.5 snapshots, `rm -rf` inside the workspace is allowed and is not
Marlin-undoable. Snapshotting later adds recovery; it is not what grants write
authority.

If sandbox verification fails or the platform has no adapter, shell calls keep
the legacy ask behavior. Marlin never claims sandboxed yolo based solely on
path classification in userspace.

## Secret boundary

The daemon owns provider credentials. Tool subprocesses do not inherit known
credential variables or variables matching the configured secret-name policy.
The built-in baseline strips provider keys plus `*_API_KEY`, `*_TOKEN`,
`*_SECRET`, and `AWS_*`; ordinary process context such as `PATH`, `HOME`, and
locale remains available.

Tool output is redacted before it becomes an immutable block. First ship exact
known-value redaction for credentials loaded by the daemon; add conservative,
configurable secret-shape detection separately so false positives are visible
and reversible before persistence.

Protected paths are enforced in the tool/sandbox layer, never only described
in the system prompt. Outside the selected workspace, the starter policy covers
Marlin's credentials file, `.env*`, private-key material, SSH/AWS credentials,
and browser credential stores. Inside the workspace, the user's directory
selection is authoritative—including repo-local `.env` and key files. Direct
file tools return a typed refusal for protected external paths. Symlink
resolution is part of enforcement.

The platform sandbox enforces the subset of this policy expressible as path
roots: sandboxed shells cannot read `~/.ssh`, `~/.aws`, `~/.gnupg`, or the
Marlin credentials file (kernel-denied via symlink-resolved profile
parameters, verified by the startup canary). Basename-shaped rules (`.env*`,
`*.pem`, key files at arbitrary locations) are not kernel-denied to shells;
they remain direct-tool enforcement plus a candidate for later hardening. A
workspace selected inside a protected root cannot receive both its write
grant and the read denial; sandboxed execution refuses it with a typed error
rather than running half-enforced.

## Approval and grant behavior

An approval request carries:

- capability and human-readable action;
- concrete scope (path/root/host where applicable);
- why the call crossed the current policy;
- original tool and arguments for inspection;
- allowed decisions: deny, allow once, or allow for this session.

Session grants live in daemon session state and are reconstructable from
durable approval blocks after `/reboot --build`. A broader request never
silently reuses a narrower grant. Interrupt, kill, and shutdown deny a pending
request exactly as they do today.

Command-prefix allowlists are intentionally excluded. `git status` and
`git push --force` sharing a prefix is evidence that strings are the wrong
security boundary.

## Shell sandbox contract

The baseline shell sandbox permits ordinary reads, writes within the canonical
session cwd and a Marlin-owned temporary location, process execution, and
network access. It denies writes outside the workspace and reads of the
protected credential roots. Network isolation is a later hardening decision;
M3.5 must state clearly that allowed shell commands can still exfiltrate
workspace data.

Use Seatbelt on macOS and Landlock on Linux, with seccomp added only for a
specific syscall threat model. `sandbox-exec` and its SBPL language are
deprecated/private interfaces, so the macOS adapter must self-test at runtime:
prove that an inside write succeeds, a sibling write fails, and protected
reads fail before enabling automatic shell execution. Two SBPL facts the
canary pins down because no public documentation guarantees them: `subpath`
parameters match only fully symlink-resolved paths, and rule conflicts
resolve last-match-wins (the protected-read denial must follow the broad
read allow). Repeat this in CI against supported macOS releases (the canary
runs as a macOS-gated unit test). If a platform sandbox is unavailable or its
probe fails, never claim enforcement and never promote shell calls to
automatic execution; retain the legacy per-call approval fallback.

A sandbox denial is data, not a crash. The tool result identifies the blocked
capability and scope so the model can re-plan or request escalation. A granted
escalation reruns the call with only that capability added.

## Network blocklists

Networking remains allow-by-default. Marlin-owned network tools may subscribe
to optional hostname blocklists as defense in depth; this is not presented as
an exfiltration boundary. Raw subprocess sockets, direct IP connections,
custom DNS, and DNS-over-HTTPS remain outside managed-tool coverage until a
proxy or platform network filter exists. Marlin does not infer networking by
regex-scanning shell command text.

The primary configuration is:

```toml
[network]
blocklists = "hagezi-tif-mini"
allow = "false-positive.example"
deny = "local-deny.example"
```

Each value accepts a comma-separated set. `MARLIN_NETWORK_BLOCKLISTS`,
`MARLIN_NETWORK_ALLOW`, and `MARLIN_NETWORK_DENY` are final environment
overrides for temporary or automated runs.

Precedence is explicit deny, explicit allow, subscribed blocklist, then the
default allow. Rules apply to a domain and its subdomains. Every redirect from
the built-in `fetch` tool is checked before Marlin connects to the next host;
a blocked result names the matching rule and list.

The starter catalog contains the security-only HaGeZi Threat Intelligence
Feeds mini list (GPL-3.0; malware, phishing, scams, spam, cryptojacking, and
command-and-control domains). It is opt-in, refreshed at most every 12 hours
on daemon startup, cached under the user's cache directory, and falls back to
the last-known-good copy. If no copy is available, refresh failure is visible
in daemon logs and networking fails open. Marlin intentionally does not ship
ad/tracker lists in the security preset.

## Implementation slices

1. **Secret environment:** central subprocess environment builder, known-name
   scrubbing, and tests proving provider keys cannot reach `bash` or helper
   subprocesses.
2. **Capability contract:** typed capability/scope/risk structures, path
   canonicalization, protected-path policy, and policy unit tests.
3. **Rich approvals:** protocol and block schema for capability requests,
   allow-once/session decisions, in-memory grants, reboot reconstruction, and
   TUI cards.
4. **Direct-tool enforcement:** read/write/edit/grep/glob/fetch classification,
   symlink-safe protected paths, and outside-write escalation.
5. **Shell sandbox:** macOS and Linux adapters, structured denial reporting,
   narrow rerun after escalation, and unavailable-platform fallback.
6. **Capture redaction:** exact known-value scrub before blob/block persistence,
   followed by optional secret-shape rules.
7. **Rollout:** adversarial fixtures, flag-off/legacy equivalence, opt-in daily
   use, then decide which capability defaults can replace per-tool prompts.

## Exit criterion

`bash -c env` cannot reveal provider credentials; protected files cannot be
read through direct paths or symlinks without explicit escalation; an outside
write is blocked by the kernel sandbox; approval cards identify the exact
capability and scope; allow-once and allow-session survive the expected
lifecycle; and disabling capability mode reproduces the existing approval
transcript.
