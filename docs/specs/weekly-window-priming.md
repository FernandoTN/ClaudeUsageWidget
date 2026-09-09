# Weekly window priming (Codex)

**Status:** `feat/weekly-window-priming`, draft PR — see the status row in
`docs/specs/ux-revamp-status.md`. **Scope: Codex only, by owner decision
(2026-09-09).** Claude accounts are not primed: no Messages API call, no
toggle, no Fable verification. (The original brief covered both providers;
the owner narrowed it before any Claude-side code existed.)

## The owner's ask (2026-09-09)

> "the weekly usage limit doesn't start running until we send a message or
> use a little bit of the usage of each account … When an account's weekly
> reset happens we basically do a temporary session in a terminal with the
> token active so that, for that account, we can send a message and greet it
> … We need to automate that process so that the weekly starts running and
> the resets come sooner rather than having to switch manually when the auto
> switch kicks in."

## Semantics — from the widget's own records

Codex's weekly window is **rolling, 7 days from the first real request after
the previous window ended**. Polling `wham/usage` does not start it. An idle
account past its reset has **no window at all**, and its next reset is 7 days
after whenever the rotation happens to reach it.

| Account | Window start (`reset_at − 604800`, profile store) | What happened then |
|---|---|---|
| xFho | 2026-09-08 12:40 | switched 12:34; the owner relaunched codex ≈ 12:40 |
| xFme | 2026-09-08 18:57 | switch 18:53:46; the new daemon's first request 18:57 |
| xFernando (dev) | 2026-09-09 03:05 | switch 03:05 |
| xLucifer (dev), 09-04 | 2026-09-04 08:20 | manual switch 08:17 → window start 08:20 |

**Live confirmation, 2026-09-09 08:05–08:10 (pid 94842):** xLucifer (dev)
idled past its reset; every sweep logged `Codex: usage parsed - weekly-only -
session: 0.0%, weekly: 0.0%` and its stored `weeklyResetTime` read fetch time
+ 7 d — 08:05, then 08:10 — because the parser invented `now + 7 d` whenever
the payload carried no window (`primary_window` null). That drifting stamp is
exactly the "no window" state priming is for, and it was being presented as a
measurement. The parser now stores the sentinel plus
`ClaudeUsage.weeklyWindowOpen == false`; the healer projects the display
boundary 7 days out and marks it projected (the dashboard's `~`).

Priming is never worse: the quota per window is unchanged, only the clock
moves earlier. A window primed at reset + 5 min resets 7 days later instead
of 7 days after the next switch reaches the account.

Provider docs do not state the mechanism; **the before/after stamps are the
source of truth.** A successful prime moves the reported reset from "none"
to ≈ now + 7 d and the used percentage from 0 to a small non-zero value; the
verifying fetch reads both and the log line records them.

## Behaviour

### Detection

`WeeklyWindowState.of(usage, provider:, now:)`, pure:

| Last fetch said | State | Meaning |
|---|---|---|
| `weeklyWindowOpen == false` | `closed` | the account idled past its reset; only a request opens the next window |
| a reported stamp in the future | `open(resetAt)` | the clock is running |
| a reported stamp in the past, no fetch since | `expired(resetAt)` | the next fetch decides (Codex is fetched every sweep) |
| never measured / sentinel / projected stamp / non-Codex | `unknown` | nothing to do |

A projected boundary is never a reason to do, or skip, anything.

### Schedule (`WeeklyPrimeSchedule`, pure, tested)

For every profile, each sweep (`WeeklyWindowPrimer.tick`, called at sweep
end after the Codex owner re-derivation, never while `isSwitchingProfile`):

- **Excluded**, in this order: unsupported provider (Claude, Grok), no Codex
  credentials, dead login, **the provider's active owner** (being used anyway),
  the toggle off, the "Never prime" list.
- **Episode**: a closed window opens an episode (`episodeObservedAt = now`,
  attempts reset); an open window ends it. `expired` / `unknown` change nothing.
- **Due** at `episodeObservedAt + jitter`, jitter ∈ [2 min, 10 min] —
  **deterministic** (FNV-1a over the profile id and the episode's epoch
  second), so the due time is identical on every tick and after a relaunch
  without being stored, and a fleet whose windows closed together never fires
  as one burst.
- **Once per window**: a successful prime records `primedForWindowEndingAt`
  (the reset the verifying fetch reported); while the reported window is
  that one (±2 min) the verdict is `alreadyPrimed`.
- **Retry once**: a failed or unmoved attempt is retried 30 min later; after
  two attempts the episode is spent (`attemptsExhausted`) until a new
  window closes. The user gets ONE INFO notice per spent episode
  (`NotificationManager.sendWeeklyPrimeFailedNotification`, routed through
  `deliver`, identifier keyed by the episode start). Routine primes are
  log-and-dashboard only.
- **One profile per tick** — the most overdue — and never two primes in
  flight.

### The request (`CodexPrimeCommand`, `CodexWindowPrimer`)

One tiny headless request **through the CLI**, so auth refresh, rollout
writing and the primary bucket behave exactly like real use:

```
CODEX_HOME=<isolated home> codex exec --skip-git-repo-check --sandbox read-only \
  --color never -c model_reasoning_effort="low" "Reply with exactly OK" < /dev/null
```

- **Home**: the profile's remembered `codexHomePath`, else
  `~/.codex-accounts/<slug of the profile name>` (`CodexLoginService.slug`).
  **Never the default `~/.codex`** — a remembered path equal to it is refused.
  A profile synced from the default home gets an isolated home of its own on
  its first prime, and `codexHomePath` is stamped so re-logins and later
  primes land there.
- **Credentials**: `ensureFreshCredentials(freshFor: 24 h)` first (the CLI
  must never have to refresh with a token the widget is about to rotate),
  then the profile's stored auth.json is **written to the isolated home**
  (0600, home 0700) — the copy there may hold a refresh token the widget has
  since rotated, and running the CLI on a consumed refresh token is the
  "refresh token was revoked" failure this codebase already learned from.
  After the run, `adoptAuthFileIfSameAccount(for:inHome:)` adopts any
  rotation the CLI made (same `account_id`, fresher `last_refresh` or
  expiry), the switch path's own rule.
- **Binary**: the standalone build in the Codex home
  (`<default home>/packages/standalone/current/bin/codex`, the one the daemon
  and the terminals run) first, then Homebrew's paths, then
  `zsh -lc 'command -v codex'` — `CodexLoginService.locateCodexBinary`.
- **Model**: none passed — the account's own default model is what every
  real request charges the weekly window with. `-m` is plumbed
  (`arguments(model:)`) for the day a cheaper model is verified to charge the
  same window; the verifying fetch's used-percentage is the measurement to
  compare.
- **Process**: off the main actor, stdin closed (an open pipe makes the CLI
  wait for input forever), stdout + stderr drained as they arrive and capped
  to a 16 KB tail, hard timeout 90 s (SIGTERM, then SIGKILL after 5 s), cwd =
  the isolated home. Exit 0 is required; the output tail goes to the log at
  info level, never a token.
- **Never** the shared daemon (`codex exec` runs in-process), never
  `~/.codex/auth.json` for a non-owner, never a pointer move: priming is not
  a switch.

### Verification and provenance

After a clean exit the primer runs **one forced fetch** for the profile on
the sweep's own path (`MenuBarManager.fetchAndPublishUsage`: healed stamps,
staged, published, the open dashboard rebuilt) and compares before and after
(`WeeklyPrimeVerification.compare`):

