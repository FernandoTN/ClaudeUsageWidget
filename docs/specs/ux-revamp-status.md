# UX revamp — status

Owner endeavour: end the focus-vs-provider-active confusion for a 25–40-account
fleet across Claude / Codex / Grok. Spec: `docs/specs/ux-revamp.md`. Check-in
brief (self-contained HTML): `docs/specs/ux-revamp-checkin.html`. Consult
outputs: `docs/specs/consults/2026-09-03-*-ux-revamp-review.md`.

Worktree `.claude/worktrees/ux-revamp`; branches `feat/ux-revamp-<stage>`; one
draft PR per stage, ≤ ~600 lines, ≤ 15 tests, each behind a setting or additive.
The orchestrating session (`*********CLAUDECODE-USAGE**********`) deploys; every
merge sha is messaged to it. Never `/Applications` or the running process.

## Timeline (2026-09-03, PDT)

| When | What |
|---|---|
| 19:20 | Ground truth loaded: CLAUDE.md, both audits, the Codex research doc, the redesign spec/status, Settings + popover + ProfileManager activation code, every preference key (source + live plist) |
| 19:25 | Scope split proposed to the menu-bar redesign session; accepted at 19:32 (see Ownership) |
| 19:40 | B2 (#62, `8da0c3d`) merged by the redesign session; worktree created from it |
| 19:50 | Proposal v1 written (`docs/specs/ux-revamp.md`) |
| 19:52 | Pinned Codex consult launched (`gpt-5.6-sol`, xhigh, read-only, backgrounded); Grok advisory launched; independent Fable review launched |
| 19:52 | Seam request sent to the fixes session: `ProfileManager.viewProfile(_:)`, `activeGrokProfileId` + claim + store, `GrokUsageService.applyProfileCredentials(_:)` |

## Ownership (agreed in writing, 2026-09-03 19:32)

| Area | Owner |
|---|---|
| Bar rendering (`StatusBarUIManager`, `MenuBarSummaryRenderer`, `FleetSummary`), `DashboardView` / `DashboardModel` / `PopoverContentView`, popover lifecycle (`togglePopover`, `ensurePopover`, `createContentViewController`, `detachableWindow`, `closePopover*`, `refreshViewedProfileUsage`), `rebuildDashboardSnapshot` / `fleetSummaryContext`, the paint sites, the `preflightVerdicts` stamps, Stage C overflow | menu-bar redesign session |
| `ProfileManager`, `ClaudeAPIService`, `NotificationManager`, `walkReaction`, the candidate walk, the credential sheets' in-flight PRs | fixes session (`*********CLAUDECODE-USAGE**********`) |
| The Viewing-vs-Active model + vocabulary (`Shared/Models/ProviderActiveSelection.swift`), the ⇄ selector item + menu (`MenuBar/ActiveSelectorMenu.swift`), `FleetCounts`, the Accounts inspector (`Views/Settings/Accounts/`), `Views/Settings/**` + `SettingsView.swift` (after the fixes session's two PRs merge), the Settings key registry, `FleetInsights` + `DashboardInsightsView` (stage 4, embedded by the redesign session), the `MenuBarManager.setup()` hook that creates the selector item once | this session |

Agreements: `SettingsSection` raw values `cliAccount`, `codexAccount`,
`manageProfiles` stay resolvable (aliases, spec §5.4); the redesign session's
"Menu bar layout" and "Click opens" pickers stay reachable (Display page, same
bindings); additive dashboard data goes through new `DashboardSnapshot` fields,
never reshaping existing types, every number a `UsageMeasurement`; B2.1 (theirs)
consumes `ProviderActiveSelection` + `Notification.Name.activeSelectorRequested`
and makes the popover's name menu view-only once `viewProfile` exists.

## Decisions so far (owner check-in pending)

See spec §7. Recommended: S2a one ⇄ selector item with an `NSMenu` (on by
default, per-provider items as a setting); `NSAlert` confirmation suppressible
per provider; I1 inspector as Settings › Accounts master-detail; Viewing
follows the new owner after a switch; popover name menu and the next-profile
hotkey become view-only; a Grok pointer; Settings top level Accounts / Active &
Auto-switch / Alerts / Display / Advanced / About; fleet alert defaults with
per-account override; stage 3 behind `settingsLayout_v2`.

## Stages

| Stage | Branch | PR | State |
|---|---|---|---|
| 0 spec | `feat/ux-revamp-spec` | — | consults running |
| 1 selectors + vocabulary | `feat/ux-revamp-1-selectors` | — | after check-in |
| 2 inspector + counts | `feat/ux-revamp-2-inspector` | — | after the fixes session's Settings PRs |
| 3 Settings restructure + key migration | `feat/ux-revamp-3-settings` | — | — |
| 4 dashboard depth | `feat/ux-revamp-4-insights` | — | — |

## Open questions

Spec §9 (selector shape/default, confirmation policy, view-only popover menu,
fleet alert defaults, stage-4 priorities, window width). Plus: whether the
fixes session lands the Grok pointer/apply in stage 1's window.
