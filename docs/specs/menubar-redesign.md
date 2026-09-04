# Menu-bar redesign — fleet summary + dashboard

**Date:** 2026-09-03 (revised the same day after the design consult, §6)
**Base:** `main @ 5580649` (271 tests green)
**Branches:** `feat/menubar-redesign-a1` (model + config + tests + docs), `feat/menubar-redesign` (paint path, stacked on A1); worktree `.claude/worktrees/menubar-redesign`
**Status doc:** `docs/specs/menubar-redesign-status.md`
**Consult outputs:** `docs/specs/consults/2026-09-03-codex-menubar-review.md`, `…-grok-menubar-review.md` (the Fable review is folded into §6 verbatim where it changed a decision)

## 0. The problem, measured

The bar renders every selected account as its own ~24 pt tile (progress-bar
style: session bar / weekly bar / 3-letter label), concatenated per provider
into ONE fixed-width status item per provider (`StatusBarUIManager`,
composite mode). Live shape on the owner's Mac today:

| Fact | Value |
|---|---|
| Profiles / selected for the bar | 24 / 22 (20 Claude, 3 Codex, 1 Grok) |
| Tile pitch (24 pt tile + 3 pt gap) | 27 pt |
| Claude group width | 18 × 27 ≈ 488 pt |
| Codex + Grok groups | 81 pt + 27 pt |
| Total app width on the bar | **≈ 600 pt** of a 1728 pt display, before the app menu and the system items |
| Overflow behaviour | macOS hides a WHOLE provider item at once (fixed length), Codex first. The composite branch of `updateMultiProfileButtons` returns before `strandedTileDetected` ever runs, so nothing logs, banners or notifies (audit 2026-09-03 H7; `debugTileLayout` is still stamped 2026-07-30, the last legacy evaluation) |
| Dead logins right now | 2 of 3 Codex, 1 of 20 Claude — visible only as a red "login expired" row in the switcher menu |
| Weekly-maxed at the 99 % threshold | 11 of the 17 background Claude accounts (Fable 99–100 %) — visible only as a light-red 3-letter label |

The bar has stopped being a summary. It is a 600 pt list of 22 near-identical
tiles whose only per-account differentiators are a 3-letter label and the bar
colours, with the two facts that actually drive action — *which account is
being burned right now* and *is there somewhere to go next* — encoded as a
cyan label somewhere in the strip and nothing at all, respectively.

## 1. First principles: what a 22 pt strip must answer

Decisions the owner makes from the bar, ranked by how often and how costly a
wrong answer is:

1. **Is the account my CLI sessions are on about to stall?** — the
   provider-active account's *session* window (5 h) is what stalls sessions;
   its weekly and Fable windows are what the auto-switch fires on at 99 %.
   Cost of being wrong: the fleet dies on the wall (2026-08-13 incident).
2. **When it stalls, is there somewhere to go, and where?** — the predicted
   next candidate and whether its login is *proven* live (a probe, a refresh,
   a real switch), or whether the user queued a hand-off. Cost of being
   wrong: a switch onto a dead login (bricked CLI) or a switch that never comes.
3. **Is anything broken that only I can fix?** — dead logins (needs
   `/login` + re-sync), a blind/suspected active account (purple), cfprefsd
   degraded (values on screen are cached), stale data.
4. **How much of the fleet is still usable this week?** — ready vs exhausted.
   This is a *planning* signal, not an action signal; a pattern or a count is
   enough on the bar, the details belong one click away.

What the bar does **not** need to answer, because the answer costs a click
and the click is cheap: per-account percentages, per-account reset times,
per-model weekly windows, pace markers, who is 2nd/3rd in the ranking.

Three provider groups are the natural unit: the two shared CLI logins (Claude,
Codex) and Grok each have exactly one "active" account, and the auto-switch
never crosses providers. So the bar is **one summary tile per provider**, in
the **same three `NSStatusItem`s the composite mode already creates** — the
item set never changes (every teardown leaks CAContexts on macOS 26/27).

