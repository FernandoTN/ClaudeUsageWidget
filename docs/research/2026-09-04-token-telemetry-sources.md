# Token-consumption telemetry — where the numbers are, and what they are worth

**Date:** 2026-09-04 (measured 20:30–21:10 PDT on the owner's Mac, read-only)
**Purpose:** ground the token-telemetry window (`docs/specs/token-telemetry.md`):
for each provider, exactly which local files and fields carry tokens, model,
time and account; how much data there is; where it lies; and how fast a
Swift indexer can walk it.
**Rule this whole endeavour inherits (owner ruling 2026-08-12, restated):**
these are **consumption** counts read from the CLIs' own logs. They do **not**
reproduce the providers' quota bars and are never presented as quota. Every
figure the window shows carries its source and its age.

Scripts used (read-only, kept for re-runs): the job's `census/claude_census.py`,
`census/codex_census2.py`, `census/grok_census.py`, and the Swift hot-path
prototype `proto/scan.swift`. Numbers below are from those runs.

---

## 0. Headline

| | Claude Code | OpenAI Codex | xAI Grok |
|---|---|---|---|
| Source | `~/.claude/projects/**/*.jsonl` | `~/.codex/{sessions,archived_sessions}/**/rollout-*.jsonl` (+ `~/.codex-accounts/<slug>/sessions/**`) | `~/.grok/sessions/<cwd>/<id>/updates.jsonl` (+ `~/.grok/logs/unified.jsonl`, ~3 days) |
| Record | `type: "assistant"` → `message.usage`, `message.model` | `event_msg.payload.type: "token_count"` → `info.total_token_usage` (cumulative) ; model from `turn_context.payload.model` | `_x.ai/session/update` → `update.sessionUpdate: "turn_completed"` → `usage.modelUsage[<model>]` |
| Files / bytes | 12,560 / 14.2 GB (10,439 are subagent files) | 1,241 / 12.2 GB (425 archived = 11.3 GB) | 1,541 sessions; `updates.jsonl` total 1.67 GB (2.7 GB dir) |
| Distinct units | 861,785 messages (from 1,805,239 records) | 435,976 token_count events in 1,209 sessions | 1,158 turns in 1,148 sessions |
| Span present on disk | 2026-07-27 → today (37 days with data; **CLI deletes after 30 days**) | 2026-05-14 → today (63 days with data; nothing deleted) | 2026-08-06 → today (30 days; unified log only since 09-01) |
| All-time input-class tokens | **259.7 B** (251.4 B cache reads, 8.2 B cache writes, 6.4 M uncached) | **54.2 B** (51.7 B cached) | **0.93 B** (0.77 B cached) |
| All-time output tokens | **677 M** (200 M of them thinking) | **181 M** (65.5 M reasoning) | **21.3 M** (16.0 M reasoning) |
| Last 7 days input / output | 78.3 B / 120 M | 0.62 B / 2.4 M | ≈ 150 M / 2.6 M |
| Account in the record? | **No** | **No** (default home); **yes by path** in an isolated home | No, but there is one Grok account |
| Cost figure in the record? | No | No | **Yes**, `costUsdTicks` (nano-USD, xAI list price, ≥200k tier) |
| Retention hazard | **High** — 30-day rolling window | None observed | Medium — sessions ≤ 30 d old; per-call log ≈ 3 d |

Two consequences drive the design:

1. **Dedup or over-count 2.1×.** Claude Code writes one `assistant` record per
   content block (thinking, text, each `tool_use`) of the same API response,
   all carrying the same `message.id` and the response's usage. The naive sum
   of the corpus is 539.5 B input-class / 1,241 M output; the deduplicated
   truth is 259.7 B / 677 M. Codex's `token_count` is cumulative per session
   and is re-emitted unchanged 37,323 times (8.6 %); summing `last_token_usage`
   disagrees with the final total in 294 of 1,209 sessions.
2. **The index is the archive.** Claude Code deletes transcripts 30 days after
   their last activity (`cleanupPeriodDays`, default 30, not overridden on this
   Mac — 99 % of the messages on disk are ≤ 30 days old). "All-time" in the
   window can only mean "since the widget started indexing, plus what the CLI
   still held on day one". The store must therefore be durable and never
   rebuilt from scratch.

---

## 1. Claude Code transcripts

### 1.1 Files

`~/.claude/projects/<project-slug>/<session-uuid>.jsonl` plus
`<session-uuid>/subagents/agent-<id>.jsonl` (10,439 of the 12,560 files) and
`<session-uuid>/tool-results/` (1,278 directories; never a transcript line —
pruned, exactly as `LocalLimitSignalService` does). 157 project directories.
Six files exceed 50 MB (largest 160 MB); the median session is a few MB.
Modified in the last 24 h: 367 files (1.0 GB); last 7 days: 2,602.

### 1.2 The record

```json
{"type":"assistant","uuid":"…","parentUuid":"…","timestamp":"2026-08-12T01:55:56.952Z",
 "sessionId":"df500d6f-…","isSidechain":false,"cwd":"/Users/…/memoriLLM","gitBranch":"…",
 "requestId":"req_011Cdx2GmDyiREHcvcLKzNMY","apiBlockIndex":0,"effort":"xhigh",
 "message":{"id":"msg_011Cdx2Gnk1CdtWYzCCYFkTZ","model":"claude-fable-5","role":"assistant",
   "usage":{"input_tokens":2,"cache_creation_input_tokens":45212,"cache_read_input_tokens":24591,
            "output_tokens":533,"output_tokens_details":{"thinking_tokens":291},
            "cache_creation":{"ephemeral_1h_input_tokens":45212,"ephemeral_5m_input_tokens":0},
            "service_tier":"standard","speed":"standard","iterations":[…]}}}
```

| Field | Use |
|---|---|
| `message.id` | **dedup key** (fallback `requestId`, then `uuid`). 1,805,239 records → 861,785 ids; 2.09 records per message |
| `message.usage.output_tokens` | takes the **maximum** across the id's records. In 230,609 messages (27 %) the block records disagree: early blocks carry the streaming-time partial output count (`4` on the thinking block, `1730` on the tool_use block of the same message — `req` identical, input/cache fields identical). Input, cache-creation and cache-read never differ within an id in the 60-file check |
| `cache_creation_input_tokens`, `cache_read_input_tokens`, `input_tokens` | the three input classes; billed at different rates. Cache reads are **96.8 %** of all input-class tokens (Opus 5: 197.0 B of 202.8 B) |
| `output_tokens_details.thinking_tokens` | reasoning share (200 M of 677 M = 29.5 %) |
| `cache_creation.ephemeral_1h_input_tokens` / `…_5m…` | cache-write tier (1 h costs 2× input, 5 m 1.25×) — needed for a cost estimate |
| `message.model` | `claude-opus-5` 658,563 msgs · `claude-fable-5` 101,676 · `claude-sonnet-5` 84,552 · `claude-fable-5-1` 16,700 · `claude-opus-4-8` 226 · `claude-haiku-4-5-20251001` 68 · `<synthetic>` 2,685 (errors, zero usage — excluded) |
| `timestamp` | ISO-8601 with fractional seconds; the day bucket is computed in the user's local zone at aggregation time (store UTC) |
| `sessionId`, `cwd`, `isSidechain` | grouping. 509,677 of 861,785 messages (59 %) are sidechain (subagent) turns — they are real API calls and count; the window can split "main vs subagents" |
| `error` / `apiErrorStatus` | 2,641 error records: `rate_limit` 2,228 (the death events the tripwire already reads), `server_error` 345, `invalid_request` 56, `authentication_failed` 11 |
| `quotaLimits` | a small number of records carry the server's quota verdict (`status: rejected`, `rateLimitType: five_hour`, `resetsAt`) — the same class of signal as the rate-limit tripwire; recorded, not summed |

### 1.3 Volumes

| Window (to 2026-09-04) | Messages | Uncached input | Cache writes | Cache reads | Output |
|---|---|---|---|---|---|
| All on disk (37 days) | 861,785 | 6.35 M | 8.22 B | 251.4 B | 677.1 M |
| Last 30 days | 853,194 | 6.19 M | 8.11 B | 249.7 B | 669.4 M |
| Last 7 days | 219,021 | 3.45 M | 2.24 B | 76.1 B | 119.9 M |
| Median day / max day | 20,786 / 65,094 | | | 5.81 B / 19.2 B input-class | 16.3 M / 62.4 M |

Records per day: ~40k–100k `assistant` lines; bytes per day: ~1 GB of transcript.

### 1.4 Accuracy caveats

- **Block duplication** (above): dedup by `message.id`, max `output_tokens`.
- **Synthetic records**: `model: "<synthetic>"` are CLI-generated error turns with
  zero usage — skip; keep the `error` kind as an event.
- **Resumed sessions** append to the same file (same `sessionId`); `--continue`
  in a different cwd can create a second file for the same session id in another
  project directory — the id dedup is per **file** in the indexer (cheap) and
  per message id at aggregation (correct); a message id never appears in two
  files in the census.
- **Subagents** are in separate files under `<session>/subagents/`; their
  `isSidechain` is true and `sessionId` is the parent's. Count them; label them.
- **Retention**: the CLI deletes after 30 days of inactivity. The widget's
  store keeps what it indexed; the first pass on a fresh install imports the
  ~30 days present.
- **Not quota**: the server's session/weekly bars weigh models and windows in
  ways these sums do not reproduce (2026-08-12 research). Never derive a
  percentage from these counts.

### 1.5 Account attribution

The record carries no account. Attribution is by **time**: which profile owned
the shared `Claude Code-credentials` login at `timestamp`.

| Evidence | Where | Horizon |
|---|---|---|
| Switch history ring | `SharedDataStore.loadSwitchHistory()` — `switchHistory_v1`, 30 entries (`at`, `from`, `to`, trigger, reason), names only | measured today: the 30 entries span 24.7 hours (see §5) — about a day, not 30 days |
| Current owner | `ProfileManager.activeClaudeProfileId` / `activeAccountIds(among:)` (the authority, per the fixes session) and `~/.claude.json` `oauthAccount.accountUuid` (`<uuid>`, the CLI's own record) | now |
| Profile ↔ account | `Profile.claudeAccountUUID` stamps (`stampAccountIdentity`) | as stamped |
| External changes | `.providerOwnerChangedExternally` (fixes session, #70) | going forward |

So: the widget must keep its **own append-only ownership log** (provider,
profile id, account stamp, from, to) from the moment stage 1 ships; before the
first log entry, attribution falls back to the switch ring where it reaches and
to **"unattributed"** everywhere else — shown as its own band, never guessed.

---

## 2. OpenAI Codex sessions

### 2.1 Files

`~/.codex/sessions/YYYY/MM/DD/rollout-<local ts>-<uuid>.jsonl` (816 files,
0.93 GB) and `~/.codex/archived_sessions/rollout-*.jsonl` (425 files,
11.3 GB — the July consult waves). Nothing is deleted: the oldest rollout is
2026-05-14. Isolated homes created by the widget's in-app login
(`~/.codex-accounts/{xfenrir-dev, xfho-example, xfme-example, xlucifer-dev}`)
have `sessions/` directories with **0 files** tonight; the layout is identical
and the slug maps to a profile through `Profile.codexHomePath`.

`session_meta.payload.id` is **not** unique per file: 76 ids appear in several
rollouts (subagent threads spawned within seconds share the parent's id, each
with its own totals). Key the index by **file**, never by session id.

### 2.2 The records

```json
{"type":"session_meta","payload":{"id":"019f9b38-…","timestamp":"…","cwd":"…","originator":"codex_exec","cli_version":"0.144.6","source":"exec"}}
{"type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"xhigh","cwd":"…"}}
{"timestamp":"2026-07-25T21:39:56.196Z","type":"event_msg","payload":{"type":"token_count",
  "info":{"total_token_usage":{"input_tokens":60827,"cached_input_tokens":29440,"output_tokens":477,"reasoning_output_tokens":159,"total_tokens":61304},
          "last_token_usage":{"input_tokens":30576,"cached_input_tokens":29440,"output_tokens":165,"reasoning_output_tokens":10,"total_tokens":30741},
          "model_context_window":258400},
  "rate_limits":{"limit_id":"codex","primary":{"used_percent":0.0,"window_minutes":10080,"resets_at":1785619061},"secondary":null,"plan_type":"pro",…}}}
```

| Field | Use |
|---|---|
| `info.total_token_usage` | **cumulative per rollout**. Consume as **deltas between successive distinct totals** (37,323 events repeat the previous total verbatim — they carry only a `rate_limits` refresh). `cached_input_tokens` ⊂ `input_tokens`; `reasoning_output_tokens` ⊂ `output_tokens`; `total = input + output` |
| Negative steps | `output_tokens` / `reasoning_output_tokens` stepped **backwards** 29 times each while `total_tokens` kept rising; `total_tokens` dropped once (a fresh counter). Rule: per-key negative delta → 0; a drop in `total_tokens` → treat the new total as the delta. Re-adding the whole cumulative on any negative inflated the first census from 54.4 B to 70.0 B |
| `last_token_usage` | per-call usage — **do not sum it** (disagrees with the final total in 294 sessions, and the repeated events would double-count) |
| `turn_context.payload.model` | the model **from that turn on** (3 sessions switch models mid-way); 183 sessions (12 M tokens total) have no `turn_context` → model "unknown". `codex-auto-review` (138 sessions, the "guardian" subagent) is a model name in its own right |
| `rate_limits` | the plan's window shape at that moment (weekly-only since ~2026-07-29; 3,248 old events still show the 5 h + weekly pair) — quota, not consumption; recorded as an event, never summed |
| `session_meta.payload.source` / `originator` | `exec` 618 · `vscode` 380 · `cli` 148 · subagent `thread_spawn` 402 · `guardian` 138; originators `codex_exec` 867, `codex-tui` 369, `Codex Desktop` 354, `codex_work_desktop` 96 — a useful "surface" split |
| `timestamp` on the event | day bucket |

### 2.3 Volumes (corrected census)

| Window | Input (incl. cached) | of which cached | Output | of which reasoning |
|---|---|---|---|---|
| All (63 active days since 05-14) | 54.23 B | 51.73 B (95.4 %) | 181.3 M | 65.5 M |
| Last 30 days | 1.62 B | 1.54 B | 7.9 M | 4.5 M |
| Last 7 days | 0.62 B | 0.60 B | 2.4 M | 1.4 M |
| Median day | 38 M total | | | |

Two days dominate the history: 2026-07-16 (35.5 B, 159 sessions) and
2026-07-17 (14.4 B). By model: `gpt-5.6-sol` 53.8 B / 179 M (752 sessions),
`gpt-5.5` 276 M / 1.6 M, `codex-auto-review` 152 M / 0.16 M, `gpt-5.6-terra`
0.35 M, unknown 12 M. Cross-check: the sum of every file's **final** total is
54.38 B, within 0.1 % of the delta method's 54.43 B.

### 2.4 Account attribution

`session_meta` has no account id (`docs/research/2026-09-03-codex-accounts-tokens.md`).
Default-home rollouts belong to whoever owned `~/.codex/auth.json` at the
time — the same time-based rule as Claude, keyed on `activeCodexProfileId`
and the ownership log. Isolated-home rollouts are unambiguous by path.
`Profile.codexAccountId` stamps the account; the slug in `codexHomePath` maps
the directory.

---

## 3. xAI Grok sessions

### 3.1 Files

`~/.grok/sessions/<percent-encoded cwd>/<session-uuid>/` holds
`chat_history.jsonl`, `events.jsonl`, `updates.jsonl`, `summary.json`,
`signals.json`, `prompt_context.json`, `rewind_points.jsonl` (1,544 sessions,
1,541 with `updates.jsonl`, 1.67 GB of updates). Also
`~/.grok/logs/unified.jsonl` (3.9 MB, 15,469 lines, **2026-09-01 22:38 → now**
only — rotated), and `sessions/session_search.sqlite` (FTS index, no tokens).

### 3.2 The records

Per prompt turn, `updates.jsonl` ends the turn with:

```json
{"timestamp":1788491778,"method":"_x.ai/session/update","params":{"sessionId":"01a06a5e-…",
 "update":{"sessionUpdate":"turn_completed","prompt_id":"…","stop_reason":"end_turn",
  "usage":{"inputTokens":7004569,"outputTokens":34345,"totalTokens":7038914,"cachedReadTokens":6571520,
           "cacheCreationTokens":0,"reasoningTokens":18391,"modelCalls":49,"apiDurationMs":710641,"costUsdTicks":8743001400,
           "modelUsage":{"grok-4.6-build":{…same fields…}},"numTurns":49}}}}
```

| Field | Use |
|---|---|
| `usage` / `modelUsage[model]` | **per turn** (verified on an 8-turn session: 34 k, 2.11 M, 1.81 M, 1.85 M, 0.27 M… — not cumulative). Sum turns. Cached ⊂ input; reasoning ⊂ output |
| `costUsdTicks` | the CLI's own cost figure in **nano-USD** (verified: 8,743,001,400 ticks = $8.74 = the ≥200k-context xAI list tier for 433 k uncached × $4 + 6.57 M cached × $1 + 34 k out × $12). `null` on one turn of eight. Shown as "reported by the Grok CLI", never recomputed |
| `timestamp` | epoch seconds |
| `events.jsonl` `turn_started.model_id` | `grok-4.6` (the request model; usage names `grok-4.6-build`) |
| `signals.json` | `contextTokensUsed` / `contextWindowTokens` — context occupancy, not consumption |
| `logs/unified.jsonl` `shell.turn.inference_done` | **per model call**: `prompt_tokens`, `cached_prompt_tokens`, `completion_tokens`, `reasoning_tokens`, `sid`, `loop_index`, `attempts` — finer than turns, but only ~3 days deep |

### 3.3 Volumes

| Model | Turns | Input | Cached | Output | Reasoning | CLI cost |
|---|---|---|---|---|---|---|
| `grok-4.6-build` | 1,093 | 881.2 M | 731.5 M (83 %) | 20.6 M | 15.5 M | $2,803.9 |
| `grok-4.5-build` | 65 | 50.0 M | 43.4 M | 0.75 M | 0.42 M | $308.1 |

30 days of data (08-06 → 09-04); no session older than 30 days is present
(policy or start of use — unknown; the directory dates from 07-17).

### 3.4 Accuracy caveats

- **Only completed turns write usage.** Against the per-call log on the same
  days, `turn_completed` under-reports by 5–10 % (09-02: 60.1 M vs 62.7 M
  prompt; 09-03: 27.2 M vs 31.5 M; 09-04: 14.9 M vs 16.5 M) — cancelled or
  crashed turns never close. Stage 1 indexes `updates.jsonl` as the durable
  source and, optionally, folds in `inference_done` calls for sessions with no
  `turn_completed` in the log's window; the window labels Grok as
  "completed turns".
- One Grok account exists, so attribution is trivial (`activeGrokProfileId`,
  `~/.grok/auth.json` `user_id`); the same time rule applies if a second one
  appears.
- `costUsdTicks` is the CLI's estimate at list price; the SuperGrok
  subscription does not bill per token. Label accordingly.

---

## 4. Indexing strategy and measured cost

### 4.1 Shape

- **Own module, own timer, own store** (agreed with the fixes session): a
  `.utility` timer, never the 30 s sweep; skipped while a switch is in flight.
- **Off the main actor by construction**: a `nonisolated` reader (the
  `LocalLimitSignalService` pattern — the keyword is load-bearing under
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), dispatched on a serial
  `DispatchQueue(qos: .utility)`, never `Task.detached` (warning storm).
- **Per-file cursor**: `(path, size, mtime, byteOffset, lastMessageIdSeen)`.
  A pass lists candidates by mtime > cursor mtime (or size ≠ cursor size),
  reads from `byteOffset` to EOF, and only parses lines that contain a byte
  needle (`"type":"assistant"`, `"token_count"`, `"turn_completed"`). A file
  that shrank is re-read from 0 (a truncation, not an append).
- **Bounded per tick**: ≤ 200 files and ≤ 2 s wall per tick, then yield; the
  rest waits for the next tick. First run on a fresh install therefore takes
  a few minutes of ticks, never one long block.
- **Store** under `~/Library/Application Support/Claude Usage/telemetry/`:
  `events-YYYY-MM.jsonl` (one compact line per deduplicated message / delta /
  turn: provider, ts, model, the token classes, session, file id, account
  attribution slot), `cursors.json`, `ownership.jsonl`. Append-only files,
  atomic rename on rewrite, a `schemaVersion`. Not UserDefaults (cfprefsd), not
  SQLite (no new dependency, and the query needs are day-bucket sums — a
  monthly-file scan of ≤ 1 M lines is sub-second; revisit only if it is not).
- **Daily rollups** cached in memory and in `rollups.json` (per provider ×
  model × account × day) so the window opens instantly; recomputed from the
  event files when the schema or attribution changes.

### 4.2 Measured on this Mac (Swift, `-O`, warm page cache, read-only)

| Pass | Files | Bytes | Time | Throughput |
|---|---|---|---|---|
| Claude — full corpus | 12,560 | 14.21 GB | 50.5 s | 281 MB/s |
| Claude — files touched in the last 24 h | 366 | 1.00 GB | 3.0 s | 331 MB/s |
| Claude — files touched in the last 1 h | 50 | 0.36 GB | 1.3 s | 276 MB/s |
| Codex — `archived_sessions` | 425 | 11.27 GB | 12.8 s | 878 MB/s |
| Codex — `sessions` | 816 | 0.93 GB | 1.1 s | 837 MB/s |

(Python with the same prefilter: Claude 27.5 s, Codex 13.5 s, Grok 1.9 s.)
The prototype re-read whole files; with byte-offset cursors a steady-state
tick reads only the bytes appended since the last tick (tens of MB per
minute at tonight's rate), so a 2 s budget is generous. The first pass on a
fresh install (≈ 27 GB) is ~65 s of CPU spread across ticks.

### 4.3 Compaction

Event lines are ~150 bytes; ~25 k Claude messages + ~7 k Codex deltas + ~40
Grok turns per day ≈ 5 MB/day, ≈ 1.8 GB/year uncompressed. Monthly files
older than 3 months are rolled into their `rollups.json` entries and gzipped
(`Compression` framework, no dependency); the window reads rollups for
anything older than the current month.

---

## 5. What attribution can and cannot say today

Measured tonight from the widget's plist: 24 profiles; `claudeAccountUUID`
stamped on 17, `codexAccountId` on 5 (4 with an isolated `codexHomePath`),
`grokEmail` on 1; the switch ring holds 30 events (17 auto, 12 manual, 1
queued) spanning **24.7 hours** — the fleet switches many times a day, so the
ring alone cannot attribute the day before yesterday. The three pointers name
the current owners.

Therefore the window's per-account view is honest about three bands:

1. **Attributed** — a switch-ring or ownership-log entry brackets the
   record's timestamp (all data from stage 1 onwards; today's data now).
2. **Isolated-home / single-account** — Codex isolated homes, Grok.
3. **Unattributed** — everything older than the log; shown per provider as
   "unattributed", never redistributed.

The ownership log is written by the telemetry module from
`ProfileManager.activeAccountIds(among:)` + the three pointers at every tick
where they changed, and from `.providerOwnerChangedExternally`.

---

## 6. Prices for the "API-equivalent cost" estimate (labelled, optional)

Subscriptions are not billed per token; the estimate answers "what would this
have cost at list price" and is always labelled as such.

| Model | Input $/M | Cache read $/M | Cache write $/M (5 m / 1 h) | Output $/M | Source |
|---|---|---|---|---|---|
| claude-fable-5-1 | 10.00 | 0.25 | 12.50 / 20.00 | 50.00 | Anthropic pricing (claude-api skill, cached 2026-06-24; Fable 5.1 cache read 0.25) |
| claude-fable-5 | 10.00 | 1.00 | 12.50 / 20.00 | 50.00 | same |
| claude-opus-5, claude-opus-4-8 | 5.00 | 0.50 | 6.25 / 10.00 | 25.00 | same |
| claude-sonnet-5 | 2.00 | 0.20 | 2.50 / 4.00 | 10.00 | same |
| claude-haiku-4-5 | 1.00 | 0.10 | 1.25 / 2.00 | 5.00 | same |
| gpt-5.6-sol | 4.00 | 0.40 | — | 20.00 | developers.openai.com/api/docs/pricing (fetched 2026-09-04) |
| gpt-5.6-terra | 2.00 | 0.20 | — | 12.00 | same |
| gpt-5.5 | 5.00 | 0.50 | — | 30.00 | same |
| codex-auto-review | unpriced | | | | not on the price page — shown as "n/a" |
| grok-4.6 / grok-4.5 | 2.00 (4.00 ≥200k) | 0.50 / 0.30 (1.00 / 0.60 ≥200k) | — | 6.00 (12.00) | docs.x.ai/docs/models — but the CLI's own `costUsdTicks` is used instead |

The table is a `TokenPriceTable` value in code with a `asOf` date and is
editable; an unknown model shows tokens only.

---

## 7. Decisions this research fixes

1. Dedup Claude by `message.id` with max `output_tokens`; skip `<synthetic>`.
2. Codex: deltas of `total_token_usage` between distinct totals, per-key
   negatives clamped, model from the latest `turn_context`; index by file.
3. Grok: sum `turn_completed.usage.modelUsage`; keep `costUsdTicks` as the
   CLI's figure; label "completed turns".
4. Store = append-only monthly event files + cursors + ownership log under
   Application Support; the store is the archive because the CLIs prune.
5. Attribution by time from the ownership log; three bands; never guess.
6. Everything is consumption; the UI says so once per surface, and every
   number carries its source and age.