```
Prime: codex 'xLucifer(dev)' — window reset moved none → Sep 16 08:12, used 1%
Prime: codex 'xLucifer(dev)' — no window movement (no window — semantics differ?)
Prime: codex 'xLucifer(dev)' — codex exec exited 2: <output tail>
```

The ledger (`weeklyPrimeLedger_v1`) keeps, per profile, the episode and the
last prime that opened a window (`lastPrimedAt`, `primedForWindowEndingAt`,
`lastVerifiedUsedPercent`) — measured values, never synthetic. The dashboard
roster row and the inspector Overview show `primed HH:MM · resets <date>`
from those two stamps, `prime pending HH:MM` while due, `prime retry HH:MM`
after a failure, and the exclusion word otherwise; every prime attempt is
also an Insights incident (`FleetInsights.Incident.Kind.primed`).

### Settings and actions

- **Active & Auto-switch › Weekly window priming**: "Prime Codex weekly
  windows after reset" (default ON; an absent key reads ON) and a per-account
  "Never prime" list (`weeklyPrimePolicy_v1`, journaled + shadowed).
- **Accounts › Overview › Prime now** (Codex accounts): the owner's explicit
  ask — the schedule, the toggle and the never list do not apply; no
  credentials, a dead login and a switch in flight refuse. The outcome line
  is shown on the page and booked like a scheduled prime (no notice).

## Keys

See `docs/specs/ux-revamp.md` §5.2: `weeklyPrimePolicy_v1`,
`weeklyPrimeLedger_v1` (both SharedDataStore, journaled, shadowed, registered;
`SettingsKeyRegistryTests`).

## Tests (`WeeklyWindowPrimingTests`, 15, pure)

Parser "no window" → closed + sentinel, healer projection; window state;
exclusions (owner, dead, unsupported, never list, toggle); jitter bounds and
determinism; episode open/end; once per window; retry once then spent;
verification moved / no movement / already open; attempt bookkeeping;
command arguments, environment, output tail; home resolution (default home
refused); binary order; run verdicts; settings record decoding and round trip.

## First live prime — what to check

The first scheduled prime (or a "Prime now" on an idle Codex account, e.g.
xLucifer (dev) on 2026-09-09) is the semantics test. Expected in the log,
in order: `weekly window seen closed`, `priming due HH:MM`, `starting attempt
1`, `codex exec exited 0 in N s: OK`, `window reset moved none → <now + 7 d>,
used N%`. If the last line reads `no window movement`, the request did not
charge the primary window — try `-m` with the account's default model named
explicitly, or a different effort, and record the finding here.