Owner rulings this design keeps (not relitigated):

- No synthetic 100 %. Suspected throttle = data-quality purple + last
  measured value and its age. Only measured / header-affirmed values are truth.
- A switch is expensive (every concurrent CLI session re-reads its context,
  ~10–15 % of quota). The UI must make the cost and the NEXT candidate's
  state obvious; the auto-switch never fires on inference.
- Menu-bar agent; the click surface is a popover (a window is acceptable if
  it opens from the bar and closes cleanly).
- cfprefsd degradation keeps its banner and cached-values behaviour.

## 2. The bar

All widths are points at the bar's 22 pt content height (a Claude
progress-bar tile is 22 pt: 4 pt bar, 2 pt gap, 4 pt bar, 2 pt gap, 10 pt
label row; a weekly-only Codex/Grok tile is 16 pt — one bar). Every layout
keeps the existing tile renderer for the ACTIVE block, so its bars, pace
ticks, purple suspected tint and weekly-maxed light-red tint are unchanged
pixel-for-pixel.

### 2.1 Readiness — the one taxonomy every layout renders

Each account is classified once per paint (`AccountReadiness.classify`,
pure, tested). First match wins:

| State | Rule | Mark |
|---|---|---|
| `dead` | provider login flagged dead, or expired with no refresh token (`ProfileCredentialStatusCache.hasDeadLogin`, hydration-aware, no Keychain) | orange **×** — a human must `/login` |
| `excluded` | the switch walk's own exclusions: per-profile auto-switch toggle off, or a free-plan CLI login | grey dash |
| `exhausted` | server-affirmed throttle stamp live, OR measured session ≥ session threshold (live window), OR `isWeeklyMaxed` (all-models / Fable ≥ weekly threshold) | red dot |
| `suspected` | inferred throttle stamp live — *after* exhausted, so a measured exhaustion can never disappear behind a suspicion (same precedence the tile tints use) | purple dot |
| `unknown` | never fetched (`claudeUsage == nil`) | grey hollow ring |
| `low` | session ≥ 80 % or weekly/Fable ≥ 90 %, below the switch thresholds | orange dot |
| `ready` | everything else | green dot |

Two things that are deliberately NOT states:

- **Staleness** is an orthogonal flag (`FleetMember.isStale`, reading older
  than 3 min — the walk's own "verify a stale candidate first" boundary):
  the dot keeps its colour at 50 % alpha. A stale "maxed" is still a fact
  until its window rolls over; a stale "42 %" is an old measurement, not
  "no information".
- **Eligibility**: the walk accepts `{ready, low, unknown}` as targets and
  refuses `{suspected, exhausted, excluded, dead}` (`blocksSwitchTarget`).
  "Green" therefore means *ready*, not *the only thing the switch would take*.

Thresholds are the auto-switch's own (`loadAutoSwitchThreshold`,
`loadAutoSwitchWeeklyThreshold`). Classification reads the MEASURED
`sessionPercentage` with a live window, never `effectiveSessionPercentage`
(which reports 100 while any stamp is live, inferred included — it is the
decision seam, not the display seam).

### 2.2 Recommended: B — active tile + fleet dots (`MenuBarLayout.fleetDots`)

```
 ┌─────────┬──────────────────────────┐
 │ ▓▓▓▓▓▓░ │ Cl   ●●●●●●●●●  ← row 1 │   dots: OTHER accounts, column-major
 │ ▓▓░░░░░ │      ●●×●–●●●●  ← row 2 │   from the RIGHT edge of the block;
 │   dRi   │      91→dJo✓            │   rightmost column = soonest weekly reset
 └─────────┴──────────────────────────┘
   24 pt   3      10 + max(dots, 52)
```

Row 1 sits on the active tile's session bar, row 2 on its weekly bar, the
candidate row on its label row: the block is as tall as the active tile
whenever it fits (one dot row, or counts, beside a 16 pt weekly-only tile),
22 pt only when two dot rows are needed (`FleetBlockGeometry.blockHeight`).

