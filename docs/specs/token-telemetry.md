# Token usage — a consumption telemetry window

**Date:** 2026-09-04
**Base:** `main @ 0d762a8` (#75 added the entry points that post `.telemetryWindowRequested`)
**Research:** `docs/research/2026-09-04-token-telemetry-sources.md` (every number below that is not a design choice comes from it)
**Status doc:** `docs/specs/token-telemetry-status.md`
**Check-in brief:** `docs/specs/token-telemetry-checkin.html` (self-contained)
**Consults:** §8 (Codex `gpt-5.6-sol`, Grok advisory; outputs in `docs/specs/consults/`)

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
- **Nothing leaves the machine.** Every read is local; the only network is
  none. The estimate of cost uses a price table shipped in the binary.

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
4. **What would this cost at list price?** — a labelled estimate; the
   subscriptions are flat, but the estimate is the only common unit across
   Opus/Fable/Sonnet and across providers, and it is what makes "impact"
   legible.
5. **How complete is this?** — indexed through when, how much of the history
   is attributed, which days are missing (Grok cancelled turns, Claude
   pre-index history).

What it does **not** answer: remaining quota, when a window resets, who to
switch to. Those live in the bar, the dashboard and the inspector.

## 2. Data contract (stages 1–2)

### 2.1 Unit records (`Telemetry/TelemetryEvent`)

One record per **deduplicated** unit, stored as a compact JSON line:

| Field | Claude | Codex | Grok |
|---|---|---|---|
| `provider` | `claude` | `codex` | `grok` |
| `at` (UTC) | `timestamp` | event `timestamp` | `timestamp` (epoch s) |
| `model` | `message.model` | latest `turn_context.model` (`unknown` if none) | `modelUsage` key |
| `unit` | 1 message (`message.id`) | 1 delta between distinct `total_token_usage` snapshots | 1 completed turn |
| `input` | `input_tokens` | `input − cached` | `inputTokens − cachedReadTokens` |
| `cacheRead` | `cache_read_input_tokens` | `cached_input_tokens` | `cachedReadTokens` |
| `cacheWrite` | `cache_creation_input_tokens` (+ 5 m / 1 h split) | 0 | `cacheCreationTokens` |
| `output` | max `output_tokens` over the id's records | `output_tokens` delta (clamped ≥ 0) | `outputTokens` |
| `reasoning` | `output_tokens_details.thinking_tokens` | `reasoning_output_tokens` delta (clamped) | `reasoningTokens` |
| `reportedCostNanoUSD` | — | — | `costUsdTicks` |
| `session` | `sessionId` (+ `isSidechain`) | rollout file id | session uuid |
| `source` | `cwd`-derived project slug, `entrypoint` | `originator` / `source` | cwd |
| `attribution` | filled by stage 4 (profile id or `unattributed`) | same; isolated-home path → profile | single account |

Excluded, recorded as **events** instead (`TelemetryMarker`): Claude
`error: rate_limit` deaths (2,228 on disk) and `quotaLimits` rejections; Codex
`rate_limits` snapshots are not stored at all (quota, not consumption).

### 2.2 Store (`Telemetry/TelemetryStore`)

`~/Library/Application Support/Claude Usage/telemetry/`

```
schema.json                 { "version": 1 }
cursors.json                { "<file id>": { path, size, mtime, offset, lastId } }
events/2026-09.jsonl        one TelemetryEvent per line, append-only
markers/2026-09.jsonl       TelemetryMarker per line
ownership.jsonl             { at, provider, profileId, accountStamp, name, cause }
rollups.json                per (provider, model, attribution, localDay) sums — rebuilt on schema change
```

Rules: append-only files, atomic rename on rewrite, `.utility` QoS, never
UserDefaults (cfprefsd), no SQLite (no dependency; day-bucket sums over
≤ 1 M lines/month are sub-second — revisit only on measurement). Months older
than three are gzipped and served from `rollups.json`.

### 2.3 Indexer (`Telemetry/TelemetryIndexer`, `nonisolated`)

- Own timer (default every 5 min; 60 s while the window is open), never the
  sweep; skipped while `ProfileManager` is mid-switch.
- Per-file cursors (mtime/size change → read from `offset` to EOF; shrink →
  from 0); byte needle prefilter (`"type":"assistant"`, `"token_count"`,
  `"turn_completed"`) before any JSON parse; `tool-results` pruned.
- Bounded: ≤ 200 files and ≤ 2 s per tick, then yield. Measured: the whole
  27 GB first pass is ~65 s CPU spread over ticks; a 24 h delta is 3 s
  re-reading whole files, far less with offsets.
- Dedup rules from the research: Claude by `message.id` (max output), skip
  `<synthetic>`; Codex deltas of distinct totals, per-key negatives → 0, a
  drop in `total_tokens` → fresh counter; Grok per-turn sums.
- Ownership log: at every tick, compare `activeAccountIds(among:)` + the
  three pointers with the last logged owner per provider; append on change;
  also on `.providerOwnerChangedExternally`. Seed on first run from the
  switch ring (24.7 h of history tonight) — everything earlier is
  *unattributed*.
- Verification harness: `telemetry-verify` (a test-target executable-free
  path: an XCTest that runs the indexer against fixture directories and
  prints totals) plus `TelemetryIndexerTests` on fixtures for every dedup rule.

### 2.4 Aggregation (`Telemetry/TelemetryReport`, pure)

```
TelemetryQuery(scope: .fleet | .provider(kind) | .account(id) | .unattributed(kind),
               window: .today | .days(7) | .days(30) | .allIndexed,
               metric: .inputClass | .output | .cost,
               stack: .provider | .model | .account | .kind)
→ TelemetryReport(series: [Bucket], kpis: KPIs, models: [Row], accounts: [Row],
                  markers: [Marker], provenance: Provenance)
```

- Buckets are **local-calendar days** (hours for `.today`); the window is
  inclusive of today's partial day, drawn hatched.
- `KPIs`: input-class total with the cache-read share, output with the
  reasoning share, units, estimated cost, each with the delta vs the
  previous equal-length window and a 12-point sparkline.
- Moving average: trailing 7-day mean of the total, only when ≥ 7 buckets.
- `Provenance`: indexed-through time, bytes read, records, attributed share,
  per-provider caveat strings ("completed turns only", "30-day CLI retention",
  "deduplicated by message id").
- Cost: `TokenPriceTable` (research §6) with an `asOf`; Grok uses the CLI's
  reported nano-USD; unknown models contribute tokens but no cost and the tile
  says "n models unpriced".

## 3. The window

### 3.1 Options considered

**A — Report page.** One scrollable column: header, KPI row, trend chart,
models table, accounts table, footer. Filters in the header (provider chips,
account popup). Simplest to build; everything in one glance. Weak on
per-account drilling with 24 profiles (a popup of 24 names) and no place for
the account's own switch timeline.

**B — Source list + report (recommended).** A sidebar scopes the report:
*Fleet*, then each provider, indented accounts under it (sorted by last
activity), and an *Unattributed* row per provider; the main pane is A's stack
for the selected scope. The chart's stacking follows the level — Fleet stacks
by provider, a provider by model, an account by model — so the drill-down
reads the same at every depth. The inspector's "Usage history" deep link
simply selects a sidebar row. Scales to the 30–40 accounts the UX spec sizes
for. Costs a wider minimum window (880 pt).

**C — Tabs (Overview / Models / Accounts / Timeline).** Hides comparison
behind clicks; the owner's questions 1–3 want to be on one screen. Rejected.

### 3.2 B, frame by frame

```
┌ Token usage ────────────────────────────────────────────────────────────────── 1040 × 680 ┐
│ ┌ sidebar 220 ┐ ┌ report ──────────────────────────────────────────────────────────────┐ │
│ │ Fleet       │ │ Claude · Fleet                              Today  [7 days]  30 days  All │ │
│ │ ▸ Claude 17 │ │ Consumption read from local CLI logs · not quota · indexed 12 s ago     │ │
│ │   dRir  Cl  │ │ ┌ Input-class ─────┐ ┌ Output ─────────┐ ┌ Messages ─┐ ┌ ≈ Cost ───────┐ │ │
│ │   dJor      │ │ │ 78.3 B  ▲ 12 %   │ │ 120 M  ▼ 4 %    │ │ 219 k     │ │ $2,140 list   │ │ │
│ │   dLeo      │ │ │ 97 % cache reads │ │ 30 % thinking   │ │ 59 % sub- │ │ estimate ⓘ    │ │ │
│ │   …         │ │ │ ▁▂▃▅▆▅▇▆▅▆▇█     │ │ ▂▃▃▅▆▅▆▆▅▆▇▆    │ │ ▃▄▅▅▆▅▆▅  │ │ ▁▂▃▅▆▅▇▆▅▆▇█  │ │ │
│ │   Unattrib. │ │ └──────────────────┘ └─────────────────┘ └───────────┘ └───────────────┘ │ │
│ │ ▸ Codex  5  │ │ Tokens per day · stacked by provider · ─ 7-day mean        ● Claude ● Codex ● Grok │
│ │ ▸ Grok   1  │ │ 20 B ┤                                        ▆                            │ │
│ │             │ │      │                        ▅        ▆      █▆     ▇                     │ │
│ │             │ │ 10 B ┤        ▅      ▆   ▅    █   ▆    █   ▅  ██  ▆  █   ▅  ░  ← today,    │ │
│ │             │ │      │   ▃    █   ▄  █   █    █   █    █   █  ██  █  █   █  ░    hatched    │ │
│ │             │ │    0 ┴───┴────┴───┴──┴───┴───┴────┴───┴────┴───┴──┴┴──┴──┴───┴──┴─────────  │ │
│ │             │ │        Aug 29  30   31  Sep 1   2    3   ⇄ dRir→dJo (auto)   ×3 rate-limit │ │
│ │             │ │ ┌ By model ───────────────────────────┐ ┌ By account ─────────────────────┐ │ │
│ │             │ │ │ claude-opus-5   ███████▌ 62 %  $…   │ │ dRir  Active for Claude  ████ 31 %│ │ │
│ │             │ │ │ gpt-5.6-sol     ██▌      21 %  $…   │ │ dJor                     ███  24 %│ │ │
│ │             │ │ │ claude-fable-5  █▌       11 %  $…   │ │ …                                 │ │ │
│ │             │ │ │ …                                   │ │ Unattributed (before 09-03) ██ 18 %│ │ │
│ │             │ │ └─────────────────────────────────────┘ └───────────────────────────────────┘ │ │
│ │             │ │ Sources: Claude Code transcripts (dedup by message id) · Codex rollouts (deltas) │ │
│ │             │ │ · Grok completed turns · nothing leaves this Mac                                 │ │
│ └─────────────┘ └──────────────────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

**Frame 1 — the header.** Scope name (sidebar selection) on the left; the
window control on the right as a segmented control (`Today · 7 days · 30 days ·
All indexed`; default **7 days**). Under it one line of provenance:
"Consumption read from local CLI logs · not quota · indexed 12 s ago". This
line is the only place the disclaimer lives on screen; it is never a banner.

**Frame 2 — the KPI row.** Four stat tiles (dataviz contract: label, compact
value, signed delta vs the previous window, 12-point sparkline in the
de-emphasis gray with the current period in the accent):

- *Input-class tokens* with the sub-line "97 % cache reads" — the single most
  important disclosure: the load is cache traffic, not fresh context.
- *Output tokens* with "30 % thinking".
- *Messages / turns* with "59 % subagents" (Claude) or "148 sessions".
- *≈ Cost at list price* with an ⓘ that opens the price table and its
  `asOf`; Grok's share says "reported by the Grok CLI".

Deltas colour by direction only when the reader can act on them; here up is
neither good nor bad, so the arrow is drawn in the secondary text colour and
the number is not coloured (dataviz: text never wears a status colour it does
not mean).

**Frame 3 — the trend chart (the hero).** Daily columns, stacked, ≤ 24 pt
thick, 2 pt surface gaps between segments, 4 pt rounded top on the top
segment; hairline solid gridlines; y ticks in clean `B`/`M`; a 2 pt line for
the trailing 7-day mean in the secondary text colour; today's column hatched
(partial). Stack dimension follows the scope (provider → model → model); the
metric picker sits in the chart title (`Input-class · Output · Cost`). Hover
gives a crosshair and one tooltip with every segment plus the total and the
day; the legend is always present for ≥ 2 series and doubles as a filter
(click to isolate — emphasis mode, others go gray, never re-coloured).

Under the axis, stage 4 draws **markers**: `⇄` for a switch of the scope's
provider (tooltip: from → to, trigger, reason), `×` for a Claude rate-limit
death. Markers are recessive glyphs in the secondary colour with a status
colour only on hover.

Scale: the two July Codex days (35 B and 14 B) would flatten every other
column of an "All indexed" fleet chart. Rule: when the largest column exceeds
20× the median, the chart switches to **small multiples per stack series**
(one row each, own y-axis, shared x) and says so in the title. Never a log
axis (the eye cannot stack logs), never a dual axis.

**Frame 4 — two tables.** *By model*: model, units, input-class, cached %,
output, reasoning %, ≈ cost, and an inline share bar (share of the scope's
input-class total; one hue, slot 1 — the categories are nominal). *By
account*: profile name with the provider glyph, the `ActiveVocabulary.activeFor`
badge on the current owner, tokens, ≈ cost, last active, share bar; the last
row is **Unattributed (before <first ownership entry>)** drawn in the
secondary colour — its share is shown, never redistributed. In an account
scope the second table becomes *Switches* (when this account became / stopped
being Active, and what it burned in between).

**Frame 5 — the sidebar.** `Fleet`, then a disclosure group per provider
with its account count, accounts sorted by last activity (the busiest today
on top), each row: name, the cyan `Cl/Cx/Gk` mark on the current owner only
(the bar's convention), and a right-aligned compact token figure for the
selected window. `Unattributed` rows appear only when they are non-zero.
Keyboard: ↑↓ move, → expands, type-to-select; the report follows selection.

**Frame 6 — the footer.** Sources and caveats for the scope ("Grok:
completed turns only, ~5–10 % under the per-call log"; "Claude: the CLI
deletes transcripts after 30 days — history before <first index date> was
never on disk"). Right-aligned: "Indexed through 21:04 · 27.1 GB · 1.2 M
records".

**Empty and degraded states.** Before the first pass completes: the KPI tiles
show "indexing… 41 %" with a determinate bar (files done / files found), and
the chart draws whatever days are complete. Store unwritable → one line in
the footer, the window keeps working from memory. No data for a scope → the
tables say "nothing indexed for <name> in this window", never zeros with
confidence.

### 3.3 Colour, type, light/dark

- Series colours are the only literal colours in the module, taken from the
  validated data-viz palette (CVD-checked adjacent pairs, separate light and
  dark steps): providers fixed **Claude = slot 1 blue, Codex = slot 2 orange,
  Grok = slot 3 aqua** (the three-slot all-pairs cap is exactly the provider
  count); models take slots 1–6 in a fixed table keyed by model family
  (Opus, Fable, Sonnet, Haiku, GPT, Grok), the tail folds into *Other*.
  Colour follows the entity: filtering never repaints survivors.
- Everything else is semantic (`.primary`, `.secondary`, `.accentColor`,
  `.adaptiveGreen`, the `AccountReadiness` colours for badges) so light/dark
  is free; text never wears a series colour — identity comes from a swatch
  beside it.
- Type: the dashboard's scale (`12` bold section titles, `9.5` card titles,
  `9` body, `8.5` captions), tabular figures in tables and axes,
  proportional in tiles. Strings through `DashboardFormatting` (`age`,
  `duration`) and `ActiveVocabulary`; new strings in `Localizable.strings`.
- Accessibility: each chart exposes an accessibility summary ("7 days, Claude
  78 B input-class, peak Sep 2 19 B"); the tables are the table view; the
  legend is the identity channel; a texture fill is available for the CVD
  setting.

### 3.4 Window plumbing (agreed with the redesign and UX-revamp sessions)

- `Telemetry/TelemetryWindowController` (NSWindowController, one instance,
  `isReleasedWhenClosed = false`, reopened not recreated, delegate releases
  the hosting controller on close) — copies the Settings window pattern
  (`BorderlessSettingsWindow` style mask, `preferencesClicked`'s double-open
  guard), foregrounds through `MenuBarManager.bringWindowToForeground`, never
  flips the activation policy, no SwiftUI `Window` scene.
- Opened by `.telemetryWindowRequested` (declared in
  `Notification+Extensions`, #72): object `UUID?` (profile, nil = Fleet),
  userInfo `"provider": Profile.ProviderKind`. Posters live on main since
  #75: the dashboard header's chart icon, each dashboard row's context menu,
  the classic popover's name menu; the UX-revamp sibling adds the ⇄ footer
  entry and the inspector's "Usage history". Reverse link: the account
  scope's header offers "Open in Accounts…" (`SettingsRoute` once 2a lands;
  the string `"manageProfiles"` until then).
- The shared `WindowCoordinator` is the redesign session's; this controller
  registers with it when it exists and is not rewritten for it.

## 4. Staged plan (one draft PR each, ≤ ~600 lines)

| Stage | Contents | Tests |
|---|---|---|
| **0** (this PR) | research doc, this spec, status doc, consults, check-in brief | — |
| **1 — index + store** | `Telemetry/TelemetryEvent`, `TelemetryStore` (append-only monthly files, cursors, ownership log, atomic writes), three `nonisolated` readers (`ClaudeTranscriptReader`, `CodexRolloutReader`, `GrokUpdatesReader`) with the dedup rules, `TelemetryIndexer` (timer, bounds, QoS), a verification harness that prints totals for a directory | fixtures for every dedup rule (block duplicates, `<synthetic>`, Codex repeated totals, negative steps, total drop, Grok multi-turn, truncated file), cursor resume, bound enforcement, store atomicity |
| **2 — report model** | `TelemetryQuery`/`TelemetryReport`, day bucketing in the local zone, moving average, shares, `TokenPriceTable`, provenance strings, small-multiples rule | pure tests on synthetic events; a golden test on a 3-day fixture |
| **3 — window** | `TelemetryWindowController`, `TelemetryView` (sidebar + report), `StackedColumnChart`, `StatTile`, tables, hover layer, empty/indexing states, light/dark, keyboard; observer for the notification; Settings hook handed to the UX-revamp sibling | view-model tests; a render-to-image smoke test at 1040 × 680 in light and dark |
| **4 — attribution + markers** | ownership log seeded from the switch ring, per-tick owner diff, `.providerOwnerChangedExternally`, isolated-home mapping, unattributed band, switch and rate-limit markers, the account scope's *Switches* table | attribution against a synthetic ownership log; isolated-home mapping; marker placement |

Each stage: Release build + full suite green on the merged tree
(`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, dedicated
`-derivedDataPath`), merge sha reported to the fixes session, status doc
updated.

