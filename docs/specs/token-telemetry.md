# Token usage — a consumption telemetry window

**Date:** 2026-09-04 (revised the same night after the consults, §8)
**Base:** `main @ 0d762a8` (#75 added the entry points that post `.telemetryWindowRequested`)
**Research:** `docs/research/2026-09-04-token-telemetry-sources.md` (every number below that is not a design choice comes from it); tools in `docs/research/tools/token-telemetry/`
**Status doc:** `docs/specs/token-telemetry-status.md`
**Check-in brief:** `docs/specs/token-telemetry-checkin.html` (self-contained)
**Consults:** `docs/specs/consults/2026-09-04-codex-token-telemetry-review.md`, `…-grok-token-telemetry-review.md`, brief `…-token-telemetry-consult-brief.md`

## 0. What the owner asked for, and the two rulings that shape it

> "a new window … mostly for visuals that show some telemetry, meaning token
> usage … by model and for all-time, 7-day, or 30-day … also for Codex and
> maybe for Grok … per provider or the aggregate of all of them, so that we
> can see trends and how it has impacted through time."

Rulings inherited from the fleet work, not relitigated:

- **Consumption is not quota.** The CLIs' local logs say how many tokens were
  *sent and received*; the providers' bars weigh those differently and are read
  from their endpoints by the rest of the app. This window never shows a
  percentage of a limit and never a synthetic value. It says "consumption"
  once per surface and prints the source and age beside every headline.
- **Nothing leaves the machine.** Every read is local. The cost estimate uses
  a price table shipped in the binary.

The research settles what exists: Claude Code transcripts (14.2 GB, 30-day
rolling retention), Codex rollouts (12.2 GB, kept forever), Grok session
updates (1.7 GB, ~30 days) — all three carry model and timestamp, none of them
carries the account. Two facts drive the design more than any layout choice:
the store must be the archive (the CLIs prune), and per-account numbers are
only as good as the widget's own record of who owned each CLI login when.

## 1. First principles: what the window must answer

Ranked by how often the owner will open it for that answer:

1. **How much are we burning, and is it going up?** — tokens per day, by
   provider, over 7 and 30 days, with the trend visible without reading a
   single number.
2. **What is doing the burning?** — by model (Opus 5 is 76 % of Claude
   messages; `gpt-5.6-sol` is 99 % of Codex) and by *kind*: 96.8 % of Claude
   input-class tokens are cache reads, 29.5 % of output is thinking, Codex is
   95 % cached. A window that shows "260 B input" without splitting cache
   reads from uncached input misleads about both cost and load.
3. **Which account carried it, and when did we move?** — per profile, with
   the switches drawn on the timeline so a burn can be read against the
   account that was Active for that provider at the time.
4. **What would this cost at list price?** — a labelled equivalent; the
   subscriptions are flat, but the equivalent is the only common unit across
   Opus/Fable/Sonnet and across providers, and it is what makes "impact"
   legible.
5. **How complete is this?** — indexed through when, per provider; how much
   of the history is attributed; which sources are incomplete (Grok cancelled
   turns, Claude pre-index history).

What it does **not** answer: remaining quota, when a window resets, who to
switch to. Those live in the bar, the dashboard and the inspector.

## 2. Data contract (stages 1–2)

### 2.1 Unit records (`Telemetry/TelemetryEvent`)

One record per **deduplicated** unit. Events are immutable facts about a
source line; they carry **no attribution** (ownership is joined at query time
from the ownership log, so a repaired pointer never rewrites history).

| Field | Claude | Codex | Grok |
|---|---|---|---|
| `provider` | `claude` | `codex` | `grok` |
| `unitId` (unique) | `message.id` (fallback `requestId`, then `uuid`) | `<fileId>#<snapshot seq>` | `_meta.eventId` (fallback `<sessionId>#<prompt_id>`) |
| `at` (UTC) | `timestamp` | event `timestamp` | `timestamp` (epoch s) |
| `model` | `message.model` | latest preceding `turn_context.model` (`unknown` if none) | `modelUsage` key |
| `input` (uncached) | `input_tokens` (already uncached) | `input − cached` (clamped ≥ 0) | `inputTokens − cachedReadTokens` (clamped) |
| `cacheRead` | `cache_read_input_tokens` | `cached_input_tokens` | `cachedReadTokens` |
| `cacheWrite` (+ `cacheWrite1h`) | `cache_creation_input_tokens` (+ `cache_creation.ephemeral_1h_input_tokens`) | `cache_write_input_tokens` when present | `cacheCreationTokens` |
| `output` | the **full usage snapshot of the max-output record** for the id (never maxima mixed across records) | `output_tokens` component delta (clamped ≥ 0) | `outputTokens` |
| `reasoning` (⊂ output) | `output_tokens_details.thinking_tokens` from that same record | `reasoning_output_tokens` delta (clamped, ≤ output) | `reasoningTokens` |
| `reportedCostNanoUSD` | — | — | `costUsdTicks` (null → no cost for that turn, never interpolated) |
| `session` / `sidechain` | `sessionId`, `isSidechain` | rollout file id | session uuid |
| `source` | project slug from `cwd`, `entrypoint` | `originator` / `source` (exec, vscode, cli, guardian, thread_spawn) | cwd |
| `fileId`, `sourceOffset` | relative path under the projects root + inode | rollout **basename** (unique `rollout-<ts>-<uuid>`) + inode — a move into `archived_sessions` is not a new file | session dir + inode |
| `parserVersion` | 1 | 1 | 1 |

Rules the census and the consults fixed:

- **Claude**: one `assistant` record per content block; collapse by
  `message.id`; skip `<synthetic>` and **any record whose usage is all zeros**
  (errors); never add `iterations[]` (it mirrors the top-level usage);
  subagent files count and are labelled; retries with distinct ids are
  distinct consumption. A unit is **in flight** until a later record of the
  id carries `stop_reason` or the file has not grown for one tick; the store
  upserts the in-flight snapshot by `unitId`, so a partial output seen on one
  tick is corrected — not duplicated — on the next. Uniqueness is global, not
  per file (`--continue` in another cwd can start a second file).
- **Codex**: cumulative `total_token_usage` per rollout, re-emitted unchanged
  8.6 % of the time; consume **component deltas** (`input`, `cached`, `output`,
  `reasoning`, `cache_write`), per-key negatives → 0 (output and reasoning
  step backwards 29 times each on disk), a drop in `total_tokens` → the
  components restart from zero. **Ignore the `total_tokens` remainder**: an
  `<EXTERNAL SESSION IMPORTED>` snapshot has every component 0 and
  `total_tokens` 11,177 — emit nothing when every component delta is 0.
  `last_token_usage` is diagnostic only. The cursor persists the **last
  component vector and current model**. Index by file, never by
  `session_meta.id` (76 ids are shared by subagent rollouts).
- **Grok**: sum `turn_completed.usage.modelUsage` per turn (per-turn, not
  cumulative — verified on an 8-turn session); dedup by `_meta.eventId`;
  `unified.jsonl` (per call, ~3 days) is **not** folded in — cancelled turns
  stay missing and the footer says so.
- **Cross-provider footgun**: only Claude's `input_tokens` is already
  uncached; a generic `input − cacheRead` under-counts Claude. A fixture has a
  Claude row with `input_tokens = 2` and tens of thousands of cache reads.

Excluded, recorded as **markers** instead (`TelemetryMarker`): Claude
`error: rate_limit` deaths and `quotaLimits` rejections (kind, at, session).
Codex `rate_limits` snapshots are not stored at all (quota, not consumption).

### 2.2 Store (`Telemetry/TelemetryLedger`) — SQLite, system library

`~/Library/Application Support/Claude Usage/telemetry/ledger.sqlite` (directory
`0700`, files `0600`; WAL; one serial `.utility` queue; `import SQLite3` — a
system framework, not a dependency).

```
events    (unit_id TEXT PRIMARY KEY, provider, at REAL, model, input, cache_read, cache_write, cache_write_1h,
           output, reasoning, cost_nano INTEGER NULL, session, sidechain, source, file_id, source_offset,
           parser_version, in_flight INTEGER)                         -- INSERT … ON CONFLICT(unit_id) DO UPDATE
markers   (marker_id PRIMARY KEY, provider, kind, at, session, detail)
cursors   (file_id PRIMARY KEY, path, inode, size, mtime, offset, state BLOB)  -- state = Codex component vector + model, Claude in-flight ids
ownership (seq PRIMARY KEY, at, provider, profile_id, previous_profile_id, account_stamp, name, basis, cause)
health    (provider PRIMARY KEY, scanned_at, data_through, files_seen, files_unreadable, lines_malformed,
           unknown_shapes, backlog_files, backlog_bytes)
meta      (key PRIMARY KEY, value)                                    -- schema version, price-table version, window frame, last scope
```

**Schema v2 (stage 2, after the first deploy measured ~540 B/event on v1):**
`file_id`, `session` and `source` are interned into a `strings(id, value
UNIQUE)` table and stored as integer refs on `events`; a v1 ledger is rebuilt
in place on first open inside one transaction that also bumps the version
(measured on a copy of the live 716 MB / 1.26 M-event ledger: 5.6 s including
`VACUUM`, 302 MB after, 239 B/event). A WAL cap (`journal_size_limit` 64 MB)
and a `wal_checkpoint(TRUNCATE)` at the end of each catch-up run keep the
sidecar small.

Why SQLite over the first draft's monthly JSONL (consult §8): the ledger needs
a **unique unit key** (Claude in-flight upsert, shrink/rewrite re-reads, Codex
files moving into `archived_sessions`, crash replays) and **one transaction**
covering events + cursor advance; append-only files plus atomic renames do not
close the cursor-vs-events crash window, and a JSON sidecar for in-flight state
would be a second system. Rollups are derived, cached in memory and
recomputed from the ledger when the time zone, the ownership log or the
price table changes. No UserDefaults anywhere (cfprefsd), including the
window frame and last scope — they live in `meta`.

### 2.3 Indexer (`Telemetry/TelemetryIndexer`, `nonisolated`)

- **Own timer on the serial `.utility` queue** (`DispatchSource.makeTimerSource`),
  never the sweep, never a main-run-loop `Timer`. Steady state every 5 min
  (60 s while the window is open). **Catch-up**: while a pass hits a bound, the
  next slice is scheduled immediately (250 ms yield) — the first 27 GB is
  minutes of wall clock, not hours (12,560 files at 200 per 5-minute tick
  would be 5 h).
- Roots from the app's own seams: `Constants.ClaudePaths.projectsDirectory`
  (honours `CLAUDE_CONFIG_DIR`), `CodexUsageService.defaultCodexHome` +
  `isolatedHomesRoot` (honours `CODEX_HOME`), `~/.grok/sessions`. All roots
  and the ledger URL are injected; **tests never touch the real home**.
- Per-file cursors keyed by `fileId`; a candidate is a file whose
  `(inode, size, mtime)` differs from its cursor. Snapshot the size at open,
  read from `offset` to that size, frame on `\n`, **commit the cursor only
  through the last complete newline** (a partial last line is normal), a
  shrink re-reads from 0 (the unique key makes that idempotent), a vanished
  file drops only its cursor — never its events.
- Byte-needle prefilter before any JSON parse (`"type":"assistant"` and the
  spaced variant, `"token_count"`, `"turn_completed"`); `tool-results` pruned;
  chunked `FileHandle` reads (six files exceed 50 MB).
- **Bounded by files, bytes and wall time** (≤ 200 files, ≤ 64 MB, ≤ 2 s per
  slice), resuming inside a file at a newline. One transaction per slice:
  events upserted, markers inserted, cursors advanced, health updated.
- A store failure, disk-full, unreadable file or unknown shape **does not
  advance the cursor**; it increments the provider's health counters, which
  the window shows — never as zero consumption.
- The tick takes an immutable `OwnerSnapshot` (three pointers, stamps,
  `isSwitchingProfile`) captured on the main actor; the indexer queue never
  touches `ProfileManager`. A switch in flight pauses only the ownership
  write, never the file walk.
- Verification: `TelemetryIndexerTests` on fixtures for every rule above;
  a Lab-only harness (`CUW_TELEMETRY_VERIFY=<root>` env, DEBUG) runs a full
  pass against a directory and prints per-provider totals to compare with
  the census tools.

### 2.4 Ownership log (stage 1, so it accrues from the first deploy)

| Writer | When | Basis recorded |
|---|---|---|
| Claim seam | the moment `claimActive{Claude,Codex,Grok}Ownership` sets a pointer (a notification posted from that seam — asked of the fixes session; until it lands, the backstop below) | `exactClaim` |
| `.providerOwnerChangedExternally` | an adoption pass routed a CLI-side login to a profile — an **observation**, not the switch time | `externalObservation` |
| Tick backstop | the snapshot's owners differ from the last logged owner per provider | `observedAtTick` |
| Heartbeat | one row per provider per hour while unchanged, bounding downtime gaps | `heartbeat` |
| Seed | once, from the 30-entry switch ring: only rows whose `to` name maps to exactly one current profile of exactly one provider, **skipping focus-only rows** (`reason` starts "focus only") | `seededFromRing` |

Attribution (stage 2, at query time): a record at time *t* belongs to the
profile whose ownership interval brackets *t* with `exactClaim` or
`seededFromRing` evidence; between the last sighting of A and the first
sighting of B under observation-only evidence the interval is
**unattributed** — never "B, approximately". Isolated Codex homes attribute by
path (`Profile.codexHomePath`); a single Grok account attributes trivially.
Three bands, always shown: attributed · by path or sole account ·
unattributed (labelled "before <first ownership entry>").

### 2.5 Aggregation (`Telemetry/TelemetryReport`, pure)

```
TelemetryQuery(scope: .fleet | .provider(kind) | .account(id) | .unattributed(kind),
               window: .today | .days(7) | .days(30) | .allIndexed,
               metric: .inputClass | .inputByKind | .output | .cost,
               stack: .provider | .model | .account | .kind | .originator)
→ TelemetryReport(series: [Bucket], kpis: KPIs, models: [Row], accounts: [Row],
                  markers: [MarkerCluster], provenance: [ProviderProvenance])
```

- Buckets: `.today` hourly; 7 / 30 days daily; `.allIndexed` weekly, monthly
  once the history exceeds 26 weeks. Local calendar computed **at query time**
  from UTC `at` (never persisted per day). Today's partial bucket is drawn
  hatched, excluded from the trailing 7-bucket mean, and compared with the
  same elapsed portion of the previous period.
- KPIs by scope — Fleet: input-class (with the cache-read share), output
  (with the thinking share), **coverage** (attributed share · per-provider
  `dataThrough` · incomplete-source warning), estimate. Provider / account:
  the provider-native count (Claude messages with the subagent share; Codex
  sessions; Grok completed turns) replaces coverage. No sparklines (the hero
  chart is the trend).
- Outliers: when a series' largest bucket exceeds 20× the median of its
  **non-zero** buckets and the window has ≥ 14 buckets, the y-axis fits the
  typical range and the outlier column is drawn with a break mark and its
  value; "Show outliers" restores the full scale. Never a log axis, never a
  dual axis. Fleet scope defaults to **Split** (one row per provider, own
  scale) because Codex + Grok are 1.1 % of Claude; Stacked is one click away.
- Provenance per provider: `scannedAt` and `dataThrough` (a fresh scan of a
  stale source is not fresh data), health counters, caveat strings.
- Cost: `TokenPriceTable` (research §6) with `asOf` and a version; history is
  priced uniformly at the shipped rates (comparison, not accounting); Grok uses
  the CLI's nano-USD; Claude cache writes use the 5 m / 1 h split and fall back
  to the 5 m rate flagged approximate; unknown models contribute tokens only
  ("n models unpriced").

## 3. The window

### 3.1 Options considered

**A — Report page.** One scrollable column with filters in the header.
Simplest; weak on 24 accounts (a pop-up) and no home for an account's
switch timeline. Fallback if 1040 pt proves too wide.

**B — Source list + report (recommended; both consults concur).** A sidebar
scopes the report: *Fleet*, then each provider, its accounts, and an
*Unattributed* row; the main pane is A's stack for the selected scope. The
chart's stacking follows the level (Fleet by provider, a provider or an
account by model). The inspector's deep link selects a sidebar row. **Selecting
a row is a scope, never `viewProfile`.**

