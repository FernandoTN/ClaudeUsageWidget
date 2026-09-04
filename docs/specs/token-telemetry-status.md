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

## Deploy of 1a + 1b (fixes session, 2026-09-03 22:01 PDT, pid 90169)

Seeded 26 ownership rows from the switch ring; catch-up 141 slices in the
first 2 m 16 s at ~1 slice/s (64 MB each), backlog 28.07 GB → 0 in 5 m 32 s
(~68 MB/s); main thread idle throughout (all `sample` frames parked in
`nextEventMatchingMask`; the work on the `com.claudeusagewidget.telemetry`
queue); CPU 67–93 % during catch-up then 0 %; RSS peaked 453 MB (the pass's
working set) and fell to 230 MB; sweep, preflight, ⇄ selector, exposure
probes unaffected; 0 cfprefsd rejections. **Ledger 683 MB on schema v1**
(~540 B/event) — the trigger for schema v2 below. Incremental ticks after
the next deploy (main `d45d518`): "slice: 4 files, 488 KB, +12 events".

## Stage 2 — report model + ledger v2 (PR pending)

`Telemetry/TelemetryQuery.swift` (scope / window / metric / stack; windows →
local-calendar buckets at query time, hour / day / week → month, DST by the
calendar; previous period over the same elapsed portion),
`TokenPriceTable.swift` (shipped list prices, longest-prefix match, nano-USD),
`AttributionResolver.swift` (timeline with the gap rule, byPath for isolated
Codex homes, sole account for Grok; two-heartbeat trailing trust),
`TelemetryReport.swift` (minute aggregates → attributed rows → buckets /
series with the Other fold, KPI totals + previous, 7-bucket mean over complete
buckets, model and account tables with Unattributed last, coverage,
per-provider provenance and caveats, outlier verdict ≥ 14 buckets and > 20×
the non-zero median, provider-native counts), `TelemetryLedger` v2 (interned
strings, in-place migration, `aggregateMinutes`, `distinctSessions`,
checkpoint), slice budget 32 MB. Tests: `TelemetryReportTests` (9),
`TelemetryLedgerTests` +3 (migration from a hand-built v1 file, aggregation,
reassignment); opt-in migration timing test.

Measured on an online copy of the live ledger (1,261,884 events): migration
5.6 s including `VACUUM`, 716 MB → 302 MB (239 B/event); last-24 h minute
aggregates 6,997 rows.

## Stage 2 deploy (fixes session, 22:15 PDT, pid 43841)

Migration on the live ledger 683 MB → 287 MB; first incremental slice 8 s
after launch; main thread untouched; RSS 164 MB idle. Follow-ups folded into
3a: the WAL sat at the 64 MB cap because the checkpoint was keyed to a bounded
catch-up — now after any slice that wrote, and right after the migration's
VACUUM; the migration logs its duration and sizes.

## Stage 3a — window shell (PR pending)

