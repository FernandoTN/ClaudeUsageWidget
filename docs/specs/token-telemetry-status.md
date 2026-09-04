# Token usage telemetry — status

Owner endeavour: a window that shows token CONSUMPTION over time (Claude Code,
Codex, Grok) by provider / model / account with trends, read from the CLIs'
local logs. Spec: `docs/specs/token-telemetry.md`. Research:
`docs/research/2026-09-04-token-telemetry-sources.md` (tools under
`docs/research/tools/token-telemetry/`). Check-in brief:
`docs/specs/token-telemetry-checkin.html`. Consults: `docs/specs/consults/2026-09-04-*token-telemetry*`.

Sibling sessions and what they own (agreed in writing 2026-09-03 evening):

| Session | Owns | Agreed with us |
|---|---|---|
| `*********CLAUDECODE-USAGE**********` (fixes/deploys) | ProfileManager, MenuBarManager sweep/auto-switch, ClaudeAPIService, CodexUsageService, ProfileStore, SharedDataStore, deploys | independent `.utility` timer + file store owned by the telemetry module; read-only use of `loadSwitchHistory`, `Profile` stamps, `activeAccountIds(among:)` / `providerOwnerId(for:among:)`; our own ownership log; every merge sha reported to it; **asked (21:10)** for a claim-seam notification from `claimActive{Claude,Codex,Grok}Ownership` (object new owner UUID, userInfo provider / previousOwnerId / cause) |
| `claudeusagewidget menu-bar redesign` | DashboardModel/View, StatusBarUIManager, GroupExposure, popover/window lifecycle, `detachableWindow`, any future `WindowCoordinator` | one `TelemetryWindowController` under `Telemetry/` copying the Settings window pattern, foregrounded via `bringWindowToForeground`; it posts `.telemetryWindowRequested` from the dashboard header, dashboard rows and the popover name menu (landed in #75) |
| `claudeusagewidget ia audit kickoff` (UX revamp) | Views/Settings/**, SettingsView, ActiveSelectorMenu, `MenuBarManager.setup()`, `ActiveVocabulary`, Notification+Extensions during 1a | it declared `Notification.Name.telemetryWindowRequested` (#72); adds the ⇄ footer "Token usage…" and the inspector's per-account "Usage history"; we use `ActiveVocabulary` and `SettingsRoute` for the reverse link |

Owner instructions relayed by the fixes session (21:05): record per-surface
design passes in the spec before a PR leaves draft; ship a DEBUG-only frame
render harness (`CUW_RENDER_FRAMES=<dir>`) in the window stage so a pixel
pass can run without live screenshots.

## Timeline (2026-09-03/04, PDT)

| When | What |
|---|---|
| 20:25 | Kickoff. Messaged all three siblings; answers within 15 min (above) |
| 20:30–20:50 | Read-only census of the three sources (Python), Swift hot-path prototype timing; Grok source discovered (`updates.jsonl` `turn_completed.usage`, plus a 3-day per-call log) |
| 20:55 | Codex census corrected: re-adding the cumulative total on any negative per-key delta had inflated 54.4 B to 70.0 B |
| 21:15 | Research doc written; worktree `token-telemetry` on `feat/token-telemetry-research` from `main @ 0d762a8` |
| 20:45 | Proposal spec v1 (layout B recommended); consults launched (Codex `gpt-5.6-sol` xhigh read-only; Grok advisory) |
| 20:58–21:00 | Check-in brief built, rendered headless (dark), three frame fixes (footer collision, two clipped tile sub-lines) |
| 21:01 | Check-in brief delivered to the owner via SendUserFile (render) |
| 21:03 / 21:04 | Codex review in (24 min) · Grok review in (12 min); both "approve with revisions" |
| 21:10 | Spec revised: SQLite ledger, in-flight Claude upsert, Codex component deltas (ignore the total remainder), Grok eventId dedup, catch-up scheduling, ownership log in stage 1 with claim-seam/backstop/heartbeat/strict seed, gap rule, Coverage KPI, per-provider `dataThrough`, outlier break, markers switches-only by default, six stages; consult log §8 |
| 21:12 | Branch pushed; draft PR opened for stage 0 |

## Stage 0 — research + proposal (branch `feat/token-telemetry-research`)

Deliverables: research doc, spec (revised after consults), this status doc,
consult brief + two reviews, check-in brief, census/prototype tools.

## Decisions so far

- Consumption ≠ quota: header line once per surface with per-provider
  `dataThrough`; no percentages of limits.
- Units: Claude deduplicated message (`message.id`, full snapshot of the
  max-output record, in-flight upsert); Codex component deltas between
  distinct cumulative snapshots (total remainder ignored); Grok completed turn
  (`_meta.eventId`).
- Store: **SQLite** (system `SQLite3`) ledger under
  `~/Library/Application Support/Claude Usage/telemetry/`, unique `unitId`,
  one transaction per slice; never UserDefaults.
- Attribution by time from our own ownership log (claim seam when available,
  external observation, tick backstop, hourly heartbeat, strict ring seed
  skipping focus-only rows); joined at query; gaps unattributed; three bands.
- Window: layout B, default 7 days, Fleet chart Split by default, Coverage
  KPI at Fleet, list-price equivalent shown and labelled "not billed",
  switches-only markers collapsed per bucket (stops opt-in) — pending the
  owner's check-in; proceeding on these if silent.
- Stages: 1a ledger + ownership · 1b readers + scheduler · 2 report model ·
  3a window shell (+ DEBUG frame harness) · 3b chart · 4 attribution polish.

## Open questions

Spec §6. The one change since the brief went out: markers default to
switches only (the brief recommended switches + rate-limit stops).
