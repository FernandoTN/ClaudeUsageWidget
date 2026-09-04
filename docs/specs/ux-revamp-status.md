# UX revamp — status

Owner endeavour: end the focus-vs-provider-active confusion for a 25–40-account
fleet across Claude / Codex / Grok. Spec: `docs/specs/ux-revamp.md` (v3). Check-in
brief (self-contained HTML): `docs/specs/ux-revamp-checkin.html`. Per-site
replacement list for the fixes session: `docs/specs/ux-revamp-focus-authority.md`.
Consult outputs: `docs/specs/consults/2026-09-03-{codex,fable,grok}-ux-revamp-review.md`.

Worktree `.claude/worktrees/ux-revamp`; branches `feat/ux-revamp-<stage>`; one
draft PR per stage, ≤ ~600 lines, ≤ 15 tests, each additive. The orchestrating
session (`*********CLAUDECODE-USAGE**********`) deploys; every merge sha is
messaged to it. Never `/Applications` or the running process.

## Timeline (2026-09-03, PDT)

| When | What |
|---|---|
| 19:20 | Ground truth loaded: CLAUDE.md, both audits, the Codex research doc, the redesign spec/status, Settings + popover + ProfileManager activation code, every preference key (source + live plist) |
| 19:25 | Scope split proposed to the menu-bar redesign session; accepted 19:32 |
| 19:40 | B2 (#62) merged by the redesign session; worktree created from it |
| 19:50 | Proposal v1 written |
| 19:52 | Pinned Codex consult (`gpt-5.6-sol`, xhigh, read-only), Grok advisory and an independent Fable review launched; seam request sent to the fixes session (`viewProfile`, Grok pointer + apply) |
| 20:00 | Fixes session accepted the seams; its Settings PRs #63/#64 merged; redesign session agreed the ⇄ item's bar contract (fixed 24 pt, created once, exposure-probe hook, `makeFleetSummaryContext` internal) |
| 20:10 | Grok advisory in → v2 (verified its focus-as-authority findings line by line; four more seams requested: trigger guard, fallbacks, auto-switch Viewing rule, delete) |
| 20:20 | Owner ask relayed: Codex usage limit resets; slot reserved (§4.1); research dispatched by the fixes session |
| 20:30 | Codex + Fable reviews in (both approve with revisions; same three fixes); #66 seams merged (`ead8c54`); per-site list written for the `fix/focus-is-never-authority` PR (dispatched) |
| 20:50 | Reset facts verified (endpoints, shapes, hazards) → §4.1 designed on them; service contract agreed |
| 21:00 | **v3** spec, regenerated check-in, this status; docs PR #68 opened; check-in opened for the owner |
| 21:10 | Owner (via the fixes session): "use your best judgment and go with your recommendations"; design bar: "go frame by frame and 100× make it better" — per-surface design passes recorded per stage. A token-usage telemetry sibling introduced itself; window-plumbing ownership agreed (redesign session owns a future `WindowCoordinator`; telemetry and Settings are registered kinds) |
| 21:20 | Reset seams merged (#69, `9d86552`); focus-authority merged (#70, `96c9aa5`: `providerOwnerId(for:among:)`, owner guard in `checkAutoSwitchIfNeeded`, R7 pinned-view veto, `.providerOwnerChangedExternally`, delete → view, `.common` timers); popover survives focus change (#71, `cee4c07`) |
| 21:30 | #68 squash-merged (`80949d2`). Stage 1a built on the merged tree: Release build OK, 393 tests / 0 failures; draft PR opened |
| 21:40 | Stage 1a #72 squash-merged (`a8f3a60`), deployed by the fixes session at 20:39 PDT (24 profiles / 23 tiles, healthy). Redesign session's B2.1 (#75, `0d762a8`) consumes the 1a models: dashboard header vocabulary, counts strip, view-only name menu, ⇄ link, "Token usage…" entries |
| 22:00 | Stage 1b #77 merged (`6b83180`), deployed 20:56 PDT. Bar order came up claude < grok < codex < ⇄; a fresh-process probe showed fixed-length items place textbook (X G C S) while the zero-width variable-length groups tie behind the anchor — the redesign session removes the tie (fixed 24 pt initial group length) in its next PR; fallback = selector after the groups |
| 22:20 | Stage 2a: design pass §12.2 recorded; `SettingsRoute` (typed, decodes the legacy strings), `SettingsSection.accounts`, the roster sidebar replaces the window sidebar in Accounts mode, `AccountsRosterModel` (pure), Overview tab, window 820 × 750 resizable (min 760 × 600), `MenuBarManager.current`; the DEBUG frame harness (`CUW_RENDER_FRAMES=<dir>`, also `TEST_RUNNER_CUW_RENDER_FRAMES` through the test host) rendered 32 frames — the pass caught overlapping two-line roster rows, an unmarked projected value on a suspected row, "1 profiles", "fires at" on a single-account provider and a doubled "dead login · login dead"; all fixed before the PR |
| 21:50 | Stage 1b: frame-by-frame design pass recorded (spec §12.1); `ActiveSelectorMenuModel` (pure rows / badge / tooltip / confirmation), `ActiveSelectorItem` (fixed 24 pt item created once in `setup()` before the groups, `NSMenu` built in `menuNeedsUpdate`, never-suppressible `NSAlert`, outcomes in place, app activated before every alert), `activeSelectorItem_v1` setting + toggle in Manage Profiles, `buildActiveSelections()` / `activeSelectorStatusItem` / `manuallyPinnedProfileIds` on `MenuBarManager`, `makeFleetSummaryContext` internal, wizard identity stamp after its claim; 14 tests |

## Ownership (agreed in writing)

| Area | Owner |
|---|---|
| Bar rendering, `DashboardView` / `DashboardModel` / `PopoverContentView`, popover lifecycle (incl. the `recreatePopover` half of the `$activeProfile` observer split), `rebuildDashboardSnapshot`, paint sites, `preflightVerdicts` stamps, stage C overflow / exposure probe (adds the selector via an auxiliary-items seam) | menu-bar redesign session |
| `ProfileManager`, `ClaudeAPIService`, `NotificationManager`, the sweep and the candidate walk, `CodexUsageService` (incl. the reset seams), the "focus is never authority" PR, the timers' run-loop mode, `.providerOwnerChangedExternally`, read-only `autoSwitchedProfileIds` | fixes session |
| The Viewing-vs-Active model + vocabulary (`Shared/Models/ProviderActiveSelection.swift`), the ⇄ selector item + menu (`MenuBar/ActiveSelectorMenu.swift`, the create-once hook in `setup()`, `activeSelectorStatusItem`, `makeFleetSummaryContext` made internal), `FleetCounts`, the Accounts inspector (`Views/Settings/Accounts/`), all of `Views/Settings/**` + `SettingsView.swift`, the Settings picker and hotkey rewire (sites #27/#26), the key registry, `FleetInsights` + `DashboardInsightsView` (embedded by the redesign session), the resets surface | this session |

Agreements: `SettingsSection` raw values stay resolvable (typed `SettingsRoute` decodes
the old strings); the redesign session's "Menu bar layout" and "Click opens"
pickers stay reachable (Display, same bindings); additive dashboard data through
new `DashboardSnapshot` fields, every number a `UsageMeasurement`;
`ProviderActiveSelection.build` is pure, `now`-injectable, `Inputs` shaped like
`DashboardSnapshot.Inputs` so B2.1 builds it once per paint; B2.1 consumes the
vocabulary, `FleetCounts.Provider`, `Notification.Name.activeSelectorRequested`, and
makes the popover's name menu view-only via `viewProfile`.

## Decisions (v3; owner check-in sent, defaults apply unless he says otherwise)

S2a one ⇄ item (fixed 24 pt, on by default, `isVisible` toggle), S2b dropped;
confirmation never suppressible, sweep timers in `.common`; I1 inspector as
Settings › Accounts master-detail at 820 pt resizable with profile-id-scoped login
components and typed routes; Viewing follows a user switch, follows an auto-switch
only if it was on the outgoing owner and no Settings window / sheet is up; popover
name menu and hotkey view-only; Grok pointer (#66); Settings top level Accounts /
Active & Auto-switch / Alerts / Display / Advanced / About; counts on distinct
accounts with eligible / measured-headroom / login-live; fleet alert defaults with a
migration that keeps customized profiles; additive rollout, old pages deleted in
3d; Import/Sync named and gated; resets: surface + gate on the verified endpoints,
redeem only when measured at the limit. Full table: spec §7; consult log §10.

## Stages

| Stage | Branch | PR | State |
|---|---|---|---|
| 0 spec | `feat/ux-revamp-spec` | #68 | **merged** `80949d2` |
| F (fixes session) | `fix/focus-is-never-authority`, reset seams | #70, #69 | **merged** `96c9aa5`, `9d86552` |
| 1a models + picker/hotkey rewire + wizard ownership claim (#28) | `feat/ux-revamp-1a-models` | #72 | **merged** `a8f3a60`, deployed 20:39 |
| 1b ⇄ selector item + menu + confirmation + setting | `feat/ux-revamp-1b-selector` | #77 | **merged** `6b83180`, deployed 20:56 |
| 2a Accounts shell: typed `SettingsRoute`, window 820 resizable, roster sidebar + Overview tab, Debug frame harness | `feat/ux-revamp-2a-shell` | draft | frames rendered and reviewed (§12.2) |
| 2a fix: selector created after the groups (order fallback) | `fix/ux-revamp-selector-after-groups` | draft | — |
| 2b / 2c inspector tabs, login components | — | — | after 2a |
| 3a / 3b / 3c / 3d Settings | — | — | after 2 |
| 4a / 4b insights, 4.1 resets | — | — | after 3 / the reset seams |

## Open items

- Owner check-in answers (spec §9) — the owner said to proceed on the
  recommendations; the page stays open for notes.
- `.providerOwnerChangedExternally` (#70) is consumed by the ⇄ selector (stage
  1b: one banner row per episode, cleared when the menu is next opened); the
  inspector shows it too in stage 2a.
- B2.1 (redesign session): dashboard header vocabulary, popover name menu →
  `viewProfile`, `FleetCounts.Provider` in the header, the selector link.
- Telemetry sibling: launch points agreed (⇄ footer "Token usage…", dashboard
  footer via the redesign session, per-account "Usage history" in the inspector
  Overview, `.telemetryWindowRequested` object = profile UUID?); reverse link via
  `SettingsRoute` from stage 2a.
- Design passes: every surface gets a recorded frame-by-frame pass (hierarchy,
  density, typography, all states incl. loading / degraded / dead / suspected /
  duplicate / at-limit / blind, keyboard, light + dark) before its PR is marked
  ready — spec §12 (added with stage 1b).