- **Active block** (left): the provider-active account's tile, rendered by the
  configured style, unchanged. Dimmed to 55 % when its last measurement is
  older than 10 min. A provider with NO active login shows empty gauges and
  a "—" label — never some other account promoted to look active.
- **Fleet block** (right): a 6 pt provider mark (`Cl` / `Cx` / `Gk` — not
  `C/X/G`, X is ambiguous between Codex and xAI) in a 10 pt column, then one
  4 pt mark per OTHER account of the provider — every profile of the
  provider, selected or not, exactly the population the switch walk ranks —
  at 6 pt pitch. One row up to ten accounts, two balanced rows beyond
  (17 → 9 columns), filled **column-major from the right edge of the block**
  so the wrap never moves the soonest reset off the right edge and the
  soonest reset sits where the every-account layout puts it. Past 20, the
  two leftmost columns become `+N` (11 pt at 6 pt); the representation never
  flips wholesale at account 21.
- **Row 3 of the fleet block** is the candidate row (§2.4). It lives UNDER the
  dots, so it adds no height: the block is `10 + max(dot matrix, 52)` pt and
  **fixed for a given roster and layout** — arming, digits ticking and
  verdict flips repaint pixels but never change `statusItem.length` (every
  length change relayouts the whole bar, exactly when it is fullest). The
  52 pt reserve is the widest form of the row (`99Q→WWW✓`, 50.1 pt at 7 pt
  semibold) measured with the real font; `FleetSummaryTests.testReservedWidthsCoverTheRealFonts`
  re-measures it, so a font or notation change cannot silently clip the bar.

Live roster: Claude 24 + 3 + (10 + 52) = **89 pt**, Codex 24 + 3 + (10 + 52) =
**89 pt**, Grok **24 pt** (single account: no fleet block) → **≈ 202 pt** plus
system spacing, from ≈ 600.

Why dots over counts: the owner selected 22 accounts because he wants to
*see the fleet*. Dots keep that — "mostly red, four green on the left, two ×"
reads in a glance without a digit — and they keep the ordering. A count is
the same information with the order thrown away.

### 2.3 Fallback: A — active tile + fleet counts (`MenuBarLayout.fleetCounts`)

Same active block and candidate row; the matrix becomes ONE row of
`●12` ready · `◐3` low · `▲11` exhausted · `×2` dead at 6 pt (72 pt reserved
for two-digit counts in every cell, measured; a second row would collide
with the candidate row in 22 pt). States are never merged — `low` is still a valid
switch target and `exhausted` is not. Unknown / suspected / excluded stay out
of the counts (they are neither capacity nor its absence; the dashboard names
them). Because the row reserves two-digit room, counts are NOT narrower than
dots for this roster (Claude 109 pt vs 89 pt): a style preference, selectable
in Settings, not a width win — the Stage C ladder therefore steps
`dots → active-only`.

### 2.4 The candidate row — `91→dJo✓`

Shown while **armed**: the active account's keyed window ≥ 75 % (the
preflight's own milestone; `ProviderSummary.keyedDisplayPercentage` — the
display seam, weekly alone for weekly-only providers), OR a queued hand-off
exists, OR — at any usage — there is nobody to go to ("2 of 3 dead, no
candidate" is the only fact a group like that has; today's live Codex).

Set in 7 pt semibold (monospaced digits), one attributed string, four parts:

| Part | Content | Tint |
|---|---|---|
| digits | the active account's keyed percentage (last measured / projection when suspected — never the stamp's 100) | white; purple when suspected; light red when exhausted |
| prefix | `→` ranked · `Q→` queued · `Q→` with a RED Q = ranked fallback behind a blocked queue head · `→—` no executable candidate · `⇄` mid-switch | white; `→—` red |
| name | the candidate's 3-letter label | its QUOTA evidence: green ready, orange low, grey stale/unknown |
| glyph | `✓` login proven live · `?` unverified · `×` dead | its LOGIN evidence: green / grey / red |

