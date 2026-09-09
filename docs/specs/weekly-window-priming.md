# Weekly window priming (Codex)

**Status:** stage 1 `feat/weekly-window-priming`, PR #169, **merged**
`c0952b8` (squash), deployed 2026-09-09 08:41:51 as pid 82343 — suites 658 / 0
twice, Release green. Stage 2 `fix/weekly-priming-placeholder`, PR #170,
**merged** `cf484e7` (squash), deployed 2026-09-09 09:32:42 as pid 36421 with
clean probes — suites 664 / 0 twice, Release green: the stage-1 detector
never fired in the field because an idle account is reported with a
PLACEHOLDER window, not with no window (see "Semantics"). The first live
prime (xLucifer (dev)) is being watched by the orchestrating session; its
outcome goes under "First live prime". See the status rows in
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

## Semantics — from the widget's own records and the endpoint

Codex's weekly window is **rolling, 7 days from the first real request after
the previous window ended**. Polling `wham/usage` does not start it.

| Account | Window start (`reset_at − 604800`, profile store) | What happened then |
|---|---|---|
| xFho | 2026-09-08 12:40 | switched 12:34; the owner relaunched codex ≈ 12:40 |
| xFme | 2026-09-08 18:57 | switch 18:53:46; the new daemon's first request 18:57 |
| xFernando (dev) | 2026-09-09 03:05 | switch 03:05 |
| xLucifer (dev), 09-04 | 2026-09-04 08:20 | manual switch 08:17 → window start 08:20 |

**How an idle account is reported — verified against `wham/usage` with each
account's own token, 2026-09-09 09:12 (orchestrating session):**

| Account | `used_percent` | `limit_window_seconds` | `reset_after_seconds` | `reset_at` |
|---|---|---|---|---|
| xLucifer (dev), idle since its reset | 0 | 604800 | **604800** | **now + 7 d exactly, advancing with every poll** (07:56 → 09:10 → 09:12) |
| xFernando (dev), active | 28 | 604800 | 582757 | fixed |
| xFenrir (dev), exhausted | 100 | 604800 | 466209, `limit_reached` | fixed |

So an idle account is **not** reported as "no window": it gets a
**placeholder** — nothing used, a countdown equal to the full window length,
a reset stamp that follows the clock. A running window's `reset_after` counts
down and its `reset_at` never moves. (Stage 1 read the drifting stamp as the
parser's own `now + 7 d` fallback and looked for a missing window object,
which some plans may still send; the field showed every Codex account with
`weeklyWindowOpen = true` and no prime ever fired. The missing-window case is
kept as a second closed shape.)

Priming is never worse: the quota per window is unchanged, only the clock
moves earlier. A window primed at reset + 5 min resets 7 days later instead
of 7 days after the next switch reaches the account.

## Behaviour

### Detection (`CodexWindowPlaceholder`, pure)

Closed (`ClaudeUsage.weeklyWindowOpen == false`) when EITHER:

- **parser rule** — `used_percent == 0` and `reset_after_seconds ≥
  limit_window_seconds − 120` (or, without `reset_after_seconds`, `reset_at`
  within 2 min of now + window); or the payload carries no weekly window at
  all;
- **poll-to-poll cross-check** (`healMissingResetStamps`, every fetch) —
  `used_percent == 0` and the REPORTED reset advanced ≥ 60 s since the
  previous reported one (a projection is not evidence).

The stored stamp of a closed window is the sentinel; the healer projects
`now + 7 d` marked projected for the ranking's "when does this quota come
back", and the dashboard prints **`W no window (idle)`** — a fact, not a
missing stamp — instead of that projection. `weeklyWindowSeconds` keeps
`limit_window_seconds` for the rules below.

`WeeklyWindowState.of(usage, provider:, now:)`:

| Last fetch said | State | Meaning |
|---|---|---|
| `weeklyWindowOpen == false` | `closed` | idle past its reset; only a request opens the next window |
| a reported stamp in the future | `open(resetAt)` | the clock is running |
| a reported stamp in the past, no fetch since | `expired(resetAt)` | the next fetch decides (Codex is fetched every sweep) |
| never measured / sentinel / projected stamp / non-Codex | `unknown` | nothing to do |

### Schedule (`WeeklyPrimeSchedule`, pure, tested)

For every profile, each sweep (`WeeklyWindowPrimer.tick`, called at sweep
end after the Codex owner re-derivation, never while `isSwitchingProfile`):

- **Excluded**, in this order: unsupported provider (Claude, Grok), no Codex
  credentials, dead login, **the provider's active owner** (being used anyway),
  the toggle off, the "Never prime" list.
- **Episode**: a closed window opens an episode (`episodeObservedAt = now`,
  attempts reset); a running window ends it. `expired` / `unknown` change
  nothing. A sent prime keeps its episode: the window reads closed until the
  clock has run past the placeholder tolerance, and that is not a new window.
