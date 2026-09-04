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
| 21:12 | Branch pushed; draft PR #81 opened for stage 0 |
| 21:15–21:20 | Stage 1a built: `Telemetry/TelemetryEvent`, `TelemetryLedger` (system SQLite), `OwnershipRecorder`, `TelemetryService`; AppDelegate start hook. 16 tests; full suite 429 / 0; PR #87 |
| 21:25 | Fixes session landed the claim seam `.providerOwnerClaimed` (#89, `1353cfd`) exactly as requested |
| 21:20–21:35 | Stage 1b built: `JSONLFraming`, three readers, `TelemetryIndexer`, catch-up ticks. Bugs found by the tests before any real data: a byte-bounded file re-queued with its stale cursor (would never progress), a line longer than the byte budget stalling forever, `/private/var` symlink garbling the Claude file id, Grok's `_meta` living inside `params` |
| 21:35–21:45 | Real-corpus verification (opt-in test): the test host was killed at ~4 min — autorelease growth from 1.8 M parsed lines; per-line and per-file pools added |
| 21:47–21:55 | Verification rerun: 15,402 files, 28.16 GB, 53 slices, 467 s; matches the census (§ below); 6.1 B Codex tokens sat before a rollout's first `turn_context` → "unknown" units now take the file's first model (`reassignUnknownModel`) |
| 22:00 | #81 (stage 0) squash-merged as `2237730`; #87 (stage 1a, merged tree 455 / 0) squash-merged as `b73c776`; both shas sent to the fixes session with a request to deploy after 1b |
| 22:05 | Stage 1b merged with main (three add/add conflicts from the squash, resolved to the 1b versions); full suite 475 / 0 (1 opt-in skipped); PR #98 retargeted to main |

## Stage 0 — research + proposal (MERGED `2237730`, #81)

Deliverables: research doc, spec (revised after consults), this status doc,
consult brief + two reviews, check-in brief, census/prototype tools.

## Stage 1a — ledger + ownership (MERGED `b73c776`, #87)

`Telemetry/TelemetryEvent.swift`, `TelemetryLedger.swift` (SQLite, 0700/0600,
WAL; unique unit key; events never regress to a smaller output; markers,
cursors, ownership, health, meta), `OwnershipRecorder.swift` (exactClaim /
externalObservation / observedAtTick / heartbeat / strict ring seed),
`TelemetryService.swift` (serial `.utility` queue, DispatchSource timer,
`OwnerSnapshotBox`, `os.Logger` category `telemetry`); one call in
`AppDelegate.applicationDidFinishLaunching` (skipped under XCTest).
Tests: `TelemetryLedgerTests` (11), `OwnershipRecorderTests` (6).

## Stage 1b — readers + indexer (PR #98)

`JSONLFraming`, `ClaudeTranscriptReader`, `CodexRolloutReader`,
`GrokUpdatesReader`, `TelemetryIndexer` (+ `TelemetrySourceRoots.live()` via
`Constants.ClaudePaths.projectsDirectory`, `CodexUsageService.defaultCodexHome`
+ `isolatedHomesRoot`, `~/.grok/sessions`), catch-up scheduling in
`TelemetryEngine.tick`, `TelemetryService.refreshNow()`. Tests:
`TelemetryReadersTests` (9), `TelemetryIndexerTests` (9),
`TelemetryCorpusVerificationTests` (opt-in, `TEST_RUNNER_CUW_TELEMETRY_VERIFY=1`).

Real-corpus verification vs the census (2026-09-03 21:50 PDT):

| | Indexer | Census | Note |
|---|---|---|---|
| Claude units | 861,739 | 861,785 | a few message ids appear in two files and now collapse (global unique key) |
| Claude cache reads / output | 251.57 B / 677.06 M | 251.45 B / 677.14 M | new data since the census; 12,444 units in flight (the last message of every file) |
| Codex input incl. cached / output | 54.25 B / 181.3 M | 54.23 B / 181.3 M | 398,567 deltas; "unknown" model 6.1 B before the reassignment fix |
| Grok input incl. cached / output | 932.9 M / 21.38 M | 931.2 M / 21.35 M | 1,159 turns |
| Rate-limit markers | 2,228 | 2,228 | exact |
| Malformed / unknown / unreadable | 0 / 0 / 0 | — | |

First full pass in one process: 467 s for 28.2 GB (SQLite upserts + JSON
parsing; the prototype's 50 s was read + prefilter only). In the app it runs as
catch-up slices at `.utility`, so expect ~15–20 min of background work after
the first deploy, then tens of MB per tick.

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

## Next

Stage 2 (report model: bucketing, attribution resolver, shares, price table,
coverage, outlier rule, per-provider provenance), then 3a (window shell +
DEBUG frame harness `CUW_RENDER_FRAMES`), 3b (chart), 4 (attribution polish).
The fixes session deploys after 1b so the ledger starts accumulating.

## Open questions

Spec §6. The one change since the brief went out: markers default to
switches only (the brief recommended switches + rate-limit stops). No owner
reply yet; proceeding on the recommendations.