`Telemetry/TelemetryWindowController.swift` (one reusable titled window with
a hidden titlebar, created on first show, observer installed at launch by
`TelemetryService.start()`, frame persisted in ledger meta, foregrounded via
`MenuBarManager.bringWindowToForeground`), `TelemetryWindowModel.swift`
(scope / window / metric, Fleet report → sidebar, reloads only while
visible, `.telemetryLedgerUpdated` throttled, `scope(from:)` for the
notification's object + userInfo forms), `TelemetryView.swift` (pure-SwiftUI
sidebar and segmented controls, KPI tiles, static stacked columns with the
7-bucket mean and ⇄ markers, by-model / by-account tables with the
`ActiveVocabulary.activeFor` badge, footer with Refresh now / Pause indexing
/ Copy numbers, indexing / empty / degraded / paused states),
`TelemetryFormatting.swift` (compact numbers, USD, deltas; the data-viz
palette as the module's only literal colours), `TelemetryFrameHarness.swift`
(DEBUG; 13 states × light/dark to `telemetry-<state>-<light|dark>@2x.png` +
the shared `index.md` section), `TelemetryService` report/status API. Strings
under `telemetry.*` in `Localizable.strings`. Tests: `TelemetryWindowTests`
(4, renders the frames with `TEST_RUNNER_CUW_RENDER_FRAMES`). Design passes
17–25 recorded in the spec §5. Full suite 502 / 0 (2 opt-ins skipped).

Stage 3a merged as `2ea61f9` (#105). WAL note from the fixes session: on a
normal launch the end-of-catch-up TRUNCATE leaves the WAL at ~300 KB; the
64 MB residue was the migration launch (VACUUM after the checkpoint), and
the checkpoint follows the VACUUM since 2ea61f9. The 22:29 PDT auto-switch
(Google → jskxkxjssh) was confirmed in the live ledger as ownership seq 30,
exactClaim / activate.

## Stage 3b — the chart (PR #108)

`Telemetry/TelemetryChartView.swift`: Canvas columns (≤ 24 pt, 2 pt gaps,
rounded top), hairline gridlines, nice-number axis, 7-bucket mean, hatched
partial bucket, clipped outliers with a break mark and value, ⇄ counts;
Stacked and Split modes (Fleet opens Split); hover crosshair + column band +
one tooltip with every series; ←/→ and Return; click → the bucket's own
by-model / by-account breakdown (`TelemetryBucketBreakdown`, fed by the new
`byModel` / `byAccount` on every `TelemetryBucket`); legend click isolates.
`TelemetryChartMath` pure (ceiling, trailing mean, hit-test). Frames added:
fleet-7d-stacked, fleet-7d-hover, provider-claude-isolated. Ownership claim
and external-observation writes log one line each. Design passes 26–31.
Full suite on the merged tree 519 / 0.

Stage 3b merged as `fe8f7f4` (#108); deployed by the orchestrator at
22:46:58 PDT (pid 57516): first incremental slice 5 files / +1043 events /
1.81 s, ledger 288 MB, WAL 0 KB after the checkpoint, RSS 168 MB idle.

## Stage 3c — the punch list

Every MUST and SHOULD from the orchestrator's 3b review (T1–T25) plus the
By-kind 100 % share toggle. Delta sanity ("new" / "from 2.33 B") with one
comparison caption under the tiles; mean on the clipped series and named
by bucket unit; model colours by provider hue and tier step; the by-kind
ramp re-stepped and validated (≥ 16.6 ΔE every adjacent pair, both
surfaces — the old dark steps sat at ΔE 4.9); hatched partial swatch;
the shared `ActivePill` in the sidebar and By account rows (it landed on
main as f887cdf mid-stage, so the swap is in this PR); account scope shows "Active for <provider> in this window" spans instead of the
100 % self-reference; degraded state keeps last-known sidebar numbers and
names the ledger path; collapsible "About these numbers" persisted in
ledger meta; `ViewThatFits` scroll fallback so the footer is never
clipped; month-boundary axis labels; "≈ Cost"; "still to index";
"· paused"; provider-unit count tile for accounts. Frames added:
fleet-7d-notes (760 pt tall), fleet-by-kind-share; degraded now carries
the path. Tests: delta / mean label / comparison caption, model colour
steps, ownership spans. Design passes 32–43.

Stage 3c merged as `d3c9866` (#115; the orchestrator gated and squashed it
after this session's merge was blocked by its permission classifier) and
deployed 23:12:51 PDT (pid 62272): first incremental slice 9 files /
+95 events / backlog 0, ledger 288 MB, WAL 0, RSS 160 MB. Orchestrator's
3c review: every item resolved; one leftover, T26 (Split-axis ⇄ replacing
the date), carried into 4a. The duplicate-key finding from the 3c merge
(four setup-wizard keys defined twice on main) was fixed by the
orchestrator in `6e81128`.

## Stage 4a — attribution polish, part 1

T26 (the month-boundary yield rule applied to dense axes — a rule, not a
marker; now sparse axes only, tested); the rate-limit overlay as an opt-in
legend checkbox with per-bucket status triangles, placed by attribution
like units and per-series in Split; switch detail on the ownership spans
("first claim (activate) · handed to dJormun (activate)"); Export CSV…
with four provenance comment lines and provider / source / attribution /
cost_basis columns on every row, built from the report's own input.
`TelemetryExport` is pure; `TelemetryEngine.reportInput` is the one read
path for report and export. Frames added: fleet-7d-ratelimits,
provider-claude-ratelimits. Tests: `TelemetryExportTests` (6). Design
passes 44–48.

Stage 4a merged as `7a74fed` (#120; approved from the frames, T26 confirmed
fixed) and deployed 23:29:01 PDT (pid 23312): the new ownership info line
logged the first claim at 23:29:05, first incremental slice at 23:29:07,
ledger 288 MB / WAL 0, RSS 161 MB.

## Stage 4b — the stack switch

`TelemetryStack.sidechain` (Main vs subagents) beside the existing
originator stack; `TelemetryStack.options(for:provider:)` and
`title(provider:)` decide what a scope offers and what it is called
(Project for Claude and Grok, Originator for Codex, Source across the
fleet). The window model holds `stack` (resets with the scope) and passes
it to the scoped query and the export; a pure-SwiftUI pill beside the
chart title opens a popover of the options. Ranked parts of one provider
wear its hue at lightness steps. Frames added: provider-claude-sidechain,
provider-codex-originator. Tests in `TelemetryExportTests` (+1). Design
passes 49–50.

Stage 4b merged as `5a2b12e` (#122; approved from the frames) and deployed
23:36:53 PDT (pid 56402): catch-up complete at 23:36:59, ledger 303 MB,
WAL 0, RSS 165 MB.

## Stage 4c — compaction

Schema v3 (additive): `minutes` keyed by provider / UTC minute / model /
source / sidechain / session with exact first and last times, and
`compacted` (per-file watermark). `TelemetryLedger.compact(before:
maxSeconds:)` folds raw events older than the cutoff one UTC day per
transaction; `aggregateMinutes`, `distinctSessions`, `eventCount` and
`eventTimeSpan` read the union of both tables; `upsert` drops a replay at
or before a file's watermark. `TelemetryEngine.maybeCompact` runs at the
end of a non-catch-up tick, 90-day age, 2 s budget, one completed pass a
day, checkpoint after, one log line. Tests: `TelemetryCompactionTests`
(4: equivalence on 200 synthetic days, in-flight rows stay raw, replay
dropped / new file lands / watermarks survive reopen, budget stops after a
day and resumes). Design pass 51.

Stage 4c merged as `734755c` (#123), held back from deploy until the
imminent auto-switch completes (it is inert on this ledger anyway).

## Stage 4d — isolated Codex homes attribute by path

The T27 defect (isolated-home rollouts credited by time to the default-home
owner, because the home never reached the aggregate). `TelemetrySourceRoots`
learns the default home; the indexer writes "<home>/<originator>" for
isolated homes; `AttributionResolver.codexHomeSlug` / `codexOriginator`
split it; the Originator stack labels "exec (xfenrir-dev)"; the Codex
reader state carries `sourceVersion`, and a cursor below the current one
marks its file for a replace-in-transaction re-index (`deleteEvents` +
upsert + cursor save), counted at scan time into meta
(`codexReindexPending_v1`) and shown in the Codex notes while files remain.
Tests: `TelemetryIndexerTests` (+1, end to end). Design pass 52. Harness
fixture sources are now "exec" and "xfenrir-dev/vscode".

Stage 4d merged as `6a5eab2` (#124) and deployed 23:57:36 PDT (pid 54481;
bar pinned, RSS 165 MB, 0 cfprefsd rejections). **Dormant on this Mac:**
all four isolated homes under `~/.codex-accounts/` (xfenrir-dev,
xfho-fer-hotmail-com, xfme-fernando-mymemori-app, xlucifer-dev) hold zero
rollouts — the widget copies each account's auth into `~/.codex` on a
switch, so every Codex session so far ran in the default home and is
attributed by time. The first tick after launch was an ordinary slice
(13 files, +259 events): no re-read, no pending line, and the Codex
Unattributed share will NOT move until Codex is run with `CODEX_HOME`
pointed at an isolated home. It moves only when a switch-history gap
closes.

## First live compaction pass (4c), verified

Contrary to the "nothing is 90 days old yet" note above, the Codex archive
reaches back to mid-May 2026, so the first non-catch-up tick after the
`734755c` deploy (23:53:02 PDT) folded 1,063 Codex rows from six UTC days
(May 14, 15, 19, 21, 22, 29) in 43 default-home files into 201 minute rows;
WAL 8 KB after the checkpoint, ledger unchanged at 288 MB. Verified
read-only at 23:56 PDT — a `sqlite3 .backup` of the live ledger against the
22:11 v2 copy that still held the raw rows — with zero deltas per day
(units, every token column, cost, unpriced, distinct sessions, first and
last times) and zero differences in both directions on the (provider,
minute, model, source, sidechain) keys (99 keys each side; 201 rows collapse
to 99 once sessions merge, by design). No raw row older than the cutoff
remains; none of the 43 files is in an isolated home, so the 4d re-index
never meets a compacted file. Scripts: `~/.claude/jobs/35d51d44/tmp/
verify-compaction.sh`, `verify-compaction-2.sh`.

Stage 4 is closed. The orchestrator's final frame-by-frame pass on
`6a5eab2` (all three surfaces) found nothing new for telemetry — the
expanded notes, legend isolation, Split axis with ⇄ markers, dark chart,
rate-limit overlay and stack pill all hold; no T28. Deployed as pid 54481.
Nothing further is queued until the owner reviews the window live.

## Next

The fixes session's punch
list on the shell (typography, sidebar density, footer actions) once its
pixel pass lands.

## Open questions

Spec §6. The one change since the brief went out: markers default to
switches only (the brief recommended switches + rate-limit stops). No owner
reply yet; proceeding on the recommendations.
