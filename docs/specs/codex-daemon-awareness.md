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
**2026-09-08:** the restart never fired when it mattered (incident below); the
restart guard was rewritten — exhausted outgoing login ⇒ restart regardless of
attached sessions, only interactive and non-stale hosts count, default ON,
verified exit with one SIGKILL escalation, a ten-minute reminder and a
dashboard Restart affordance (`fix/codex-daemon-restart-guard`, #167, **merged**
`fe9f36d` (squash), deployed 2026-09-08 13:11:25 as pid 94842 by the
orchestrating session; suites 643 / 0 before and after the merge, Release
green; see "Restart on switch").

## The 2026-09-08 incident (12:34, main `e896e09`, deployed `c22d614`, pid 85212)

- 12:34:16 `AutoSwitch: Switching from 'xFenrir(dev)' to 'xFho(…)'` — xFenrir's
  weekly window at 100 % — and `✓ Applied Codex credentials … (auth.json read
  back as the target account)`.
- 12:34:17 `CodexDaemon: the Codex daemon (pid 55232) still holds the previous
  login after the switch to 'xFho' — 1 attached session(s)` plus the
  `CODEX_DAEMON` notification. The daemon had been running since 20:08 the
  previous evening. Its children: ONE stale `codex-code-mode-host` started
  21:09 the night before, and some thirty `Codex Computer Use.app` / `cua_node`
  helpers the ChatGPT desktop app spawns continuously.
- The owner opened new terminals; every one attached to the daemon, inherited
  the exhausted xFenrir login and reported the rate limit. The notification
  went unanswered. The orchestrating session killed the daemon by hand and set
  `codexDaemonRestartOnSwitch_v1 = true`.
- With the toggle ON the old code would STILL not have restarted: the guard
  required zero attached sessions, and on this Mac a stale host plus the
  desktop app's helpers are always attached.

Three rules were wrong at once: the guard counted a session nobody was using;
it protected sessions that were already broken (they 429 on the exhausted
login, so a restart costs them nothing); and the one thing that could have
helped — the restart — was opt-in and off.

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

