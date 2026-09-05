# Codex daemon awareness

Stage 2 of the Codex-switch work (stage 1: `fix/codex-switch-repaint`, PR #153 —
fleet repaint on pointer change, fail-closed apply, repair grace window). This
stage makes the widget aware of the one Codex process a switch cannot reach.

**Status:** stage 1 merged as main `9bed05e` (#153, 2026-09-04 17:50); this stage
merged as `1bb44f4` (#154, 18:04). Both deployed by the orchestrating session; the
first sweep after the deploy resolved `CodexDaemon: Terminals: <profile> since
9:48 AM` from the newest `codex-tui` rollout. **2026-09-05:** the rollout scan
was found reading 55 MB per sweep (10.4 % of a core, measured 09:50 on pid
73406) and was bounded to head + tail reads with a per-file cache and a 120 s
cadence (#160, merged `a70b5a0`, deployed 10:20:20 as pid 91164: cold scan
68 KB from 1 file, CPU 1.5 % of a core; see "Bounded reads" below).

## Verified facts (this Mac, 2026-09-04)

- The Codex standalone build (0.153.3) is installed at
  `~/.codex/packages/standalone/current/bin/codex` (symlinked from
  `~/.local/bin/codex`, ahead of Homebrew on PATH; releases under
  `~/.codex/packages/standalone/releases/<version>/bin/`).
- Interactive `codex` (the TUI) attaches to a detached shared daemon,
  `…/packages/standalone/current/codex app-server --listen unix://…`, whose
  parent is launchd. Its control socket is
  `~/.codex/app-server-control/app-server-control.sock`, with
  `app-server-startup.lock` beside it. The socket exists only while the daemon
  runs (at 17:04 only the lock was present and no daemon process existed).
- The daemon loads `~/.codex/auth.json` ONCE at launch and never reloads: its
  rate-limit series ran unbroken across a rewrite. `codex exec` runs in-process
  and reads the file fresh. The ChatGPT desktop app also rewrites the file.
- Consequence: a widget Codex switch reaches headless runs and the desktop app
  but NOT terminals until the daemon restarts. It respawns on the next `codex`
  launch.
- Rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) start with a
  `session_meta` line whose `payload.originator` is `codex-tui` for
  daemon-hosted sessions and `codex_exec` for headless runs (23 vs 17 of the 40
  newest on 2026-09-04). Their `token_count` events carry
  `payload.rate_limits.primary.resets_at` (epoch seconds) and
  `primary.window_minutes` (10080 = the 7-day window on this plan). That stamp
  equals `wham/usage rate_limit.primary_window.reset_at` for the same account,
  which the widget already parses per profile (`weeklyResetTime`, or
  `sessionResetTime` for a 5-hour primary).
- `codex-code-mode-host` is a child of whichever process HOSTS a session: the
  daemon for TUI sessions, the `codex exec` process for headless runs.

## Design

Everything lives in `CodexDaemonService.swift`; the pure parts are `enum`s so
the tests need no process, socket or file.

### Detection — path-anchored, never by name

`CodexDaemon.isDaemonCommand(_:codexHome:)` matches a process only when its
executable path starts with `<codexHome>/packages/standalone/`, its executable
is named `codex`, and its first argument is `app-server`. The bare name `codex`
is never matched: it would hit the user's TUIs, the ChatGPT desktop app's
embedded codex, and every `codex exec` run. `codexHome` is
`CodexUsageService.defaultCodexHome` (`$CODEX_HOME` or `~/.codex`, audit M11).

The process list comes from `/bin/ps -axo pid=,ppid=,command=` run off the main
actor (`CodexDaemonService.listProcesses`); `CodexDaemon.parseProcessList`
parses it. The control socket's presence is recorded as corroboration; the
process match is authoritative.

### Attached sessions

`CodexDaemon.attachedSessionCount(daemonPid:in:)` counts children of the daemon
whose executable is `codex-code-mode-host`. A code-mode host under a `codex
exec` process is not an attached terminal and is not counted.

### After a successful Codex switch (deliverable a + b)

`CodexDaemonService` observes `.providerOwnerClaimed` with `provider == codex`
and `cause == activate` — the one signal every activation path emits (the ⇄
menu, the dashboard, the inspector, the auto-switch), so no activation seam is
edited. It then scans once:

- No daemon → one log line; terminals pick up the new login on the next `codex`
  launch.
- Daemon present and **Restart Codex daemon on switch** is ON and no session is
  attached → SIGTERM the ONE matched pid (re-scanned immediately before the
  signal, so a recycled pid is never hit), log, and notify "Codex daemon
  restarted — new codex terminals use '<profile>'".
- Otherwise → notify "Codex terminals still on the previous login" with a
  **Restart Codex daemon** action button (`UNNotificationCategory`
  `CODEX_DAEMON`, action `RESTART_CODEX_DAEMON`, handled in
  `AppDelegate.userNotificationCenter(_:didReceive:)`). The body names the new
  profile and the number of attached sessions.

The setting is `SharedDataStore.loadCodexDaemonRestartOnSwitch()` (key
`codexDaemonRestartOnSwitch_v1`, journaled single-shot write, registered in
`SettingsKeyRegistry`, default OFF). Settings › Advanced gains a "Codex daemon"
card: the toggle, a live status line (pid + attached sessions, or "not
running"), and a manual **Restart Codex daemon** button.

### Terminals line (deliverable c)

At the end of a refresh sweep, off the main actor,
`CodexTerminals.newestDaemonEvidence(sessionsRoot:)` walks the newest rollout
files (two newest day directories, newest 30 files by mtime), skips every
rollout whose originator is not `codex-tui`, and takes the LAST
`rate_limits.primary.resets_at` in the newest daemon-written one, together
with that session's `session_meta` timestamp.
`CodexTerminals.profile(matching:in:)` resolves the stamp to the UNIQUE Codex
profile whose cached reset (weekly when `window_minutes` ≥ 6 days, else
session) equals it to the minute; no match or two matches → "unknown account".
Nothing is inferred beyond the stamp.

**Bounded reads (2026-09-05 regression fix).** The first release read each of
the 30 files whole on every 30 s sweep — 55 MB per sweep on this Mac (largest
rollout 6 MB), which cost the app 10.4 % of a core and tripped the
`StormWatchdog` 270 times overnight. A rollout is needed for exactly two
lines, so the scan now reads with seeks and never the middle:

- **Head:** the first 4 KB (`ReadBudget.headInitial`). A first line closed by a
  newline is parsed as JSON; a line cut short — real ones are ~22 KB because
  the session's instructions ride in the `session_meta` payload — is searched
  for the closed `"type"`, `"originator"` and `"timestamp"` fields, which sit
  in its first few hundred bytes. Only when neither settles it does the read
  grow to 64 KB (`headMax`).
- **Tail:** the last 64 KB (`tailInitial`), walked backwards for the last
  `"rate_limits"` line that parses; if none does, ONE growth reads the 192 KB
  in front of it (`tailMax` = 256 KB) and the walk repeats. A stamp deeper
  than that is not chased: the file reads as stampless and the next newest
  terminal rollout wins. Measured 2026-09-05, the last stamp sat ≤ 14 KB from
  the end in all 30 newest files.
- **Cache (`RolloutScanCache`):** per path, the head verdict is learned once
  (an append-only file's first line never changes), so a `codex_exec` rollout
  costs its head once and is never opened again however much it grows; the
  stamp is tied to the (size, mtime) pair it was read at, so an unchanged
  terminal rollout costs one stat and a grown one costs its tail. Entries for
  files that leave the newest-30 set are pruned each scan. A head caught
  mid-creation (no newline, fields not closed) is not cached and is re-read
  next scan.
- **Cadence:** `CodexDaemonService.refreshTerminalsState` re-scans the tree at
  most every 120 s (`rolloutScanInterval`; `force:` scans now) and re-matches
  the cached evidence against the current profiles on every call, since their
  cached resets move with every usage fetch. The cold scan logs the bytes it
  read at default level; later scans log at debug.

Worst case per file is `ReadBudget.perFileMax` = 320 KB; steady state is
30 stats and a few KB.

Shown as `Terminals: <profile> since HH:MM` (the daemon has served that
account at least since that session began), `Terminals: unknown account since
HH:MM`, or `Terminals: unknown` — under the Codex section caption in the
dashboard and as a "Terminals" fact in the inspector Overview of Codex
profiles.

### Safety rules

- Never match a process by the bare name `codex`.
- Never signal anything but the single path-anchored daemon process, and only
  after a fresh scan.
- Auto-restart is opt-in (default OFF) and only fires with zero attached
  sessions; the notification action is the user's explicit click.
- Rollout reads are read-only, off the main actor, bounded (30 files, ≤ 320 KB
  per file — head and tail only, never the whole file), and never parse
  anything but the two line shapes above.
- No file watcher on `auth.json`; the daemon is never started by the widget.

## Tests (`CodexDaemonTests`)

Process-list parsing; the path-anchored predicate against the daemon, a bare
`codex exec`, the ChatGPT-embedded codex, a code-mode host under the standalone
path, a standalone `codex exec`, and another home; attached-session counting
(daemon children only); stamp → profile resolution (minute quantization,
Codex-only, ambiguity → nil); rollout line parsing (originator, session start,
stamp); line formatting; the setting's OFF default; an end-to-end scan of a
temporary sessions tree that skips a newer `codex_exec` rollout and reads the
last stamp of the newest `codex-tui` one. Bounded reads: a > 1 MB fixture
rollout is resolved from ≤ 68 KB (one head chunk + one tail chunk), an
unchanged file costs zero bytes on the next scan, an appended stamp re-reads
only the tail; a stamp beyond 64 KB from the end grows the tail once within
the 320 KB budget and one beyond 256 KB is not chased; a ~30 KB first line is
settled from the 4 KB head chunk and a `codex_exec` rollout is never reopened
after its head verdict.

## Follow-ups

- Restart the daemon only when its *own* login differs from the new owner
  (would need the daemon's account, which the terminals line approximates).
- A "Restart" affordance in the dashboard Codex section next to the terminals
  line (today: the notification action and Settings › Advanced).
