# Token usage telemetry — status

Owner endeavour: a window that shows token CONSUMPTION over time (Claude Code,
Codex, Grok) by provider / model / account with trends, read from the CLIs'
local logs. Spec: `docs/specs/token-telemetry.md`. Research:
`docs/research/2026-09-04-token-telemetry-sources.md`. Check-in brief:
`docs/specs/token-telemetry-checkin.html`.

Sibling sessions and what they own (agreed in writing 2026-09-03 evening):

| Session | Owns | Agreed with us |
|---|---|---|
| `*********CLAUDECODE-USAGE**********` (fixes/deploys) | ProfileManager, MenuBarManager sweep/auto-switch, ClaudeAPIService, CodexUsageService, ProfileStore, SharedDataStore, deploys | independent `.utility` timer + file store owned by the telemetry module; read-only use of `loadSwitchHistory`, `Profile` stamps, `activeAccountIds(among:)` / `providerOwnerId(for:among:)`; our own append-only ownership log; every merge sha reported to it |
| `claudeusagewidget menu-bar redesign` | DashboardModel/View, StatusBarUIManager, GroupExposure, popover/window lifecycle, `detachableWindow`, future `WindowCoordinator` | one `TelemetryWindowController` under `Telemetry/` copying the Settings window pattern, foregrounded via `bringWindowToForeground`; it posts `.telemetryWindowRequested` from the dashboard header, dashboard rows and the popover name menu (landed in #75) |
| `claudeusagewidget ia audit kickoff` (UX revamp) | Views/Settings/**, SettingsView, ActiveSelectorMenu, `MenuBarManager.setup()`, `ActiveVocabulary`, Notification+Extensions during 1a | it declared `Notification.Name.telemetryWindowRequested` (#72); adds the ⇄ footer "Token usage…" and the inspector's per-account "Usage history"; we use `ActiveVocabulary` and `SettingsRoute` for the reverse link |

## Timeline (2026-09-03/04, PDT)

| When | What |
|---|---|
| 20:25 | Kickoff. Messaged all three siblings; answers within 15 min (above) |
| 20:30–20:50 | Read-only census of the three sources (Python), Swift hot-path prototype timing, Grok source discovered (`updates.jsonl` `turn_completed.usage`, plus a 3-day per-call log) |
| 20:55 | Codex census corrected: re-adding the cumulative total on any negative per-key delta had inflated 54.4 B to 70.0 B |
| 21:15 | Research doc written; worktree `token-telemetry` on `feat/token-telemetry-research` from `main @ 0d762a8` |
| 21:30 | Proposal spec written (layout B recommended) |
| 21:35 | Consults launched (Codex `gpt-5.6-sol` xhigh read-only; Grok advisory) |

## Stage 0 — research + proposal (this branch)

Deliverables: research doc, spec, this status doc, consult outputs under
`docs/specs/consults/`, the check-in brief.

## Decisions so far

- Consumption ≠ quota: header line once per surface; no percentages of limits.
- Units: Claude deduplicated message (`message.id`, max output); Codex delta
  between distinct cumulative totals; Grok completed turn.
- Store: append-only monthly JSONL + cursors + ownership log + rollups under
  `~/Library/Application Support/Claude Usage/telemetry/`; never UserDefaults;
  no SQLite unless measurement demands it.
- Attribution by time from our own ownership log; three bands; unattributed is
  shown, never redistributed.
- Window: layout B (sidebar scope + report), default 7 days, list-price cost
  labelled as an estimate, markers for switches and rate-limit deaths —
  pending the owner's check-in.

## Open questions

See spec §6. Proceeding on the bold defaults if the owner is silent.