**C — Tabs.** Hides the comparisons the owner asked for. Rejected.

### 3.2 B, frame by frame

```
┌ Token usage ────────────────────────────────────────────────────────────────── 1040 × 680 ┐
│ ┌ sidebar 220 ┐ ┌ report ──────────────────────────────────────────────────────────────┐ │
│ │ Fleet       │ │ Fleet                                        Today  [7 days]  30 days  All │ │
│ │ ▸ Claude 17 │ │ Consumption read from local CLI logs · not quota · Claude through 21:04 · … │ │
│ │   dRir  Cl  │ │ ┌ Input-class ─────┐ ┌ Output ─────────┐ ┌ Coverage ─┐ ┌ ≈ API list ──┐ │ │
│ │   dJormun   │ │ │ 78.3 B  ▲ 48 %   │ │ 120 M  ▲ 14 %   │ │ 82 % attr.│ │ $58.7 k       │ │ │
│ │   …         │ │ │ 97 % cache reads │ │ 30 % thinking   │ │ Grok: turns│ │ not billed ⓘ  │ │ │
│ │   Unattrib. │ │ └──────────────────┘ └─────────────────┘ └───────────┘ └───────────────┘ │ │
│ │ ▸ Codex  5  │ │ Input-class per day · Split ▾ · ─ 7-day mean                 Stacked | Split │ │
│ │ ▸ Grok   1  │ │ Claude  78.3 B · 98.9 %  ▃ █ █ ▃ ▇ █ ▆ ░                          20 B │ │
│ │             │ │ Codex   0.62 B · 0.8 %   ▄ ▆ ▄ ▁ ▁ █ ▄ ░                         250 M │ │
│ │             │ │ Grok    0.24 B · 0.3 %   ▂ ▂ ▆ ▃ ▆ █ ▄ ░                          70 M │ │
│ │             │ │        Aug 28  29  30  31  Sep 1  2  3  today      ⇄3   ⇄5  ⇄2         │ │
│ │             │ │ ┌ By model ──────────────────────┐ ┌ By account ───────────────────────┐ │ │
│ │             │ │ │ claude-opus-5 ███████▌ 62 % $… │ │ dRir  Active for Claude ████ 31 %  │ │ │
│ │             │ │ │ …                              │ │ Unattributed (before 09-03 01:14) ██│ │ │
│ │             │ │ └────────────────────────────────┘ └───────────────────────────────────┘ │ │
│ │             │ │ Sources · caveats · Refresh now · Pause indexing · Copy numbers            │ │
│ └─────────────┘ └──────────────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

**Frame 1 — the header.** Scope name (13 pt bold, the dashboard header
scale); window control `Today · 7 days · 30 days · All indexed` (default **7
days**); one 9 pt secondary line: "Consumption read from local CLI logs ·
not quota · Claude through 21:04 · Codex through 20:58 · Grok through 21:01".
The disclaimer lives here and nowhere else — never a banner.

**Frame 2 — the KPI row.** Four stat tiles, no sparklines: *Input-class*
("uncached + cache writes + cache reads" in the ⓘ) with the cache-read share;
*Output* with the thinking share; *Coverage* at Fleet (attributed share, the
oldest `dataThrough`, "Grok: completed turns only") or the provider-native
count in a provider/account scope; *≈ API list-price equivalent* — "not
billed · rates as of 4 Sep 2026" in the sub-line, ⓘ opens the table and the
mixed-methodology note. Deltas are signed, uncoloured (up is neither good nor
bad), against the same elapsed portion of the previous period. "Copy numbers"
copies the row as text.

**Frame 3 — the chart (the hero).** Columns ≤ 24 pt, 2 pt surface gaps,
4 pt rounded top, today hatched; hairline solid gridlines; clean `B`/`M`
ticks; a 2 pt 7-bucket mean in the secondary colour. Fleet: Split rows with
the series total and share in each row title; Stacked one click away.
Metric picker in the title: `Input-class · Input by kind (uncached / writes /
reads) · Output · Cost`. Hover: crosshair + one tooltip with every series and
the total. **Click a bucket** → a popover with that bucket's by-model and
by-account breakdown ("what was 16 July?"). Legend always present for ≥ 2
series; click to isolate (emphasis, never re-coloured). Under the axis,
**markers collapsed per bucket**: `⇄N` switches of the scope's provider
(tooltip lists who → who, trigger, reason); rate-limit stops `×N` are an
**opt-in overlay** (off by default — quota events belong to the dashboard;
here they explain dips when asked for).

**Frame 4 — two tables.** *By model*: model, native count, input-class,
cached %, output, thinking %, ≈ list equivalent, share bar (one hue, nominal
categories). *By account*: name, provider glyph, `ActiveVocabulary.activeFor`
badge on the current owner (never plain "Active"), tokens, ≈ equivalent,
last active, share bar; last row *Unattributed (before <first ownership
entry>)* in the secondary colour — shown, never redistributed. Account scope:
the second table becomes *Switches* (when this account became / stopped being
Active, what it burned in between). Provider scope offers a stack switch to
*by originator* (Codex: exec / vscode / cli / guardian) and *main vs
subagents* (Claude).

**Frame 5 — the sidebar.** `Fleet`; a disclosure group per provider with its
count; accounts sorted by activity in the window; the cyan `Cl/Cx/Gk` mark on
the current owner only; a compact total right-aligned **only when the
ownership log covers the window**, otherwise "—". `Unattributed` rows only
when non-zero. ↑↓ moves, → expands, type-to-select.

**Frame 6 — the footer.** Sources and caveats for the scope; `Refresh now`,
`Pause indexing` (after the first pass hammered the disk), `Delete telemetry
archive…` (confirmation; this is a durable behavioural archive), storage size
and record count.

**States.** Before the first pass completes: tiles show "indexing… 41 %" with
a determinate bar and the chart draws complete buckets. Ledger unwritable →
one footer line, the window keeps working from memory. Nothing for a scope →
"nothing indexed for <name> in this window". Health counters non-zero →
"3 files unreadable · 12 lines skipped" beside the provider's `dataThrough`.

### 3.3 Colour, type, light/dark, accessibility

- Series colours are the only literal colours in the module, from the
  validated data-viz palette (CVD-checked adjacent pairs; separate light/dark
  steps): providers **Claude = slot 1 blue, Codex = slot 2 orange, Grok = slot
  3 aqua**; models take slots 1–6 in a fixed table keyed by family (Opus,
  Fable, Sonnet, Haiku, GPT, Grok), the tail folds into *Other*. Colour
  follows the entity; filtering never repaints survivors.
- Everything else is semantic (`.primary`, `.secondary`, `.accentColor`,
  `.adaptiveGreen`, `AccountReadiness` colours for badges); text never wears a
  series colour. Type: 13 bold header / 9 secondary (dashboard header), 12
  bold section titles, 9.5 / 9 / 8.5 for rows and captions; tabular figures
  in tables and axes, proportional in tiles. Strings through
  `DashboardFormatting.age`, `ActiveVocabulary`, `Localizable.strings`
  (`"popover.token_usage"` already exists).
- Accessibility: each chart exposes a summary ("7 days, Claude 78 B
  input-class, peak Sep 2 19 B"); tables are the table view; the legend is
  the identity channel; a texture fill is available for the CVD setting;
  every tooltip value is also reachable without hovering.

### 3.4 Window plumbing (agreed with the redesign and UX-revamp sessions)

- `Telemetry/TelemetryWindowController`: one instance, **titled window with a
  hidden titlebar** (the `BorderlessSettingsWindow` pattern — never
  `.borderless`, which reintroduced the window-server storm),
  `isReleasedWhenClosed = false`, **reused** across opens (the hosting
  controller is kept, so sidebar selection and scroll survive), double-open
  guard, `MenuBarManager.bringWindowToForeground`, no activation-policy flip,
  no SwiftUI `Window` scene. Frame and last scope persisted in `meta`, not
  `autosaveName`.
- The **observer is registered at launch** (a lazily created controller would
  drop the first post). `.telemetryWindowRequested`: object `UUID?`, userInfo
  `"provider"` decoded both as `Profile.ProviderKind` and as its `String`
  name; `(nil, .claude)` opens the provider scope, `(nil, nil)` Fleet. Posters
  on main since #75; the UX-revamp sibling adds the ⇄ footer entry and the
  inspector's "Usage history". Reverse link: "Open in Accounts…" posts
  `SettingsRoute` (2a) or `"manageProfiles"` until then.
- A `WindowCoordinator` is built only when a third window kind demands it
  (redesign session's call); this controller registers then, not before.
- **DEBUG frame harness** (owner instruction, relayed 2026-09-04): with
  `CUW_RENDER_FRAMES=<dir>` at launch, render every window state from fixture
  data — empty ledger, indexing 41 %, Fleet split and stacked, each window,
  provider scope, account scope attributed and unattributed, degraded — to
  `telemetry-<state>-<light|dark>@2x.png` plus `index.md`; ≤ ~200 lines,
  compiled out of Release.

## 4. Staged plan (one draft PR each, ≤ ~600 lines where possible)

| Stage | Contents | Tests |
|---|---|---|
| **0** (this PR) | research, spec, status, consults, check-in, census tools | — |
| **1a — ledger + ownership** | `TelemetryEvent`, `TelemetryMarker`, `TelemetryLedger` (SQLite schema, upsert, transactions, health, meta), `OwnershipRecorder` (claim-seam notification, external observation, tick backstop, heartbeat, strict ring seed), `OwnerSnapshot` | ledger idempotency (re-insert, shrink replay), transaction atomicity, ownership seed rules (unique name, focus-only skipped, cross-provider), off-main assertion |
| **1b — readers + scheduler** | `JSONLFraming` (size snapshot, newline framing, partial tail), `ClaudeTranscriptReader`, `CodexRolloutReader`, `GrokUpdatesReader`, `TelemetryIndexer` (bounds, catch-up, cursors, roots via app seams), Lab verify harness | fixtures for every rule in §2.1 (block duplicates and the in-flight finalize, all-zero records, `iterations[]`, Codex repeated totals, negative steps, external import, cache_write, multi-model, Grok multi-turn and duplicate eventId, truncated tail, moved Codex file), bound enforcement, cursor resume |
| **2 — report model** | `TelemetryQuery`/`TelemetryReport`, bucketing (hour/day/week/month, local zone at query), attribution resolver (three bands, gap rule), shares, `TokenPriceTable`, coverage, outlier rule, provenance | pure tests on synthetic ledgers; a golden test on a 3-day fixture; DST and time-zone change |
| **3a — window shell** | `TelemetryWindowController`, observer at launch, sidebar, header, KPI row, tables, states, footer controls, DEBUG frame harness | view-model tests; the harness's PNGs reviewed by the fixes session's pixel pass |
| **3b — chart** | `StackedColumnChart` (Canvas), split rows, hover layer, bucket click breakdown, legend isolate, collapsed markers, light/dark, accessibility summary | geometry tests (gaps, rounding, hatching, outlier break); render smoke in both appearances |
| **4 — attribution polish** | isolated-home mapping, *Switches* table, marker details, rate-limit overlay (opt-in), by-kind / by-originator / main-vs-subagent stacks, export CSV | attribution against a synthetic ownership log; originator fixtures |

Each stage: Release build + full suite green on the merged tree
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, dedicated
`-derivedDataPath`); per-surface design passes recorded in §5 before the PR
leaves draft; merge sha to the fixes session; status doc updated.

## 5. Design passes (what changed while going frame by frame)

1. The first draft summed transcript records; the census showed 2.09 records
   per message. The unit became the deduplicated message.
2. "Input tokens" as one number hid that 96.8 % are cache reads. The KPI
   became *input-class* with the cache share; *Input by kind* became a chart
   metric (consult).
3. A single fleet chart over "All indexed" was flattened by two July Codex
   days; small multiples were added, then (consult) the trigger was tightened
   to non-zero medians and ≥ 14 buckets, and an explicit outlier break with
   "Show outliers" replaced the silent switch.
4. A provider filter pop-up with 24 accounts read badly; the sidebar became
   the filter and gave attribution its own rows.
5. Per-account numbers looked authoritative before the ownership log existed;
   the unattributed band is drawn and dated; sidebar totals show "—" until
   the log covers the window (consult).
6. Cost coloured green/red implied good/bad; deltas lost their colour.
7. Grok's per-call log tempted a "calls" unit; completed turns are the unit,
   labelled, with the gap stated.
8. A log axis was rejected (stacks do not read on logs).
9. The disclaimer started as a banner; it became the header's second line,
   now with per-provider `dataThrough` (consult: one global age is not
   "every number carries its age").
10. Deep link = sidebar selection; one state model.
11. Real numbers showed Codex and Grok as slivers under Claude; Fleet defaults
    to Split.
12. The check-in mock's per-account rows are labelled illustrative.
13. (consult) The Fleet "messages & turns" tile mixed three nouns; it became
    *Coverage*. Sparklines were redundant beside the hero chart; dropped.
14. (consult) Rate-limit stops are quota events on a consumption chart;
    default markers are switches only, collapsed per bucket, stops opt-in.
    This flips the check-in's recommendation 5.
15. (consult) The mock's `$2,140` was not computed; the real 7-day figure is
    five figures ($58.7 k at list). The window computes it and labels it
    "API list-price equivalent · not billed".
16. (consult) A click on a bucket opens its breakdown — without it the hero
    chart is a poster.

Stage 3a, rendered through the `CUW_RENDER_FRAMES` harness at 1040 × 680
in light and dark (13 states × 2), reviewed frame by frame:

17. `List`, segmented `Picker`, `ScrollView` and `ProgressView` are
    AppKit-backed on macOS and render as blank/prohibited blocks in
    `ImageRenderer`: the sidebar, both segmented controls and the progress
    bar became pure SwiftUI (the sidebar scrolls only when its content is
    taller than the pane; ↑↓ move the selection through `onMoveCommand`).
18. Account share bars took palette slots by row index, so dJormun wore
    Codex's orange under a legend that said orange = Codex; account bars now
    carry their provider's hue, model bars their model family's.
19. "indexed 0 s ago" — ages used the wall clock while the fixture's clock
    was elsewhere; every age in the pane is measured against the report's
    `now`, so a rendered frame and the live window agree.
20. The Coverage tile's sub-line repeated its own value ("99 % · 99 %
    attributed") and clipped; it now says what is missing ("0.6 %
    unattributed · oldest 15:14").
21. The axis ceiling rounded 26.5 B up to 50 B (columns at half height) and
    printed "50.0 B"; the ceiling now snaps to 1 / 1.2 / 1.5 / 2 / 2.5 / 3 / 4 /
    5 / 6 / 8 / 10 × 10ⁿ and compact numbers drop false trailing zeros.
22. Four identical "indexing… 41 %" tiles read as a glitch; the indexing
    state is one wide tile with the remaining-files count and a bar, and the
    chart area says the numbers appear as files complete.
23. "CLAUDE · 3" as a section header above a "Claude" row said the same
    thing twice; the provider row is the header, count beside the name.
24. A clipped outlier column's "▲ 35.1 B" label truncated to "▲ 3…" at a
    30-bucket pitch, as did "Aug 6" on the axis; labels are `fixedSize` and
    the legend names the clipped bucket ("Aug 18: 35.1 B").
25. Segment labels "All indexed" and "Input by kind" wrapped to two lines
    at the control's width; they are "All" and "By kind".

Stage 3b, the chart proper (Canvas), rendered in split / stacked / hover /
isolated states:

26. In Fleet the stacked chart was a Claude chart with two invisible
    slivers; Fleet now opens in Split (one row per provider, own scale,
    shared days, the row title carrying total and share) with Stacked one
    click away; a provider or account opens Stacked.
27. The chart had a fixed 250 pt height and left a 100 pt gap above the
    footer in a 680 pt window; it now takes the pane's spare height.
28. The "7-bucket mean" legend entry appeared in Split even when no mean
    could be drawn (seven buckets, one partial); it appears only when a
    mean is drawn.
29. The partial bucket was a dimmed column that read as a lighter series;
    it is hatched in the surface colour at 55 % opacity, with the legend
    swatch matching.
30. Hover: a crosshair and a column band across every row, one tooltip
    with the bucket, every series' value and the total; ←/→ move it from the
    keyboard and Return opens the bucket's breakdown — the same popover a
    click opens, listing that bucket's own by-model and by-account rows.
31. Legend click isolates a series (the others fade to 22 %, nothing is
    recoloured); a second click restores.

## 6. Open questions for the owner (check-in brief, sent 21:01)

1. Layout **B** vs A. 2. Default **7 days** vs 30. 3. Cost **shown, labelled**
vs toggle vs omitted. 4. First index **everything on disk** vs 30 days.
5. Markers — the brief recommended switches + stops; after the consults the
recommendation is **switches only by default, stops as an opt-in overlay**.
If the owner is silent, the bold options proceed.

## 7. Risks

- **Main-thread regression** — readers, ledger and report are `nonisolated`
  on the utility queue; the tell is an "expression is 'async' but is not
  marked with 'await'" warning at a call site; tests assert
  `!Thread.isMainThread`.
- **Ledger growth** — ~150 B/event, ~30 k events/day ≈ 1.6 GB/year; monthly
  `VACUUM` after the first pass; "Delete telemetry archive…" exists.
- **Format drift** — readers tolerate unknown fields, count unknown shapes in
  `health`, and the census tools in `docs/research/tools/` re-check.
- **Ownership gaps** — the claim-seam notification is the fixes session's to
  add; until then the tick backstop and heartbeats bound the uncertainty and
  the gap rule keeps those intervals unattributed.
- **Attribution before the log** — everything before the first ownership
  entry is unattributed forever; the window says so with the date.

## 8. Consult log

**Question.** Are the dedup/delta rules complete; JSONL vs SQLite; is
time-based attribution from a 25-hour ring honest; is B right and what is
missing in week one; is a list-price figure useful; where does the staging
break against this codebase?

**Codex `gpt-5.6-sol` xhigh (read-only, 24 min).** "Approve with revisions."
Claude in-flight accumulator with the full max-output snapshot, global
`unitId`, never sum `iterations[]`; Codex cursor persists the component vector
+ model, clamp derived uncached, `cached ≤ input`, `reasoning ≤ output`,
counter-correction diagnostic; Grok dedup by `_meta.eventId`; do not fold
`unified.jsonl`. **Choose SQLite** (system library; unique key + one
transaction for events, markers, cursors); snapshot size at open, commit
through the last newline; bound bytes; catch-up scheduling (5-min ticks make
the first pass 5 hours); path is not identity (archived rollouts); never
advance a cursor past a failure; 0700/0600. Attribution: seed only unique
names; record at the claim seam with basis; external notification is an
observation; gaps are unattributed, not "approximate"; heartbeats; attribution
off the events. Window: B; buckets hour/day/week→month; non-zero median and
≥ 14 buckets; outlier control; exclude today's partial from the mean;
Coverage KPI at Fleet instead of units; per-provider `scannedAt`/`dataThrough`;
week-one asks (by project/originator, main vs subagent, refresh/pause/delete/
export, scan health, marker clustering, visible completeness); sparklines
redundant. Cost: "API list-price equivalent — not billed · rates published
<date>"; Codex "base-rate estimate"; Grok "CLI-reported"; mixed methodology
stated; uniform as-of rates, versioned. Staging: attribution/ownership
ahead of the window; split the stages; serial `.utility` `DispatchSourceTimer`
with `Sendable` owner snapshots; share only a small JSONL primitive with the
tripwire; observer at startup; inject roots; commit fixtures and tools.

**Grok `grok-4.6` xhigh (advisory, read the live logs, 12 min).** "Approve with
revisions." Confirmed live: `output_tokens` 1 → 1 → 390 across one id;
`iterations[]` one-element mirror; a Codex `<EXTERNAL SESSION IMPORTED>`
snapshot with all components 0 and `total_tokens` 11,177 (**ignore the total
remainder; skip all-zero snapshots**); `cache_write_input_tokens` exists on
Codex rollouts; Claude `input_tokens` is already uncached (cross-provider
footgun). Keep JSONL + a small sidecar rather than SQLite ("revisit if
uniqueness becomes the bug"). Partial last line, crash order (events fsynced
before the cursor rename), shrink re-emits without a unique key, vanished
files keep events, gzip-vs-rebuild contradiction, local day at query time,
catch-up ticks, timer on the utility queue, chunked reads. Attribution: write
at `claimActive*Ownership` time and on `.providerOwnerChangedExternally`
(userInfo provider is a `String`), tick-diff as backstop; **skip focus-only
ring rows**; unique name per provider; label "before <first ownership-log
time>"; join at query; sidebar selection is scope, not Viewing. Window:
titled-with-hidden-titlebar, reuse the instance, observer at launch, decode
provider as String and enum, `(nil, .claude)` = provider scope; small-multiple
trigger only on ≥ 14-day windows with a non-zero median; drop the Fleet units
tile; sparklines off; click a day → breakdown; input by kind as a metric;
main vs subagent; Codex originator; pause after the first pass; copy numbers.
**Default markers switches only** (deaths are the tripwire's job), collapse
`⇄N`; sidebar totals "—" while unattributed. Cost: show it, labelled; the
mock's `$2,140` is inconsistent with 76 B cache reads (five figures); 5 m rate
when the split is missing, flagged. Staging: ownership writes into stage 1,
split stage 3, do not share the tripwire's tail reader, no `Task.detached`.

**Decision (owner said: best judgment, take counsel).** Everything both
reviews agree on is adopted verbatim (§2, §3, §4, passes 13–16). On the one
split — the store — **SQLite** wins: the ledger needs a unique unit key and a
single transaction over events + cursors, and Grok's own list of JSONL
failure modes (in-flight upsert, shrink replay, crash order, moved files) is
exactly the list SQLite closes; Grok's objection (no need for a query
planner) is not a cost. Rate-limit markers default off (Grok's argument that
they are quota events on a consumption chart outweighs Codex's "cluster
them"); switches collapse per bucket. The claim-seam ownership notification
is requested from the fixes session (its file); the backstop and heartbeats
carry attribution until it lands. Grok's `unified.jsonl` stays out of v1.
Stage 1 is split (ledger + ownership; readers + scheduler) and stage 3 is
split (shell; chart), per both.
