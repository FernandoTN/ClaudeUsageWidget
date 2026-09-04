# Menu-bar redesign — status

Owner endeavour: rethink how the menu bar visualizes a large, growing roster
of subscription accounts (24 profiles, 22 on the bar, three providers).
Spec: `docs/specs/menubar-redesign.md`. Check-in brief (self-contained HTML):
`docs/specs/menubar-redesign-checkin.html`.

## Timeline (2026-09-03)

| When (PDT) | What |
|---|---|
| 17:40 | Ground truth loaded; live roster measured read-only (≈ 600 pt of bar; 2/3 Codex + 1 Claude logins dead; 11/17 background Claude accounts weekly-maxed at 99 %) |
| 17:42 | Design brief v1 written |
| 17:45 | Pinned Codex consult launched → **401: `codex login status` = "Not logged in", no `~/.codex/auth.json`**. Degraded to Fable + Grok per protocol; a watcher armed for a login |
| 17:52 | A Codex login appeared on the machine → pinned consult relaunched (`gpt-5.6-sol`, xhigh, read-only) |
| 17:57 | Fable review in (independent session) |
| 18:03 | Codex review in (`docs/specs/consults/2026-09-03-codex-menubar-review.md`) |
| 18:09 | Grok advisory in (`…-grok-menubar-review.md`; first two launches failed on output-format flags, third ran) |
| 18:10 | Spec revised (§2 taxonomy/geometry/notation, §5 stage C, §6 consult log); Stage A code revised accordingly |
| 18:20 | Check-in brief regenerated and opened in the owner's browser (`SendUserFile` was unavailable in this session) |
| 18:25 | A1 + A2 committed, rebased onto `origin/main @ 494d223` (#52 isolated-`CODEX_HOME` login, #53, #54 device-code login), full suite 299 / 0 |
| 18:27 | Push refused by the auto-mode classifier — branches local; commands to publish below |
| 18:40–19:00 | Owner asked for a frame-by-frame pass before publishing. Rendered the check-in with headless Chrome and audited every frame; measured the renderer's real font widths. Found and fixed: the candidate row (`91→dJo✓` = 45 pt at 8 pt) would have clipped its own 40 pt reserve — now 7 pt with a 52 pt reserve measured from `99Q→WWW✓`; `Q!→` replaced by a red `Q`; the dot matrix right-aligned in the block; the block's height follows the active tile so dots sit on its bars; counts as one row (72 pt measured) — a second row collided with the candidate row; `+N` given two reserved columns; mark column 10 pt (`Gk` = 8.5); the mock frames now use the browser's own text metrics (tspans) and the dashboard has stacked sections and two-line rows. A real-font test (`testReservedWidthsCoverTheRealFonts`) now guards every reserve; it caught two more misses (50.1 and 65.4 pt) before the numbers settled. Both commits rebuilt on `origin/main @ 494d223` (it had moved twice more; a soft reset had silently reverted those files once — caught by diffing the tip against the base); suite 305 / 0. |
| 19:08–19:15 | Owner: push, open the draft PRs, merge. #55 and #57 squash-merged to main. |
| 19:20–19:35 | Coordinated with the fixes session (`*********CLAUDECODE-USAGE**********`): it deployed main `50e6d71`, owns the deploy from here, and listed its file areas; provenance contract agreed. |
| 19:40–20:05 | Stage B1 built on main: provenance, click surface, dashboard snapshot model, 15 tests; PR #59. |
| 20:10 | B1 merged (`ee0e5ff`). Fixes session merged #60 (duplicate accounts) and #61. |
| 20:15–20:45 | Stage B2: dashboard view + wiring; rendered from the test harness and inspected at full height (no overlaps; Codex "nowhere with headroom", single-account Grok, collapsed switches all correct). UX-revamp sibling (`fe2aabe1`) agreed a file split: it owns the selection vocabulary model, per-provider selectors, the inspector, Settings restructure, counts; I keep the bar, dashboard view/model, popover lifecycle, overflow. |
| 21:05 | B2 merged (#62, `8da0c3d`). Fixes session deployed main `46bc36a` (B2 + #63), then `98aff7b` (+ #64) at 19:51 PDT: 23 profiles / 22 tiles, default layout, no composite rebuild at launch. |
| 22:07 | Fixes session deployed `ead8c54` (C0 + #66): the probe's first field sample was a false positive on every group (hit-test leg structurally blind on macOS 27). C0.1 fix-forward: WindowServer evidence, advisory hit test. |
| 00:05–00:20 | Deployed `6b83180` came up with the provider groups REVERSED (claude < grok < codex left→right; before: codex < grok < claude). Not slot memory: a 130 s quit did not restore it and neither our defaults nor ControlCenter's hold positions for the bundle. #80 (`1c40eba`) adds `order=` / `ORDER MISMATCH` to the probe line. Working theory (UX-revamp sibling's fresh-process probe): a fixed-length item as the app's first item flips the tiebreak between zero-width variable-length groups at creation; fix in flight: create the group items with a fixed initial length. |
| 00:20–00:35 | Frame harness (owner: "look at it frame by frame, pixel by pixel once finalized"): fixture half in the test target (`TEST_RUNNER_CUW_RENDER_FRAMES`), live half in DEBUG builds (`CUW_RENDER_FRAMES`). First finding, fixed: the Make-active confirmation sentences truncated at popover width on both surfaces. |
| 23:55 | UX revamp 1b merged (#77, the ⇄ selector item). #78 (`3ad7d3f`): the exposure probe logs the selector item beside the provider groups (`auxiliaryExposureItems`, telemetry only). Deployed `a6154c0` (#75 + #76) at 20:52 PDT, healthy. |
| 23:20–23:50 | Fixes session held the deploy of #75: on the DEFAULT layout the classic popover's name menu was the owner's manual switch path and #75 made it view-only, while the dashboard is reachable only with a fleet layout or "Click opens → Fleet dashboard". B2.2: "Make active for <provider>…" row on the viewed account in the classic popover (two-step confirmation with the cost and the dead-login warning, through `activateProfileDetailed(userInitiated: true)`, outcome note in place). Deploys together with #75. |
| 22:47 | Deployed `a8f3a60` reads the healthy signature: first paint `unknown` (h = 0, occ = 1), second probe `exposed` (occ = 0) on every group, no CONFIRMED HIDDEN. |
| 22:50–23:15 | B2.1 on `a8f3a60` (UX revamp stage 1a merged as #72): the dashboard reads the ⇄ selector's `ProviderActiveSelection` built once per snapshot; section captions in the Viewing / Active-for vocabulary; counts strip + ⇄ button per section; roster rows carry the selector's verdict, `next`, `re-login needed`; the classic name menu is view-only ("Viewing …"); "Token usage…" entries on both surfaces post `.telemetryWindowRequested`. Rendered and inspected frame by frame; 4 tests; suite 397 / 0. |
| 22:40 | Second probe sample on `96c9aa5`: `on=0` for every group (status-item windows are not in this app's on-screen list on macOS 27). C0.2: the on-screen list is telemetry only; occlusion alone says exposed. |
| 22:25 | Popover lifecycle (row 25 of `docs/specs/ux-revamp-focus-authority.md`, my half): a focus change no longer drops the open popover — `refocusOpenSurface(on:)` rebuilds the dashboard snapshot or re-points the classic popover through `viewProfile`. Found by reading: the dashboard's own Make active… closed the dashboard one runloop after confirming. |
| 21:10–21:55 | Stage C0: observe-only exposure telemetry. Pure `MenuBar/GroupExposure.swift` (verdict over one observation + hysteresis tracker), the probe in `StatusBarUIManager` (next runloop after every composite assembly, and on `NSWorkspace.didActivateApplicationNotification`), `hiddenProviders` fed to the dashboard's overflow banner, `GroupExposureTests` (5). Full suite 350 / 0. |

## Stage A — fleet summary layout (MERGED)

| PR | Merged | Contents |
|---|---|---|
| #55 `4365bc4` | 2026-09-04 02:08 UTC | `MenuBarLayout` + `barLayout` on `MultiProfileDisplayConfig` (decode-compat), `Shared/Models/FleetSummary.swift`, `MenuBar/FleetBlockFonts.swift`, `FleetSummaryTests` (15, incl. the real-font width check), spec + consults + check-in |
| #57 `5b89a0c` | 2026-09-04 02:15 UTC | `MenuBar/MenuBarSummaryRenderer.swift`, `StatusBarUIManager` summary path, `MenuBarManager` (`predictedNextCandidate`, `preflightVerdicts`, paint context), Settings picker, strings |

(#56 was the stacked A2 PR; GitHub closed it when the A1 base branch was
deleted on merge, so the same commit was cherry-picked onto main as #57.)

**Deployed:** the fixes session installed main `50e6d71` (= #57 + #58) at
19:23 PDT on 2026-09-03; the launch log shows no "rebuilding composite
groups" line. The layout stays "Every account" until the owner picks
"Active + dots" / "Active + counts" in Settings → Profiles → Multi-Profile
Display → Menu bar layout.

Rollback: pick "Every account" (the default; an absent config key decodes
to it).

## Stage B — dashboard (MERGED)

| PR | Branch | Contents | State |
|---|---|---|---|
| B1 #59 `ee0e5ff` | merged 2026-09-04 02:5x UTC | `ClaudeUsage.provenance` (`ownEndpoint` / `headerRescue` / `cliCache`, stamped by the header rescue and the CLI-cache adoption), `MultiProfileDisplayConfig.clickSurface`, `MenuBar/DashboardModel.swift` (`DashboardSnapshot.build`), `DashboardModelTests` (15) | merged |
| B2 #62 `8da0c3d` | merged | `MenuBar/DashboardView.swift` (stacked provider sections; active card with the threshold each window fires at, provenance + age, suspected caveat, ETA; Next line with verdict age + headroom age; queue slice; two-line roster rows with state chips, queue position, same-account captions, provenance; row tap → account detail reusing the classic usage rows; context menu with an inline two-step "Make active…" through `activateProfileDetailed`, Queue next / Remove, repair deep links; recent switches collapsed), `DashboardStore` (the view observes one snapshot per paint, not the manager), `MenuBarManager` wiring (snapshot rebuilt once per paint while showing, `clickedProvider`, type-erased content factory, per-surface popover/panel sizes 320×600 / 380×640, `duplicateClaudeAccountGroups` fed in), the "Click opens" picker, `DashboardViewTests` (6) + an opt-in preview render test (`TEST_RUNNER_CUW_DASHBOARD_PREVIEW=<png>` [+ `_HEIGHT`]) used to inspect the layout frame by frame without launching the app | merged; deployed by the fixes session as main `46bc36a` / `98aff7b` |

Coordination with the fixes session (2026-09-03 evening): it owns
`ProfileManager` (activation outcome, identity stamping, duplicate-account
groups), `ClaudeAPIService`, `NotificationManager`, `walkReaction` and the
candidate-skip in `findNextAvailableProfile`; it is not touching the popover
view, the popover lifecycle, `createContentViewController` /
`detachableWindow`, `Constants.WindowSizes`, or the composite overflow
branch. Its asks, all folded into B1's model: provenance + age beside every
number, never a value measured with someone else's credentials, a one-click
repair route for dead logins, the verdict age on the next-candidate card,
and duplicate groups shown as one quota with member names.

## Stage B2.1 — vocabulary + selector hook + telemetry entries

| PR | Branch | Contents | State |
|---|---|---|---|
| B2.1 | `feat/menubar-dashboard-b2-1` | `ProviderSection.selection` (built once inside `DashboardSnapshot.build` from `ProviderActiveSelection.build`, #72); `RosterRow.candidateStatus / isNext / needsRelogin`; `Inputs.manuallyPinned / needsRelogin`; `DashboardFormatting.sectionCaption` ("Viewing X · Active for Claude: Y" / "Active for Claude: Y" / "No active Claude login" / "· pinned") and `rosterHeader` ("· N eligible now"); section header with `FleetCounts.Provider.strip` (sentence on hover) and the ⇄ button posting `.activeSelectorRequested(provider)`; "Make active for <provider>…"; `ProfileSwitcherCompact` view-only through `ProfileManager.viewProfile` with a "Viewing" label; "Token usage…" in the dashboard header (fleet), row context menus (account) and the classic name menu, all posting `.telemetryWindowRequested` (object = profile id or nil, `userInfo["provider"]`); `rebuildDashboardSnapshot` passes `FleetCounts.duplicateGroups(in:published:)`, the manual pins and the re-login set. `DashboardSelectionTests` (4). | draft PR, suite 397 / 0 |

| B2.2 | `feat/popover-make-active` | `PopoverSwitchRule.canMakeActive` (never the provider's owner; Claude needs the CLI-login stamp, Codex its credentials, Grok its login); the classic popover's "Make active for <provider>…" row under the viewing tag / group navigator with the dashboard's two-step confirmation and outcome note; `onMakeActive` through the one activation seam. `PopoverSwitchRuleTests` (1). Companion to #75 on the default layout. | PR, suite 398 / 0 |

Until UX-revamp stage 1b (the ⇄ item + observer) and the telemetry
sibling's window controller land, the ⇄ button and the "Token usage…"
entries post notifications nobody observes (no-ops by design).

## Stage C — overflow (C0 in review)

Scope revised by the consult: C0 observe-only telemetry with screen-point hit
tests from the composite branch, then a fixture-tested detector, then a
per-provider `dots → counts → active-only` ladder inside the same status
item. Never the heal-rebuild path, never an item-count change.

| PR | Branch | Contents | State |
|---|---|---|---|
| C0 | `feat/menubar-overflow-c0` | `MenuBar/GroupExposure.swift`: `GroupExposure.Observation` (window frame, screen frame, visibility, occlusion, item length, per-probe hits) → `verdict` (a hit on the item's own window is proof of exposure; nil window/screen → unknown; never laid out, off a screen edge, parked below the 100 pt bar band, a stub narrower than half the item length, not visible, or every probe resolving to another window → hidden; a plausible frame with no probe → unknown) and `GroupExposureTracker` (confirmed hidden after 2 consecutive hidden samples, cleared after 3 exposed, unknown leaves the state alone, vanished items drop out). `StatusBarUIManager`: `scheduleExposureProbe` coalesced onto the next runloop turn after every `assembleComposites` (AppKit lays the bar out after the assignment returns) and on `NSWorkspace.didActivateApplicationNotification` (the frontmost app's menu width decides the overflow); `observeExposure(of:)` hit-tests 25 / 50 / 75 % of the button width at mid-height with `NSWindow.windowNumber(at:belowWindowWithWindowNumber: 0)`; `hiddenProviders` (confirmed set) → `DashboardSnapshot.Inputs.hiddenProviders` → the dashboard's "hidden by the menu bar" banner; one default-level log line per change (`Menu bar exposure (<reason>): claude=exposed [x=… w=… h=… len=… hits=111] …`) mirrored to the `debugGroupExposure` default; the tracker resets on `clearOverflowParkedState` (screen change) and `cleanup`. `GroupExposureTests` (5). | draft PR, full suite 350 / 0 |

First field sample (fixes session, build `ead8c54`, 20:07 PDT, macOS 27):
every group CONFIRMED HIDDEN while the tiles were visibly on the bar —
`claude=hidden [x=1078 w=461 h=33 len=458 hits=000] …`. The hit-test leg
can never resolve to the item's own window on macOS 27 (the menu-bar host
owns the event surface above third-party items, the same architecture as the
synthesized-center clicks), so "plausible frame + every probe elsewhere →
hidden" was always true. C0.1 (fix-forward, same evening): the WindowServer's
answers decide — `occlusionState` `.visible` → exposed, absent from the
on-screen window list → hidden — the hit test is advisory (a hit proves
exposure, a miss proves nothing), the `h = 0` first-paint frame is unknown
rather than hidden, and the log line carries `vis= occ= on=`. A plausible,
ordered-in, fully-occluded frame stays `unknown` until the field says
occlusion is trustworthy for status windows.

Second field sample (build `96c9aa5`, 20:36 PDT): `vis=1 occ=0 on=0` on
every group, again CONFIRMED HIDDEN while the tiles were on the bar — the
on-screen window list never carries this app's status-item windows on
macOS 27 (they are hosted out of process), so absence from it proves
nothing. C0.2: the list is telemetry only; `occlusionState` is the one
WindowServer answer that has read correctly in the field, and it alone now
says "exposed". Still unknown, by design, until a real overflow is logged:
whether occlusion flips for a parked status window.

What C0 deliberately does not do: no notification, no ladder, no rebuild.
The next stage reads the log lines this one produces on the owner's machine
(a real overflow, a full-screen app, a display change) before the detector's
thresholds are trusted to drive a repaint.

Reading the telemetry after a deploy:

```bash
/usr/bin/log show --predicate 'process == "Claude Usage"' --last 1h | grep "Menu bar exposure"
defaults read com.claudeusagewidget.app debugGroupExposure
```

## Open questions for the owner (unchanged)

1. Layout default: B (dots) is recommended and implemented; A (counts) is
   selectable. Confirm or pick.
2. Provider marks (`Cl/Cx/Gk`, 9 pt) — two reviewers wanted them, one did
   not. Kept; easy to drop.
3. Candidate-row notation `→ / Q→ / Q!→` with `✓ ? ×` (Codex) vs `› / »`
   with `✓ ·` (Fable). Codex's chosen for legibility at 8 pt.
4. Stage B: dashboard as a popover (D1) — confirm.

## Verification recipe (after deploy by the dispatching session)

```bash
# 1. pick the layout: Settings → Profiles → Multi-Profile Display → Menu bar layout → "Active + dots"
# 2. the composite groups must NOT be recreated (no "rebuilding composite groups" line):
/usr/bin/log show --predicate 'process == "Claude Usage"' --info --last 5m | grep -E "composite|Multi-profile"
# 3. hover a provider tile: the tooltip spells the summary; VoiceOver reads the same label
# 4. health: main thread parked in NSApplication run
sample "$(pgrep -x 'Claude Usage')" 3 | grep -m1 -A2 "Thread_.*main"
```
