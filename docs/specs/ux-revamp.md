# UX revamp — Viewing vs Active, per-provider selectors, the inspector, Settings

**Date:** 2026-09-03 (evening), proposal **v3** (v1 → Grok advisory → v2 → Codex +
Fable reviews → v3; consult log §10)
**Base:** `main @ 56f950f` (#67; menu-bar redesign stages A, B1, B2, C0 merged; the
fixes session's #63/#64 Settings PRs and #66 seams merged)
**Owner ask (verbatim, 2026-09-03):** "Maybe there should be two different menu bars:
1. One is for visualizing a profile and making the necessary logins and such.
2. Another selector should be for the active profile that right now is. Maybe we
should have different ones to have a Codex active one, a Claude active one, and a
Grok one because right now we only have a single one and it's quite confusing
because I need to visualize all of them. […] the number of accounts; being able
to visualize that; having a more in-depth dashboard. The menu bar, when we open it
up, has a lot of things that may not be relevant anymore, such as appearance or
general. We might want to revamp the whole thing."
Later the same evening: Codex **usage limit resets** — see how many each Codex
account has, when they expire, and redeem one from the menu (§4.1).
**Status doc:** `docs/specs/ux-revamp-status.md`. **Check-in brief:**
`docs/specs/ux-revamp-checkin.html`. **Per-site replacement list for the fixes
session:** `docs/specs/ux-revamp-focus-authority.md`. **Consult outputs:**
`docs/specs/consults/2026-09-03-{codex,fable,grok}-ux-revamp-review.md`.
**Sibling work this extends, not competes with:** `docs/specs/menubar-redesign.md`.

---

## 0. The problem, stated once

Two questions are answered by ONE control today, and the answers have started to
differ:

| Question | Today's name in code | Today's name in the UI | Who changes it |
|---|---|---|---|
| *Which account am I looking at?* (popover, Settings pages, logins, thresholds) | `ProfileManager.activeProfile` / `activeProfileId` ("focus") | "Active Profile" (Settings sidebar picker), the popover's name menu, the ✓ in that menu | the Settings picker, the popover menu, a click on a dead tile (#58), the ⌘-hotkey, a delete, **and every real switch** |
| *Which account is each CLI actually using?* (`~/.claude` shared Keychain login, `~/.codex/auth.json`, `~/.grok/auth.json`) | `activeClaudeProfileId`, `activeCodexProfileId`, `activeGrokProfileId` (#66) | the CYAN tile label, "Active" badge in Manage Profiles, "active: X" in the dashboard section header | `activateProfile`, the auto-switch, a CLI-side login the sweep adopts, a manual Sync |

One verb — "activate" — does both, so every viewing surface (the popover menu, the
Settings picker, the hotkey) is also a *switching* surface, and a switch is the
single most expensive action in the app (every concurrent CLI session re-reads its
context, ~10–15 % of the new account's window). Worse, the sweep still treats the
FOCUSED profile as if it were a CLI owner in 28 places (§1.2; all three reviews
found it independently), one of which can rewrite the CLI login and one of which
can fire the auto-switch from an account the CLI is not even using. Since #58 a
click on a profile with a dead login moves the focus without applying the login,
so the two answers now visibly diverge ("the active profile is Petrel but the blue
letters show Marlin"). #63 makes "Make active" on the viewed non-owner
complete the switch; that closes one gap. This spec replaces the model:

> **Viewing** is free, instant, never touches a CLI, costs no network request and
> changes no timer, and is what every list, menu and click does. **Active for
> Claude / Active for Codex / Active for Grok** are three deliberate, costly,
> per-provider decisions with their own selector, their own confirmation, and
> their own vocabulary. "Active" without a provider name is never displayed
> again. **Focus is never authority**: no sweep, gate, adoption, probe or trigger
> reads the viewed profile to decide anything about a CLI.

Roster today: 23 profiles (18 Claude incl. one detected duplicate pair, 4 Codex,
1 Grok); the owner adds accounts often, so every surface is sized for 30–40.

---

## 1. The model: two concepts, three pointers, one rule

### 1.1 Concepts

| Concept | Meaning | Storage (unchanged keys) | Changes when |
|---|---|---|---|
| **Viewing** | The one account the inspector, the popover's name menu and single-account bar mode show and operate on. | `activeProfileId` (kept; only the *name in the UI* changes; writes go through `viewProfile`) | the user picks it in the inspector, the popover's name menu or with the hotkey; a USER-initiated "Make active" lands (the new owner becomes viewed); an AUTOMATIC switch lands **and Viewing was on the outgoing owner and no Settings window is key / no sheet is up**; the viewed profile is deleted (→ first profile is *viewed*, never activated) |
| **Ephemeral viewing** | The popover's clicked tile / ‹ › navigator position. Not persisted, not Viewing. | `MenuBarManager.clickedProfileId` (exists) | a tile click, a navigator step |
| **Active for Claude** | The account whose login sits in the shared `Claude Code-credentials` Keychain item. | `activeClaudeProfileId` | "Make active for Claude…", the auto-switch, adoption of a CLI-side `/login` (`adoptSystemLoginByIdentity` — which also clears byte-identical copies from other profiles), a manual Import/Sync into a profile |
| **Active for Codex** | The account in `$CODEX_HOME/auth.json`. | `activeCodexProfileId` | "Make active for Codex…", the auto-switch, adoption (`adoptCodexLoginByAccountId`), a manual Import/Sync |
| **Active for Grok** | The account in `~/.grok/auth.json`. | `activeGrokProfileId` (#66; journaled + shadowed; nil = no Grok login has ever been applied on this install — the resolver derives from the auth file's identity, else the `grokEmail` stamp, never from focus) | "Make active for Grok…"; with one Grok account it is simply that account |

Two viewing tiers on purpose (Grok/Fable): the popover's ‹ › walk and a tile
click stay ephemeral — persisting a journaled single-shot key on every arrow step
is a cfprefsd footgun, and today's `$activeProfile` observer recreates the
popover. Picking a NAME (inspector row, popover name menu, hotkey) is a deliberate
choice and persists. Once the observer is split (§1.2 #25) the popover's clicked
state can derive from Viewing; until then the two stay separate by design.

Invariants the UI can now state and test:

- **R1.** Only four things change what a CLI uses: a "Make active for
  <provider>" action (every surface routes through
  `ProfileManager.activateProfileDetailed(_:userInitiated: true)`), the
  auto-switch, a login made on the CLI side that the sweep adopts (reported
  once as "Active for Claude changed outside the app: now Lark"), and a **manual
  Import/Sync** into a profile (the wizard included) — which copies the CLI's
  CURRENT login into a profile and claims the pointer, so it is a switching
  action and is labelled and confirmed as one (§2.2). A nil pointer means
  *unknown*, never "the one I am looking at" (`resolveProviderActiveAccounts`
  must stop minting the Claude pointer from focus — §1.2 #20).
- **R2.** Everything else is Viewing: choosing a row in the inspector, a name in
  the popover menu, the "next account" hotkey. Viewing never applies a login,
  never posts `.profileManuallyActivated`, never records a `SwitchEvent`, never
  runs the dead-login gate, never recreates the popover, never starts a fetch,
  never changes the sweep timer.
- **R3.** Wherever an account is shown and it is not the provider's active one,
  both facts are visible: *"Viewing Cedar · Active for Claude: Atlas"* — on the
  inspector header, the selector, the dashboard header and the popover. The
  cyan tile label keeps meaning "Active for <provider>" and nothing else. Grok
  interim: nil pointer with more than one Grok profile → "no active Grok login
  known", never the viewed one.
- **R4.** A dead login can always be viewed and repaired; only "Make active" is
  refused, and the refusal is shown where the user clicked (not only as a
  notification).
- **R5.** Every number on a selector or inspector carries its provenance and age
  through `DashboardFormatting.provenance` / `UsageMeasurement` (own endpoint /
  headers / CLI cache), and every login verdict carries its **kind** and age
  (probed / refreshed / owns login / switched / expiry-only) — two separate
  evidence axes, never collapsed. When the active account's own endpoint refuses
  and the header rescue is rate-limited to once per 60 s, the user reads
  *"headers · 3 m ago"*, never a stale value that looks live (19:35–19:38
  tonight: a three-minute blind window). A suspected account shows its last
  measured value + age, never a live-looking percentage. Provenance is shown per
  measurement GROUP (one line under the gauges), not beside every gauge.
- **R6. Focus is never authority.** No sweep, adoption, gate, probe or trigger
  resolves "the account in use" from `activeProfile`. Today it does (§1.2); the
  viewing paths in this spec ship only after that pass lands.
- **R7.** An automatic switch never moves Viewing while a Settings window is key
  or a sheet (device-code login, import) is presented; the header says "Active
  for Claude: Cedar (changed 12 s ago)" instead.

### 1.2 Seams — landed and in flight (fixes session)

**Landed in #66 (`ead8c54`)**, exactly as requested: `ProfileManager.viewProfile(_:) -> Bool`
(focus-only; `@Published activeProfile` is the change signal), `activeGrokProfileId`
+ `claimActiveGrokOwnership`, `ProfileStore.save/loadActiveGrokProfileId` (journaled +
shadowed), `GrokUsageService.applyProfileCredentials(_:) throws`, the Grok branch in
`activateProfileDetailed` with the expired-and-unrefreshable gate, `needsProviderApply`
reading the live Grok pointer, `isProviderActive` including Grok.

**In flight: `fix/focus-is-never-authority`**, implementing
`docs/specs/ux-revamp-focus-authority.md` — 28 sites verified line by line at
`9dca689`, each classed **switch** (can rewrite a CLI login or fire the
auto-switch: the trigger conditions at `MenuBarManager.swift:1574-1577`,
`:1625-1628`, `:2633-2634`, `:2671-2672`, the single-mode path `:1959-1967`, and
`checkAutoSwitchIfNeeded` itself, which has no owner guard; `deleteProfile`
activating `profiles.first`; the hotkey), **write** (`:2280` — a viewed profile's
refreshed token written into the shared Keychain item when the pointer is nil;
`ProfileManager.swift:497`, `:1434-1437` pointer minted from focus, `:1632-1636`),
**spend** (`:2726` header probe against the viewed account), **mislabel**
(`ClaudeAPIService.getAuthentication` painting the shared login's usage under the
viewed name, `:1778`, `:2594`), **tuning** (the `isActiveAccount` tests), and
**display** (`self.usage = …` for the focused profile — correctly keyed on Viewing,
kept). Plus: the auto-switch Viewing rule (R7), a `.providerOwnerChangedExternally`
notification from the two adoption paths, the wizard claiming ownership after its
sync, and the `$activeProfile` observer split (display-only work on a Viewing
change; popover recreate / timer / sweep only when a pointer changed — the
popover-recreate half is the redesign session's, handed over with the row text).
The suggested pure helper: `providerOwnerId(_:)` = pointer, else the focused
profile only when it is the sole credentialed profile of that provider, else nil.
Split agreed: the hotkey (#26) and the Settings picker (#27) are rewired in stage
1a by this endeavour; everything else in that PR.

`activateProfileDetailed(userInitiated: true)` keeps applying logins AND moving
Viewing onto the new owner. `focusedWithoutApplying` stays as a safety net for
programmatic callers; no UI path reaches it once every viewing path is focus-only.
Noted for later (Codex): activation is profile-scoped, so a legacy MIXED profile
carrying two providers changes both CLIs — a `provider:` parameter would scope
it; profiles are provider-exclusive by construction today, so this is not a
blocker.

### 1.3 Vocabulary (shared strings, `Shared/Models/ProviderActiveSelection.swift`)

| Where | Today | After |
|---|---|---|
| Settings sidebar picker label | "Active Profile" (activates) | "Viewing" (`viewProfile`) — same PR as the label, never a picker named Viewing that switches CLIs |
| Popover name menu (`ProfileSwitcherCompact`) | activates on pick, ✓ = focus | "View account" — `viewProfile`; ✓ = Viewing; a cyan `Cl`/`Cx`/`Gk` mark = Active for that provider (redesign session, B2.1) |
| Manage Profiles / roster badge | "Active" | "Active for Claude" / "…Codex" / "…Grok" |
| Dashboard section header (B2) | "CLAUDE   active: Atlas" + "focused" chip | "CLAUDE · Active: Atlas" + "Viewing" chip; header links to the selector (B2.1) |
| Tile tooltip | "Claude: Atlas 78 % …" | unchanged — it already names the active account |
| Hotkey "Next profile" | activates the next profile in array order (cross-provider!) | "View next account" — within the viewed provider group, in the bar's painted order (`paintedGroupMembers(for:)`, like the popover's ‹ › walk) |
| Switch verb | "Activate" / "Switch" | "Make active for <provider>…" (always with the ellipsis: a confirmation follows) |
| Sync button | "Sync from Claude Code" | "Import the CLI's current login into this profile…" — names the account the CLI holds and who is Active for it |
| Outside change | (silent) | "Active for Claude changed outside the app: now Lark" (one banner per episode) |

---

## 2. Surfaces

### 2.1 Per-provider ACTIVE selectors

What a selector must answer, per provider, in one glance: who is active, how much
headroom it has and how fresh / what kind that number is, who is next (queued vs
ranked) and whether that login is *proven* live (and by what), and how to switch
now — with the cost.

#### Options

**S1 — right-click (or ⌥-click) on each provider's tile opens the selector menu.**
Zero bar width; the "two menu bars" become left-click = view, right-click = select.
Risk: composite/scene-hosted status items on macOS 26/27 deliver *synthesized*
click events (`scene-click-synthesized-center` incident); right-click delivery
through the group button's action is unmeasured, and a selector that sometimes
opens the popover instead is worse than none. → **an accelerator for a later
stage, after a measurement pass**, not the primary surface. (All three reviews.)

**S2a — ONE dedicated selector status item (`⇄`, fixed 24 pt) with a native
`NSMenu` holding three sections: Active for Claude / Codex / Grok.** (recommended;
all three reviews)

```
menu bar:   … [ ▓▓░ Atl ●●●●●●●●● 91→Ced✓ ] [ ▓░ Mar ●×●× →— ] [ Grk ] [ ⇄ ] 🔋 📶 12:41
                    Claude group (existing)     Codex (existing)   Grok  ↑ new, 24 pt fixed, created FIRST
                                                                          so it sits rightmost and
                                                                          survives overflow
click ⇄ →
┌──────────────────────────────────────────────────────────┐
│ ACTIVE FOR CLAUDE                                        │
│   ● Atlas       S 78 %  W 16 %  F 16 %   own · 28 s ago  │  ← owner row (disabled, cyan mark). "headers · 3 m" when rescued;
│                                                          │     purple "last measured 74 % · 12 m" when suspected; "pinned by you"
│   next → Cedar    ✓ probed 12 m ago · headroom 3 m ago   │  ← evidence row: verdict KIND + age, quota age — two axes
│   Switch Claude to next (Cedar)…                         │  ← the common action
│   Switch Claude to                                     ▸ │  ← submenu, ranked order (no rank numbers); ⌥ = "Queue X next"
│   Queue next                                           ▸ │  ← explicit path too (⌥ must not be the only one)
│   Queue: Fjord › Ridge                          Edit…    │
│ ACTIVE FOR CODEX                                         │
│   ● Marlin (dev)     W 95 %  fires at 99 %   own · 1 m   │
│   Resets: 2 available · next expires Sep 9  Redeem…      │  ← §4.1; "unknown" when the payload says null
│   next → —   nobody with headroom (2 of 4 dead)          │  ← red
│   Switch Codex to                                      ▸ │
│   Repair 2 dead Codex logins…                            │  ← opens Accounts › Login on the first
│ ACTIVE FOR GROK                                          │
│   ● Grok        W 12 %   single account                  │
│ ──────────────────────────────────────────────────────── │
│ ⇄ switching Claude → Cedar…                              │  ← only while a switch is in flight (rows disabled)
│ Auto-switch ON · 95 % / 99 %                Active & Auto-switch… │
│ Accounts…                                   Dashboard…   │
└──────────────────────────────────────────────────────────┘

Switch Claude to ▸        (type-select works; rows scroll)
   ● Cedar        S 12  W 70  F 99    ✓ probed 12 m
   ● Fjord        S 40  W 55  F 61    ? expiry only     queued #1
   ● Ridge        S  3  W 20  F 20    ? unverified      queued #2
   ○ Pebble       never measured      ?                  (eligible — the walk accepts unknown)
   ◐ Granite      S 93  W 20  F 20    excluded (free plan)      (disabled)
   ─────
   ▲ Harbor       weekly maxed · resets Mon 09:41                (disabled)
   ▲ Iris         session exhausted · 3 h 10 m                   (disabled)
   × Echo         login dead — Repair…                            (enabled → Accounts › Login)
   ⧉ Beacon       same account as Atlas · re-login needed        (disabled; #64's caption)
```

Dropped since v1: the "View <owner>" rows (Viewing belongs to the inspector /
dashboard), the policy paragraph (one line + a link), rank numbers (order already
says it), and **S2b as a v1 option** (below).

Picking a candidate opens a **confirmation** — **never suppressible** (Codex and
Fable: the deliberate-switch ruling wants the cost visible on every manual switch;
v1's "don't ask again" and its key are dropped):

```
Switch the Claude Code login to Cedar?
Every running Claude Code session re-reads its context on the new account
(≈10–15 % of Cedar's 5-hour window). Cedar: session 12 %, weekly 70 %,
Fable 99 % — login verified 12 m ago (usage probe). Atlas keeps 22 % of its
session until 14:02.
                                          [Cancel]  [Switch now]
```

Mechanics (Fable §2c): `NSAlert.runModal` spins `NSModalPanelRunLoopMode`, and the
sweep timer is a `Timer.scheduledTimer` in `.default` mode
(`MenuBarManager.swift:566-575`, `:983-989`) — an alert left open would stop the
auto-switch clock. Two acceptable fixes, decision D15: (a) schedule the two sweep
timers in `.common` modes (one line each; the fixes session's file; also makes the
sweep run during menu tracking) and keep `NSAlert`; (b) a non-modal `NSPanel`
confirmation. **(a) is requested**; (b) is the fallback if (a) is refused. Either
way the app is activated first (`NSRunningApplication.current.activate(options:
[.activateIgnoringOtherApps])`, the `bringWindowToForeground` lesson) and the
activation policy is never flipped. The confirmation runs synchronously from the
menu action; outcome alerts after the `await` re-activate the app first.

Outcomes are shown in place: `.activated` → the menu re-reads on next open and the
tile label moves; `.credentialsRefused` / `.focusedWithoutApplying` → "Not
switched — Cedar's Claude login is dead. Repair it in Accounts › Login" with a
button that opens the inspector there; `.switchInFlight` → "Another switch is in
progress; try again in a moment"; `.alreadyActive` cannot happen (the owner row is
disabled). #63's `CodexActivationOffer` ("Make it the active Codex account now?"
after an in-app login) routes through the same confirmation text (stage 2c; the
file is this endeavour's now).

Pixel budget: item **24 × 22 pt, fixed length** (SF `arrow.triangle.2.circlepath`;
tinted red when any provider has no executable candidate or its active login is
dead, purple when an active account is suspected/blind, amber while cfprefsd is
degraded); menu ≈ 340 pt wide, ≤ 22 rows + submenus (~85 items total, built
eagerly in the parent's `menuNeedsUpdate`, fine). `autoenablesItems = false`;
`isAlternate` ⌥ rows immediately follow their primary with an empty
`keyEquivalent` and `.option` mask. The menu is a pure map from a precomputed
`ProviderActiveSelection` snapshot to `NSMenuItem`s — no ranking, no Keychain, no
roster walk in the delegate; the snapshot is built once per menu open (and once
per paint by the dashboard) from `makeFleetSummaryContext()` (made internal — one
word — in stage 1b, agreed), never cached across sweeps.

**Placement (measured 2026-09-03 late; creation order is NOT the mechanism).**
The item is created ONCE in `MenuBarManager.setup()`, after the provider groups
(#88). What the deployed bar showed: with the selector created first the groups
came up claude < grok < codex < ⇄; a ≥ 2-minute quit changed nothing; fixed-length
placeholder group lengths (#83) changed nothing; with the selector created LAST
(#88) the first probe read `codex<grok<claude ok` with the selector BETWEEN grok
and claude, and 28 s later `grok<codex<claude` with grok/codex relocated ~430 pt
left while claude and the selector stayed. Conclusion: the host RE-INSERTS group
items after later paints (their length changes), so no creation sequence
guarantees a slot for anything — the selector's slot is not guaranteed by
creation order, the exposure probe's `order=` field is the truth, and the fix is
on the paint side (fixed final widths / a deferred first paint — the redesign
session owns it). #88 stays as harmless. It is **owned by `MenuBarManager`**, never placed in
`StatusBarUIManager`'s dictionaries (whose `cleanup()` removes every item it owns on
each group rebuild). `MenuBarManager.setup()` re-entry (AppDelegate's delayed
retry, post-wizard) calls `MenuBarManager.cleanup()` — that path must **keep** the
selector (guarded creation) so re-entry neither duplicates nor recreates it. **Named, since 2026-09-04:** `autosaveName = "cuw.selector"` with `NSStatusItem
Preferred Position cuw.selector = 50` seeded before creation ONLY when absent (a
slot the owner dragged it to is respected), alongside the redesign's per-ROLE
group names `cuw.group.<provider>` at 100/200/300 — the deployed host ignored
creation order entirely, and a remembered slot is the one documented handle. The
2026-07-17 failure came from rotating per-TILE names, not from naming as such;
`behavior = []` keeps the item un-draggable-out. (Superseded: "no autosaveName".) Never torn down (every recreate leaks a
CAContext). The on/off setting toggles `isVisible` on the one item — a rare user
action, never programmatic cycling (the StormWatchdog cycle is the falsified cure).
Agreed with the redesign session: fixed 24 pt + system spacing goes into the C0/C1
exposure budget; the item is exposed read-only as
`MenuBarManager.activeSelectorStatusItem` and their next stage-C PR adds an
auxiliary-items seam so a hidden selector shows up in the same `Menu bar exposure`
log line. One measurement pass on the scene-hosted bar before the item is called
done.

**S2b — three selector items, one per provider.** Dropped from v1 (Codex, Fable):
54 extra points that repeat what the fleet tiles show, three menus that hide the
one-click overview, and a runtime item-count change (the CAContext leak) unless
gated on relaunch. Revisit only if the owner asks after living with S2a.

**S3 — no new item: the selector as a card inside the dashboard (B2) and a
Settings page.** Zero bar cost, but it puts the switching control *inside* the
viewing surface — the conflation the owner asked to end — and a popover closes on
the outside click a confirmation needs. → Built as a **mirror** (Settings › Active
& Auto-switch; B2.1's header link), never as the only selector.

**Decision: S2a**, S3 as mirrors, S1 measured later, S2b dropped.

#### What the selector reads (pure model, `ProviderActiveSelection`)

```swift
struct ProviderActiveSelection: Hashable {           // one per provider
    var provider: Profile.ProviderKind
    var owner: OwnerRow?                             // nil = no active login known for this provider
    var viewing: UUID?                               // the Viewing account when it is in this provider
    var next: NextCandidate?                         // stage A's type: queued/ranked/blocked head, ✓ ? ×
    var candidates: [CandidateRow]                   // ranked; eligible first, blocked after a separator
    var queue: [QueueEntry]                          // B1's type, this provider's slice
    var counts: FleetCounts.Provider                 // §3
    var autoSwitch: AutoSwitchPolicy                 // enabled, session/weekly thresholds
    var alert: FleetAlert?                           // noCandidate / deadLogins / degraded
    var isSwitching: Bool
    var resets: CodexResetSummary?                   // §4.1, Codex only: count or unknown, next expiry when fetched
}
struct OwnerRow: Hashable { id, name, gauges: [WindowGauge], measurement: UsageMeasurement?, suspected: SuspectedCaveat?, etaToThreshold, isManuallyPinned: Bool, blindFor: TimeInterval? }
struct CandidateRow: Hashable { id, name, readiness: AccountReadiness, gauges, measurement: UsageMeasurement?, verdict: NextCandidate.Verdict, verdictKind: PreflightVerdict.Kind?, verdictAt, rank: Rank /* ranked | queued(n) | blocked(reason) | duplicate(of:, needsRelogin) | excluded(reason) */, repair: RepairAction? }

struct Inputs {                                      // same shape as DashboardSnapshot.Inputs so the
    var profiles: [Profile]; var activeIds: Set<UUID>; var focusedId: UUID?           // dashboard builds it inside its own
    var paintedOrder: [Profile.ProviderKind: [UUID]]; var context: FleetSummaryContext  // build once per paint, no second
    var queue: [UUID]; var duplicateGroups: [[UUID]]; var manuallyPinned: Set<UUID>     // observable (redesign session's ask)
    var needsRelogin: Set<UUID>                                                        // #64's profilesNeedingAccountRelogin
}
static func build(_ inputs: Inputs, ranking: (Profile.ProviderKind) -> [UUID]) -> [ProviderActiveSelection]
```

Ranking reuses `MenuBarManager.rankAutoSwitchCandidates` and
`predictedNextCandidate(for:)` (side-effect free) — never a second resolver.
Readiness reuses `AccountReadiness.classify`. Gauges reuse
`DashboardSnapshot.gauges(for:)`. `manuallyPinned` is
`MenuBarManager.autoSwitchedProfileIds` exposed read-only (fixes session; small).
The menu builder (`MenuBar/ActiveSelectorMenu.swift`) maps rows to `NSMenuItem`s;
the item-model → titles/enabled flags mapping is pure and tested.

### 2.2 The profile INSPECTOR / browser (Viewing)

What it must do: show *any* account's numbers, provenance and age, reset times,
readiness and dead-login state, identity and history; perform logins, sync,
import, removal; edit that account's eligibility, alerts and tile label; rename
and delete — and never change what a CLI uses except through the two explicit,
confirmed switching actions ("Make active for <provider>…", Import).

#### Options

**I1 — the Accounts section of the existing Settings window, as master-detail:
the sidebar becomes the roster.** (recommended; all three reviews)

```
┌ Settings ──────────────────────────────────────────────────────────────── 820 × 750, resizable (min 760 × 600) ┐
│ ● ● ●                                                                                                          │
│ ┌ ACCOUNTS ─────────────── 250 ┐ ┌ Viewing  Cedar                                                   Claude ┐ │
│ │ ⌕ filter                      │ │ not active · Active for Claude: Atlas                                      │ │
│ │ CLAUDE 18 profiles · 17 accts │ │ [Make active for Claude…]  [Queue next]  [Open in dashboard]              │ │
│ │   ●4 ◐2 ○1 ▲10 ×1 · ⧉2       │ │ ─ Overview ─ Login ─ Alerts ─ Monitoring ─                                 │ │
│ │ ● Atlas a…@example   78  Cl   │ │ Session  ▓▓░░░░░░░░ 12 %   resets 4 h 02 m                                 │ │
│ │ ● Cedar    jor…@…    12  ✓    │ │ Weekly   ▓▓▓▓▓▓▓░░░ 70 %   resets Mon 09:41                                │ │
│ │ ● Fjord    b…@example  40  Q1   │ │ Fable    ▓▓▓▓▓▓▓▓▓▓ 99 %   at the 99 % threshold                           │ │
│ │ ● Ridge    …          3  Q2   │ │ measured 3 m ago · own endpoint · not stale                                │ │
│ │ ○ Pebble   …         —        │ │ Readiness  ready · login verified 12 m (usage probe)                       │ │
│ │ ◐ Granite …          93  free │ │ Identity   jor…@… · account …0000 · org …00                                │ │
│ │ ▲ Harbor   …         W! Mon   │ │ Fetch      every sweep · no backoff                                        │ │
│ │ ▲ Iris     …         S! 3h10m │ │ History    active 2×/24 h · last switch 2 h ago (auto, ← Fjord)            │ │
│ │ × Echo     …         dead     │ │                                                                            │ │
│ │ ⧉ Beacon   a…@example = Atlas │ │                                                                            │ │
│ │ …                             │ │                                                                            │ │
│ │ CODEX 4 · ●1 ◐1 ×2            │ │                                                                            │ │
│ │ ● Marlin (dev)       95  Cx   │ │                                                                            │ │
│ │ × Juniper (dev)      dead     │ │                                                                            │ │
│ │ GROK 1 · ●1                   │ │                                                                            │ │
│ │ ● Grok               12  Gk   │ │                                                                            │ │
│ │ + Add account…                │ │                                                                            │ │
│ ├───────────────────────────────┤ │                                                                            │ │
│ │ Active & Auto-switch          │ │                                                                            │ │
│ │ Alerts                        │ │                                                                            │ │
│ │ Display                       │ │                                                                            │ │
│ │ Advanced                      │ │                                                                            │ │
│ │ About                  [Quit] │ │                                                                            │ │
│ └───────────────────────────────┘ └────────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Window:** 820 × 750 (Codex 800–820, Fable 800, Grok 840 → 820), `.resizable`
  added to the style mask (today fixed 720: `SettingsView.swift:246` and
  `Constants.WindowSizes.settingsWindow`), minimum 760 × 600; the pages hard-framed
  at 520 (`AboutView`, `ShortcutsSettingsView`, `AppSettingsView`) and the 520 pt
  Codex sheets keep fitting. Roster 250, detail ≥ 560. App-level sections are
  **text rows under the roster** (System Settings pattern); Quit is a button, not a
  destination.
- **Roster (sidebar):** grouped by provider with the counts strip in the header
  (§3, profiles vs distinct accounts stated), one 20 pt row per account: readiness
  glyph, name, email (dimmed, truncated), keyed percentage (session for Claude,
  weekly for Codex/Grok; `W!`/`S!` when maxed, `—` when never measured), and ONE
  badge: `Cl/Cx/Gk` cyan = Active for that provider, `Q1` = queue position,
  `✓/?/×` = candidate verdict when it is the next, `free`/`off` = excluded, `= Atlas`
  = duplicate (+ "re-login needed" when #64 flags it). Filter field (name, email,
  state words). Selecting a row = Viewing (`viewProfile`). Sorted like the bar
  (soonest weekly reset first) with a toggle for alphabetical. 40 rows scroll.
  Type-ahead selects.
- **Detail, tabs:**
  - *Overview* — the gauges with threshold ticks and reset countdowns; ONE
    provenance + age line; readiness with its evidence (verdict kind, when);
    identity (email, account-uuid suffix, org, Codex home path); fetch state
    (interval, backoff / throttled-until / suspected caveat / blind-for);
    manual pin; the account's own switch history; "same account as" caption;
    Codex: the reset summary (§4.1) with an on-demand "Details" fetch.
  - *Login* — **extracted components that take a stable `profileId`** (stage 2c),
    not the current pages whole: today `CLIAccountView` / `CodexAccountView` read
    the global `activeProfile` at a dozen sites, and the Claude sync captures one
    id then updates *whichever profile is viewed when the async completes*
    (`CLIAccountView.swift:273-300`) — that must be fixed before roster selection
    can change mid-sync. Provider exclusivity reproduced (`isProviderLocked`; a
    credential-less profile offers both). Same buttons and sheets: **Log in a new
    Codex account…** (device code; the sheet keeps the profile it opened for and
    survives row changes), Import from another home…, Remove, masked token +
    expiry, last synced, the dead-login banner with the exact repair, the hazard
    note; #63's post-login "Make it active" offer routes through the switch
    confirmation. **Sync is relabelled and gated**: "Import the CLI's current
    login into this profile…" shows the account the CLI currently holds
    (identity stamp / `~/.claude.json` cache, or `auth.json` `account_id`) and
    who is Active for it; enabled when the viewed profile has no account yet or
    the CLI's login is that profile's own account (a repair); a confirmation
    naming both accounts otherwise (#64 already refuses a login another profile
    holds; this is the remaining "copy the owner's login into the row I happen
    to be viewing" path — the 2026-09-03 contamination shape). A dead non-owner's
    repair is the isolated-home login / Import, offered first. Grok gets a page
    body of the same shape (new, small).
  - *Alerts* — "Use fleet defaults" or the account's own thresholds and sound.
  - *Monitoring* — refresh interval with the honest caption "one sweep timer;
    the interval of the account being viewed drives it" (today's behaviour,
    `MenuBarManager.swift:983`), show on the menu bar, tile label (first UI for
    `menuBarLabel`, audit M3; uniqueness check against the roster), and a
    read-only line "Auto-switch eligibility: on — change in Active &
    Auto-switch" (one primary location, Codex).
  - Footer: Rename, Delete (a delete now views the first profile, never
    activates it).
- **Routing:** `.settingsSectionRequested` becomes a typed
  `SettingsRoute(section, profileId?, tab?)` (Codex, Fable) — today it carries
  only a section, so "Repair…" on dashboard row X would open the Login page of
  whichever profile is viewed. Old string payloads keep decoding (§5.4). Default
  section `.appearance` → `.accounts`. The `EmptyView` Settings scene stays
  (orphan path O3).

**I2 — a separate "Accounts" window.** A second window lifecycle in an app that
has already fought orphaned windows and activation-policy storms, and every repair
deep link learns a second target. → Not now; I1's Accounts section can be lifted
into its own window later without changing its content.

**I3 — the dashboard's account detail (B2's `.account` route) as the inspector.**
380 pt wide, closes on an outside click — a device-code login takes minutes and a
browser hop. → No; the dashboard row links to I1 ("Open in Accounts").

**Decision: I1, at 820 pt resizable, with profile-id-scoped login components and
typed routes.**

---

## 3. Counts — one model, four places

`Shared/Models/FleetCounts.swift` (pure, built on `AccountReadiness.classify` and
`ReadinessThresholds` — never a second classification; the redesign session
exposes the readiness map `DashboardSnapshot.build` already computes so there is
one classification per paint):

```swift
struct FleetCounts: Hashable {
    struct Provider: Hashable {
        var provider: Profile.ProviderKind
        var profiles: Int                          // rows
        var distinctAccounts: Int                  // dedup by claudeAccountUUID / codexAccountId (unstamped = its own); Grok: no stamp → = profiles
        var byReadiness: [AccountReadiness: Int]   // ready · low · unknown · suspected · exhausted · excluded · dead — first-match partition, no double count
        var excludedByToggle: Int; var freePlan: Int   // the two meanings of `excluded` (one is still manual capacity, one is not)
        var stale: Int                             // orthogonal flag
        var duplicateProfiles: Int; var duplicateGroups: [[UUID]]   // orthogonal; shown after a separator, never summed into the strip
        var needsRelogin: Int                      // #64's contaminated / duplicate non-owner — a human-action state outside the taxonomy
        var queued: Int; var onBar: Int; var pinned: Int
        var measuredHeadroom: Int { ready + low }               // measured and has headroom
        var autoSwitchEligible: Int { ready + low + unknown }   // exactly what the walk accepts (unknown is a legal target)
        var loginLive: Int                         // distinct accounts whose login is not dead (excluded accounts ARE live — Codex)
        var capacityRemaining: Double              // Σ (100 − weekly) over loginLive DISTINCT accounts, measured only
    }
    var providers: [Provider]; var profiles: Int; var distinctAccounts: Int; var dead: Int; var duplicateProfiles: Int
    static func build(profiles:, readiness: [UUID: AccountReadiness], stale: Set<UUID>, duplicateGroups: [[UUID]], needsRelogin: Set<UUID>, queue: [UUID], pinned: Set<UUID>, now: Date) -> FleetCounts
    func strip(_ provider) -> String        // "18 · ●4 ◐2 ○1 ▲10 ×1 · ⧉2"  (bar glyphs; ⧉ after a separator — it is not part of the sum)
    func sentence(_ provider) -> String     // "18 Claude profiles, 17 accounts: 4 ready, 2 low, 1 unmeasured, 10 exhausted, 1 dead · 2 duplicate rows · 7 eligible now"
}
```

Stated for the owner: the bar's `fleetCounts` layout drops unknown / suspected /
excluded by design (redesign spec §2.3), so the inspector histogram and the bar
disagree on totals; the inspector says "18 profiles · 17 accounts" so nobody sums
the glyphs. Codex duplicate groups are derived from `codexAccountId` inside
`FleetCounts` (only `duplicateClaudeAccountGroups` is published today); Grok has no
persisted account id, so its ⧉ is 0 and says so.

Where it shows: inspector group headers (strip); selector menu (sentence, as a
disabled row under the owner whenever anything is dead, duplicated or has no
candidate); selector tooltip / accessibility label ("Active: Claude Atlas 78 % ·
Codex Marlin 95 % · Grok 12 % — 23 profiles / 22 accounts, 3 dead, 2
duplicates"); dashboard header (B2.1 consumes the same model); the bar unchanged.

---

## 4. Dashboard depth beyond B2 (stage 4, additive)

B2 already ships: stacked provider sections, active card with gauges + thresholds
+ provenance + suspected caveat + ETA, next line with verdict age, queue slice,
two-line roster rows with chips and repair links, account detail, row context menu
(Make active… two-step, Queue next, Repair), five recent switches collapsed; C0/C1
add the hidden-provider banner. Stage 4 adds fields to `DashboardSnapshot` (never
reshapes existing types; every number is a `UsageMeasurement`) and one view file
the redesign session embeds. Order (Grok/Codex: the timeline is the planning view):

| # | Addition | Model (mine) | Why |
|---|---|---|---|
| 1 | **Reset timeline** — the next 7 days as a strip with a marker per DISTINCT account at its weekly (and Fable) reset, labelled with the headroom that returns | `FleetInsights.resetTimeline` | the only planning view for "when does capacity come back" |
| 2 | **Blind spots** — per provider-active account: seconds since the last OWN measurement, provenance of the shown number, header-rescue count in the last hour, backoff state | `FleetInsights.blindness` | tonight's 3-minute blind window |
| 3 | **Drift banner** — the CLI's live identity ≠ the provider pointer, and the "changed outside the app" episode | `FleetInsights.drift` (from `.providerOwnerChangedExternally`) | adoption repairs it silently; the user should see that it happened |
| 4 | **Switch log** — the full 30-entry ring with provider filter, trigger (auto / manual / queued; legacy "focus-only" rows labelled as legacy — R2 says viewing never records one), reason, the outgoing account's headroom at the time | `FleetInsights.switchLog` | forensics without `defaults read` |
| 5 | **Burn rate** — pp/min from `measuredSessionHistory_v1` with the last four samples as a sparkline | `FleetInsights.burn` | why an account is projected to cross, not just when |
| 6 | **Rate-limit incidents** — tripwire events, affirmed / inferred stamps, header-probe 429s, per account, last 24 h (in-memory ring, 100; a new buffer in `MenuBarManager`, seam requested with 4a) | `FleetInsights.incidents` | the unified log keeps ~12 h |
| 7 | **Filters** — readiness, provenance, stale > N min, queued only, provider | `DashboardFilter` | 40 rows need a filter |
| 8 | **Capacity remaining** — §3's deduped number, per provider | `FleetCounts` | one planning number |
| 9 | **"Why not the others"** — per blocked candidate: the block's evidence and age in one place (Fable) | from `CandidateRow.rank` | trust before a manual switch |

Stage 4 ships as 4a (models + persistence) and 4b (presentation).

### 4.1 Codex usage limit resets (owner ask; facts verified 2026-09-03)

Official name: **"usage limit resets"** (user copy) / **rate limit reset credits**
(wire vocabulary) — "bank" is informal. Evidence and endpoints:
`docs/research/2026-09-03-codex-bank-resets-local-evidence.md` (codex source +
read-only live probes on all five local Codex homes). What matters for the UI:

- **Count** is already in the payload the widget fetches: `GET /wham/usage` →
  top-level `rate_limit_reset_credits`, **`null` when the account has none** —
  indistinguishable from zero, so the UI shows "none / unknown", never "0" with
  confidence; else `{ available_count }`.
- **Expiry / detail** only from `GET /wham/rate-limit-reset-credits` →
  `{ available_count, credits: [{ id, reset_type, status, granted_at, expires_at
  (RFC 3339 or null = never), title, description }], total_earned_count, … }`.
  Rate-limited hard per IP (3 of 5 probes in one burst got 429): **fetched on
  demand only** (inspector Overview open, explicit "Details"), never on the sweep;
  a 429 reads as "unknown", never "none"; cached ≥ 10 min.
- **Redeem**: `POST /wham/rate-limit-reset-credits/consume` `{ redeem_request_id:
  <uuid>, credit_id? }` → `{ code: reset | nothing_to_reset | no_credit |
  already_redeemed, windows_reset }`. Never send the `luna-reserve` header.
- Caveat: every local account holds zero credits right now; non-null shapes rest
  on the Rust types + fixtures. "Redeem" ships source-verified and gets its first
  live test when an account earns a credit.

Service seams (fixes session, in flight; contract as of 2026-09-03 ~21:00):
`ClaudeUsage.codexResetCreditsAvailable: Int?` + `codexResetCreditsMeasuredAt:
Date?` (parsed in the existing usage parse; nil = unknown/none);
`CodexUsageService.fetchResetCredits(for:force:) async throws -> CodexResetCredits
{ availableCount, credits: [CodexResetCredit { id, resetType, status, grantedAt,
expiresAt (nil = never), title, description }], totalEarnedCount?,
immediateResetPurchaseEligible?, fetchedAt }` (on demand, cached; 429 →
`.resetCreditsUnavailable(retryAfter:)` = "unknown");
`activateReset(for:creditId:evidence: CodexResetActivationEvidence { measuredAtLimit,
measuredAt, source }) async throws -> CodexResetActivationOutcome { reset(windowsReset:
Int), nothingToReset, noCredit, alreadyRedeemed, unknown(code:) }` — `windows_reset`
is an INTEGER count of cleared windows (2 = weekly + 5 h), rendered "Reset applied
· 2 windows cleared".

Copy rules from the companion web research
(`docs/research/2026-09-03-codex-bank-resets-web-research.md`): credits are
GRANTS ("earned reset", a `@friend` fixture), not a published allotment — say
"Usage limit resets: N available", never imply a schedule or refill date; show
`expires_at` as-is and "never expires" when null, no assumed countdown; hide the
datum for API-key Codex profiles (ChatGPT-auth only); `nothing_to_reset` does not
spend a credit (a mis-timed attempt is not catastrophic — the gate and the
confirmation stay anyway); the action is exactly the CLI's `/usage → Redeem`, so
the confirmation reads "Use one usage limit reset for <account> (same as the CLI's
Redeem)" and it is strictly user-initiated, never automatic; after a redeem the UI
mirrors the CLI's two states, "Resetting your usage…" then "Usage reset".

Surface and gate (this endeavour, stage 4.1): shown in the inspector Overview for
Codex rows ("Usage limit resets: 2 available · next expires Sep 9 · Details"), one
line under the owner in the ⇄ Codex section, a roster badge when > 0, the
dashboard's Codex active card (B2.1 consumes the field). **"Use a usage limit
reset…"** (selector row, inspector button, dashboard row menu) is enabled only when
the account is MEASURED at its limit (weekly ≥ threshold or a server-affirmed
stamp — never on inference, never with headroom: a reset must never be spent for
nothing), opens the confirmation above naming the credit, its expiry and what is
reset, and shows the outcome in place with its provenance. If `fetchResetCredits`
is unknown the action is disabled with "couldn't read the credits (rate-limited);
try again in a minute".

---

## 5. Settings restructure

### 5.1 Today → after

| Today (tab) | Contents | After |
|---|---|---|
| App › Manage Profiles | roster + create; multi-profile display config; auto-switch enable/thresholds/queue/eligibility | split: roster → **Accounts**; display config → **Display**; auto-switch → **Active & Auto-switch** |
| App › Popover | time display, time format | **Display › Popover** |
| App › App Settings | launch at login | **Advanced** |
| App › Shortcuts | four recorders | **Advanced › Shortcuts** |
| App › About | about | **About** (text row) |
| Profile › General | refresh interval; notifications | refresh → **Accounts › Monitoring**; notifications → **Alerts** (fleet defaults) + **Accounts › Alerts** (override) |
| Profile › Appearance | single-account icon config; locked in multi mode | **Display › Single-account bar** (shown only when display mode is single; keys kept) |
| Profile › Credentials › CLI Account / Codex Account | sync, login, import, remove, token info | **Accounts › Login** |
| (sidebar) "Active Profile" picker | activates | "Viewing" in stage 1a (view-only); gone once the roster exists |

New top level (text rows under the roster): **Accounts · Active & Auto-switch ·
Alerts · Display · Advanced · About**, plus a Quit button.

**Active & Auto-switch**: the three "Active for" cards (owner, headroom +
provenance/age, next + verdict kind, manual pin, `Switch…` → same confirmation),
the enable toggle, the two thresholds, the queue editor (today's, with a
**provider filter**), the eligibility list (the ONE primary location), and the two
rules as text. **Alerts**: fleet default thresholds + sound (new key), "Use fleet
defaults for all / selected" bulk action, the list of always-on system alerts with
their one-per-episode rule stated, "Test notification". **Display**: display mode,
the multi-profile config (icon style, week, label, monochrome, time/pace markers,
pace coloring, **Menu bar layout**, **Click opens** — the redesign session's two
pickers, same bindings), the ⇄ selector on/off, the popover time settings, the
single-account icon config when relevant. **Advanced**: launch at login,
shortcuts, diagnostics (preferences-degraded state and the last write check,
"Re-assert settings now", "Open log", debug API logging — a key with no UI today),
"Forget dead-login flags for…".

### 5.2 Key migration map — nothing renamed, nothing lost

| Key | Owner | Kept | Read/written after | UI after |
|---|---|---|---|---|
| `profiles_v3` | ProfileStore | yes | unchanged | Accounts |
| ↳ per-profile `iconConfig` | Profile | yes | unchanged | Display › Single-account bar |
| ↳ `refreshInterval` | Profile | yes | unchanged | Accounts › Monitoring (one-timer caption) |
| ↳ `checkOverageLimitEnabled` | Profile | yes (no UI today, none after) | unchanged | — |
| ↳ `notificationSettings` | Profile | yes | unchanged; a profile whose **new** `usesFleetAlertDefaults == true` reads `fleetAlertDefaults_v1` instead. Migration: `decodeIfPresent`; absent → `true` iff `notificationSettings == NotificationSettings()` (untouched defaults follow the fleet, customized ones keep their override); new profiles `true` | Accounts › Alerts |
| ↳ `isSelectedForDisplay` | Profile | yes | unchanged | Accounts › Monitoring ("Show on the menu bar") |
| ↳ `menuBarLabel` | Profile | yes | unchanged (first UI for it: audit M3) | Accounts › Monitoring |
| ↳ `includeInAutoSwitch` | Profile | yes | unchanged | Active & Auto-switch (primary); read-only line on the account |
| ↳ identity/metadata fields | Profile | yes | unchanged | Accounts › Overview (read-only) |
| `activeProfileId` | ProfileStore | yes | = Viewing; written by `viewProfile` and by a landed switch | roster selection |
| `activeClaudeProfileId`, `activeCodexProfileId`, `activeGrokProfileId` (#66) | ProfileStore | yes | unchanged | Active & Auto-switch, selector |
| `profileDisplayMode` | ProfileStore | yes | unchanged | Display |
| `multiProfileDisplayConfig` (incl. `barLayout`, `clickSurface`) | ProfileStore | yes | unchanged | Display |
| `credentialsMigratedToKeychain`, `credentialsRepairedToKeychain_v2`, `keychainItemsRebuiltViaSecurityTool_v3` | ProfileStore | yes | migration flags, untouched | — |
| `hasCompletedSetup`, `hasShownWizardOnce` | SharedDataStore | yes | untouched | — |
| `debugAPILoggingEnabled` | SharedDataStore | yes | unchanged | Advanced › Diagnostics (first UI) |
| `shortcutTogglePopover`, `shortcutRefresh`, `shortcutOpenSettings`, `shortcutNextProfile` | SharedDataStore | yes | unchanged; `nextProfile` now means "view next" | Advanced › Shortcuts |
| `autoSwitchProfileEnabled`, `autoSwitchThreshold`, `autoSwitchWeeklyThreshold` | SharedDataStore | yes | unchanged | Active & Auto-switch |
| `autoSwitchQueue` | SharedDataStore | yes | unchanged (provider filter is view-side) | Active & Auto-switch, selector, dashboard |
| `popoverShowRemainingTime` (legacy) → `popoverTimeDisplay`, `timeFormatPreference` | SharedDataStore | yes | unchanged (existing one-time migration kept) | Display › Popover |
| `switchHistory_v1`, `measuredSessionHistory_v1` | SharedDataStore | yes | unchanged; read by stage 4 | Dashboard |
| `claudeDeadLogins_v1`, `codexDeadLogins_v1`, `grokDeadLogins_v1`, **`claudeContaminatedLogins_v1`** (#64) | services | yes | unchanged (raw `UserDefaults.standard` writes for Claude/Grok/contaminated; the Codex one honours the test suite — journal routing and the test-suite fix are the fixes session's open item; the registry does not fix it) | Accounts › Login banner; Advanced "forget" |
| `sentNotifications` | NotificationManager | yes | unchanged (name-keyed; §11) | — |
| `codexAutoImported_v1`, `grokAutoImported_v1`, `grokDisplayBackfill_v1` | ProfileManager | yes | untouched | — |
| `legacyBundleDefaultsMigrated_v1` | MigrationService | yes | untouched | — |
| `menuBarLayoutDefault_v1` | MenuBarManager | yes (new 2026-09-04) | one-time flag: an untouched `multiProfileDisplayConfig` (legacy layout, no click surface) is moved to `barLayout = fleetDots` once — the owner's decision-card pick; the pickers stay the user's afterwards | — |
| `menuBarIconConfiguration`, `menuBarIconStyle`, `monochromeMode` (legacy single-mode) | MenuBarIconConfiguration | yes | untouched (`load()` is live) | Display › Single-account bar |
| `claudeUsageData`, `notificationsEnabled`, `refreshInterval` (app-level; only the unused `UserDefaults.refreshInterval` KVO extension reads it), `apiUsageData`, `apiTrackingEnabled`, `apiSessionKey`, `apiOrganizationId`, `showIconNames`, `showNextSessionTime`, `sessionIconEnabled/Style/Order`, `weekIconEnabled/Style/Order`, `weekDisplayMode`, `apiIconEnabled/Style/Order`, `apiDisplayMode` | `Constants.UserDefaultsKeys` | yes | registered as **legacy, unread** (tombstoned, never deleted) | — |
| `debugTileLayout`, **`debugGroupExposure`** (#65), `NSQuitAlwaysKeepsWindows` | misc | yes | untouched | — |
| `autoSwitchCustomOrder`, `autoSwitchCustomOrderEnabled` | on disk only (no code) | left alone | — | — |
| `cuwSlotPinsVersion` | on disk only (2026-07-17 slot-pinning experiment, never merged) | left alone, registered legacy-unread (3d) | — | — |
| **`fleetAlertDefaults_v1`** | SharedDataStore | **new**, journaled + shadowed | `NotificationSettings` JSON; seeded from `NotificationSettings()` — or, when every profile's settings are identical, promoted from them; never from whichever row is viewed | Alerts |
| **`activeSelectorItem_v1`** | SharedDataStore | **new**, journaled | `{ enabled: Bool }`; default enabled; toggles `isVisible` | Display |
| **`codexDaemonRestartOnSwitch_v1`** | SharedDataStore | **new**, journaled | `Bool`; default false; after a Codex switch the widget may restart the Codex daemon when no interactive session is attached (`docs/specs/codex-daemon-awareness.md`) | Advanced |

Dropped since v1: `activeSelectorConfirm_v1` (confirmation is not suppressible),
`settingsLayout_v2` (no two-tree flag; §5.5), the per-provider selector mode.

A `SettingsKeyRegistry` is added in stage 3c as the **source of truth**: each
store/service exposes `static let registeredKeys: [RegisteredKey]` (key, status ∈
live / legacy-unread / migration-flag, since) and the registry aggregates them; a
test asserts every key on disk in a fixture plist is registered and every *live*
key has a reader in the store that owns it — the "no key lost" check the owner
asked for. New keys go through `PreferenceWriteJournal` (its `Owner` enum gains
the cases it needs) and the last-known-good shadow. Fleet-vs-override alert
resolution lives in one `Profile.effectiveNotificationSettings(fleet:)` used by
the sweep's per-profile notify path (`MenuBarManager.swift:1562-1566`) and by the
legacy `NotificationManager.checkAndNotify(usage:)` that today reads the VIEWED
profile's settings (`NotificationManager.swift:33, 258-267`; re-route requested
with stage 3b).

### 5.3 What is removed, and where its information lives

| Removed | Lives now |
|---|---|
| "Active Profile" picker in the sidebar (activating) | roster row = Viewing; switching only via "Make active for…" |
| Profile › General page | refresh interval → Accounts › Monitoring; notifications → Alerts / Accounts › Alerts |
| Profile › Appearance page | Display › Single-account bar (hidden in multi mode instead of "locked") |
| Manage Profiles' "Activate" button | "Make active for <provider>…" on the inspector header, with confirmation |
| Popover menu's activate-on-pick | View-on-pick; the switch lives in the selector and the dashboard's "Make active…" |
| Hotkey "next profile" switching CLIs | "view next account" within the provider, painted order (audit M7) |
| Delete → activate first profile | Delete → view first profile |
| "Sync from Claude Code" as an unlabelled copy | "Import the CLI's current login into this profile…", named and gated |
| #63's post-login "Make it active now?" without a cost sentence | the same switch confirmation |

Nothing in the model or the sweep is deleted; every action that existed is
reachable from the inspector or the selector.

### 5.4 Routes and aliases (deep links keep resolving)

| Old raw value (posted by the dashboard, notifications) | Resolves to |
|---|---|
| `manageProfiles` | `SettingsRoute(.accounts)` |
| `cliAccount`, `codexAccount` | `SettingsRoute(.accounts, tab: .login)` for the viewed profile — the dashboard passes `profileId` once B2.1 adopts the typed route |
| `general` | `.accounts`, tab `.monitoring` |
| `appearance`, `popover` | `.display` |
| `appSettings`, `shortcuts` | `.advanced` |
| `about` | `.about` |

`SettingsRoute` decodes both the old string payload and the typed object; the
handler selects section, profile (via `viewProfile`) and tab.

### 5.5 Rollout

No two-tree flag. Stage 2a adds **Accounts** as a new sidebar entry beside the
old pages (which keep working untouched); stages 3a–3c add the other new pages
the same way; stage 3d deletes the old pages after the owner has used the new
ones for a few days.

---

## 6. The interaction model, end to end

| The user… | Happens | Never happens |
|---|---|---|
| clicks a provider tile / steps ‹ › in the popover | ephemeral viewing (`clickedProfileId`); the header says *Viewing X · Active for Claude: Y* when they differ | a switch; a persisted write; a popover recreate |
| picks a name in the popover menu / a roster row / presses ⌘-next | Viewing moves (`viewProfile`); Settings and the popover follow; no fetch, no timer change | login applied, `.profileManuallyActivated`, `SwitchEvent`, dead-login notice |
| views a dead profile | the inspector opens with the red Login banner and the exact repair (isolated-home login / Import first) | a refusal notice; an Import button that would copy the owner's login into it silently |
| chooses "Make active for Claude…" (selector, inspector header, dashboard row, Active page, post-login offer) | confirmation with cost + candidate evidence → `activateProfileDetailed(userInitiated: true)` → the outcome shown in place (app activated first); Viewing moves onto the new owner on success | a silent no-op; a switch onto a dead login; a switch between duplicates; a suppressed confirmation |
| picks "Queue next" (menu or ⌥) | `autoSwitchQueue` head written | a switch |
| the auto-switch fires | the owner changes; Viewing follows only if it was on the outgoing owner and no Settings window / sheet is up; the selector item re-reads; the existing notification | a switch on an inferred stamp; a switch into a suspect; a switch triggered by the VIEWED non-owner's usage; the inspector yanked off a repair |
| runs `/login` in Claude Code (or a Codex login in an isolated home, then Import) | the sweep re-derives the owner; one banner *"Active for Claude changed outside the app: now Lark"*; Viewing stays | the app rewriting the CLI login |
| presses Import on the Login tab | a confirmation naming the CLI's current account and the viewed profile; the copy + pointer claim (R1) | a silent copy of the owner's login into a viewed non-owner |
| logs a Codex account in through the inspector | device-code sheet (target frozen); afterwards the switch confirmation ("Make it active for Codex now?") | a second `codex login` in `~/.codex` |
| leaves the switch confirmation open | the sweep keeps running (timers in `.common`); a later manual switch reports `.switchInFlight` if the auto-switch got there first | the auto-switch clock stopping |

---

## 7. Decision table

| # | Decision | Options | Recommendation | Why |
|---|---|---|---|---|
| D1 | Selector surface | S1 right-click · **S2a one ⇄ item + menu** · S2b three items · S3 in-dashboard only | **S2a**; S2b dropped from v1 | native, keyboard-navigable, no popover lifecycle, 24 pt fixed, survives overflow, one click shows all three owners (3/3 reviews) |
| D2 | Selector item default | on · off | **on** (`isVisible` toggle in Display) | it is what the owner asked for; additive |
| D3 | Switch confirmation | NSAlert suppressible · **NSAlert, never suppressible** · none | **never suppressible** | the deliberate-switch ruling (Codex, Fable) |
| D4 | Inspector surface | **I1 Settings › Accounts master-detail** · I2 own window · I3 dashboard detail | **I1, window 820 resizable** | one window lifecycle; deep links keep working; logins need a window that stays open (3/3) |
| D5 | Viewing after a switch | user-initiated: follows · automatic: follows only if Viewing was the outgoing owner and no Settings window / sheet is up · CLI-side adoption: stays | as listed | you switched to look at it; a background rotation must not yank the inspector off a repair (3/3) |
| D6 | Popover name menu | view-only · keep activating | **view-only** | R2 (redesign session wires it in B2.1) |
| D7 | Hotkey "next profile" | view next · keep switching | **view next, within the provider, painted order** | a hotkey must never rewrite a CLI login (audit M7) |
| D8 | Grok pointer | add · keep focus-as-active | **added (#66)** | symmetry; a second Grok account is coming |
| D9 | Settings top level | Accounts / Active & Auto-switch / Alerts / Display / Advanced / About | as listed | the owner's own list, with Active & Auto-switch added because the policy deserves a page |
| D10 | Counts vocabulary | profiles vs distinct accounts; readiness partition; eligible / measured headroom; excluded split; duplicates orthogonal | as §3 | same taxonomy as the bar; dedup by account; no summed strip |
| D11 | Notifications | per-account only · **fleet defaults + per-account override**, migration keeps every customized profile | fleet defaults | 25 accounts cannot be configured one by one |
| D12 | Stage 3 rollout | two-tree flag · **additive sections, old pages deleted in 3d** | additive | two trees cost more than they protect |
| D13 | Import/Sync on the Login tab | ungated copy · **named, gated, confirmed** | gated | the 2026-09-03 contamination path, now reachable from any viewed row |
| D14 | Usage limit resets | design now · **surface + gate on the verified endpoints; redeem only when measured at the limit** | as §4.1 | never spend a reset for nothing; never trust a null count |
| D15 | Alert vs the sweep timer | `.common` timers + NSAlert · non-modal panel | **`.common` timers** (fallback: panel) | one line each; the auto-switch clock must not stop behind a dialog |

---

## 8. Staged plan (one draft PR each, ≤ ~600 lines, ≤ 15 tests)

| Stage | Branch | Contents | Additive / flag | Depends on |
|---|---|---|---|---|
| **0** | `feat/ux-revamp-spec` | this spec, status doc, check-in brief, replacement list, consult outputs | docs | — |
| **F** (fixes session) | `fix/focus-is-never-authority` (+ the reset seams branch) | the §1.2 pass; `.providerOwnerChangedExternally`; timers in `.common`; read-only `autoSwitchedProfileIds`; `CodexUsageService` reset seams | — | #66 ✓ |
| **1a** | `feat/ux-revamp-1a-models` | `Shared/Models/ProviderActiveSelection.swift` (model + `ActiveVocabulary` + `Inputs` shaped like the dashboard's), `Shared/Models/FleetCounts.swift`, `Notification.Name.activeSelectorRequested`, the Settings sidebar picker → "Viewing" + `viewProfile` (#27), the hotkey → view-next within the provider (#26); tests | additive | #66 ✓ — unblocks B2.1 |
| **1b** | `feat/ux-revamp-1b-selector` | `MenuBar/ActiveSelectorMenu.swift` (item, menu, confirmation, outcome routing, activation before alerts), `setup()` create-once hook + re-entry guard, `activeSelectorStatusItem` accessor, `makeFleetSummaryContext` internal, `activeSelectorItem_v1`; item-model → menu-item tests | on by default; `isVisible` toggle placed in Manage Profiles until 3c | 1a; F (trigger guard + `.common` timers); Grok apply ✓ |
| **2a** | `feat/ux-revamp-2a-shell` | typed `SettingsRoute` + aliases, window 820 resizable, sidebar text rows, the Accounts roster (email, counts strip, filter, type-ahead, sort) with an Overview tab | new sidebar entry beside the old pages | F |
| **2b** | `feat/ux-revamp-2b-tabs` | Alerts and Monitoring tabs (label uniqueness check), Rename/Delete footer, "Make active…" header button, dashboard "Open in Accounts" link (redesign session posts the typed route) | additive | 2a |
| **2c** | `feat/ux-revamp-2c-login` | profile-id-scoped Login components (Claude / Codex / Grok), gated Import, sheet target freeze, #63's offer through the switch confirmation, async completion bound to the captured id | additive | 2b |
| **3a** | `feat/ux-revamp-3a-active` | Active & Auto-switch page (three cards, queue with provider filter, eligibility list) | additive | 1a |
| **3b** | `feat/ux-revamp-3b-alerts` | Alerts page, `fleetAlertDefaults_v1`, `usesFleetAlertDefaults` migration, `effectiveNotificationSettings(fleet:)`, bulk action; legacy `checkAndNotify(usage:)` re-route (fixes session) | additive | 2b |
| **3c** | `feat/ux-revamp-3c-display-advanced` | Display page (moves the redesign pickers + selector toggle + popover time + single-account config), Advanced page (diagnostics, debug logging UI, forget flags), `SettingsKeyRegistry` + "no key lost" test | additive | 3a, 3b |
| **3d** | `chore/ux-revamp-remove-legacy-settings` | delete Manage Profiles / Credentials / General / Appearance / Popover / App Settings / Shortcuts pages | — | 3c + a few days of use |
| **4a** | `feat/ux-revamp-4a-insights-model` | `FleetInsights` (timeline, blindness, drift, switch log, burn, incidents ring seam, filters, capacity) | additive snapshot fields | 3c |
| **4b** | `feat/ux-revamp-4b-insights-view` | `DashboardInsightsView` sections (redesign session embeds) | additive | 4a |
| **4.1** | `feat/ux-revamp-codex-resets` | reset summary surface + gated "Redeem…" on the service seams | additive | F reset seams |
| **5** (optional) | `feat/ux-revamp-5-tile-context` | right-click on a provider tile → its selector section, after measuring | setting | 1b |

Verification per PR: Release build + full suite green on the merged tree
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, dedicated
`-derivedDataPath`), test files ≤ 500 lines, no assistant trailers, merge sha
messaged to the orchestrator for deploy.

---

## 9. Open questions for the owner

1. **D1/D2:** one `⇄` selector item, on by default — confirm (per-provider items
   dropped unless you want them).
2. **D3:** the switch confirmation is never suppressible — confirm.
3. **D6:** the popover's name menu becomes view-only (switching moves to the
   selector / dashboard "Make active…"). Confirm — this is the one habit change.
4. **D11:** fleet-wide alert defaults with per-account override — confirm.
5. **Stage 4 priorities:** timeline, blind spots, drift, switch log, burn,
   incidents, filters, capacity, "why not the others" — order?
6. **D4:** Settings window 820 wide and resizable — confirm.
7. **§11:** which of the larger gaps to pull into this endeavour first —
   isolated-config Claude login, fetch-budget tiers, bulk roster operations,
   per-provider auto-switch toggles.

---

## 10. Consult log

**Question.** Is Viewing vs Active-for-<provider> the right cut and are R1–R5
complete; S2a vs S2b/S1/S3; I1 vs I2/I3 and the window size; the counts model;
the Settings top level and the key map; where a viewing action could still apply
a login; the staging and the requested seams; what a 30–40-account operator still
lacks.

**Grok `grok-4.6` xhigh (advisory; worktree at `8da0c3d`).** Approve with
revisions. Right cut, right surfaces. Blockers: focus is still CLI authority in
the auto-switch trigger and a dozen `?? activeProfile` fallbacks; split ephemeral
vs persisted viewing; manual Sync on a viewed non-owner is the contamination path;
selector `MenuBarManager`-owned, fixed length, no `autosaveName`, S2b no runtime
item churn; activate before post-await alerts; force confirmation for risky
candidates; drop "View" rows; widen the window; `usableNow` under-counts; dedup by
account; missing legacy keys; fleet defaults not seeded from Viewing, flag off;
auto-switch must not steal Viewing; hotkey within provider; delete must not
activate; split stage 1; drop the two-tree flag; per-provider queue filter;
manual-pin visibility; drift banner.

**Codex `gpt-5.6-sol` xhigh (read-only; `a67c519`).** Approve with revisions.
Change 1: make activation provider-scoped and remove every focus-as-authority
fallback first (ProfileManager:497, 1434–1437, 1632–1636; MenuBarManager:1774–1782;
`ClaudeAPIService.getAuthentication`). Change 2: one permanent selector item with a
NON-suppressible confirmation; drop S2b. Change 3: widen Settings (800–820,
resizable), correct fleet-count semantics (`live` ≠ total − dead − excluded;
`unknown` is walk-acceptable; profiles vs distinct accounts), split stage 1. Also:
explicit Queue path besides ⌥; two evidence axes (usage provenance vs login
verdict); typed route (section, profileId, tab); Login bodies with a stable
`profileId` (the Claude sync updates whichever profile is viewed at completion);
keys `claudeContaminatedLogins_v1`, `legacyBundleDefaultsMigrated_v1`, the legacy
`Constants` keys; registry as source of truth; `effectiveNotificationSettings`;
sticky-follow D5; remove "focus-only" from the switch log; Grok owner from
`auth.json` `user_id`, never focus; bulk actions, archive state, duplicate
resolution, UUID-keyed audit records, config export.

**Fable (independent session; `a67c519`).** Approve with revisions. Change 1:
make `viewProfile` actually free — split `handleProfileSwitch` (popover recreate,
full sweep, timer re-arm on every focus change) and pick one Viewing store.
Change 2: retire focus as fallback authority (2280 `syncToSystem` on the viewed
profile = unsafe write; 2725 header probe = quota spend; 1574/2170 trigger for the
viewed non-owner = unsafe write; `deleteProfile` = unsafe write; 1435 pointer
minted from focus). Change 3: no `runModal` (pauses the `.default`-mode sweep
timer) and no "don't ask again"; add `claudeContaminatedLogins_v1`,
`debugGroupExposure`; tombstone the dead `Constants` keys. Also: R6 (no network /
timer on a Viewing change) and R7 (never move Viewing while a sheet is up);
`getAuthentication` restricted to the owner; the sidebar picker must be rewired in
the same PR as its relabel; `CodexActivationOffer` needs the cost sentence; the
dashboard's repair link needs a profile id; wizard should claim ownership; the
name-keyed `sentNotifications` / `SwitchEvent`; the biggest gaps: an
isolated-config Claude login (`CLAUDE_CONFIG_DIR`), fetch-budget scaling for 30
Claude accounts (2 background fetches per sweep → ~7 min per account, everything
"stale"), bulk roster operations, per-provider auto-switch enable, backup/restore,
digests, archive state, org grouping, "why not the others".

**Decision (v3).** Model kept with R6/R7 added; the focus-authority pass is a
blocking prerequisite (F), written up per site in
`ux-revamp-focus-authority.md` and dispatched; S2a with a non-suppressible
confirmation and `.common` timers, S2b dropped; I1 at 820 resizable with
profile-id-scoped login components and typed routes; counts redefined (§3);
fleet defaults with a migration that keeps customized profiles; additive Settings
rollout; stages split as §8; resets designed on the verified endpoints; §11 lists
the gaps outside this endeavour with a recommendation.

---

## 11. Gaps beyond this endeavour (from the reviews), with a recommendation

| Gap | Owner / stage | Recommendation |
|---|---|---|
| **Adding a Claude account without displacing the CLI login** — Claude Code honours `CLAUDE_CONFIG_DIR`; the app already resolves hashed Keychain service names. An isolated-config "Log in a new Claude account" flow, twin of the Codex one. | services (fixes session) + a Login-tab button (2c) | **pull in next** — the largest gap in either spec; every `/login` today displaces the shared login and the sweep adopts it |
| **Fetch-budget scaling** — 2 background Claude fetches per 30 s sweep; with 30 accounts each is measured every ~7 min and `staleAfter = 180 s` dims nearly every dot | sweep (fixes session) | cadence tiers (hot / warm / cold) + "measured N ago" sort column (2a shows the age; the tiers are theirs) |
| **Per-provider auto-switch enable/thresholds** — `autoSwitchProfileEnabled` is global | 3a + walk | pull into 3a as a per-provider override (default = global) |
| **Bulk roster operations** (multi-select → show on bar, eligibility, alerts, delete, label) | 2b | multi-select in the roster; the four toggles as bulk actions |
| **Name-keyed state** — `SwitchEvent.from/to`, `sentNotifications` key on names; 3-char label collisions | fixes session (small) + 2b | record ids alongside names; label uniqueness check in Monitoring |
| **Archive / offboard state** distinct from exclude and delete; plan tier for weighted capacity | later | a `Profile.isArchived` flag: hidden from bar, counts and walk, kept for history |
| **Backup / restore** of `profiles_v3` + Keychain items; `profiles_v3` rewritten every sweep with 40 usage snapshots (cfprefsd substrate) | later (storage) | non-secret export/import first; move usage snapshots out of `profiles_v3` when the plist churn is measured |
| **Notification digests / quiet hours** | 3b | one digest per sweep when > 3 alerts fire together |
| **Grouping by org / identity** | 2a filter | filter by email domain / org uuid |
| **Duplicate resolution** across providers (pick canonical, merge, archive) | later | after archive exists |
| **Codex/Grok duplicate groups** published like Claude's | fixes session | `FleetCounts` derives Codex groups from stamps meanwhile |

---

## 12. Design passes (frame by frame, per surface)

The owner's bar (2026-09-03, 21:10): "go frame by frame and 100× make it better".
Every surface gets a recorded pass before its PR is marked ready: hierarchy,
density, typography, every state, keyboard access, light + dark. Frames are
numbered so a review can point at one.

### 12.1 The ⇄ selector (stage 1b)

**Item (frame 0 — rest).** 24 × 22 pt fixed. SF `arrow.triangle.2.circlepath`,
15 pt medium, drawn as a template image so the bar's own appearance tints it
(white on a dark bar, black on a light one) — no custom tint at rest, so it reads
as a system control, not a status light. Attention badge: a 5 pt dot at the
bottom-right corner, drawn only when something needs a human, one colour by
precedence: **red** (a provider has no executable candidate, or its active
login is dead) > **purple** (an active account is suspected / blind) > **amber**
(cfprefsd degraded — the same fact the banner carries). When a badge is drawn the
image is composed non-template with the glyph in the button's effective
`labelColor`, and repainted on `statusBarAppearanceDidChange` like the tiles.
Tooltip = accessibility label = one sentence: "Active: Claude Atlas 78 % · Codex
Marlin 95 % · Grok 12 % — 23 profiles / 22 accounts · 3 dead · 2 duplicates".
Hidden (`isVisible = false`) when the setting is off; never removed.

**Menu typography.** Native `NSMenu` (13 pt system). Section headers are disabled
rows in 11 pt semibold small caps, secondary colour: "ACTIVE FOR CLAUDE". Owner and
candidate rows are attributed titles: readiness glyph (● ◐ ○ ◒ ▲ – × ⧉) tinted by
its system colour, name in 13 pt semibold, gauges in 12 pt monospaced-digit
regular ("S 78 % · W 16 % · F 16 %"), evidence in 11 pt secondary. Rows stay
under 380 pt; nothing wraps. Dark/light: system colours only
(`systemGreen/Orange/Red/Purple/Cyan`, `secondaryLabelColor`).

**Frame 1 — healthy.** Per provider: header; owner row (disabled; ● cyan-marked
name, gauges, provenance + age "measured 28 s ago" / "via API headers · 3 m ago",
"pinned by you" when manually activated); evidence row (disabled; "next →
Cedar · ✓ proven 12 m ago · headroom 3 m ago" — verdict kind and quota age are
two facts); "Switch Claude to next (Cedar)…"; submenu "Switch Claude to ▸"
(eligible rows in rank order, a separator, then blocked / duplicate / excluded
rows disabled with their reason; ⌥ turns an eligible row into "Queue X next");
submenu "Queue next ▸" (eligible rows; explicit path, ⌥ is not the only one); a
disabled queue row "Queue: Fjord › Ridge" when the queue has entries for this
provider, with "Edit queue…" beside it. Footer: "Auto-switch on · 95 % session /
99 % weekly" (disabled) + "Active & Auto-switch…"; "Accounts…", "Dashboard…",
"Token usage…". Counts sentence appears as a disabled row under the owner only
when something is dead, duplicated or has no candidate (frame 2) — a healthy
group does not need to be told it is healthy.

**Frame 2 — Codex with no candidate and dead logins.** Owner row "W 95 % · fires at
99 %"; the counts sentence ("4 Codex profiles, 4 accounts: 1 ready, 1 low, 2 dead
· 1 eligible now"); evidence row in red: "next → — nobody with headroom (2 of 4
dead)"; "Repair 2 dead Codex logins…" (views the first dead profile, opens
Settings › Codex Account); "Usage limit resets: 2 available" as a disabled row
when the usage payload carries a count (nil → no row; §4.1 adds Details and the
redeem action in stage 4.1). Item badge red.

**Frame 3 — Grok, one account.** Owner row + "single account" muted. No actions.

**Frame 4 — no owner known.** "No active Claude login chosen" (muted) in the
owner's place; candidates as usual; "Switch Claude to next…" still offered.

**Frame 5 — suspected / blind owner.** Owner gauges replaced by purple "last
measured 74 % · 12 m ago" + "(projection 81 %)" when a projection exists; never a
live-looking number, never 100. Item badge purple.

**Frame 6 — cfprefsd degraded.** First row of the menu, amber: "macOS
preferences unavailable — values may be cached". Item badge amber (if nothing
red or purple outranks it).

**Frame 7 — switch in flight.** Every action row disabled; a row "⇄ switching
Claude → Cedar…" under the provider being switched. Re-opening the menu after
the switch shows the new owner.

**Frame 8 — changed outside the app.** A row under the owner, cyan: "Active for
Claude changed outside the app: now Lark", shown until the menu has been opened
once after the event (one per episode; `.providerOwnerChangedExternally`).

**Frame 9 — confirmation.** `NSAlert`, app activated first, never suppressible:
"Switch the Claude Code login to Cedar?" / "Every running Claude Code session
re-reads its context on the new account (≈10–15 % of Cedar's 5-hour window).
Cedar: session 12 %, weekly 70 %, Fable 99 % — login verified 12 m ago (usage
probe). Atlas keeps 22 % of its session until 14:02." Unverified candidate: adds
"Its login has not been verified recently — the switch may be refused."
Buttons: Cancel (default is Cancel — switching is the costly action), Switch now.

**Frame 10 — outcomes.** Success: nothing modal — the tile label moves and the
next menu open shows the new owner. Refused (dead login): alert "Not switched —
Cedar's Claude login is dead. The CLI keeps Atlas." with "Repair in Accounts"
(views Cedar, opens the Login page) and OK. In flight: "Another switch is in
progress — try again in a moment." Already active: cannot happen (owner row is
disabled). Every alert re-activates the app first (the click's grant has expired
after the `await`).

**Keyboard / accessibility.** Arrow keys, type-select, Return, Escape — native.
⌥ swaps "Switch to X…" ↔ "Queue X next" in place. The item's accessibility label
is the tooltip sentence; every row's title is the whole fact, so VoiceOver needs
no extra labels. Disabled rows carry their reason in the title, not in a tooltip.

**Rejected in this pass.** A percentage badge on the item (the fleet tiles already
show the active account); a menu section per account (25 rows in the top level —
the submenu keeps the top level under 22 rows); a "View X" row (Viewing belongs to
the inspector); a suppressible confirmation (owner ruling; two of three reviews).

### 12.2 The Accounts inspector (stages 2a–2c)

**Shell (frame 0).** The Settings window grows from a fixed 720 to **820 × 750,
resizable** (minimum 760 × 600); `.resizable` joins the style mask. Choosing
"Accounts" turns the window's sidebar INTO the roster (250 pt) with a "‹ All
settings" row at the bottom that returns to the classic sidebar; every other
section keeps today's sidebar untouched (additive rollout, D12) until stage 3d
deletes the old pages and the roster becomes permanent with the new sections as
text rows under it. Default section when the window opens with no route:
Accounts.

**Roster (frame 1).** Filter field at the top (matches name, email and state
words: "dead", "maxed", "queued", "unmeasured", "duplicate", "free", "off",
"pinned"); a sort toggle (bar order = soonest weekly reset first, the walk's
rank / alphabetical). One section per provider: title "CLAUDE", subtitle "18
profiles · 17 accounts" (stated so nobody sums the glyphs), the counts strip in
the bar's glyphs. Rows, 22 pt: readiness glyph in its colour (dimmed 50 % when
stale), name in 12 pt medium, email in 10.5 pt secondary truncated to ~18
characters, the keyed percentage right-aligned in monospaced digits ("78";
"W!" / "S!" / "F!" when maxed; "—" never measured), and ONE mark at the right
edge: `Cl`/`Cx`/`Gk` cyan = Active for that provider, `Q1` = queue position,
`✓ ? ×` = the next candidate's verdict, `⧉` = duplicate, `free`/`off` =
excluded. A dead row's name is orange; a row flagged by #64 gets a small
"re-login" caption under the name. Selecting a row = Viewing (free); the
selected row is the accent-filled one. Type-ahead selects. 40 rows scroll; the
section headers stay pinned.

**Detail header (frame 2).** "Viewing Cedar" in 16 pt semibold with the
provider in secondary; under it the R3 caption "not active · Active for Claude:
Atlas" (or "Active for Claude" in cyan when this IS the owner, or "no active Claude
login chosen"). Buttons: "Make active for Claude…" (primary; hidden for the
owner; disabled with the reason as tooltip when the login is dead — "Repair it
on the Login tab" — or when a switch is in flight), "Queue next" (hidden when
queued or when it is the owner), "Open in dashboard" (stage 2b). Tabs: Overview
· Login · Alerts · Monitoring (2a ships Overview; the others land in 2b/2c and
are hidden until then, never shown empty).

**Overview (frame 3).** Gauges as rows: label (Session / Weekly / Fable), a 6 pt
bar with a threshold tick, the percentage in monospaced digits, the reset
("resets in 4 h 02 m" / "resets Mon 09:41"); Fable row only when the account has
one; weekly-only providers show one bar with "fires at 99 %". ONE provenance
line under the gauges: "measured 3 m ago · own endpoint" / "via API headers · 3 m
ago" / "CLI cache · 5 m ago" / "not measured yet"; "stale" appended when older
than the staleness threshold. Then a two-column fact list: Readiness (state +
login verdict kind and age, e.g. "ready · login probed 12 m ago"), Identity
(email · account …0000 · org …00; Codex: home path), Fetch ("every sweep" /
"backing off until …" is stage 2b — MenuBarManager keeps it private; 2a shows
the refresh interval), History (the last three switch events naming this
account, from the ring buffer), Same account as (when duplicated), Usage limit
resets (Codex, when the count is known). States: never measured → gauges
replaced by "not measured yet — the next sweep measures it" in secondary;
suspected → the session row shows the last measured value in purple with its
age and "(projection 81 %)"; dead → a red banner at the top "Login dead — the
CLI cannot use this account. Repair it on the Login tab." with the tab link;
duplicate → the caption names the twin and, when #64 flags it, "re-login
needed"; degraded → the existing amber banner wording at the top.

**Keyboard / accessibility.** ↑/↓ moves the selection (Viewing) row by row,
type-ahead selects, ⌘F focuses the filter, Tab moves through the header buttons
and tabs; every glyph has an accessibility label spelled out (the mark "Cl"
reads "Active for Claude"); the percentage cell reads "78 percent session".

**Light / dark.** System colours only (`adaptiveGreen`, `.orange`, `.red`,
`.purple`, `.secondary`, accent for the selection); the sidebar keeps the
existing vibrancy material.

**Rejected in this pass.** Per-row bars in the roster (22 pt rows, 40 of them —
the percentage digit is the scan target; bars live in the detail); an "Active"
badge without its provider; a 720 pt window (the roster + a readable detail do
not fit, three reviews); showing empty tabs before their stage ships.

### 12.3 Settings › Active & Auto-switch (stage 3a)

**Frame 0 — page.** Header "Active & Auto-switch". Three cards, one per provider,
each a mirror of the ⇄ menu's section: title "Active for Claude"; owner row
(legend glyph in the active cyan, name, compact stats "S 78 · W 16 · F 16",
provenance + age, "pinned by you"); the suspected caveat in purple when it
applies; the next line ("next → Cedar · ✓ verified 12 m ago") with the
"Make active for Claude…" button at the right, which runs the shared
confirmation; "next: nobody with headroom" in blocking red; "single account" for
a one-account provider; an amber note when the auto-switch is off. Then the
policy card (enable, the two typed thresholds, the two rules as one sentence),
the hand-off queue with a provider filter (All / Claude / Codex / Grok; "next"
marks the first entry of each provider — what that provider's next switch
takes), and the eligibility list grouped by provider with the active account's
pill — the ONE place the toggle lives (the account's Monitoring tab links here).

**States.** Switching → "switching…" in the card, the button disabled. No owner →
"No active Claude login chosen". Degraded → the window's existing banner.

**Rejected.** Per-provider thresholds (spec §11: a later override); editing the
queue from the cards (one editor, below); a fourth card for "all providers".

### 12.4 Settings › Alerts (stage 3b)

**Frame 0 — page.** Header "Alerts". Card "Fleet defaults": the ONE
`NotificationSettingsEditor` (enable, the three built-in thresholds with their
colour chips, custom thresholds, sound), then "Followed by 12 of 14 accounts."
Card "Accounts with their own settings": one row per override — name, a one-line
summary ("50 · 90 % · no sound"; "… — same as the fleet today" when the override
equals the fleet), "Open" (link → that account's Alerts tab) and "Follow fleet";
a footer with the bulk "Follow the fleet for all N" and the note that their own
settings are kept. Empty state: "Every account follows the fleet defaults." The
rules as one caption at the bottom.

**Account › Alerts tab.** A "Use the fleet defaults" toggle first. Following:
one line "Fleet defaults: 75 · 90 · 95 % · default sound" + "Edit fleet
defaults" link. Own: the same editor bound to the profile. Leaving the fleet
copies the fleet's values in when the account never had its own, so the editor
opens on what was in force rather than on stale type defaults.

**Rejected.** A second editor implementation for the fleet card (one component,
two bindings); deleting an account's settings when it follows the fleet (kept,
so "own" is reversible); seeding the fleet key from the viewed row.

### 12.5 Settings › Display and Advanced (stage 3c)

**Display.** Header, then "Menu bar": the mode picker (Single account /
Multiple accounts) with the note that WHICH accounts show is each account's own
Monitoring setting; in multi mode the icon style, layout and click-opens
pickers with their one-line notes, then the three cosmetic toggles. "Active-
account selector" is the ⇄ toggle moved from Manage Profiles. "Popover" holds
the two time pickers. "Single-account bar" is a note + link to Appearance — the
icon configuration moves here with 3d, together with the `.appearance` route
alias (aliasing it now would loop the link back onto Display).

**Advanced.** "Startup" (launch at login), "Keyboard shortcuts" (the rows are
now `ShortcutRowsCard`, shared with the legacy page until 3d deletes it),
"Diagnostics" (the first UI for `debugAPILoggingEnabled`, the `log show`
command with Copy, version), "Dead-login flags" (one row per flagged login with
"Forget flag" — clears through the owning service, credentials untouched, the
note says where the repair is) and "Stored settings" (live / registered / on
disk counts, an amber alarm for any on-disk key nobody registered, a
disclosure listing every key with its on-disk mark and where it is edited).

**Rejected.** Duplicating the shortcut rows (extracted instead); a "reset all
settings" button (nothing in the spec asks for it, and the empty-overwrite
guard exists for a reason); deleting unregistered keys from the Advanced page.

### 12.6 Stage 3d, additive half — the move

`SingleAccountBarCards` (the Appearance page's two cards, verbatim) now renders on
Display under a one-line caption; the Appearance page is a thin host for the same
struct until the deletion PR. The three marker toggles Manage Profiles had in
multi mode (time marker, pace marker, pace colouring) are on Display's menu-bar
card — the parity gap the frame pass found. The roster gets its (+) "Add
account…" (the one thing only Manage Profiles did). Components that the new
pages share with the legacy ones moved into `Components/` and `Accounts/`
(`NotificationSettingsComponents`, `ThresholdField`, `ShortcutRowsCard`,
`ProfileCredentialStatus`, `CreateProfileSheet`), so the deletion PR is
deletions only. `.appearance` now aliases to Display.

**Deletion PR (gated on the owner's OK):** Appearance, General, Manage Profiles,
Popover, Shortcuts, App Settings, CLI Account, Codex Account pages and their
`SettingsSection` cases (the raw values stay decodable through the aliases).

### 12.7 Dashboard Insights block (stage 4b)

**Frame 0 — the block.** Eight sections in the agreed order, each a 9-pt bold
uppercase header over 10-pt rows with 9-pt secondary details (the dashboard's own
scale). "Resets, next 7 days": a strip with day ticks, one dot per distinct
account per window (green weekly, purple Fable) and a label "Atlas W +84" — the
headroom that returns — alternating between two label rows so neighbours do not
collide. "Blind spots": the active accounts, ● green when measured through their
own endpoint inside the stale threshold, ○ amber otherwise, with the evidence in
words (own measurement 4m ago · shown from the CLI cache · 2 header rescues ·
backing off 2m). "Changed outside the app" only when it happened. "Switch log":
a mini provider filter, then "Beacon → Delta · 12m ago · auto-switch · 4 %
headroom left · session 96 %"; legacy rows in the informational gray with their
caption. "Burn rate": a 40×12 sparkline of the last four samples, "+2.1 pp/min ·
crosses the threshold in 8m", or "flat". "Rate-limit incidents, last 24 h":
glyph by kind (▲ red affirmed/tripwire, ▲ amber burst/probe, ◆ purple inferred,
✓ green rescue). "Capacity remaining" as one line per provider. "Why not the
others" only when candidates are blocked: the legend glyph, the evidence, the
verdict and its age.

**Empty states.** Every section says what "nothing" means ("Nothing in the last
24 h.", "No weekly or Fable reset inside the next 7 days.") — an empty ring on a
fresh deploy must not read as a broken section.

**Rejected.** Charts with axes (the popover is 400 pt wide); a per-row context
menu (the roster already has one); a second switch surface (the redesign's
"Recent switches" disclosure goes when this lands).

### 12.8 Round-3 pass (fixes session review of the rendered frames)

R1 maxed marks carry the value ("▲ W 100"); R2 one `ActivePill` ("Active", provider
in the tooltip) on the roster row, the eligibility list and — by agreement — the
telemetry sidebar; R3 dead rows: the × and the caption are the one red, the name
stays in the label colour; R4 the dead banner's copy stops repeating what its
button says, and the frame passes the repair action; R5 the innocent duplicate's
"Same account" fact is in the caution tone with a "View <name>" link (the
re-login banner stays reserved for the contaminated case the manager flags); R6
"Make Cedar active…" names the candidate; R7 the pin is a badge with a tooltip
and an Unpin (`MenuBarManager.clearManualPin`, one log line, nothing else); R8
the diagnostics command filters on the app's subsystem (the process predicate
also matched the test host). S1 was the facsimile's clamp (widened; the live menu
has no cap); S2 waits for a reset-credit expiry on the model; S3 stays a toggle.

### 12.9 Codex usage limit resets (stage 4.1)

**Frame 0 — Overview, Codex profile.** The facts list carries a "Usage limit
resets" row: the count line ("Usage limit resets: 2 available"; a null reads
"none or unknown", never "0"), a "Details" link that fetches the grants ON DEMAND
(never on the sweep; a 429 reads "unknown right now"), the grants by expiry
("Welcome reset · expires in 3 d", "Usage limit reset · never expires", "Details
fetched 2 m ago"), and "Use one usage limit reset…" — enabled only with a grant
in hand AND a readiness of exhausted from the account's OWN measurement; the
tooltip says which condition is missing. The confirmation names the account,
the number of grants and the evidence; the outcome line says what the server
did ("Reset applied · 2 windows cleared"). The rule sentence closes the card.

**Rejected.** Any automatic redemption (a grant is the owner's to spend);
offering Redeem on a cached or inferred number; showing "0" for null.

**Round-3 addendum (merged-tree frames):** timeline labels say the window's
usage that resets ("W 84 %", not "+84"); a switch row states the outgoing level
once (the recorder's reason, else "left at 96 % session"); an affirmed stamp's
raw retry-after is dropped (its "40 min left" says it) and a rescue's header
ratio reads "5-hour window 86 %"; a why-not row lets the verdict say "dead" once;
a header rescue stays in the incidents list as an informational ○, not a green ✓.

### 12.10 Owner findings at the real scale (19 Claude profiles)

**V1 — reset strip.** Labels are laid out by a pure `InsightsTimelineLayout`:
markers sharing a slot merge ("Atlas · Harbor W 100 %"), labels stagger into up
to three rows, and past that the strip keeps its dots and lists the resets under
it ("in 9 h · Atlas W 84 %", capped at eight with "+N more"). The block's height
is a function of the layout, so it always reserves its own space.

**V2 — roster header.** The census line is one line with the sentence on hover
(the List's header row clips a second line), and the count says what it knows:
"18 profiles · 3 identified" until every profile carries an account stamp,
"18 profiles · 17 accounts" once they all do, "18 profiles" when no stamp
exists yet. `FleetCounts.Provider.identifiedAccounts` is the new number.

Frames: `accounts-roster-19`, `dashboard-insights-19`, `dashboard-insights-overflow`.

**Taxonomy addendum (redesign #138, the owner's six measured states):** my
surfaces follow `AccountReadiness.role / legendGlyph / legendWord` and needed
two literal fixes: a maxed mark ("▲ W 100", "◐ S 99") takes its row's role
colour (weekly hit is red now, session hit orange), and the one-line roster
census merges each light/bright pair by hue ("5 ready · 2 session hit · 2
weekly hit") because the dot already carries the nuance; the hover sentence
keeps all six words.
