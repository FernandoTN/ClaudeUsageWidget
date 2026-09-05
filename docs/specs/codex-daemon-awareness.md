# Codex daemon awareness

Stage 2 of the Codex-switch work (stage 1: `fix/codex-switch-repaint`, PR #153 —
fleet repaint on pointer change, fail-closed apply, repair grace window). This
stage makes the widget aware of the one Codex process a switch cannot reach.

**Status:** stage 1 merged as main `9bed05e` (#153, 2026-09-04 17:50); this stage
merged as `1bb44f4` (#154, 18:04). Both deployed by the orchestrating session; the
first sweep after the deploy resolved `CodexDaemon: Terminals: <profile> since
9:48 AM` from the newest `codex-tui` rollout.

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

At the end of every refresh sweep, off the main actor,
`CodexTerminals.newestDaemonEvidence(sessionsRoot:)` walks the newest rollout
files (two newest day directories, newest 30 files by mtime), skips every
rollout whose originator is not `codex-tui`, and takes the LAST
`rate_limits.primary.resets_at` in the newest daemon-written one, together
with that session's `session_meta` timestamp.
`CodexTerminals.profile(matching:in:)` resolves the stamp to the UNIQUE Codex
profile whose cached reset (weekly when `window_minutes` ≥ 6 days, else
session) equals it to the minute; no match or two matches → "unknown account".
Nothing is inferred beyond the stamp.

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
- Rollout reads are read-only, off the main actor, bounded (30 files), and
  never parse anything but the two line shapes above.
- No file watcher on `auth.json`; the daemon is never started by the widget.

## Tests (`CodexDaemonTests`)

Process-list parsing; the path-anchored predicate against the daemon, a bare
`codex exec`, the ChatGPT-embedded codex, a code-mode host under the standalone
path, a standalone `codex exec`, and another home; attached-session counting
(daemon children only); stamp → profile resolution (minute quantization,
Codex-only, ambiguity → nil); rollout line parsing (originator, session start,
stamp); line formatting; the setting's OFF default; an end-to-end scan of a
temporary sessions tree that skips a newer `codex_exec` rollout and reads the
last stamp of the newest `codex-tui` one.

## Follow-ups

- Restart the daemon only when its *own* login differs from the new owner
  (would need the daemon's account, which the terminals line approximates).
- A "Restart" affordance in the dashboard Codex section next to the terminals
  line (today: the notification action and Settings › Advanced).
