# UX revamp — Viewing vs Active, per-provider selectors, the inspector, Settings

**Date:** 2026-09-03 (evening), proposal v2 (v1 revised after the Grok advisory; the
Codex and Fable reviews are folded into §10 as they land)
**Base:** `main @ 9dca689` (#65; menu-bar redesign stages A, B1, B2, C0 merged; the
fixes session's #63/#64 merged; 347+ tests)
**Owner ask (verbatim, 2026-09-03):** "Maybe there should be two different menu bars:
1. One is for visualizing a profile and making the necessary logins and such.
2. Another selector should be for the active profile that right now is. Maybe we
should have different ones to have a Codex active one, a Claude active one, and a
Grok one because right now we only have a single one and it's quite confusing
because I need to visualize all of them. […] the number of accounts; being able
to visualize that; having a more in-depth dashboard. The menu bar, when we open it
up, has a lot of things that may not be relevant anymore, such as appearance or
general. We might want to revamp the whole thing."
Later the same evening (via the fixes session): Codex **bank resets** — see how many
each Codex account has, when they expire, and activate one from the menu (§4.1).
**Status doc:** `docs/specs/ux-revamp-status.md`. **Check-in brief:**
`docs/specs/ux-revamp-checkin.html`. **Consult outputs:** `docs/specs/consults/`.
**Sibling work this extends, not competes with:** `docs/specs/menubar-redesign.md`
(bar summary layouts, stage A; dashboard model + view, stages B1/B2; exposure
telemetry, C0).

---

## 0. The problem, stated once

Two questions are answered by ONE control today, and the answers have started to
differ:

| Question | Today's name in code | Today's name in the UI | Who changes it |
|---|---|---|---|
| *Which account am I looking at?* (popover, Settings pages, logins, thresholds) | `ProfileManager.activeProfile` / `activeProfileId` ("focus") | "Active Profile" (Settings sidebar picker), the popover's name menu, the ✓ in that menu | the Settings picker, the popover menu, a click on a dead tile (#58), the ⌘-hotkey, a delete, **and every real switch** |
| *Which account is each CLI actually using?* (`~/.claude` shared Keychain login, `~/.codex/auth.json`, the Grok auth file) | `activeClaudeProfileId`, `activeCodexProfileId`; Grok = the focused Grok profile or the sole one | the CYAN tile label, "Active" badge in Manage Profiles, "active: X" in the dashboard section header | `activateProfile`, the auto-switch, a CLI-side login the sweep adopts, a manual Sync |

One verb — "activate" — does both, so every viewing surface (the popover menu, the
Settings picker, the hotkey) is also a *switching* surface, and a switch is the
single most expensive action in the app (every concurrent CLI session re-reads its
context, ~10–15 % of the new account's window). Worse, the sweep still treats the
FOCUSED profile as if it were a CLI owner in a dozen places (§1.2), so a change
of what you look at can change what the machinery does. Since #58 a click on a
profile with a dead login moves the focus without applying the login, so the two
answers now visibly diverge ("the active profile is xFho but the blue letters
show xFernando"). #63 makes "Make active" on the viewed non-owner complete the
switch; that closes one gap. This spec replaces the model:

> **Viewing** is free, instant, never touches a CLI, and is what every list,
> menu and click does. **Active for Claude / Active for Codex / Active for
> Grok** are three deliberate, costly, per-provider decisions with their own
> selector, their own confirmation, and their own vocabulary. "Active" without a
> provider name is never displayed again. **Focus is never authority**: no
> sweep, gate, adoption or trigger reads the viewed profile to decide anything
> about a CLI.

Roster today: 23 profiles (18 Claude incl. one detected duplicate pair, 4 Codex,
1 Grok); the owner adds accounts often, so every surface is sized for 30–40.

---

## 1. The model: two concepts, three pointers, one rule

### 1.1 Concepts

| Concept | Meaning | Storage (unchanged keys) | Changes when |
|---|---|---|---|
| **Viewing** | The one account the inspector, the popover's name menu and single-account bar mode show and operate on (numbers, logins, sync, thresholds, rename). | `activeProfileId` (kept; only the *name in the UI* changes) | the user picks it in the inspector, the popover's name menu or with the hotkey; a USER-initiated "Make active" lands (the new owner becomes viewed); an AUTOMATIC switch lands **and Viewing was on the outgoing owner** (keep watching the active account); the viewed profile is deleted |
| **Ephemeral viewing** | The popover's clicked tile / ‹ › navigator position. Not persisted, not Viewing. | `MenuBarManager.clickedProfileId` (exists) | a tile click, a navigator step |
| **Active for Claude** | The account whose login sits in the shared `Claude Code-credentials` Keychain item. | `activeClaudeProfileId` | "Make active for Claude…", the auto-switch, adoption of a CLI-side `/login`, a manual Sync into a profile |
| **Active for Codex** | The account in `$CODEX_HOME/auth.json`. | `activeCodexProfileId` | "Make active for Codex…", the auto-switch, adoption of a CLI-side login, a manual Sync |
| **Active for Grok** | The account in `~/.grok/auth.json`. | **new** `activeGrokProfileId` (journaled + shadowed like the other two; nil → today's rule: the sole Grok profile) | "Make active for Grok…"; with one Grok account it is simply that account |

Two viewing tiers on purpose (Grok review §1): the popover's ‹ › walk and a
tile click stay ephemeral — persisting a journaled single-shot key on every
arrow step is a cfprefsd footgun, and `handleProfileSwitch` (which follows
`$activeProfile`) recreates the popover. Picking a NAME (inspector row, popover
name menu, hotkey) is a deliberate choice and persists.

Invariants the UI can now state and test:

- **R1.** Only four things change what a CLI uses: a "Make active for
  <provider>" action (every surface routes through
  `ProfileManager.activateProfileDetailed(_:userInitiated: true)`), the
  auto-switch, a login made on the CLI side that the sweep adopts (reported
  as "Active for Claude changed outside the app: now dLeo"), and a **manual
  Sync / Import** into a profile (the wizard included) — which copies the CLI's
  CURRENT login into the viewed profile and claims the pointer, so it is a
  switching action and is labelled as one (§2.2).
- **R2.** Everything else is Viewing: choosing a row in the inspector, a name in
  the popover menu, the "next account" hotkey. Viewing never applies a login,
  never posts `.profileManuallyActivated`, never records a `SwitchEvent`, never
  runs the dead-login gate, never recreates the popover for a tile click.
- **R3.** Wherever an account is shown and it is not the provider's active one,
  both facts are visible: *"Viewing dJormun · Active for Claude: dRir"* — on the
  inspector header, the selector, the dashboard header and the popover. The
  cyan tile label keeps meaning "Active for <provider>" and nothing else (Grok:
  focus-as-active until the pointer lands).
- **R4.** A dead login can always be viewed and repaired; only "Make active" is
  refused, and the refusal is shown where the user clicked (not only as a
  notification).
- **R5.** Every number on a selector or inspector carries its provenance and age
  through `DashboardFormatting.provenance` / `UsageMeasurement` (own endpoint /
  headers / CLI cache). When the active account's own endpoint refuses and the
  header rescue is rate-limited to once per 60 s, the user must read *"headers ·
  3 m ago"*, never a stale value that looks live (observed 19:35–19:38 tonight:
  a three-minute blind window). A suspected account shows its last measured
  value + age, never a live-looking percentage.
- **R6. Focus is never authority.** No sweep, adoption, gate, probe or trigger
  resolves "the account in use" from `activeProfile`. Today it does (§1.2); the
  viewing paths in this spec ship only after that pass lands.

### 1.2 Seams (owned by the fixes session; requested and accepted 2026-09-03)

```swift
// ProfileManager — focus only. Sets `activeProfile`, persists `activeProfileId`,
// publishes. Never touches credentials, provider pointers, the switch history or
// the manual-activation mark. Returns false if the id is unknown.
@discardableResult func viewProfile(_ id: UUID) -> Bool

// Grok pointer, symmetric with the other two
@Published private(set) var activeGrokProfileId: UUID?
func claimActiveGrokOwnership(_ profileId: UUID)
// ProfileStore: save/loadActiveGrokProfileId (journaled single-shot + shadow)
// GrokUsageService.applyProfileCredentials(_:) — rewrites ~/.grok/auth.json
// (same-user_id merge as the refresh write-back); Grok branch in
// activateProfileDetailed with the expired-and-unrefreshable gate;
// activeAccountIds / isProviderActive / deleteProfile / RefusedProvider read it.
```

**"Focus is never authority" pass** (verified line by line in `9dca689`, requested
2026-09-03 ~20:20):

| Site | Today | Required |
|---|---|---|
| `MenuBarManager.swift:1574-1577`, `:1625-1628` (and the mid-sweep checks `:1543`, `:1591`) | `checkAutoSwitchIfNeeded` fires when `profile.id == activeProfile?.id \|\| activeClaudeProfileId \|\| activeCodexProfileId`; `checkAutoSwitchIfNeeded` (`:3005-3060`) has no owner guard | trigger only for `activeAccountIds(among:)` members. Otherwise a sweep of a VIEWED non-owner at 96 % switches the CLI away from an owner that has headroom |
| `:1778` system-Keychain usage fallback, `:2280` `ensureFreshCredentials(adoptSystemKeychain:)`, `:2398`/`:2410` dead-login fetch skip (Claude, Grok), `:2528`, `:2594` header rescue, `:2726` header-probe gate — all `activeClaudeProfileId ?? activeProfile?.id`; plus the `== activeProfile?.id` "isActiveAccount" tests at `:1639 :2163 :2170 :2193 :2430 :2633 :2671 :2794 :2922` | focus as fallback owner | owner from the provider pointers; fall back to focus ONLY when the pointer is nil AND the focused profile is the sole credentialed profile of that provider |
| `:1351` sweep priority | focus + Claude owner | keep (a fetch priority, not an owner test) |
| `ProfileManager.swift:497` outgoing Claude owner, `:1392`, `:1618` pointer inference | focus fallback | same rule |
| `ProfileManager.swift:221-226` `deleteProfile` | `activateProfile(profiles.first)` — a delete rewrites a CLI login | `viewProfile(first.id)` |
| `activateProfileDetailed(userInitiated: false)` | moves `activeProfile` to the new owner | move Viewing only if Viewing WAS the outgoing owner; CLI-side adoption never moves Viewing |
| `activateProfileDetailed` `.alreadyActive` | fixed in #63 (`needsProviderApply`: a viewed non-owner completes the apply) | — |

`activateProfileDetailed(userInitiated: true)` keeps applying logins AND moving
Viewing onto the new owner (after a switch you want to look at the account you
switched to). `focusedWithoutApplying` stays as a safety net for programmatic
callers; no UI path reaches it once every viewing path is focus-only.

### 1.3 Vocabulary (shared strings, `Shared/Models/ProviderActiveSelection.swift`)

| Where | Today | After |
|---|---|---|
| Settings sidebar picker label | "Active Profile" | "Viewing" |
| Popover name menu (`ProfileSwitcherCompact`) | activates on pick, ✓ = focus | "View account" — `viewProfile`; ✓ = Viewing; a cyan `Cl`/`Cx`/`Gk` mark = Active for that provider (redesign session, B2.1) |
| Manage Profiles / roster badge | "Active" | "Active for Claude" / "…Codex" / "…Grok" |
| Dashboard section header (B2) | "CLAUDE   active: dRir" + "focused" chip | "CLAUDE · Active: dRir" + "Viewing" chip; header links to the selector (B2.1) |
| Tile tooltip | "Claude: dRir 78 % …" | unchanged — it already names the active account |
| Hotkey "Next profile" | activates the next profile in array order (cross-provider!) | "View next account" — within the viewed provider group, in the bar's painted order |
| Switch verb | "Activate" / "Switch" | "Make active for <provider>…" (always with the ellipsis: a confirmation follows) |
| Sync button | "Sync from Claude Code" | "Import the CLI's current login into this profile…" — names the account the CLI holds and who is Active for it |
| Outside change | (silent) | "Active for Claude changed outside the app: now dLeo" (one banner per episode) |

---

## 2. Surfaces

### 2.1 Per-provider ACTIVE selectors

What a selector must answer, per provider, in one glance: who is active, how much
headroom it has and how fresh/what kind that number is, who is next (queued vs
ranked) and whether that login is *proven* live (and by what), and how to switch
now — with the cost.

#### Options

**S1 — right-click (or ⌥-click) on each provider's tile opens the selector menu.**
Zero bar width; the "two menu bars" become left-click = view, right-click = select.
Risk: composite/scene-hosted status items on macOS 26/27 deliver
*synthesized* click events (`scene-click-synthesized-center` incident); the
event type for a right-click has not been measured to arrive reliably through
the group button's action, and a selector that sometimes opens the popover
instead is worse than none. Discoverability is also poor. → **an accelerator
for a later stage, after a measurement pass**, not the primary surface.

**S2a — ONE dedicated selector status item (`⇄`, fixed 24 pt) with a native
`NSMenu` holding three sections: Active for Claude / Codex / Grok.** (recommended)

```
menu bar:   … [ ▓▓░ dRi ●●●●●●●●● 91→dJo✓ ] [ ▓░ xFe ●×●× →— ] [ Grk ] [ ⇄ ] 🔋 📶 12:41
                    Claude group (existing)     Codex (existing)   Grok  ↑ new, 24 pt fixed, created FIRST
                                                                          so it sits rightmost and
                                                                          survives overflow
click ⇄ →
┌──────────────────────────────────────────────────────────┐
│ ACTIVE FOR CLAUDE                                        │
│   ● dRir        S 78 %  W 16 %  F 16 %   own · 28 s ago  │  ← owner row (disabled, cyan mark); "headers · 3 m" when rescued; purple "last measured 74 % · 12 m" when suspected; "pinned by you" when manually activated
│   next → dJormun  ✓ probed 12 m ago · headroom 3 m ago   │  ← evidence row: verdict KIND (probed / refreshed / owns login / switched) + ages
│   Switch Claude to next (dJormun)…                       │  ← the common action
│   Switch Claude to                                     ▸ │  ← submenu, ranked; ⌥ turns rows into "Queue X next"
│   Queue: Memori › 2026                          Edit…    │
│ ACTIVE FOR CODEX                                         │
│   ● xFernando(dev)   W 95 %  fires at 99 %   own · 1 m   │
│   Resets: 2 available · next expires Sep 9  (§4.1, pending research) │
│   next → —   nobody with headroom (2 of 4 dead)          │  ← red
│   Switch Codex to                                      ▸ │
│   Repair 2 dead Codex logins…                            │  ← opens the inspector on the first
│ ACTIVE FOR GROK                                          │
│   ● Grok        W 12 %   single account                  │
│ ──────────────────────────────────────────────────────── │
│ ⇄ switching Claude → dJormun…                            │  ← only while a switch is in flight
│ Auto-switch ON · 95 % / 99 %                Active & Auto-switch… │
│ Accounts…                                   Dashboard…   │
└──────────────────────────────────────────────────────────┘

Switch Claude to ▸        (type-select works; 25 rows scroll)
   ● dJormun      S 12  W 70  F 99    ✓ probed 12 m     ranked #1
   ● Memori       S 40  W 55  F 61    ? expiry only     queued #1
   ● 2026         S  3  W 20  F 20    ? unverified      queued #2
   ○ Hotmail      never measured      ?                  (eligible — the walk accepts unknown)
   ◐ Stanford     S 93  W 20  F 20    excluded (free plan)      (disabled)
   ─────
   ▲ Commits      weekly maxed · resets Mon 09:41                (disabled)
   ▲ BBR          session exhausted · 3 h 10 m                   (disabled)
   × Ai           login dead — Repair…                            (enabled → inspector › Login)
   ⧉ Google       same account as dRir                            (disabled)
```

Dropped from v1 after the Grok review: the "View <owner>" rows (Viewing belongs
to the inspector / dashboard, not the selector) and the policy paragraph (one
line + a link).

Picking a candidate opens a **confirmation** — `NSAlert`, run synchronously from
the menu action while the click's interaction grant is live; suppressible per
provider, but **always asked** when the candidate is unverified (`?`), dead,
suspected, or a duplicate of the current owner — those are the expensive
mistakes. The menu has already closed, so the popover-vs-alert problem the
dashboard has does not apply:

```
Switch the Claude Code login to dJormun?
Every running Claude Code session re-reads its context on the new account
(≈10–15 % of dJormun's 5-hour window). dJormun: session 12 %, weekly 70 %,
Fable 99 % — login verified 12 m ago (usage probe). dRir keeps 22 % of its
session until 14:02.
                                   ☐ Don't ask again for Claude
                                          [Cancel]  [Switch now]
```

Outcomes are shown in place. Because the outcome arrives after an `await`, the
click's activation grant has expired — the alert is preceded by
`NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])`
(the `bringWindowToForeground` lesson, `MenuBarManager.swift` ~L3900) or it
opens behind the frontmost app. `.activated` → the menu re-reads on next open
and the tile label moves; `.credentialsRefused` / `.focusedWithoutApplying` →
"Not switched — dJormun's Claude login is dead. Repair it in Accounts › Login"
with a button that opens the inspector there; `.switchInFlight` → "Another
switch is in progress; try again in a moment"; `.alreadyActive` cannot happen
(the owner row is disabled).

Pixel budget: item **24 × 22 pt, fixed length** (SF `arrow.triangle.2.circlepath`;
tinted red when any provider has no executable candidate or its active login is
dead, purple when an active account is suspected/blind, amber while cfprefsd is
degraded — the same signal the banner carries); menu ≈ 340 pt wide, ≤ 22 rows +
one submenu per provider (25 rows ≈ 480 pt tall, scrolls). `autoenablesItems =
false` (disabled owner / duplicate / maxed rows must not fight AppKit);
`isAlternate` ⌥ rows immediately follow their primary. The menu is a pure map
from a precomputed `ProviderActiveSelection` snapshot to `NSMenuItem`s in
`menuNeedsUpdate` — no ranking, no Keychain, no roster walk in the delegate; the
snapshot is built once per menu open (and once per paint by the dashboard) from
`makeFleetSummaryContext()` (made internal — one word — in stage 1b), never
cached across sweeps (verdicts carry a TTL, readiness comes from live usage).

The item is created ONCE in `MenuBarManager.setup()` BEFORE `StatusBarUIManager`
creates the provider groups — each new status item lands LEFT of the existing
ones (`StatusBarUIManager.setupCompositeGroups`, creation order Claude → Grok →
Codex puts Claude rightmost), so an item created first is rightmost and stays
there across group rebuilds, which only ever add items to its left. It is
**owned by `MenuBarManager`**, never placed in `StatusBarUIManager`'s
dictionaries (whose `cleanup()` removes every item it owns on each group
rebuild); `setup()` re-entry reuses it. No `autosaveName` (a 2026-07-17 pinning
experiment left tiles split across remembered positions with no code-side way
back; a named ⇄ ⌘-dragged against anonymous groups would split the cluster).
Never torn down (remap-not-rebuild invariant; every recreate leaks a
CAContext). Agreed with the redesign session (it owns the bar's item-count /
overflow budget): fixed 24 pt + system spacing goes into the C0/C1 exposure
budget; the item is exposed read-only as `MenuBarManager.activeSelectorStatusItem`
and the redesign session's next stage-C PR adds an auxiliary-items seam so a
hidden selector shows up in the same `Menu bar exposure` log line
(telemetry-only, no hysteresis tracker for it). One measurement pass on the
scene-hosted bar before the item is called done — this path does not depend on
click-x, so it is the safe bet, but it is unmeasured.

**S2b — three selector items, one per provider** (`Cl`, `Cx`, `Gk`, ~26 pt
each, 78 pt total). Literal reading of the ask. Each menu is S2a's section. The
extra 54 pt buy nothing the fleet-layout tiles do not already show (the active
account per provider is ON those tiles), and three menus hide the cross-provider
overview S2a gives in one click. Kept as a **setting** (`Selector: one item /
one per provider`) — same menu builder filtered by provider — with one platform
rule: **the item count never changes at runtime** (the CAContext leak; hiding
items via `isVisible` is the falsified StormWatchdog cure). The setting takes
effect at the next launch, and says so. Off by default.

**S3 — no new item: the selector lives as a card in the dashboard (B2) and as a
Settings page.** Zero bar cost, but it puts the switching control *inside* the
viewing surface — the exact conflation the owner asked to end — and a popover
closes on the outside click a confirmation needs. → The card is still built
(Settings › Active & Auto-switch, and B2.1's header link), but as a mirror of
S2a, never as the only selector.

**Decision: S2a**, with S2b as a relaunch-applied setting, S3 as mirrors, S1
measured later.

#### What the selector reads (pure model, `ProviderActiveSelection`)

```swift
struct ProviderActiveSelection: Hashable {           // one per provider
    var provider: Profile.ProviderKind
    var owner: OwnerRow?                             // nil = no active login for this provider
    var viewing: UUID?                               // the Viewing account when it is in this provider
    var next: NextCandidate?                         // stage A's type: queued/ranked/blocked head, ✓ ? ×
    var candidates: [CandidateRow]                   // ranked; eligible first, blocked after a separator
    var queue: [QueueEntry]                          // B1's type, this provider's slice
    var counts: FleetCounts.Provider                 // §3
    var autoSwitch: AutoSwitchPolicy                 // enabled, session/weekly thresholds
    var alert: FleetAlert?                           // noCandidate / deadLogins / degraded
    var isSwitching: Bool
    var resets: CodexResetAllowance?                 // §4.1, Codex only, pending research
}
struct OwnerRow: Hashable { id, name, gauges: [WindowGauge], measurement: UsageMeasurement?, suspected: SuspectedCaveat?, etaToThreshold, isManuallyPinned: Bool }
struct CandidateRow: Hashable { id, name, readiness: AccountReadiness, gauges, measurement: UsageMeasurement?, verdict: NextCandidate.Verdict, verdictKind: PreflightVerdict.Kind?, verdictAt, rank: Rank /* ranked(n) | queued(n) | blocked(reason) | duplicate(of:) | excluded(reason) */, repair: RepairAction? }

struct Inputs {                                      // same shape as DashboardSnapshot.Inputs so the
    var profiles: [Profile]; var activeIds: Set<UUID>; var focusedId: UUID?           // dashboard builds it inside its own
    var paintedOrder: [Profile.ProviderKind: [UUID]]; var context: FleetSummaryContext  // build once per paint, no second
    var queue: [UUID]; var duplicateGroups: [[UUID]]; var manuallyPinned: Set<UUID>     // observable (redesign session's ask)
}
static func build(_ inputs: Inputs, ranking: (Profile.ProviderKind) -> [UUID]) -> [ProviderActiveSelection]
```

Ranking reuses `MenuBarManager.rankAutoSwitchCandidates` and
`predictedNextCandidate(for:)` (side-effect free) — never a second resolver.
Readiness reuses `AccountReadiness.classify`. Gauges reuse
`DashboardSnapshot.gauges(for:)`. `manuallyPinned` is
`MenuBarManager.autoSwitchedProfileIds` exposed read-only (a small ask to the
fixes session; the walk owns it). The menu builder
(`MenuBar/ActiveSelectorMenu.swift`) maps rows to `NSMenuItem`s (attributed
titles with monospaced digits, SF glyphs, `isAlternate` ⌥ rows for "Queue X
next"); the item-model → titles/enabled flags mapping is pure and tested.

### 2.2 The profile INSPECTOR / browser (Viewing)

What it must do: show *any* account's numbers, provenance and age, reset times,
readiness and dead-login state, identity and history; perform logins, sync,
import, removal; edit that account's eligibility, alerts and tile label; rename
and delete — and never change what a CLI uses (the switching controls on it are
the explicit "Make active for <provider>…" button and the Import/Sync action,
both labelled as such and both confirmed).

#### Options

**I1 — the Accounts section of the existing Settings window, as master-detail:
the sidebar becomes the roster.** (recommended)

```
┌ Settings ──────────────────────────────────────────────────────────────────── 840 × 750, resizable ┐
│ ● ● ●                                                                                              │
│ ┌ ACCOUNTS ─────────────── 260 ┐ ┌ Viewing  dJormun                                     Claude ┐ │
│ │ ⌕ filter                      │ │ not active · Active for Claude: dRir                           │ │
│ │ CLAUDE 18  ●4 ◐2 ○1 ▲10 ×1 ⧉2 │ │ [Make active for Claude…]  [Queue next]  [Open in dashboard]  │ │
│ │ ● dRir  fer…@gmail   78  Cl   │ │ ─ Overview ─ Login ─ Alerts ─ Display ─                        │ │
│ │ ● dJormun  jor…@…    12  ✓    │ │ Session  ▓▓░░░░░░░░ 12 %   resets 4 h 02 m                     │ │
│ │ ● Memori   fer…@mym  40  Q1   │ │ Weekly   ▓▓▓▓▓▓▓░░░ 70 %   resets Mon 09:41                    │ │
│ │ ● 2026     …          3  Q2   │ │ Fable    ▓▓▓▓▓▓▓▓▓▓ 99 %   at the 99 % threshold               │ │
│ │ ○ Hotmail  …         —        │ │ measured 3 m ago · own endpoint · not stale                    │ │
│ │ ◐ Stanford …         93  free │ │ Readiness  ready · login verified 12 m (usage probe)           │ │
│ │ ▲ Commits  …         W! Mon   │ │ Identity   jor…@… · account …9f3a · org …c2                    │ │
│ │ ▲ BBR      …         S! 3h10m │ │ Fetch      every sweep · no backoff                            │ │
│ │ × Ai       …         dead     │ │ History    active 2×/24 h · last switch 2 h ago (auto, ← Memori)│ │
│ │ ⧉ Google   fer…@gmail = dRir  │ │                                                                │ │
│ │ …                             │ │                                                                │ │
│ │ CODEX 4  ●1 ◐1 ×2             │ │                                                                │ │
│ │ ● xFernando(dev)     95  Cx   │ │                                                                │ │
│ │ × xFenrir(dev)       dead     │ │                                                                │ │
│ │ GROK 1  ●1                    │ │                                                                │ │
│ │ ● Grok               12  Gk   │ │                                                                │ │
│ │ + Add account…                │ │                                                                │ │
│ ├───────────────────────────────┤ │                                                                │ │
│ │ Active & Auto-switch          │ │                                                                │ │
│ │ Alerts                        │ │                                                                │ │
│ │ Display                       │ │                                                                │ │
│ │ Advanced                      │ │                                                                │ │
│ │ About                    Quit │ │                                                                │ │
│ └───────────────────────────────┘ └────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Window:** 840 × 750, `.resizable` added to the style mask (today's window is
  fixed 720, `SettingsView.swift` `.frame(minWidth: 720, maxWidth: 720)` and
  `Constants.WindowSizes.settingsWindow`), minimum 760 × 600. 230 + 490 inside
  720 did not fit a row like `● xFernando(dev)  95  Cx` plus a seven-icon
  bottom bar (Grok review §3); the roster is 260 and the app-level sections are
  **text rows under the roster** (System Settings pattern), not icons.
- **Roster (sidebar):** grouped by provider with the counts strip in the header
  (§3), one 20 pt row per account: readiness glyph, name, email (dimmed,
  truncated), keyed percentage (session for Claude, weekly for Codex/Grok;
  `W!`/`S!` when maxed, `—` when never measured), and ONE badge: `Cl/Cx/Gk` cyan
  = Active for that provider, `Q1` = queue position, `✓/?/×` = candidate verdict
  when it is the next, `free`/`off` = excluded, `= dRir` = duplicate. Filter
  field (name, email, state words: "dead", "maxed", "queued", "unknown").
  Selecting a row = Viewing (`viewProfile`). Sorted like the bar (soonest weekly
  reset first) with a toggle for alphabetical. 40 rows scroll.
- **Detail, tabs:**
  - *Overview* — the gauges with threshold ticks and reset countdowns;
    provenance + age line; readiness with its evidence (verdict kind, when);
    identity (email, account-uuid suffix, org, Codex home path); fetch state
    (interval, backoff / throttled-until / suspected caveat); manual pin; the
    account's own switch history; "same account as" caption; Codex: the reset
    allowance (§4.1).
  - *Login* — today's CLI Account / Codex Account page bodies by `providerKind`
    (they already bind `activeProfile` and reload on its id, so `viewProfile`
    drives them; the device-code sheet is on the Settings window and survives;
    `CodexLoginService.loginTarget` keys off the viewed profile — kept): **Log
    in a new Codex account…** (device code), Import from another home…, Remove,
    masked token + expiry, last synced, the dead-login banner with the exact
    repair, the hazard note. **Sync is relabelled and gated**: "Import the CLI's
    current login into this profile…" shows the account the CLI currently
    holds (identity stamp / `~/.claude.json` cache, or `auth.json`
    `account_id`) and who is Active for it; it is enabled when the viewed
    profile has no account yet or the CLI's login is that profile's own
    account (a repair), and it is a confirmation naming both accounts
    otherwise (#64 already refuses a login another profile holds; this is the
    remaining "copy the owner's login into the row I happen to be viewing"
    path — the 2026-09-03 contamination shape). A dead non-owner's repair is
    the isolated-home login / Import, not Sync, and the tab offers that
    button first. Grok gets a page body of the same shape (new work, small).
    Selecting another roster row while a login sheet is up freezes the sheet's
    target (it keeps the profile it opened for).
  - *Alerts* — per-account notification settings: "Use fleet defaults" (new,
    §5) or the account's own thresholds and sound (today's General › Notifications).
  - *Display* — tile label (first UI for `menuBarLabel`, audit M3), show on the
    menu bar, auto-switch eligibility, and the refresh interval with the honest
    caption "one sweep timer; the interval of the account being viewed drives
    it" (today's behaviour, `MenuBarManager.swift:983`).
  - Footer: Rename, Delete (today's confirm — a delete now views the first
    profile, never activates it).
- Deep links keep working: `.settingsSectionRequested("cliAccount")` opens
  Accounts › Login for the viewed profile — the alias mapper (§5.4) also
  selects the tab and leaves the roster where it is.

**I2 — a separate "Accounts" window.** Cleaner split (data vs preferences) but a
second window lifecycle in an app that has already fought orphaned windows and
activation-policy storms; and the repair deep links from notifications and the
dashboard would have to learn a second target. → Not now; I1's Accounts section
can be lifted into its own window later without changing its content.

**I3 — the dashboard's account detail (B2's `.account` route) as the inspector.**
380 pt wide, closes on an outside click — a device-code login takes minutes and
a browser hop. → No; the dashboard row links to I1 instead ("Open in Accounts").

**Decision: I1, at 840 pt resizable.**

---

## 3. Counts — one model, four places

`Shared/Models/FleetCounts.swift` (pure, built on `AccountReadiness.classify` and
`ReadinessThresholds` — never a second classification; the redesign session passes
its already-computed readiness/stale maps in):

```swift
struct FleetCounts: Hashable {
    struct Provider: Hashable {
        var provider: Profile.ProviderKind
        var total: Int                             // profiles
        var accounts: Int                          // DISTINCT accounts (dedup by claudeAccountUUID / codexAccountId; unstamped = its own)
        var byReadiness: [AccountReadiness: Int]   // ready · low · unknown · suspected · exhausted · excluded · dead (first-match, no double count)
        var stale: Int                             // orthogonal flag (older than staleAfter)
        var duplicates: Int                        // profiles that share an account with another
        var duplicateGroups: [[UUID]]
        var queued: Int; var onBar: Int; var pinned: Int
        var knownHeadroom: Int { ready + low }       // measured and has headroom
        var eligible: Int { ready + low + unknown }  // exactly what the walk accepts (unknown is a legal target)
        var live: Int                              // distinct accounts that are not dead and not excluded
        var capacityRemaining: Double              // Σ (100 − weekly) over live DISTINCT accounts, measured only
    }
    var providers: [Provider]; var total: Int; var dead: Int; var duplicates: Int
    static func build(profiles:, readiness: [UUID: AccountReadiness], stale: Set<UUID>, duplicateGroups: [[UUID]], queue: [UUID], pinned: Set<UUID>, now: Date) -> FleetCounts
    func strip(_ provider) -> String        // "18 · ●4 ◐2 ○1 ▲10 ×1 ⧉2"  (the bar's glyphs, nothing new)
    func sentence(_ provider) -> String     // "18 Claude profiles (17 accounts): 4 ready, 2 low, 1 unmeasured, 10 exhausted, 1 dead, 2 duplicates — 7 eligible now"
}
```

Grok review §4 fixes folded in: `usableNow` was `ready + low` and under-counted
the walk (which accepts `unknown`) → `eligible` says what the walk would take and
`knownHeadroom` what is measured; `live` and `capacityRemaining` count DISTINCT
accounts (a duplicate pair is one quota), using the non-secret stamps
(`claudeAccountUUID`, `codexAccountId`); Codex duplicate groups are derived from
`codexAccountId` inside `FleetCounts` (today only `duplicateClaudeAccountGroups`
is published); Grok has no persisted account id, so its ⧉ is 0 and says so.

Where it shows:

| Place | Form |
|---|---|
| Inspector group headers | `CLAUDE 18 · ●4 ◐2 ○1 ▲10 ×1 ⧉2` |
| Selector menu, per section | the sentence as a disabled row under the owner whenever anything is dead, duplicated or has no candidate |
| Selector item tooltip / accessibility label | "Active: Claude dRir 78 % · Codex xFernando 95 % · Grok 12 % — 23 profiles / 22 accounts, 3 dead, 2 duplicates" |
| Dashboard header (B2.1, redesign session consumes) | per-provider strips |
| The bar | unchanged — the `fleetCounts` layout already exists; no new glyphs (redesign session's) |

---

## 4. Dashboard depth beyond B2 (stage 4, additive)

B2 already ships: stacked provider sections, active card with gauges +
thresholds + provenance + suspected caveat + ETA, next line with verdict age,
queue slice, two-line roster rows with chips and repair links, account detail,
row context menu (Make active… two-step, Queue next, Repair), five recent
switches collapsed; C0 adds the hidden-provider banner. Stage 4 adds fields to
`DashboardSnapshot` (never reshapes existing types; every number is a
`UsageMeasurement`) and one view file the redesign session embeds. Order (Grok:
the timeline is the planning view; ship it first):

| # | Addition | Model (mine) | Why |
|---|---|---|---|
| 1 | **Reset timeline** — the next 7 days as a strip with a marker per DISTINCT account at its weekly (and Fable) reset, labelled with the headroom that returns | `FleetInsights.resetTimeline: [ResetMark]` | the only planning view for "when does capacity come back", today reconstructed by hand from 23 popovers |
| 2 | **Blind spots** — per provider-active account: seconds since the last OWN measurement, provenance of the shown number, header-rescue count in the last hour, backoff state | `FleetInsights.blindness: [Blindness]` | tonight's 3-minute blind window; the fixes session's ask |
| 3 | **Drift banner** — the CLI's live identity (Keychain login / `auth.json` account) ≠ the provider pointer | `FleetInsights.drift: [Drift]` | adoption repairs it silently; the user should see that it happened |
| 4 | **Switch log** — the full 30-entry ring with provider filter, trigger (auto/manual/queued/focus-only), reason, and the outgoing account's headroom at the time | `FleetInsights.switchLog` (reads `switchHistory_v1`) | forensics without `defaults read` |
| 5 | **Burn rate** — pp/min from `measuredSessionHistory_v1` (≥2 samples) with the last four samples as a sparkline; ETA already exists | `FleetInsights.burn: [UUID: BurnRate]` | why an account is projected to cross the threshold, not just when |
| 6 | **Rate-limit incidents** — transcript tripwire events, server-affirmed and inferred stamps, header-probe 429s, per account, last 24 h (in-memory ring, 100) | `FleetInsights.incidents` | today only in the unified log, which keeps ~12 h |
| 7 | **Filters** on the roster — readiness, provenance (own / headers / CLI cache), stale > N min, queued only, provider | `DashboardFilter` (pure predicate) | 40 rows need a filter |
| 8 | **Capacity remaining** — §3's `capacityRemaining`, per provider | `FleetCounts` | a single planning number |

Not added: per-model Opus/Sonnet rows, thresholds editors, anything that spends
quota to measure.

### 4.1 Codex bank resets (owner ask, evening; mechanics PENDING research)

The owner wants, per Codex account: how many resets it has, when they expire,
and a way to activate one from the menu. Two research runs (Grok web research +
a local investigator reading the codex binary strings, the `openai/codex` source,
the live `wham/usage` payload and session transcripts) are establishing the
official feature name, where count/expiry are exposed, and whether a reset can
be triggered by an API call; the findings land in
`docs/research/2026-09-03-codex-bank-resets-*.md`. **This spec reserves the
surface and the gate; it does not design the endpoint call until the evidence
arrives.**

- Datum: `CodexResetAllowance { count: Int, nextExpiry: Date?, measuredAt: Date, provenance }`
  on the Codex profile's usage (parsed by `CodexUsageService`, the fixes
  session's file, behind a `resetAllowance(for:)` seam).
- Shown: inspector Overview for Codex rows ("Resets: 2 · next expires Sep 9"),
  one line under the owner in the ⇄ Codex section, a roster/row badge when > 0,
  and the dashboard's Codex active card (B2.1 consumes the same field).
- Action "Activate reset…" (selector row, inspector button, dashboard row menu),
  behind `CodexUsageService.activateReset(for:)`, gated on: the account is
  MEASURED at its limit (weekly ≥ threshold or a server-affirmed stamp — never
  on inference, never with headroom: a reset must never be spent for nothing),
  a confirmation naming what is spent and what remains, one attempt per
  account per window, and the result shown in place with its provenance.
- If the research finds no API path, the surface still shows count + expiry and
  the action becomes "Open Codex to activate…" with the exact instruction.

---

## 5. Settings restructure

### 5.1 Today → after

| Today (tab) | Contents | After |
|---|---|---|
| App › Manage Profiles | roster + create; multi-profile display config; auto-switch enable/thresholds/queue/eligibility | split: roster → **Accounts** (inspector); display config → **Display**; auto-switch → **Active & Auto-switch** |
| App › Popover | time display, time format | **Display › Popover** |
| App › App Settings | launch at login | **Advanced** |
| App › Shortcuts | four recorders | **Advanced › Shortcuts** |
| App › About | about | **About** (sidebar text row, unchanged content) |
| Profile › General | refresh interval; notifications | refresh → **Accounts › Display** (with the one-timer caption); notifications → **Alerts** (fleet defaults) + **Accounts › Alerts** (override) |
| Profile › Appearance | single-account icon config; locked in multi mode | **Display › Single-account bar** (shown only when display mode is single; keys kept) |
| Profile › Credentials › CLI Account / Codex Account | sync, login, import, remove, token info | **Accounts › Login** |
| (sidebar) "Active Profile" picker | activates | gone — the roster IS the picker and it only views |

New top level (sidebar text rows under the roster): **Accounts · Active &
Auto-switch · Alerts · Display · Advanced · About**, plus Quit.

**Active & Auto-switch** page: the three "Active for" cards (owner, headroom +
provenance/age, next + verdict kind, manual pin, `Switch…` → same confirmation),
the enable toggle, the two thresholds, the queue editor (today's, with a
**provider filter** — one list of 30 mixed ids is how a Codex hand-off gets
stuck behind Claude names), the eligibility list (today's), and the two rules
as text ("never fires on suspicion; never between duplicates of one account").
**Alerts**: fleet default thresholds + sound (new key), the list of always-on
system alerts (dead login, duplicate account, preferences degraded, auto-switch,
suspected throttle, projected exhaustion, focus-without-login, active-changed-
outside) with their one-per-episode rule stated, and a "Test notification"
button. **Display**: display mode (single / multi), the multi-profile config
(icon style, week, label, monochrome, time/pace markers, pace coloring, **Menu
bar layout**, **Click opens** — the redesign session's two pickers, same
bindings), the selector item (on/off, one item / per provider — relaunch to
apply), the popover time settings, the single-account icon config when
relevant. **Advanced**: launch at login, shortcuts, diagnostics
(preferences-degraded state and the last write check, "Re-assert settings now",
"Open log", debug API logging — a key that exists with no UI today), "Forget
dead-login flags for…", "Reset 'don't ask again'".

### 5.2 Key migration map — nothing renamed, nothing lost

| Key | Owner | Kept | Read/written after | UI after |
|---|---|---|---|---|
| `profiles_v3` | ProfileStore | yes | unchanged | Accounts |
| ↳ per-profile `iconConfig` | Profile | yes | unchanged | Display › Single-account bar |
| ↳ `refreshInterval` | Profile | yes | unchanged | Accounts › Display (one-timer caption) |
| ↳ `checkOverageLimitEnabled` | Profile | yes (no UI today, none after) | unchanged | — |
| ↳ `notificationSettings` | Profile | yes | unchanged; a profile whose **new** `usesFleetAlertDefaults == true` reads `fleetAlertDefaults_v1` instead (default **false** — upgrades keep every per-account toggle) | Accounts › Alerts |
| ↳ `isSelectedForDisplay` | Profile | yes | unchanged | Accounts › Display ("Show on the menu bar") |
| ↳ `menuBarLabel` | Profile | yes | unchanged (first UI for it: audit M3) | Accounts › Display |
| ↳ `includeInAutoSwitch` | Profile | yes | unchanged (one binding, two pages) | Accounts › Display + Active & Auto-switch |
| ↳ identity/metadata fields | Profile | yes | unchanged | Accounts › Overview (read-only) |
| `activeProfileId` | ProfileStore | yes | = Viewing; now also written by `viewProfile` | roster selection |
| `activeClaudeProfileId`, `activeCodexProfileId` | ProfileStore | yes | unchanged | Active & Auto-switch, selector |
| **`activeGrokProfileId`** | ProfileStore | **new**, journaled | nil → today's rule | Active & Auto-switch, selector |
| `profileDisplayMode` | ProfileStore | yes | unchanged | Display |
| `multiProfileDisplayConfig` (incl. `barLayout`, `clickSurface`) | ProfileStore | yes | unchanged | Display |
| `credentialsMigratedToKeychain`, `credentialsRepairedToKeychain_v2`, `keychainItemsRebuiltViaSecurityTool_v3` | ProfileStore | yes | migration flags, untouched | — |
| `hasCompletedSetup`, `hasShownWizardOnce` | SharedDataStore | yes | untouched | — |
| `debugAPILoggingEnabled` | SharedDataStore | yes | unchanged | Advanced › Diagnostics (first UI) |
| `shortcutTogglePopover`, `shortcutRefresh`, `shortcutOpenSettings`, `shortcutNextProfile` | SharedDataStore | yes | unchanged; `nextProfile` now means "view next" | Advanced › Shortcuts |
| `autoSwitchProfileEnabled`, `autoSwitchThreshold`, `autoSwitchWeeklyThreshold` | SharedDataStore | yes | unchanged | Active & Auto-switch |
| `autoSwitchQueue` | SharedDataStore | yes | unchanged (provider filter is view-side) | Active & Auto-switch, selector (⌥ rows), dashboard |
| `popoverShowRemainingTime` (legacy) → `popoverTimeDisplay`, `timeFormatPreference` | SharedDataStore | yes | unchanged (existing one-time migration kept) | Display › Popover |
| `switchHistory_v1`, `measuredSessionHistory_v1` | SharedDataStore | yes | unchanged; read by stage 4 | Dashboard |
| `claudeDeadLogins_v1`, `codexDeadLogins_v1`, `grokDeadLogins_v1` | services | yes | unchanged (raw `UserDefaults` writes; journal routing is the fixes session's open item — the registry does not fix it) | Accounts › Login banner; Advanced "forget" |
| `sentNotifications` | NotificationManager | yes | unchanged | — |
| `codexAutoImported_v1`, `grokAutoImported_v1`, `grokDisplayBackfill_v1` | ProfileManager | yes | untouched | — |
| `legacyBundleDefaultsMigrated_v1` | MigrationService | yes | untouched | — |
| `menuBarIconConfiguration`, `menuBarIconStyle`, `monochromeMode` (legacy single-mode) | MenuBarIconConfiguration | yes | untouched | Display › Single-account bar |
| `claudeUsageData`, `notificationsEnabled`, `refreshInterval` (app-level, `UserDefaults+Extensions` KVO), `apiUsageData`, `apiTrackingEnabled`, `apiSessionKey`, `apiOrganizationId`, `showIconNames`, `showNextSessionTime`, `sessionIconEnabled/Style/Order`, `weekIconEnabled/Style/Order`, `weekDisplayMode`, `apiIconEnabled/Style/Order`, `apiDisplayMode` | `Constants.UserDefaultsKeys` | yes | registered as **legacy, unread** (only `menuBarIconStyle` + `monochromeMode` are still migrated by `MenuBarIconConfiguration.load`); never deleted | — |
| `debugTileLayout`, `NSQuitAlwaysKeepsWindows` | misc | yes | untouched | — |
| `autoSwitchCustomOrder`, `autoSwitchCustomOrderEnabled` | on disk only (no code) | left alone | — | — |
| **`fleetAlertDefaults_v1`** | SharedDataStore | **new**, journaled | `NotificationSettings` JSON; seeded from `NotificationSettings()` defaults — or, when every profile's settings are identical, promoted from them (never from whichever row happened to be viewed) | Alerts |
| **`activeSelectorItem_v1`** | SharedDataStore | **new**, journaled | `{enabled: Bool, perProvider: Bool}`; default enabled, one item; per-provider applies at next launch | Display |
| **`activeSelectorConfirm_v1`** | SharedDataStore | **new**, journaled | set of providers with the confirmation suppressed (forced anyway for unverified / dead / suspected / duplicate candidates) | (the alert's checkbox; reset in Advanced) |

A `SettingsKeyRegistry` (pure list: key, owner, status ∈ live / legacy-unread /
migration-flag, since) is added in stage 3 with a test asserting every key above
is registered and every *live* key has a reader in the store that owns it — the
"no key lost" check the owner asked for. Fleet-vs-override alert resolution
happens in the sweep's per-profile notify path (`MenuBarManager.swift:1562-1566`,
which already passes that profile's settings), and the legacy
`NotificationManager.checkAndNotify(usage:)` that reads the VIEWED profile's
settings (`NotificationManager.swift:258-267`) is re-routed or removed (fixes
session's file; requested with stage 3).

No `settingsLayout_v2` flag (v1 had one): maintaining two full Settings trees is
expensive for nothing. The new sections are **added beside the old** in stages
2–3 (Accounts appears as a new sidebar entry; the old Manage Profiles /
Credentials / General / Appearance pages keep working untouched), and the old
pages are deleted in stage 3b after the owner has used the new ones for a few
days.

### 5.3 What is removed, and where its information lives

| Removed | Lives now |
|---|---|
| "Active Profile" picker in the sidebar (activating) | roster row = Viewing; switching only via "Make active for…" |
| Profile › General page | refresh interval → Accounts › Display; notifications → Alerts / Accounts › Alerts |
| Profile › Appearance page | Display › Single-account bar (hidden in multi mode instead of "locked") |
| Manage Profiles' "Activate" button (rocket) | "Make active for <provider>…" on the inspector header, with confirmation |
| Popover menu's activate-on-pick | View-on-pick; the switch lives in the selector and the dashboard's "Make active…" |
| Hotkey "next profile" switching CLIs | "view next account" within the provider, painted order; switching is never a hotkey (audit M7) |
| Delete → activate first profile | Delete → view first profile |
| "Sync from Claude Code" as an unlabelled copy | "Import the CLI's current login into this profile…", named and gated |

Nothing in the model or the sweep is deleted; every action that existed is
reachable from the inspector or the selector.

### 5.4 `SettingsSection` aliases (deep links keep resolving)

| Old raw value | Resolves to |
|---|---|
| `manageProfiles` | `accounts` |
| `cliAccount`, `codexAccount` | `accounts` + Login tab selected, roster left on the viewed profile |
| `general` | `accounts` (Display tab) |
| `appearance`, `popover` | `display` |
| `appSettings`, `shortcuts` | `advanced` |
| `about` | `about` |
| new | `accounts`, `activeAccounts`, `alerts`, `display`, `advanced` |

`SettingsSection` gets a mapper (`init?(deepLink:)`) so the old values the
dashboard posts via `.settingsSectionRequested` keep decoding, and the handler
selects the tab as well as the section (`SettingsView.swift` today only sets
`selectedSection`).

---

## 6. The interaction model, end to end

| The user… | Happens | Never happens |
|---|---|---|
| clicks a provider tile / steps ‹ › in the popover | ephemeral viewing (`clickedProfileId`); the header says *Viewing X · Active for Claude: Y* when they differ | a switch; a persisted write; a popover recreate |
| picks a name in the popover menu / a roster row / presses ⌘-next | Viewing moves (`viewProfile`); Settings and the popover follow | login applied, `.profileManuallyActivated`, `SwitchEvent`, dead-login notice |
| views a dead profile | the inspector opens with the red Login banner and the exact repair (isolated-home login / Import first); the selector lists it as `×` with "Repair…" | a refusal notice (there was nothing to refuse); a Sync button that would copy the owner's login into it |
| chooses "Make active for Claude…" (selector, inspector header, dashboard row, Active page) | confirmation with cost + candidate evidence → `activateProfileDetailed(userInitiated: true)` → the outcome shown in place (app activated first); Viewing moves onto the new owner on success | a silent no-op; a switch onto a dead login; a switch between duplicates; a suppressed confirmation for an unverified / dead / suspected / duplicate candidate |
| holds ⌥ in the selector submenu | "Queue X next" (writes `autoSwitchQueue` head) | a switch |
| the auto-switch fires | the owner changes; Viewing follows only if it was on the outgoing owner; the selector item re-reads; the existing notification | a switch on an inferred stamp; a switch into a suspect; a switch triggered by the VIEWED non-owner's usage; the inspector yanked off a repair |
| runs `/login` in Claude Code (or a Codex login in an isolated home, then Import) | the sweep re-derives the owner and the selector/inspector/dashboard say *"Active for Claude changed outside the app: now dLeo"* once; Viewing stays | the app rewriting the CLI login |
| presses Import/Sync on the Login tab | a confirmation naming the CLI's current account and the viewed profile; the copy + pointer claim (a switching action, R1) | a silent copy of the owner's login into a viewed non-owner (#64 already refuses a login another profile holds) |
| logs a Codex account in through the inspector | device-code sheet (existing, target frozen); afterwards "Make it active for Codex now?" (#63's step, same confirmation) | a second `codex login` in `~/.codex` |

---

## 7. Decision table

| # | Decision | Options | Recommendation | Why |
|---|---|---|---|---|
| D1 | Selector surface | S1 right-click · **S2a one ⇄ item + menu** · S2b three items · S3 in-dashboard only | **S2a** (S2b as a relaunch-applied setting) | native, keyboard-navigable, no popover lifecycle, 24 pt fixed, survives overflow, one click shows all three owners |
| D2 | Selector item default | on · off | **on** (toggle in Display) | it is what the owner asked for; additive; removable in one click |
| D3 | Switch confirmation | NSAlert (suppressible) · inline panel · none | **NSAlert, suppressible per provider, forced for risky candidates** | deliberate by ruling; zero new window lifecycle |
| D4 | Inspector surface | **I1 Settings › Accounts master-detail** · I2 own window · I3 dashboard detail | **I1, window 840 resizable** | one window lifecycle; deep links keep working; logins need a window that stays open |
| D5 | Viewing after a switch | user-initiated: follows · automatic: follows only if Viewing was the outgoing owner · CLI-side adoption: stays | as listed | you switched to look at it; a background rotation must not yank the inspector off a repair (Grok) |
| D6 | Popover name menu | view-only · keep activating | **view-only** | R2; the popover is a viewing surface (redesign session wires it in B2.1) |
| D7 | Hotkey "next profile" | view next · keep switching | **view next, within the provider group, painted order** | a hotkey must never rewrite a CLI login (audit M7) |
| D8 | Grok pointer | add `activeGrokProfileId` · keep focus-as-active | **add** | symmetry; a second Grok account is coming |
| D9 | Settings top level | Accounts / Active & Auto-switch / Alerts / Display / Advanced / About | as listed | the owner's own list, with Active & Auto-switch added because the policy deserves a page |
| D10 | Counts vocabulary | readiness histogram + eligible / known-headroom + distinct accounts + duplicates | as §3 | same taxonomy as the bar; dedup by account |
| D11 | Notifications | per-account only · **fleet defaults + per-account override, default off on upgrade** | fleet defaults | 25 accounts cannot be configured one by one; upgrades keep every toggle |
| D12 | Stage 3 rollout | flag with two trees · **additive sections, old pages deleted in 3b** | additive | two Settings trees cost more than they protect |
| D13 | Sync on the Login tab | ungated copy · **named, gated Import** | gated | the 2026-09-03 contamination path, now reachable from any viewed row |
| D14 | Bank resets | design now · **reserve surface + gate, mechanics after research** | reserve | never invent the call |

---

## 8. Staged plan (one draft PR each, ≤ ~600 lines, ≤ 15 tests)

| Stage | Branch | Contents | Flag / additive | Depends on |
|---|---|---|---|---|
| **0** | `feat/ux-revamp-spec` | this spec, status doc, check-in brief, consult outputs | docs | — |
| **F (fixes session, blocking the view paths)** | theirs | `viewProfile`; Grok pointer + apply + gate; the "focus is never authority" pass (§1.2); auto-switch Viewing rule; `deleteProfile` → view; read-only `autoSwitchedProfileIds` | — | accepted 2026-09-03; `viewProfile` + Grok in flight |
| **1a** | `feat/ux-revamp-1a-models` | `Shared/Models/ProviderActiveSelection.swift` (model + `ActiveVocabulary` strings + `Inputs` shaped like the dashboard's), `Shared/Models/FleetCounts.swift`, `Notification.Name.activeSelectorRequested`, tests (≤ 15: owner/next/candidates/blocked/duplicate/excluded/unknown-eligible, counts incl. distinct-account dedup, Codex duplicate groups from stamps, vocabulary) — **no UI** | additive | B2 ✓ — unblocks B2.1 |
| **1b** | `feat/ux-revamp-1b-selector` | `MenuBar/ActiveSelectorMenu.swift` (item + `NSMenu` + confirmation + outcome alerts + activation before alerts), `MenuBarManager.setup()` create-once hook, `activeSelectorStatusItem` accessor, `makeFleetSummaryContext` made internal, Settings sidebar "Viewing" label, strings, `activeSelectorItem_v1` toggle placed in Manage Profiles until stage 3; item-model → menu-item mapping tests | item on by default, toggle; "Repair…" opens the inspector via the existing deep link; no "View" rows | 1a; F for the Grok apply (Grok section read-only until then) |
| **2** | `feat/ux-revamp-2-inspector` | `Views/Settings/Accounts/` (roster sidebar with email + counts strip, detail tabs; the CLI/Codex page bodies as the Login tab with the gated Import; Grok page body), `viewProfile` wiring, filter, deep-link aliases + tab selection, window 840 resizable; tests: roster ordering/filter/badge model, alias resolution, Import gate predicate | new sidebar entry beside the old pages | F (`viewProfile`, the authority pass) |
| **3** | `feat/ux-revamp-3-settings` | new `SettingsSection` v2 (text rows), Active & Auto-switch page (three cards, queue with provider filter), Alerts page with `fleetAlertDefaults_v1` + `usesFleetAlertDefaults`, Display page (moves the two redesign pickers + selector setting), Advanced page (diagnostics, first UI for debug logging, forget flags, reset don't-ask), `SettingsKeyRegistry` + "no key lost" test | additive | 2 |
| **3b** | `chore/ux-revamp-remove-legacy-settings` | delete Manage Profiles / Credentials / General / Appearance / Popover / App Settings pages once the owner has run the new ones for a few days; legacy `checkAndNotify(usage:)` re-route (fixes session) | — | 3 |
| **4** | `feat/ux-revamp-4-insights` | `FleetInsights` model + `DashboardInsightsView` sections in the §4 order (timeline, blind spots, drift, switch log, burn, incidents, filters, capacity), snapshot fields added not reshaped | additive; the redesign session embeds | 3 |
| **4.1** | `feat/ux-revamp-codex-resets` | reset allowance surface + gated action on the `CodexUsageService` seams | after the research lands | F-side service seams |
| **5** (optional) | `feat/ux-revamp-5-tile-context` | right-click on a provider tile opens that provider's selector section — only after measuring right-click delivery on scene-hosted items | setting | 1b |

Verification per PR: Release build + full suite green on the merged tree
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, dedicated
`-derivedDataPath`), test files ≤ 500 lines, no `Co-Authored-By`, merge sha
messaged to the orchestrator for deploy.

---

## 9. Open questions for the owner

1. **D1/D2:** one `⇄` selector item (recommended) or one per provider — and on by
   default?
2. **D3:** confirmation alert on every manual switch with a per-provider
   "don't ask again" (forced anyway for risky candidates), or always ask?
3. **D6:** the popover's name menu becomes view-only (switching moves to the
   selector / dashboard "Make active…"). Confirm — this is the one habit change.
4. **D11:** fleet-wide alert defaults with per-account override — confirm.
5. **Stage 4 priorities:** reset timeline, blind spots, drift, switch log, burn,
   incidents, filters, capacity — order?
6. **D4:** Settings window 840 wide and resizable — confirm.

---

## 10. Consult log

**Question.** Is Viewing vs Active-for-<provider> the right cut and are R1–R5
complete; S2a vs S2b/S1/S3; I1 vs I2/I3 and the window size; the counts model;
the Settings top level and the key map; where a viewing action could still apply
a login; the staging and the requested seams; what a 30–40-account operator
still lacks.

**Grok `grok-4.6` xhigh (advisory; read the worktree at `8da0c3d`).** "Approve
with revisions." Right cut, right surfaces (S2a, I1). Blockers: focus is still
CLI authority in the auto-switch trigger and a dozen `?? activeProfile` fallbacks
(each verified in `9dca689`, §1.2 — the `.alreadyActive` one was already closed
by #63); split ephemeral vs persisted viewing; manual Sync on a viewed non-owner
is the contamination path → gate it; selector item must be `MenuBarManager`-owned,
fixed length, no `autosaveName`, S2b must not change the item count at runtime;
activate the app before any post-await alert; force the confirmation for
unverified/dead/duplicate candidates; drop the "View" rows and the policy
paragraph from the menu; show verdict kind, provenance, manual pin, in-flight;
window not resizable at 720 → widen to ~840 and use text rows; `usableNow`
under-counts (walk accepts unknown); dedup live/capacity by account stamp; Codex
duplicates from `codexAccountId`; keys missing from the map (legacy
`Constants.UserDefaultsKeys`, `legacyBundleDefaultsMigrated_v1`); fleet defaults
must not seed from Viewing and the flag must default off; D5: auto-switch must
not steal Viewing; hotkey within provider in painted order; delete must not
activate; split stage 1 into models / menu; drop the two-tree flag. Missing:
Codex/Grok duplicate groups, reset timeline first, per-provider queue filter,
manual-pin visibility, drift banner. **All folded into v2.**

**Codex `gpt-5.6-sol` xhigh (read-only).** Pending.

**Fable (independent session).** Pending.

**Decision.** v2 as written; re-evaluated when the two pending reviews land.
