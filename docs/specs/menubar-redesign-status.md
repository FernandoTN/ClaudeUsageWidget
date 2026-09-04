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

## Stage B — dashboard (B1 in review, B2 next)

| PR | Branch | Contents | State |
|---|---|---|---|
| B1 #59 | `feat/menubar-dashboard-b1` | `ClaudeUsage.provenance` (`ownEndpoint` / `headerRescue` / `cliCache`, stamped by the header rescue and the CLI-cache adoption), `MultiProfileDisplayConfig.clickSurface`, `MenuBar/DashboardModel.swift` (`DashboardSnapshot.build`), `DashboardModelTests` (15) | draft, full suite green |
| B2 | — | `DashboardView` (stacked provider sections, two-line rows, inline two-step "Make active…" through `activateProfileDetailed`, repair deep links, snapshot rebuilt once per paint), `AccountDetailView` extracted from the classic popover, type-erased popover factory, per-surface popover/panel sizes, Settings picker for the click surface, `duplicateClaudeAccountGroups` fed into the snapshot | not started |

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

## Stage C — overflow (not started)

Scope revised by the consult: C0 observe-only telemetry with screen-point hit
tests from the composite branch, then a fixture-tested detector, then a
per-provider `dots → counts → active-only` ladder inside the same status
item. Never the heal-rebuild path, never an item-count change.

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