## 5. Design passes (what changed while going frame by frame)

1. The first draft summed transcript records; the census showed 2.09 records
   per message. The unit became the deduplicated message.
2. "Input tokens" as one number hid that 96.8 % are cache reads. The KPI
   became *input-class* with the cache share as its sub-line, and the chart
   metric names it the same way.
3. A single fleet chart over "All indexed" was flattened by two July Codex
   days (35 B, 14 B); rule added: > 20× median → small multiples.
4. A provider filter popup with 24 accounts read badly; the sidebar became
   the filter and gave attribution its own rows (*Unattributed*).
5. Per-account numbers looked authoritative before the ownership log existed;
   the switch ring covers 24.7 h. The unattributed band is drawn, labelled by
   date, and never redistributed.
6. Cost coloured green/red implied good/bad; deltas lost their colour.
7. Grok's per-call log (3 days) tempted a "calls" unit; completed turns are
   the durable unit, labelled, with the 5–10 % gap stated in the footer.
8. A log axis was considered for the spikes and rejected (stacks do not read
   on logs); small multiples instead.
9. The disclaimer started as a banner; it became the header's second line.
10. Deep link from the inspector: the sidebar selection *is* the deep link,
    so the window has one state model, not a "filtered mode".

## 6. Open questions for the owner (check-in brief)

