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

## Stage A — fleet summary layout (in progress → draft PRs)

Split into two stacked draft PRs on the consult's line-budget advice:

| PR | Branch | Commit | Contents | State |
|---|---|---|---|---|
| A1 | `feat/menubar-redesign-a1` | first commit on `origin/main @ 494d223` | `MenuBarLayout` + `barLayout` on `MultiProfileDisplayConfig` (decode-compat), `Shared/Models/FleetSummary.swift` (readiness, verdicts, provider summary, geometry measured against the real fonts, paint context), `FleetSummaryTests` (15, incl. a real-font width check), spec + consults + check-in | builds and passes on its own; **local only — push blocked** |
| A2 | `feat/menubar-redesign` (stacked on A1) | tip | `MenuBar/MenuBarSummaryRenderer.swift`, `StatusBarUIManager` summary path, `MenuBarManager` (`predictedNextCandidate`, `preflightVerdicts`, paint context), Settings picker, strings | Release build green, **full suite 305 / 0 failures**; **local only — push blocked** |

The authoring session's auto-mode classifier refused the push (twice, plain
form), so both branches exist only in the worktree
`.claude/worktrees/menubar-redesign`. Draft PR bodies are ready in the job's
tmp dir (`/Users/fernandotn/.claude/jobs/6a773b3e/tmp/pr-a1.md`, `pr-a2.md`).
To publish (from the worktree):

```bash
cd /Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/menubar-redesign
git push -u origin feat/menubar-redesign-a1 feat/menubar-redesign
gh pr create --draft --base main --head feat/menubar-redesign-a1 \
  --title "feat(menubar): fleet-summary model, readiness taxonomy and bar-layout option (stage A1)" \
  --body-file /Users/fernandotn/.claude/jobs/6a773b3e/tmp/pr-a1.md
gh pr create --draft --base feat/menubar-redesign-a1 --head feat/menubar-redesign \
  --title "feat(menubar): fleet-summary layouts — active tile + readiness dots/counts + next candidate (stage A2)" \
  --body-file /Users/fernandotn/.claude/jobs/6a773b3e/tmp/pr-a2.md
```

Rollback: Settings → Profiles → Multi-Profile Display → Menu bar layout →
"Every account" (the default; absent config key decodes to it).

## Stage B — dashboard (not started)

Scope revised by the consult: stacked provider sections, two-line rows,
snapshot model, type-erased popover factory, per-surface sizes, inline
confirmations through `activateProfileDetailed`, reusable account-detail
component, shared `AutoSwitchPlan` resolver extraction.

## Stage C — overflow (not started)

Scope revised by the consult: C0 observe-only telemetry with screen-point hit
tests from the composite branch, then a fixture-tested detector, then a
per-provider `dots → counts → active-only` ladder inside the same status
item. Never the heal-rebuild path, never an item-count change.

## Open questions for the owner

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