A `✓` is earned only by a **proving** verdict (`PreflightVerdict.Kind`):
a usage probe that answered (every sweep 200 with the profile's own token
counts — the sweep reaches every candidate), a successful refresh-token
redemption, a real switch, or owning the shared CLI login. An expiry-only
check, or an inconclusive Codex probe (429/5xx/transport), stays `?`: it
proves nothing about an externally revoked login. Verdicts expire after
30 min (sweep successes keep them fresh).

### 2.5 Dropped from the design, and why

| Dropped | Reason |
|---|---|
| **Option C — one combined text item** | Not narrower than "active blocks only"; loses the bars and pace ticks (question 1); makes overflow all-or-nothing; and folding three items into one changes the item set (CAContext leak). Not a default, not a ladder rung. |
| **Per-provider alert dot** (red/orange/amber/grey) | `→—` in red already says "nowhere to go"; dead logins are × marks; cfprefsd is global (three amber dots for one daemon) and already a banner; 3 pt grey "stale" is invisible — the active block dims instead. |
| **"unknown = older than 60 min"** | Mis-encodes a still-valid weekly-maxed reading and a 90-minute-old 42 %; staleness is a flag, not a colour. |
| **Growing the tile at 75 %** | Length jitter exactly when the bar is fullest; the candidate row lives under the dots instead. |
| **Row-major dots** | Put the soonest reset mid-row-2 for 17 accounts; column-major from the right keeps "rightmost = next to burn". |
| **Character-count widths** (`Q!→`, a 40 pt reserve) | The real arrow is 7.6 pt wide and `91→dJo✓` measures 45 pt at 8 pt — the first draft would have clipped its own candidate row and the check-in frames overlapped. Every reserved width is now measured against the shipped fonts and re-checked by a test; the row is 7 pt and `Q!→` became a red `Q`. |
| **Two counts rows** | The second row collided with the candidate row in 22 pt; counts are one row. |

### 2.6 What the redesign REMOVES from the bar, and where the information lives

| Removed from the bar | Where it lives now |
|---|---|
| One tile per selected account (22 → 3 tiles) | Dashboard roster rows (same bars, same tints); dots on the bar |
| Per-account 3-letter labels | Dashboard rows; the group button's tooltip / accessibility label spells the summary out (`Claude: dRir 78 % · next → dJormun (ranked, login verified) · 4 ready · 11 exhausted · 1 dead`) |
| Per-account weekly-maxed light-red label | Red dot on the bar; red chip in the dashboard |
| Per-account pace ticks and time markers | Active block keeps them; dashboard rows keep them |
| Per-account click targets | A click on a provider tile opens the popover for that provider's active account (Stage A) / the dashboard scrolled to that provider (Stage B); the navigator and rows open any account. The `everyAccount` layout keeps today's per-tile click routing |
| The soonest-reset-rightmost ORDER as a visible sequence of labelled tiles | Dot order is the same order (right-aligned); the dashboard roster is sorted the same way and says so |

Nothing is deleted from the model or the sweep; this is a rendering and
click-surface change. The popover's group navigator keeps walking every
member: `paintedGroupMembers` reads the summary's painted order, not the
single click segment.

## 3. The dashboard: what is one click away (Stage B)

### D1 — Fleet board popover (380 pt wide, scrollable, detachable) — **recommended**

Stacked provider sections with sticky headers (not tabs — a *fleet* board
shows all three groups; default-scroll to the clicked provider):