1. Layout **B** (sidebar + report) vs A (single report page).
2. Default window **7 days** vs 30 days.
3. Cost estimate **shown, labelled** vs behind a toggle vs omitted.
4. First index **everything on disk** (27 GB incl. the July Codex archive)
   vs the last 30 days only.
5. Markers **switches + rate-limit deaths** vs switches only.

If the owner is silent, the bold options proceed.

## 7. Risks

- **Main-thread regression** — the reader is `nonisolated`; the tell is an
  "expression is 'async' but is not marked with 'await'" warning at the call
  site (same as `LocalLimitSignalService`). A test asserts the indexer runs
  off `Thread.isMainThread`.
- **Store growth** — ~5 MB/day; monthly gzip after three months.
- **Format drift** — each reader tolerates unknown fields and logs one line
  per new shape; the census scripts stay in `docs/research` as the re-check.
- **Ownership log gaps** — a tick missed during a switch is caught by the
  next tick's diff; the log stores *when observed*, and an attribution whose
  bracketing entries are more than one tick apart is flagged "approximate".

## 8. Consult log

_Filled after the Codex `gpt-5.6-sol` (xhigh) and Grok advisory runs; see
`docs/specs/consults/2026-09-04-codex-token-telemetry-review.md` and
`…-grok-token-telemetry-review.md`._
