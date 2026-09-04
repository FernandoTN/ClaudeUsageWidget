# UX revamp — Viewing vs Active, per-provider selectors, the inspector, Settings

**Date:** 2026-09-03 (evening), proposal v1
**Base:** `main @ 8da0c3d` (#62, menu-bar redesign stage B2 merged; 347 tests)
**Owner ask (verbatim, 2026-09-03):** "Maybe there should be two different menu bars:
1. One is for visualizing a profile and making the necessary logins and such.
2. Another selector should be for the active profile that right now is. Maybe we
should have different ones to have a Codex active one, a Claude active one, and a
Grok one because right now we only have a single one and it's quite confusing
because I need to visualize all of them. […] the number of accounts; being able
to visualize that; having a more in-depth dashboard. The menu bar, when we open it
up, has a lot of things that may not be relevant anymore, such as appearance or
general. We might want to revamp the whole thing."
**Status doc:** `docs/specs/ux-revamp-status.md`. **Check-in brief:**
`docs/specs/ux-revamp-checkin.html`. **Consult outputs:** `docs/specs/consults/`.
**Sibling work this extends, not competes with:** `docs/specs/menubar-redesign.md`
(bar summary layouts, stage A; dashboard model + view, stage B1/B2).

---

## 0. The problem, stated once

Two questions are answered by ONE control today, and the answers have started to
differ:

| Question | Today's name in code | Today's name in the UI | Who changes it |
|---|---|---|---|
| *Which account am I looking at?* (popover, Settings pages, logins, thresholds) | `ProfileManager.activeProfile` / `activeProfileId` ("focus") | "Active Profile" (Settings sidebar picker), the popover's name menu, the ✓ in that menu | the Settings picker, the popover menu, a click on a dead tile (#58), the ⌘-hotkey, **and every real switch** |
| *Which account is each CLI actually using?* (`~/.claude` Keychain login, `~/.codex/auth.json`, the Grok auth file) | `activeClaudeProfileId`, `activeCodexProfileId`, Grok = the focused Grok profile or the sole one | the CYAN tile label, "Active" badge in Manage Profiles, "active: X" in the dashboard section header | `activateProfile`, the auto-switch, a CLI-side login the sweep adopts |

One verb — "activate" — does both, so every viewing surface (the popover menu, the
Settings picker, the hotkey) is also a *switching* surface, and a switch is the
single most expensive action in the app (every concurrent CLI session re-reads its
context, ~10–15 % of the new account's window). Since #58 a click on a profile
with a dead login moves the focus without applying the login, so the two
answers now visibly diverge ("the active profile is xFho but the blue letters
show xFernando"). The in-flight PR
`fix/focused-profile-click-completes-activation` makes a second click finish the
switch; that patches the symptom. This spec replaces the model:

> **Viewing** is free, instant, never touches a CLI, and is what every list,
> menu and click does. **Active for Claude / Active for Codex / Active for
> Grok** are three deliberate, costly, per-provider decisions with their own
> selector, their own confirmation, and their own vocabulary. "Active" without a
> provider name is never displayed again.

Roster today: 23 profiles (18 Claude incl. one detected duplicate pair, 4 Codex,
1 Grok); the owner adds accounts often, so every surface is sized for 30–40.

---

## 1. The model: two concepts, three pointers, one seam

### 1.1 Concepts

| Concept | Meaning | Storage (unchanged keys) | Changes when |
|---|---|---|---|
| **Viewing** | The one account the popover, the inspector and single-account bar mode show and operate on (numbers, logins, sync, thresholds, rename). | `activeProfileId` (kept; only the *name in the UI* changes) | the user picks it anywhere; a switch lands (the new owner becomes viewed); the viewed profile is deleted |
| **Active for Claude** | The account whose login sits in the shared `Claude Code-credentials` Keychain item. | `activeClaudeProfileId` | "Make active for Claude…", the auto-switch, adoption of a CLI-side `/login` |
| **Active for Codex** | The account in `$CODEX_HOME/auth.json`. | `activeCodexProfileId` | "Make active for Codex…", the auto-switch, adoption of a CLI-side login |
| **Active for Grok** | The account in `~/.grok/auth.json`. | **new** `activeGrokProfileId` (nil → today's rule: the viewed Grok profile, else the sole one) | "Make active for Grok…"; with one Grok account it is simply that account |

Invariants the UI can now state and test:

- **R1.** Only three things change what a CLI uses: a "Make active for
  <provider>" action (every surface routes through
  `ProfileManager.activateProfileDetailed(_:userInitiated: true)`), the
  auto-switch, and a login made on the CLI side that the sweep adopts (reported
  as "Active for Claude changed outside the app: now dLeo").
- **R2.** Everything else is Viewing: clicking a tile, choosing a name in the
  popover, choosing a row in the inspector, the "next profile" hotkey. Viewing
  never applies a login, never posts `.profileManuallyActivated`, never records a
  `SwitchEvent`, never needs the dead-login gate.
- **R3.** Wherever an account is shown and it is not the provider's active one,
  both facts are visible: *"Viewing dJormun · Active for Claude: dRir"*. The cyan
  tile label keeps meaning "Active for <provider>" and nothing else.
- **R4.** A dead login can always be viewed and repaired; only "Make active" is
  refused, and the refusal is shown where the user clicked (not only as a
  notification).
- **R5.** Every number on a selector or inspector carries its provenance and age
  (`ClaudeUsage.provenance`, `lastUpdated`). When the active account's own
  endpoint refuses and the header rescue is rate-limited to once per 60 s, the
  user must read *"measured 3 m ago (headers)"*, never a stale value that looks
  live (observed 19:35–19:38 tonight: a three-minute blind window).

### 1.2 The one new seam (owned by the fixes session, requested in §8)

```swift
/// Focus only. Sets `activeProfile`, persists `activeProfileId`, publishes.
/// Never touches credentials, provider pointers, the switch history or the
/// manual-activation mark. Returns false if the id is unknown.
@discardableResult
func viewProfile(_ id: UUID) -> Bool
```

Plus the Grok pointer (`activeGrokProfileId` + `claimActiveGrokOwnership` +
`ProfileStore` save/load, `activeAccountIds` reads it first) and a
`GrokUsageService.applyProfileCredentials(_:)` that rewrites `~/.grok/auth.json`
so a second Grok account can actually be switched to. Nothing else in
`ProfileManager` changes: `activateProfileDetailed` keeps applying logins AND
moving Viewing onto the new owner (after a switch you want to look at the
account you just switched to). `focusedWithoutApplying` stays as a safety net
for programmatic callers but no UI path reaches it once every viewing path is
focus-only.

### 1.3 Vocabulary (shared strings, `Shared/Models/ProviderActiveSelection.swift`)

| Where | Today | After |
|---|---|---|
| Settings sidebar picker label | "Active Profile" | "Viewing" |
| Popover name menu (`ProfileSwitcherCompact`) | activates on pick, ✓ = focus | "View account" — focus only; ✓ = Viewing; a cyan `Cl`/`Cx`/`Gk` mark = Active for that provider |
| Manage Profiles / roster badge | "Active" | "Active for Claude" / "…Codex" / "…Grok" |
| Dashboard section header (B2) | "CLAUDE   active: dRir" + "focused" chip | "CLAUDE · Active: dRir" + "Viewing" chip; header links to the selector |
| Tile tooltip | "Claude: dRir 78 % …" | unchanged — it already names the active account |
| Hotkey "Next profile" | activates the next profile (cross-provider!) | "View next account" (within the viewed provider group) |
| Switch verb | "Activate" / "Switch" | "Make active for <provider>…" (always with the ellipsis: a confirmation follows) |

---

## 2. Surfaces

### 2.1 Per-provider ACTIVE selectors

What a selector must answer, per provider, in one glance: who is active, how much
headroom it has and how fresh that number is, who is next (queued vs ranked) and
whether that login is *proven* live, and how to switch now — with the cost.

#### Options

**S1 — right-click (or ⌥-click) on each provider's tile opens the selector menu.**
Zero bar width; the "two menu bars" become left-click = view, right-click = select.
Risk: composite/scene-hosted status items on macOS 26/27 deliver
*synthesized* click events (`scene-click-synthesized-center` incident); the
event type for a right-click has not been measured to arrive reliably through
the group button's action, and a selector that sometimes opens the popover
instead is worse than none. Discoverability is also poor. → **an accelerator
for a later stage, after a measurement pass**, not the primary surface.

**S2a — ONE dedicated selector status item (`⇄`, 24 pt) with a native `NSMenu`
holding three sections: Active for Claude / Codex / Grok.** (recommended)

```
menu bar:   … [ ▓▓░ dRi ●●●●●●●●● 91→dJo✓ ] [ ▓░ xFe ●×●× →— ] [ Grk ] [ ⇄ ] 🔋 📶 12:41
                    Claude group (existing)     Codex (existing)   Grok  ↑ new, 24 pt, created FIRST
                                                                          so it sits rightmost and
                                                                          survives overflow
click ⇄ →
┌──────────────────────────────────────────────────────────┐
│ ACTIVE FOR CLAUDE                                        │
│   ● dRir        S 78 %  W 16 %  F 16 %   own · 28 s ago  │  ← owner row (disabled, cyan mark)
│   next → dJormun  ✓ verified 12 m ago · headroom 3 m ago │  ← evidence row (disabled)
│   Switch Claude to next (dJormun)…                       │  ← the common action
│   Switch Claude to                                     ▸ │  ← submenu, ranked; ⌥ turns rows into "Queue X next"
│   Queue: Memori › 2026                          Edit…    │
│   View dRir                                              │  ← Viewing (free)
│ ACTIVE FOR CODEX                                         │
│   ● xFernando(dev)   W 95 %  fires at 99 %   own · 1 m   │
│   next → —   nobody with headroom (2 of 4 dead)          │  ← red
│   Switch Codex to                                      ▸ │
│   Repair 2 dead Codex logins…                            │  ← opens the inspector on the first
│ ACTIVE FOR GROK                                          │
│   ● Grok        W 12 %   single account                  │
│ ──────────────────────────────────────────────────────── │
│ Auto-switch ON · 95 % session / 99 % weekly · never on   │
│   suspicion, never between duplicates                    │  ← disabled info row
│ Accounts…           Dashboard…             Settings…     │
└──────────────────────────────────────────────────────────┘

Switch Claude to ▸
   ● dJormun      S 12  W 70  F 99    ✓ 12 m      ranked #1
   ● Memori       S 40  W 55  F 61    ? unverified queued #1
   ● 2026         S  3  W 20  F 20    ?           queued #2
   ◐ Stanford     S 93  W 20  F 20    excluded (free plan)      (disabled)
   ─────
   ▲ Commits      weekly maxed · resets Mon 09:41                (disabled)
   ▲ BBR          session exhausted · 3 h 10 m                   (disabled)
   × Ai           login dead — Repair…                            (enabled → inspector › Login)
   ⧉ Google       same account as dRir                            (disabled)
```

Picking a candidate opens a **confirmation** (`NSAlert`, suppressible per
provider — the menu has already closed, so the popover-vs-alert problem the
dashboard has does not apply):

```
Switch the Claude Code login to dJormun?
Every running Claude Code session re-reads its context on the new account
(≈10–15 % of dJormun's 5-hour window). dJormun: session 12 %, weekly 70 %,
Fable 99 % — login verified 12 m ago (usage probe). dRir keeps 22 % of its
session until 14:02.
                                   ☐ Don't ask again for Claude
                                          [Cancel]  [Switch now]
```

Outcomes are shown in place: `.activated` → the menu re-reads on next open and
the tile label moves; `.credentialsRefused` / `.focusedWithoutApplying` → alert
"Not switched — dJormun's Claude login is dead. Repair it in Accounts › Login"
with a button that opens the inspector there; `.switchInFlight` → "Another
switch is in progress; try again in a moment"; `.alreadyActive` cannot happen
(the owner row is disabled).

Pixel budget: item 24 × 22 pt (SF `arrow.triangle.2.circlepath`, tinted red
when any provider has no executable candidate or its active login is dead,
purple when the active account is suspected/blind); menu ≈ 340 pt wide, ≤ 22
rows + one submenu per provider (25 rows ≈ 480 pt tall — fine). The menu is
built lazily in `menuNeedsUpdate` from a snapshot (`ProviderActiveSelection`),
so a closed menu costs nothing per sweep. The item is created ONCE in
`MenuBarManager.setup()` BEFORE `StatusBarUIManager` creates the provider
groups — each new status item lands LEFT of the existing ones
(`StatusBarUIManager.setupCompositeGroups`, creation order Claude → Grok →
Codex puts Claude rightmost), so an item created first is rightmost and stays
there across group rebuilds, which only ever add items to its left. No
`autosaveName` (a 2026-07-17 pinning experiment left tiles split across
remembered positions with no code-side way back; anonymous items place by
creation order). Never torn down (remap-not-rebuild invariant; no new
CAContext churn); `setup()` re-entry reuses the existing item and `cleanup()`
leaves it alone. Agreed with the redesign session (it owns the bar's
item-count / overflow budget): the item has a **fixed length of 24 pt**, never
`variableLength`; it is exposed read-only as
`MenuBarManager.activeSelectorStatusItem` so the stage C exposure probe
(`probeGroupExposure`, which today walks `groupItems` only) can report a hidden
selector in the same log line; and the menu builder calls
`makeFleetSummaryContext()` (made internal — one word — in stage 1) exactly
once per menu open and hands the value down, never caching it across sweeps
(verdicts carry a TTL, readiness comes from live usage).

**S2b — three selector items, one per provider** (`Cl`, `Cx`, `Gk`, ~26 pt
each, 78 pt total). Literal reading of the ask. Each menu is S2a's section. The
extra 54 pt buy nothing the fleet-layout tiles do not already show (the active
account per provider is ON those tiles), and three menus hide the cross-provider
overview S2a gives in one click. Kept as a **setting** (`Selector: one item /
one per provider`) because it is the same menu builder filtered by provider —
cheap to offer, and the owner may prefer it.

**S3 — no new item: the selector lives as a card in the dashboard (B2) and as a
Settings page.** Zero bar cost, but it puts the switching control *inside* the
viewing surface — the exact conflation the owner asked to end — and a popover
closes on the outside click a confirmation needs. → The card is still built
(Settings › Active & Auto-switch, and B2.1's header link), but as a mirror of
S2a, never as the only selector.

**Decision: S2a**, with S2b as a switch, S3 as mirrors, S1 measured later.

#### What the selector reads (pure model, `ProviderActiveSelection`)

```swift
struct ProviderActiveSelection: Hashable {           // one per provider
    var provider: Profile.ProviderKind
    var owner: OwnerRow?                             // nil = no active login for this provider
    var viewing: UUID?                               // the Viewing account when it is in this provider
    var next: NextCandidate?                         // stage A's type: queued/ranked/blocked head, ✓ ? ×
    var candidates: [CandidateRow]                   // ranked; eligible first, blocked after a separator
    var queue: [QueueEntry]                          // B1's type
    var counts: FleetCounts.Provider                 // §3
    var autoSwitch: AutoSwitchPolicy                 // enabled, session/weekly thresholds
    var alert: FleetAlert?                           // noCandidate / deadLogins / degraded
}
struct OwnerRow: Hashable { id, name, gauges: [WindowGauge], measurement: UsageMeasurement?, suspected: SuspectedCaveat?, etaToThreshold }
struct CandidateRow: Hashable { id, name, readiness: AccountReadiness, gauges, verdict: NextCandidate.Verdict, verdictAt, rank: Rank /* ranked(n) | queued(n) | blocked(reason) | duplicate(of:) | excluded(reason) */, repair: RepairAction? }
static func build(profiles:, activeIds:, viewingId:, context: FleetSummaryContext, queue:, duplicateGroups:, ranking:) -> [ProviderActiveSelection]
```

Ranking reuses `MenuBarManager.rankAutoSwitchCandidates` and
`predictedNextCandidate(for:)` (side-effect free) — never a second resolver.
Readiness reuses `AccountReadiness.classify`. Gauges reuse
`DashboardSnapshot.gauges(for:)`. The menu builder (`MenuBar/ActiveSelectorMenu.swift`)
maps rows to `NSMenuItem`s (attributed titles with monospaced digits, SF glyphs,
`isAlternate` ⌥ rows for "Queue X next"); the item-model → titles/enabled flags
mapping is pure and tested.

### 2.2 The profile INSPECTOR / browser (Viewing)

What it must do: show *any* account's numbers, provenance and age, reset times,
readiness and dead-login state, identity and history; perform logins, sync,
import, removal; edit that account's eligibility, alerts and tile label; rename
and delete — and never change what a CLI uses (the only switching control on it
is the explicit "Make active for <provider>…" button, which runs the same
confirmation as the selector).

#### Options

**I1 — the Accounts section of the existing Settings window, as master-detail:
the sidebar becomes the roster.** (recommended)

```
┌ Settings ───────────────────────────────────────────────────────────── 720 × 750 ┐
│ ● ● ●                                                                            │
│ ┌ ACCOUNTS ─────────── 230 ┐ ┌ Viewing  dJormun                        Claude ┐ │
│ │ ⌕ filter                  │ │ not active · Active for Claude: dRir             │ │
│ │ CLAUDE 18  ●4 ◐2 ▲11 ×1 ⧉2│ │ [Make active for Claude…]  [Queue next]  [Sync]  │ │
│ │ ● dRir        78  Cl      │ │ ─ Overview ─ Login ─ Alerts ─ Display ─          │ │
│ │ ● dJormun     12  ✓       │ │ Session  ▓▓░░░░░░░░ 12 %   resets 4 h 02 m       │ │
│ │ ● Memori      40  Q1      │ │ Weekly   ▓▓▓▓▓▓▓░░░ 70 %   resets Mon 09:41      │ │
│ │ ● 2026         3  Q2      │ │ Fable    ▓▓▓▓▓▓▓▓▓▓ 99 %   at the 99 % threshold │ │
│ │ ◐ Stanford    93  free    │ │ measured 3 m ago · own endpoint · not stale      │ │
│ │ ▲ Commits     W! Mon 09:41│ │ Readiness  ready · login verified 12 m (probe)   │ │
│ │ ▲ BBR         S! 3 h 10 m │ │ Identity   fer…@…  · account …9f3a · org …c2     │ │
│ │ × Ai          dead        │ │ Fetch      every sweep · no backoff              │ │
│ │ ⧉ Google      = dRir      │ │ History    active 2×/24 h · last switch 2 h ago  │ │
│ │ …                         │ │                                                  │ │
│ │ CODEX 4  ●1 ◐1 ×2         │ │                                                  │ │
│ │ ● xFernando   95  Cx      │ │                                                  │ │
│ │ × xFenrir     dead        │ │                                                  │ │
│ │ GROK 1                    │ │                                                  │ │
│ │ ● Grok        12  Gk      │ │                                                  │ │
│ │ + Add account…            │ │                                                  │ │
│ ├───────────────────────────┤ │                                                  │ │
│ │ [Accts][Active][Alerts]   │ │                                                  │ │
│ │ [Display][Adv][About][⏻]  │ │                                                  │ │
│ └───────────────────────────┘ └──────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────────────────┘
```

- **Roster (sidebar, 230 pt):** grouped by provider with the counts strip in the
  header (§3), one 20 pt row per account: readiness glyph, name, keyed
  percentage (session for Claude, weekly for Codex/Grok; `W!`/`S!` when maxed),
  and ONE badge: `Cl/Cx/Gk` cyan = Active for that provider, `Q1` = queue
  position, `✓/?/×` = candidate verdict when it is the next, `free`/`off` =
  excluded, `= dRir` = duplicate. Filter field (name, email, state words:
  "dead", "maxed", "queued"). Selecting a row = Viewing (`viewProfile`). Sorted
  like the bar (soonest weekly reset first) with a toggle for alphabetical.
  40 rows scroll.
- **Detail (490 pt), tabs:**
  - *Overview* — the gauges with threshold ticks and reset countdowns;
    provenance + age line; readiness with its evidence (verdict kind, when);
    identity (email, account-uuid suffix, org, Codex home path); fetch state
    (interval, backoff / throttled-until / suspected caveat); the account's own
    switch history; "same account as" caption.
  - *Login* — today's CLI Account / Codex Account page bodies, verbatim in
    behaviour: Sync / Re-sync, **Log in a new Codex account…** (device code),
    Import from another home…, Remove, masked token + expiry, last synced, the
    dead-login banner with the exact repair, the hazard note. Grok gets the
    same page shape (sync from `~/.grok/auth.json`, remove).
  - *Alerts* — per-account notification settings: "Use fleet defaults" (new,
    §5) or the account's own thresholds and sound (today's General › Notifications).
  - *Display* — tile label, show on the menu bar, refresh interval (today's
    General › Refresh, kept per account), auto-switch eligibility.
  - Footer: Rename, Delete (today's confirm), "Open in dashboard".
- The app-level sections move to the sidebar's bottom bar (icons: Accounts,
  Active & Auto-switch, Alerts, Display, Advanced, About, Quit); choosing one
  shows its page in the detail area while the roster stays visible.
- Deep links keep working: `.settingsSectionRequested("cliAccount")` opens
  Accounts › Login for the viewed profile (alias table in §5.4).

**I2 — a separate "Accounts" window.** Cleaner split (data vs preferences) but a
second window lifecycle in an app that has already fought orphaned windows and
activation-policy storms; and the repair deep links from notifications and the
dashboard would have to learn a second target. → Not now; I1's Accounts section
can be lifted into its own window later without changing its content.

**I3 — the dashboard's account detail (B2's `.account` route) as the inspector.**
380 pt wide, closes on an outside click — a device-code login takes minutes and
a browser hop. → No; the dashboard row links to I1 instead ("Open in Accounts").

**Decision: I1.**

---

## 3. Counts — one model, four places

`Shared/Models/FleetCounts.swift` (pure, built on `AccountReadiness.classify` and
`ReadinessThresholds` — never a second classification):

```swift
struct FleetCounts: Hashable {
    struct Provider: Hashable {
        var provider: Profile.ProviderKind
        var total: Int
        var byReadiness: [AccountReadiness: Int]   // ready · low · unknown · suspected · exhausted · excluded · dead
        var stale: Int                             // orthogonal flag (older than staleAfter)
        var duplicates: Int                        // profiles that share an account with another
        var duplicateGroups: [[UUID]]
        var queued: Int
        var onBar: Int                             // isSelectedForDisplay
        var usableNow: Int { ready + low }          // switch-eligible and has headroom
        var live: Int { total - dead - excluded }   // could be a target once it has headroom
    }
    var providers: [Provider]; var total: Int; var dead: Int; var duplicates: Int
    static func build(profiles:, readiness: [UUID: AccountReadiness], stale: Set<UUID>, duplicateGroups:, queue:) -> FleetCounts
    func strip(_ provider) -> String        // "18 · ●4 ◐2 ▲11 ×1 ⧉2"  (same glyph vocabulary as the bar)
    func sentence(_ provider) -> String     // "18 Claude accounts: 4 ready, 2 low, 11 exhausted, 1 dead, 2 duplicates"
}
```

Where it shows:

| Place | Form |
|---|---|
| Inspector group headers | `CLAUDE 18 · ●4 ◐2 ▲11 ×1 ⧉2` |
| Selector menu, per section | the sentence as a disabled row under the owner when anything is dead/duplicate/no-candidate |
| Selector item tooltip / accessibility label | "Active: Claude dRir 78 % · Codex xFernando 95 % · Grok 12 % — 23 accounts, 3 dead, 2 duplicates" |
| Dashboard header (B2.1, redesign session consumes) | "23 accounts · 3 dead · updated 12 s" → per-provider strips |
| The bar | unchanged — the `fleetCounts` layout already exists; no new glyphs (redesign session's) |

Definitions are the readiness taxonomy's (spec `menubar-redesign.md` §2.1);
"live" and "usable now" are the two planning numbers the owner asked for
("how many accounts do I have, how many can I still use this week").

---

## 4. Dashboard depth beyond B2 (stage 4, additive)

B2 already ships: stacked provider sections, active card with gauges +
thresholds + provenance + suspected caveat + ETA, next line with verdict age,
queue slice, two-line roster rows with chips and repair links, account detail,
row context menu (Make active… two-step, Queue next, Repair), five recent
switches collapsed. Stage 4 adds fields to `DashboardSnapshot` (never reshapes
existing types; every number is a `UsageMeasurement`) and one view file the
redesign session embeds:

| Addition | Model (mine) | Why |
|---|---|---|
| **Reset timeline** — the next 7 days as a strip with a marker per account at its weekly (and Fable) reset, labelled with the headroom that returns | `FleetInsights.resetTimeline: [ResetMark]` | the only planning view for "when does capacity come back", today reconstructed by hand from 23 popovers |
| **Blind spots** — per provider-active account: seconds since the last OWN measurement, provenance of the shown number, header-rescue count in the last hour, backoff state | `FleetInsights.blindness: [Blindness]` | tonight's 3-minute blind window; the fixes session's ask |
| **Burn rate** — pp/min from `measuredSessionHistory_v1` (≥2 samples) with the last four samples as a sparkline; ETA already exists | `FleetInsights.burn: [UUID: BurnRate]` | why an account is projected to cross the threshold, not just when |
| **Switch log** — the full 30-entry ring with provider filter, trigger (auto/manual/queued/focus-only), reason, and the outgoing account's headroom at the time | `FleetInsights.switchLog` (reads `switchHistory_v1`) | forensics without `defaults read` |
| **Rate-limit incidents** — transcript tripwire events, server-affirmed and inferred stamps, header-probe 429s, per account, last 24 h (in-memory ring, 100) | `FleetInsights.incidents` | today only in the unified log, which keeps ~12 h |
| **Filters** on the roster — readiness, provenance (own / headers / CLI cache), stale > N min, queued only | `DashboardFilter` (pure predicate) | 40 rows need a filter |
| **Capacity remaining** — Σ (100 − weekly) over live accounts, per provider | `FleetCounts.Provider.capacityRemaining` | a single planning number |

Not added: per-model Opus/Sonnet rows, thresholds editors, anything that spends
quota to measure.

---

## 5. Settings restructure

### 5.1 Today → after

| Today (tab) | Contents | After |
|---|---|---|
| App › Manage Profiles | roster + create; multi-profile display config; auto-switch enable/thresholds/queue/eligibility | split: roster → **Accounts** (inspector); display config → **Display**; auto-switch → **Active & Auto-switch** |
| App › Popover | time display, time format | **Display › Popover** |
| App › App Settings | launch at login | **Advanced** |
| App › Shortcuts | four recorders | **Advanced › Shortcuts** |
| App › About | about | **About** (bottom bar, unchanged) |
| Profile › General | refresh interval; notifications | refresh → **Accounts › Display** (per account); notifications → **Alerts** (fleet defaults) + **Accounts › Alerts** (override) |
| Profile › Appearance | single-account icon config; locked in multi mode | **Display › Single-account bar** (shown only when display mode is single; keys kept) |
| Profile › Credentials › CLI Account / Codex Account | sync, login, import, remove, token info | **Accounts › Login** |
| (sidebar) "Active Profile" picker | activates | "Viewing" — the roster IS the picker |

New top level (sidebar bottom bar): **Accounts · Active & Auto-switch · Alerts · Display · Advanced · About · Quit**.

**Active & Auto-switch** page: the three "Active for" cards (owner, headroom +
age, next + verdict, `Switch…` → same confirmation), the enable toggle, the two
thresholds, the queue editor (today's), the eligibility list (today's), and the
two rules as text ("never fires on suspicion; never between duplicates of one
account"). **Alerts**: fleet default thresholds + sound (new key), the list of
always-on system alerts (dead login, duplicate account, preferences degraded,
auto-switch, suspected throttle, projected exhaustion, focus-without-login) with
their one-per-episode rule stated, and a "Test notification" button.
**Display**: display mode (single / multi), the multi-profile config
(icon style, week, label, monochrome, time/pace markers, pace coloring, **Menu
bar layout**, **Click opens** — the redesign session's two pickers, same
bindings), the selector item (on/off, one item / per provider), the popover
time settings, the single-account icon config when relevant. **Advanced**:
launch at login, shortcuts, diagnostics (preferences-degraded state and the
last write check, "Re-assert settings now", "Open log", debug API logging — a
key that exists with no UI today), "Forget dead-login flags for…".

### 5.2 Key migration map — nothing renamed, nothing lost

| Key | Owner | Kept | Read/written after | UI after |
|---|---|---|---|---|
| `profiles_v3` | ProfileStore | yes | unchanged | Accounts |
| ↳ per-profile `iconConfig` | Profile | yes | unchanged | Display › Single-account bar |
| ↳ `refreshInterval` | Profile | yes | unchanged | Accounts › Display |
| ↳ `checkOverageLimitEnabled` | Profile | yes (no UI today, none after) | unchanged | — |
| ↳ `notificationSettings` | Profile | yes | unchanged; a profile whose **new** `usesFleetAlertDefaults == true` reads `fleetAlertDefaults_v1` instead | Accounts › Alerts |
| ↳ `isSelectedForDisplay` | Profile | yes | unchanged | Accounts › Display ("Show on the menu bar") |
| ↳ `menuBarLabel` | Profile | yes | unchanged (first UI for it: audit M3) | Accounts › Display |
| ↳ `includeInAutoSwitch` | Profile | yes | unchanged | Accounts › Display + Active & Auto-switch |
| ↳ identity/metadata fields | Profile | yes | unchanged | Accounts › Overview (read-only) |
| `activeProfileId` | ProfileStore | yes | = Viewing; now also written by `viewProfile` | roster selection |
| `activeClaudeProfileId`, `activeCodexProfileId` | ProfileStore | yes | unchanged | Active & Auto-switch, selector |
| **`activeGrokProfileId`** | ProfileStore | **new** | nil → today's rule | Active & Auto-switch, selector |
| `profileDisplayMode` | ProfileStore | yes | unchanged | Display |
| `multiProfileDisplayConfig` (incl. `barLayout`, `clickSurface`) | ProfileStore | yes | unchanged | Display |
| `credentialsMigratedToKeychain`, `credentialsRepairedToKeychain_v2`, `keychainItemsRebuiltViaSecurityTool_v3` | ProfileStore | yes | migration flags, untouched | — |
| `hasCompletedSetup`, `hasShownWizardOnce` | SharedDataStore | yes | untouched | — |
| `debugAPILoggingEnabled` | SharedDataStore | yes | unchanged | Advanced › Diagnostics (first UI) |
| `shortcutTogglePopover`, `shortcutRefresh`, `shortcutOpenSettings`, `shortcutNextProfile` | SharedDataStore | yes | unchanged; `nextProfile` now means "view next" | Advanced › Shortcuts |
| `autoSwitchProfileEnabled`, `autoSwitchThreshold`, `autoSwitchWeeklyThreshold` | SharedDataStore | yes | unchanged | Active & Auto-switch |
| `autoSwitchQueue` | SharedDataStore | yes | unchanged | Active & Auto-switch, selector (⌥ rows), dashboard |
| `popoverShowRemainingTime` (legacy) → `popoverTimeDisplay`, `timeFormatPreference` | SharedDataStore | yes | unchanged (existing one-time migration kept) | Display › Popover |
| `switchHistory_v1`, `measuredSessionHistory_v1` | SharedDataStore | yes | unchanged; read by stage 4 | Dashboard |
| `claudeDeadLogins_v1`, `codexDeadLogins_v1`, `grokDeadLogins_v1` | services | yes | unchanged (journal routing is the fixes session's open item) | Accounts › Login banner; Advanced "forget" |
| `sentNotifications` | NotificationManager | yes | unchanged | — |
| `codexAutoImported_v1`, `grokAutoImported_v1`, `grokDisplayBackfill_v1` | ProfileManager | yes | untouched | — |
| `menuBarIconConfiguration`, `menuBarIconStyle`, `monochromeMode` (legacy single-mode) | MenuBarIconConfiguration | yes | untouched | Display › Single-account bar |
| `debugTileLayout`, `NSQuitAlwaysKeepsWindows`, bundle-migration flag | misc | yes | untouched | — |
| `autoSwitchCustomOrder`, `autoSwitchCustomOrderEnabled` | on disk only (no code) | left alone | — | — |
| **`fleetAlertDefaults_v1`** | SharedDataStore | **new** | `NotificationSettings` JSON; seeded from the Viewing profile's settings on first read | Alerts |
| **`activeSelectorItem_v1`** | SharedDataStore | **new** | `{enabled: Bool, perProvider: Bool}`; default enabled, one item | Display |
| **`activeSelectorConfirm_v1`** | SharedDataStore | **new** | set of providers with the confirmation suppressed | (the alert's checkbox; reset in Advanced) |
| **`settingsLayout_v2`** | SharedDataStore | **new** | Bool; default false until stage 3 verifies, then flipped to true (old layout removed one stage later) | Advanced (during the transition) |

A `SettingsKeyRegistry` (pure list: key, owner, since) is added in stage 3 with
a test asserting every key above is registered and every registered key has a
reader in the store that owns it — the "no key lost" check the owner asked for.

### 5.3 What is removed, and where its information lives

| Removed | Lives now |
|---|---|
| "Active Profile" picker in the sidebar (activating) | roster row = Viewing; switching only via "Make active for…" |
| Profile › General page | refresh interval → Accounts › Display; notifications → Alerts / Accounts › Alerts |
| Profile › Appearance page | Display › Single-account bar (hidden in multi mode instead of "locked") |
| Manage Profiles' "Activate" button (rocket) | "Make active for <provider>…" on the inspector header, with confirmation |
| Popover menu's activate-on-pick | View-on-pick; the switch lives in the selector and the dashboard's "Make active…" |
| Hotkey "next profile" switching CLIs | "view next account"; switching is never a hotkey (audit M7) |
| PR `fix/focused-profile-click-completes-activation`'s second-click semantics | unreachable from the UI (no viewing path activates); the `.alreadyActive` fix stays useful for "Make active" on the viewed non-owner |

Nothing in the model or the sweep is deleted; every action that existed is
reachable from the inspector or the selector.

### 5.4 `SettingsSection` aliases (deep links keep resolving)

| Old raw value | Resolves to |
|---|---|
| `manageProfiles` | `accounts` |
| `cliAccount`, `codexAccount` | `accounts` with the Login tab selected for the viewed profile |
| `general` | `accounts` (Display tab) |
| `appearance`, `popover` | `display` |
| `appSettings`, `shortcuts` | `advanced` |
| `about` | `about` |
| new | `accounts`, `activeAccounts`, `alerts`, `display`, `advanced` |

The redesign session's dashboard posts the old values; both sets decode.

---

## 6. The interaction model, end to end

| The user… | Happens | Never happens |
|---|---|---|
| clicks a provider tile | popover/dashboard opens on that account (Viewing); the header says *Viewing X · Active for Claude: Y* when they differ | a switch |
| picks a name in the popover menu / a roster row / presses ⌘-next | Viewing moves (`viewProfile`); Settings and the popover follow | login applied, `.profileManuallyActivated`, `SwitchEvent`, dead-login notice |
| views a dead profile | the inspector opens with the red Login banner and the exact repair; the selector lists it as `×` with "Repair…" | a refusal notice (there was nothing to refuse) |
| chooses "Make active for Claude…" (selector, inspector header, dashboard row, Active page) | confirmation with cost + candidate evidence → `activateProfileDetailed(userInitiated: true)` → the outcome shown in place; Viewing moves onto the new owner on success | a silent no-op; a switch onto a dead login; a switch between duplicates |
| holds ⌥ in the selector submenu | "Queue X next" (writes `autoSwitchQueue` head) | a switch |
| the auto-switch fires | the owner changes; Viewing follows (unchanged); the selector item re-reads; the existing notification | a switch on an inferred stamp; a switch into a suspect |
| runs `/login` in Claude Code (or a Codex login in an isolated home, then Import) | the sweep re-derives the owner and the selector/inspector say *"Active for Claude changed outside the app: now dLeo"* once | the app rewriting the CLI login |
| logs a Codex account in through the inspector | device-code sheet (existing); afterwards the sheet offers "Make it active for Codex now?" (the fixes session's step, same confirmation) | a second `codex login` in `~/.codex` |

---

## 7. Decision table

| # | Decision | Options | Recommendation | Why |
|---|---|---|---|---|
| D1 | Selector surface | S1 right-click · **S2a one ⇄ item + menu** · S2b three items · S3 in-dashboard only | **S2a** (S2b as a setting) | native, keyboard-navigable, no popover lifecycle, 24 pt, survives overflow, one click shows all three owners |
| D2 | Selector item default | on · off | **on** (toggle in Display) | it is what the owner asked for; additive; removable in one click |
| D3 | Switch confirmation | NSAlert (suppressible) · inline panel · none | **NSAlert, suppressible per provider** | deliberate by ruling; zero new window lifecycle |
| D4 | Inspector surface | **I1 Settings › Accounts master-detail** · I2 own window · I3 dashboard detail | **I1** | one window lifecycle; deep links keep working; logins need a window that stays open |
| D5 | Viewing after a switch | follows the new owner · stays | **follows** | unchanged behaviour; you switched to look at it |
| D6 | Popover name menu | view-only · keep activating | **view-only** | R2; the popover is a viewing surface (redesign session wires it in B2.1) |
| D7 | Hotkey "next profile" | view next · keep switching | **view next, within the provider group** | a hotkey must never rewrite a CLI login (audit M7) |
| D8 | Grok pointer | add `activeGrokProfileId` · keep focus-as-active | **add** | symmetry; a second Grok account is coming |
| D9 | Settings top level | Accounts / Active & Auto-switch / Alerts / Display / Advanced / About | as listed | the owner's own list, with Active & Auto-switch added because the policy deserves a page |
| D10 | Counts vocabulary | readiness histogram + live/usable + duplicates | as §3 | same taxonomy as the bar; two planning numbers |
| D11 | Notifications | per-account only · **fleet defaults + per-account override** | fleet defaults | 25 accounts cannot be configured one by one |
| D12 | Stage 3 rollout | flag `settingsLayout_v2` off → on → old removed | flag | parity before removal |

---

## 8. Staged plan (one draft PR each, ≤ ~600 lines, ≤ 15 tests)

| Stage | Branch | Contents | Flag / additive | Depends on |
|---|---|---|---|---|
| **0** | `feat/ux-revamp-spec` | this spec, status doc, check-in brief, consult outputs | docs | — |
| **1** | `feat/ux-revamp-1-selectors` | `Shared/Models/ProviderActiveSelection.swift` (model + vocabulary strings), `Shared/Models/FleetCounts.swift`, `MenuBar/ActiveSelectorMenu.swift` (item + `NSMenu` + confirmation + outcome alerts), `MenuBarManager.setup()` hook (create once), `Notification.Name.activeSelectorRequested`, Settings sidebar "Viewing" label, strings, `activeSelectorItem_v1` toggle (Display placeholder in Manage Profiles until stage 3), tests: selection build (owner/next/candidates/blocked/duplicate/excluded), counts, menu item model, Grok fallback | item on by default, toggle | B2 (merged); **fixes session:** `viewProfile`, Grok pointer + apply (stage 1 ships with the Grok section read-only if they land later) |
| **2** | `feat/ux-revamp-2-inspector` | `Views/Settings/Accounts/` (roster sidebar, detail tabs, reusing the CLI/Codex page bodies as the Login tab), `viewProfile` wiring, filter, deep-link aliases, tests: roster ordering/filter/badge model, alias resolution | behind `settingsLayout_v2` (old pages untouched) | fixes session's two Settings PRs merged |
| **3** | `feat/ux-revamp-3-settings` | new `SettingsSection` v2, Active & Auto-switch page, Alerts page with `fleetAlertDefaults_v1`, Display page (moves the two redesign pickers), Advanced page (diagnostics, first UI for debug logging), `SettingsKeyRegistry` + "no key lost" test, flag default flipped once verified | `settingsLayout_v2` | 2 |
| **3b** | `chore/ux-revamp-remove-legacy-settings` | delete the old pages once the owner has run v2 for a few days | — | 3 |
| **4** | `feat/ux-revamp-4-insights` | `FleetInsights` model + `DashboardInsightsView` sections (timeline, blind spots, burn, switch log, incidents, filters), snapshot fields added not reshaped | additive; the redesign session embeds | 3 |
| **5** (optional) | `feat/ux-revamp-5-tile-context` | right-click on a provider tile opens that provider's selector section — only after measuring right-click delivery on scene-hosted items | setting | 1 |

Requested seams (fixes session, exact signatures):

```swift
// ProfileManager
@discardableResult func viewProfile(_ id: UUID) -> Bool                 // focus only, see §1.2
@Published private(set) var activeGrokProfileId: UUID?
func claimActiveGrokOwnership(_ profileId: UUID)
// ProfileStore
func saveActiveGrokProfileId(_ id: UUID?); func loadActiveGrokProfileId() -> UUID?
// GrokUsageService
func applyProfileCredentials(_ profileId: UUID) throws                  // rewrites ~/.grok/auth.json (same-user_id merge rule as today's refresh write-back)
```

`activateProfileDetailed` learns the Grok branch (apply + claim, same gate shape:
expired + unrefreshable → refuse) — the fixes session's file, their call whether
stage 1 or later; the selector degrades to "single account" for Grok until then.

Verification per PR: Release build + full suite green on the merged tree
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, dedicated
`-derivedDataPath`), test files ≤ 500 lines, no `Co-Authored-By`, merge sha
messaged to the orchestrator for deploy.

---

## 9. Open questions for the owner

1. **D1/D2:** one `⇄` selector item (recommended) or one per provider — and on by
   default?
2. **D3:** confirmation alert on every manual switch with a per-provider
   "don't ask again", or always ask?
3. **D6:** the popover's name menu becomes view-only (switching moves to the
   selector / dashboard "Make active…"). Confirm — this is the one habit change.
4. **D11:** fleet-wide alert defaults with per-account override — confirm.
5. **Stage 4 priorities:** reset timeline, blind spots, burn rate, switch log,
   incidents, filters — order?
6. Should the Settings window grow (720 → 800 wide) for the master-detail, or
   keep 720 with a 230 pt roster?

---

## 10. Consult log

Pending — Codex `gpt-5.6-sol` (xhigh, read-only) review of this proposal is
launched with the check-in; the log is appended here when it lands.