- **Due** at `episodeObservedAt + jitter`, jitter ∈ [2 min, 10 min] —
  **deterministic** (FNV-1a over the profile id and the episode's epoch
  second), so the due time is identical on every tick and after a relaunch
  without being stored, and a fleet whose windows closed together never fires
  as one burst.
- **Once per window**: a verified prime records `primedForWindowEndingAt`
  (the reset the verifying fetch reported); while the running window is that
  one (±2 min) the verdict is `alreadyPrimed`.
- **Retry once**: a failed or unmoved attempt is retried 30 min later; after
  two attempts the episode is spent (`attemptsExhausted`) until a new window
  closes. The user gets ONE INFO notice per spent episode
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
  the isolated home. Exit 0 is required; the output tail goes to the log,
  never a token.
- **Never** the shared daemon (`codex exec` runs in-process), never
  `~/.codex/auth.json` for a non-owner, never a pointer move: priming is not
  a switch.

### Verification and provenance (`WeeklyPrimeVerification`)

A fetch right after the request cannot verify anything: `reset_after` has
only dropped by the seconds since the request, which is still inside the
placeholder tolerance, and a tiny request rounds to 0 % used. So a clean
exit is booked as **`sent`** and the sweep's own later fetches (Codex profiles
are fetched every sweep) resolve it:

- **moved** — the window reads running: `reset_after` below the window
  length by more than the tolerance, or a non-zero used percentage.
  `Prime: codex 'xLucifer(dev)' — window started: reset_after 604800 → 604650
  s, resets Sep 16 08:12, used 0%`. `lastPrimedAt` = the request time,
  `primedForWindowEndingAt` = the reported reset.
- **no movement** — still closed 10 min after the request (`grace`):
  `Prime: codex '…' — no window movement 10 min after the request (no window
  (idle) — semantics differ?)`; then the retry rule.
- **failed** — `codex exec` did not exit cleanly: `Prime: codex '…' — codex
  exec exited N: <output tail>`.

The ledger (`weeklyPrimeLedger_v1`) keeps, per profile, the episode and the
last prime that started a window — measured values, never synthetic. The
dashboard roster row and the inspector Overview show `primed HH:MM · resets
<date>` from those stamps, `prime sent HH:MM · verifying` while a request is
unresolved, `prime pending HH:MM` while due, `prime retry HH:MM` after a
failure, and the exclusion word otherwise; every SETTLED attempt is also an
Insights incident (`FleetInsights.Incident.Kind.primed`).

### Settings and actions

- **Active & Auto-switch › Weekly window priming**: "Prime Codex weekly
  windows after reset" (default ON; an absent key reads ON) and a per-account
  "Never prime" list (`weeklyPrimePolicy_v1`, journaled + shadowed).
- **Accounts › Overview › Prime now** (Codex accounts): the owner's explicit
  ask — the schedule, the toggle and the never list do not apply; no
  credentials, a dead login and a switch in flight refuse. The request is
  booked like a scheduled one and the row says `prime sent · verifying`
  until the fetches settle it (no notice).

## Keys

See `docs/specs/ux-revamp.md` §5.2: `weeklyPrimePolicy_v1`,
`weeklyPrimeLedger_v1` (both SharedDataStore, journaled, shadowed, registered;
`SettingsKeyRegistryTests`).

## Tests

`WeeklyWindowPrimingTests` (15, pure): parser placeholder → closed + sentinel
and a running window → open; healer projection; window state; exclusions
(owner, dead, unsupported, never list, toggle); jitter bounds and determinism;
episode open/end; once per window; retry once then spent; verification of a
sent prime (started / still verifying / no movement after the grace);
attempt bookkeeping; command arguments, environment, output tail; home
resolution (default home refused); binary order; run verdicts; settings
record decoding and round trip.

`WeeklyWindowPrimingPayloadTests` (stage 2, 6): the three real payload
shapes (idle placeholder, active, exhausted) through the parser and the
window state; the missing-window shape; the poll-to-poll drift cross-check
in the healer (advancing reset → closed; a fixed reset stays open; a
projected previous stamp is no evidence); the placeholder rule's boundaries;
the dashboard's idle countdown line and tooltip.

## First live prime — what to check

The first scheduled prime after the stage-2 deploy targets xLucifer (dev)
(idle, placeholder window) within 2–10 min of the first sweep. Expected in
the log, in order: `weekly window seen closed (idle placeholder)`, `priming
due HH:MM`, `starting attempt 1`, `codex exec exited 0 in N s: OK; the next
fetches verify the clock started`, then within ~3 min `window started:
reset_after 604800 → N s`. If the last line reads `no window movement`, the
request did not charge the primary window — try `-m` with the account's
default model named explicitly, or a different effort, and record the
finding here.