`CodexDaemon.attachedSessions(daemonPid:in:staleAfter:terminalsActive:)` lists
the daemon's children whose executable is `codex-code-mode-host` — and ONLY
those. A code-mode host under a `codex exec` process is a headless run, not a
terminal. The ChatGPT desktop app parks its own helpers under the daemon too
(`Codex Computer Use.app`, `cua_node`; ~30 of them on 2026-09-08) — none is a
terminal, none counts, and their paths contain spaces (the executable is the
first token, which never matches the host's name).

The process list carries `ps` `etime` now (`pid=,ppid=,etime=,command=`;
`CodexDaemon.parseElapsed` reads `[[dd-]hh:]mm:ss`), which ages every host. A
host is **stale** when it is older than `staleSessionAge` (12 h) AND no
daemon-written rollout has been modified within `terminalActivityWindow`
(30 min; `terminalsActive(newestTerminalWrite:now:)`, fed from the rollout
scan's `newestTerminalWrite` — the newest `codex-tui` rollout's mtime, stamped
or not). A terminal writing lately means SOME TUI is in use and which host it
belongs to is unknowable, so nothing is stale then; a host whose age did not
parse is never stale. `Status.attachedSessions` is the LIVE count (the one the
policy and the Advanced card use); `staleSessions` is shown beside it.

### Restart on switch (deliverable a + b; rewritten 2026-09-08)

`CodexDaemonService` observes `.providerOwnerClaimed` with `provider == codex`
and `cause == activate` — the one signal every activation path emits (the ⇄
menu, the dashboard, the inspector, the auto-switch), so no activation seam is
edited; `userInfo["previousOwnerId"]` names the login the daemon still holds.
It runs the rollout scan once if none has run yet (the staleness rule needs
the newest terminal write; a switch right after launch must not read "no
activity" and file every host as stale), scans the processes, and asks
`CodexDaemonRestartPolicy.verdict(restartOnSwitch:outgoingLoginExhausted:liveSessions:)`:

| toggle | outgoing login | live sessions | verdict |
|---|---|---|---|
| OFF | any | any | hold — `holdToggleOff` |
| ON | **exhausted or dead** | any, even 3 | **restart** — `restartExhaustedLogin` |
| ON | usable | 0 | restart — `restartIdle` |
| ON | usable | ≥ 1 | hold — `holdLiveSessions(n)` |

**Exhausted** (`outgoingLoginIsExhausted(usage:loginMarkedDead:sessionThreshold:weeklyThreshold:now:)`)
is "the auto-switch would have left it for a limit": the dead-login flag; a
SERVER-AFFIRMED throttle stamp still live; the session window at or over the
session switch threshold (95 % default) while that window is still open; or
the weekly window at or over the weekly threshold (99 %) while still open.
Windows that already reset are a stale cache, not evidence. An INFERRED stamp
is suspicion and never counts — restarting under live sessions on a guess is
the cost the inference rules exist to avoid. The thresholds are the
auto-switch's own (`loadAutoSwitchThreshold` / `loadAutoSwitchWeeklyThreshold`),
so a manual switch away from an exhausted account restarts exactly like an
automatic one: the question is whether the OLD login still works, not who
asked. Live sessions are logged either way (`CodexDaemon.describe`: "pid
55300 (15h 25m, stale), pid 55450 (40s)").

Outcomes:

- No daemon → one log line; terminals pick up the new login on the next
  `codex` launch. Any standing hold is dropped.
- Restart → `restartDaemon(reason:nextOwnerName:)` (below), then "Codex
  daemon restarted — new codex terminals use '<profile>'".
- Hold (toggle off, live sessions on a usable login, or a failed restart) →
  `CodexDaemon: … still holds the previous login ('<old>') … — <why>;
  attached: …`, a `Hold` (daemon pid, previous and new owner, since) is
  recorded, and "Codex terminals still on the previous login" is posted with
  the **Restart Codex daemon** action button (`UNNotificationCategory`
  `CODEX_DAEMON`, action `RESTART_CODEX_DAEMON`; routed by the pure
  `NotificationManager.responseAction(actionIdentifier:categoryIdentifier:)`
  from `AppDelegate.userNotificationCenter(_:didReceive:)` — only the button
  restarts, a tap on the body does nothing). The body names the old login,
  the new profile and the live session count.

**While a hold stands:** every sweep's `refreshTerminalsState` runs one `ps`
scan and clears the hold when the daemon it names is gone — restarted by the
button, Settings, a terminal, or its own exit — logging `hold resolved`;
`.codexDaemonStateChanged` repaints the dashboard, whose Codex block shows a
red **Terminals still on <old>** line with a **Restart** button
(`DashboardActions.restartCodexDaemon`) until then. Ten minutes after the
hold (`reminderDelay`), if the SAME pid still runs, the notice is posted once
more under its own identifier (`codex_daemon_holds_<profile>_reminder`) so the
first notice's dedupe key does not swallow it. A new Codex switch supersedes
the hold and cancels the reminder.

**`restartDaemon` — verified, never a silent half-state.** Re-scan; SIGTERM
the ONE path-anchored pid; wait off the main actor (`waitForExit`, `kill(pid,
0)` every 200 ms, ≤ `exitTimeout` = 10 s) for the process to be gone,
recording whether the control socket vanished with it; log `CodexDaemon:
restarted (pid N → gone in 0.4 s, control socket gone); next codex launch
loads '<new profile>'`. A survivor is re-scanned (still the daemon, same pid —
anything else is treated as done) and sent SIGKILL ONCE, with a further
`killTimeout` = 3 s; a process that survives both is logged as an error with
the `kill -9` to run by hand, and the hold stays. `RestartOutcome` carries
`notRunning` / `restarted(pid:forced:)` / `survived` / `signalFailed`.

The setting is `SharedDataStore.loadCodexDaemonRestartOnSwitch()` (key
`codexDaemonRestartOnSwitch_v1`, journaled single-shot write, registered in
`SettingsKeyRegistry`). **Default ON since 2026-09-08**: the pure rule
`codexDaemonRestartOnSwitch(stored:)` reads an ABSENT key as ON (migration —
installs that never touched the toggle behave like a fresh one; the owner had
already set it by hand) and only an explicit OFF sticks. Settings › Advanced
keeps the "Codex daemon" card: the toggle, a live status line (pid + live
sessions, "· N stale" when any, or "not running"), and a manual **Restart
Codex daemon** button.

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
  after a fresh scan — the SIGKILL escalation re-scans again and fires only
  when the same pid is still the daemon.
- Auto-restart is governed by the toggle (default ON since 2026-09-08; an
  explicit OFF is honoured). With the toggle ON it fires without regard to
  attached sessions ONLY when the outgoing login is exhausted or dead — those
  sessions are already broken — and otherwise only with zero LIVE sessions;
  an inferred throttle stamp never counts as exhausted. The notification
  action and the dashboard button are the user's explicit click.
- A restart is verified (process gone) and every outcome is logged; a daemon
  that survives SIGTERM and SIGKILL is reported, never assumed gone.
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

`CodexDaemonRestartTests` (2026-09-08): the `etime` column; a process list
mirroring the incident (a 15-hour-old host, the desktop app's helpers with
spaces in their paths, a fresh host, a `codex exec` with its own host) counts
exactly the two hosts and files the old one as stale only while terminals are
idle; the policy table; exhaustion from the weekly-only 100 % of the
incident, both thresholds, closed windows, affirmed vs inferred stamps, the
dead flag; absent key → ON; response routing; the hold notice and its
reminder as two dedupe keys; the hold line; the scan's `newestTerminalWrite`.
`SettingsKeyRegistryTests` asserts the key's registration and the ON default.

## Follow-ups

- Restart the daemon only when its *own* login differs from the new owner
  (would need the daemon's account, which the terminals line approximates).
- `stampAccountThrottleIfNeeded` for Codex: a `wham/usage` 429 with a real
  Retry-After would make the exhaustion rule see the throttle as
  server-affirmed; today only thresholds, the dead flag and Claude-side stamps
  feed it.