```
 ┌──────────────────────────────────────────────────────┐
 │ [banner: preferences degraded] [health: 2 dead, overflow]│
 │ CLAUDE ──────────────────────────────── ⟳  ⚙         │
 │ ACTIVE  dRir (owns the CLI login)        Updated 28s │
 │  Session  ▓▓▓▓▓▓▓▓░░ 78 %   resets in 1h 12m         │
 │  Weekly   ▓▓░░░░░░░░ 16 %   resets Mon 09:41         │
 │  Fable    ▓▓░░░░░░░░ 16 %   ← the window the 99 % switch fires on │
 │  ⚠ Suspected: endpoint refusing since 12:41; last     │
 │    measured 74 % (12:39), projection 81 % (only when suspected) │
 │  Next → dJormun  ✓ probed 12 m ago · headroom measured 3 m ago │
 │  Queue (this provider): Mem › 2026     [Edit in Settings] │
 │  ROSTER (17) · soonest weekly reset first                │
 │  ● dJormun        ready            Mon 09:41         › │
 │    session ▓▓▓░░ 12   weekly ▓▓▓▓▓▓▓░ 70   Fable 99       │
 │  × Ai             dead — /login then Sync  [Open Settings]│
 │  ◐ Stanford       session exhausted · 3 h 10 m        › │
 │  …                                                    │
 │ CODEX ─────────────────────────────────────────────── │
 │ GROK ──────────────────────────────────────────────── │
 │ RECENT SWITCHES (collapsed)                            │
 └──────────────────────────────────────────────────────┘
```

Must show (consult §6): the provider-active account vs the focused one
(the two-active-accounts model); which window will fire the switch and at
what threshold ("99 % weekly" for Codex/Grok, never "95 %"); the next
EXECUTABLE target, queued vs ranked, and a blocked queue head; what the
verdict proved, from which source, how old; quota-evidence age separately
from the login verdict (header-rescue measurements say so); ETA to the
threshold from `projectedSessionPercentage`; per-row eligibility (toggle,
free plan, queue position) and fetch state (backoff / throttled-until);
manual pin (`autoSwitchedProfileIds`) and opt-out chips; dead login as a
verb with a deep link into Settings; the Stage C overflow banner. Two-line
roster rows (identity + chip + reset, then bars) — one line does not fit at
380 pt.

Must not show: credentials, tokens, JSON; per-model Opus/Sonnet rows; pace
ticks on every roster row; the switch-cost sentence permanently (only beside
an armed `Next` and in the two-step inline confirmation of *Make active…*);
any `effectiveSessionPercentage`; thresholds / display / queue editors.

Mechanics: the classic per-account view becomes a reusable detail component
(not the whole `PopoverContentView` under a back chevron); one enum-backed
root view (`roster` / `account(id)`), no `NavigationStack` inside a
fixed-size `NSPopover`; `createContentViewController` type-erased so the
popover and the detached panel share one factory; the detached panel and
`Constants.WindowSizes.popoverSize` (320 × 600, hard-coded in three places)
sized per click surface; `DashboardModel` rebuilt once per paint as a
snapshot, not 20 rows observing `MenuBarManager`; every mutation through
`activateProfileDetailed` so `credentialsRefused` reads as "login dead", not
a silent no-op. Confirmations are inline (an `NSAlert` closes a
`.semitransient` popover).

### D2 — Dedicated dashboard window

More room and it persists, but it needs the Settings window's
activation-policy care, a second orphan-free window lifecycle, and it does
not close on an outside click — the wrong default for a glance surface.
Deferred until the detached panel is genuinely too small (30+ accounts).

### Only in Settings

Display style and layout, thresholds, per-profile auto-switch toggle, queue
editing (the dashboard shows the provider's slice, with a link), labels,
credential sync/remove, notification toggles, shortcuts.

## 4. Data the UI needs that did not exist

| Need | Before | Now (Stage A) |
|---|---|---|
| Predicted next candidate per provider | `findNextAvailableProfile` private, computed only inside the walk/preflight | `MenuBarManager.predictedNextCandidate(for:)` — the walk's own queue selection + provider-keyed ranking, side-effect free (no queue save, `quiet` logging); reports a blocked queue head |
| Verdict per candidate | logged only | `@Published preflightVerdicts: [UUID: PreflightVerdict]` with an evidence `Kind`; written by the preflight (probed / refreshed / expiry-only / owns-login), the walk (switched), and every sweep 200 / 401 |
| Readiness per account | scattered (tile tint, switcher menu, Manage Profiles cache) | `AccountReadiness.classify(...)` + `isStale` |
| Per-provider summary | — | `ProviderSummary.build(...)`, `FleetBlockGeometry` |
| Overflow-hidden provider item | never evaluated in composite mode | Stage C |

Not done, deliberately deferred: one shared `AutoSwitchPlan.resolve(snapshot:)`
used by the walk, the preflight, the bar and the dashboard (Codex's #1). Stage
A reuses the walk's helper functions rather than duplicating them; the
extraction is a Stage B refactor once the dashboard is the second consumer.

## 5. Staged plan

### Stage A — fleet summary layout, behind a display option (this branch)

Split in two stacked draft PRs (the consult's line-budget call):

- **A1** — `MenuBarLayout` + `MultiProfileDisplayConfig.barLayout`
  (`decodeIfPresent`, absent/unknown → `.everyAccount`, so an upgrade never
  changes the bar; rollback = pick "Every account"); the pure model
  (`Shared/Models/FleetSummary.swift`); `FleetSummaryTests` (15 tests:
  precedence, weekly-only, stale-vs-unknown, verdict kinds, arming, blocked
  queue head, no-candidate at any usage, keyed percentage never 100, dot
  overflow keeps the soonest, fixed widths and heights, reserved widths
  re-measured against the real fonts, decode compat); this spec, the consult
  outputs and the check-in brief.
- **A2** — `MenuBar/MenuBarSummaryRenderer.swift` (fleet block, candidate
  row, composition); `StatusBarUIManager` summary path (separate
  per-provider `summaryImages` / `summarySeq` / `SummaryRenderKey` — never
  through `tileImages`; one click segment per provider; painted order kept
  for the navigator; tooltip + accessibility label per group button);
  `MenuBarManager` (`predictedNextCandidate`, verdict publishing, the paint
  context at all five paint sites); the Settings picker.

### Stage B — the dashboard (§3)

### Stage C — overflow that can never hide a provider silently

- **C0, observe only** (a few days): from the composite branch of
  `updateMultiProfileButtons` (the legacy `strandedTileDetected` never runs
  there), log each group window's number, frame, screen, `isVisible`,
  `occlusionState`, and a **screen-point hit test** — `NSWindow.windowNumber(at:belowWindowWithWindowNumber: 0)`
  at 25 / 50 / 75 % of the button width, mid-height — at sweep end AND on
  `NSWorkspace.didActivateApplicationNotification` (overflow flips with the
  frontmost app's menu width, not with sweeps). The composite's opaque event
  shape makes interior hit tests resolve across gaps.
- **Detector**, pure and fixture-tested: exposed iff at least one probe
  resolves to the item's own window; `window == nil` / off-screen /
  height < 2 / width ≪ `statusItem.length` / parked above the bar = hidden;
  duplicate minX among group windows as secondary evidence; absent window,
  screen transitions, menu tracking = *unknown*, never hidden. Two consecutive
  hidden verdicts before acting; several visible ones before clearing.
- **Reaction**: log at default level, dashboard/popover banner ("Codex is
  not visible in the menu bar" — third-party bar managers park items the
  same way), one notification per episode, then step THAT provider's
  effective layout `fleetDots → fleetCounts → active-only (24 pt)` in the
  same `NSStatusItem`. Monotonic for the current screen configuration; step
  up only on a display / roster change. Never enters the heal-rebuild path,
  never creates or destroys an item, never merges providers. Rejected: the
  "overlaps another group / parked at x = 1701" rule (one hidden group
  overlaps nothing; 1701 is one display's parking stub).

## 6. Consult log

**Question.** Is "active tile + fleet dots" the right 22 pt abstraction for
20+ accounts across three providers, is the readiness taxonomy / candidate
affix / alert dot signal or noise, D1 or D2, where does the staged plan break
this codebase, is the overflow rule sound, what is missing?

**Fable (independent session, read the brief + code).** B, drop C from the
ladder (`dots → counts → active-only`); digits for the hot active account;
fixed affix slot so `length` never changes; affirmed stamp outranks
suspected; add `excluded` on the walk's predicate; stale as dimmed colour,
grey only for never-fetched; a `switching` state; `✓` only for probed /
refreshed (Claude's expiry-only check over-claims) and publish a verdict on
the owns-login early return; two alert colours or none; D1 with inline
confirmations and per-surface sizes (detached panel hard-coded 320 × 600);
Stage A as drafted would empty the navigator (keep painted order separate
from click segments); do not route the summary through `tileImages`;
overflow rule unsound (one hidden group overlaps nothing) → C0 telemetry,
evaluate on app activation, no automatic ladder at first. Missing:
ETA-to-threshold, rect-scoped tooltips, gated-switch surfacing.

**Codex `gpt-5.6-sol` xhigh (read-only).** "Approve direction, revise before
implementation." B, A as compact fallback, drop C. Real-font width measurement;
reserve widths; candidate row separate from the active label; `Cl/Cx/Gk` mark;
`+N` past 20 dots rather than a representation flip; dots = the switch-relevant
fleet, not the selected subset, and the active account shown even when
deselected. Separate operability / capacity / evidence axes; `ready`
over-claims eligibility; `→ Q→ ✓ ? × →—` notation; label tint = quota
evidence, glyph = login evidence; publish evidence type, not a Bool
(`isSafeToApplyLogin` returns true on an inconclusive probe); report a blocked
queue head. Drop the alert dot. D1; the dashboard must show owner-vs-focused,
the firing window, executable target, verdict source/age, quota age; two-line
rows; snapshot model; `activateProfileDetailed` for every mutation. Do not
duplicate the resolver (`AutoSwitchPlan`); separate summary pipeline with a
discrete render key (no dates); stable widths; Stage C via
`NSWindow.windowNumber(at:)` hit testing, two consecutive verdicts, monotonic
degrade, no item-count changes.

**Grok `grok-4.6` xhigh (advisory; read the in-progress tree).** B; A as
fallback; C only as a paint style of the three items. Arm and digits on the
DISPLAY seam, never `effectiveSessionPercentage` (a suspected active tile
would print 100 and announce a switch the walk will not make); column-major
right-aligned dots (row-major put the soonest reset mid-row-2 for 17);
`→—` even when not armed if no candidate exists; weekly-only tiles are 16 pt;
counts must not merge low into exhausted; drop the alert dot; per-item
`toolTip` + accessibility label (highest value per line); split Stage A into
A1/A2; verdict TTL per window; `@Published` verdicts rebuild the popover
tree (acceptable now, isolate for Stage B); do not call the queue-saving peek
from paint; overflow rule unsound, never feed overflow to the heal-rebuild
path, ladder within the same item.

**Decision.** B default + A fallback, C dropped; the 2.1 taxonomy (excluded
added, exhausted above suspected, staleness a flag); the 2.4 candidate row
under the dots with fixed widths, `→ / Q→ / Q!→ / →— / ⇄` and `✓ ? ×`,
evidence-typed verdicts fed by preflight, walk AND sweep outcomes; arming on
`keyedDisplayPercentage`; right-aligned column-major dots with `+N`; provider
marks kept (two of three reviewers wanted them; 9 pt); no alert dot; tooltip
+ accessibility label; whole-provider membership with the active shown even
when deselected; D1 as revised in §3; Stage C as revised in §5; Stage A split
into A1/A2. Deferred: the shared `AutoSwitchPlan` resolver (Stage B), ETA to
threshold and right-click candidate menu (Stage B), per-window verdict TTL
(30 min holds while sweep successes refresh verdicts continuously).
