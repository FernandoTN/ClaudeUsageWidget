I'll start by reading the review skill and the documents in the order you specified, then inspect the relevant code.The review skill is for code diffs, so I’ll treat this as a design review and keep reading the source documents in order.Next I’ll read the scanner, window plumbing, store, identity models, and the prior consult notes.I’ll pull the remaining spec sections, window plumbing, identity stamps, and any existing consults next.I’ll sample the live log shapes (needles, `iterations`, streaming blocks, Codex snapshots) so the data-correctness findings aren’t only from the research doc.Spot-checked live transcripts: streaming `message.id` duplicates, `iterations[]` matching top-level usage, and a Codex import snapshot where `total_tokens` is non-zero while every component is 0. Writing the review from that plus the spec.**approve with revisions**

The research is good enough to build from, layout B is the right window, JSONL-under-Application-Support is the right store, and the three-band attribution rule is honest. Several indexer/store rules as written will still double-count, drop streaming output, or wait hours for the first pass. Fix those before stage 1; do not treat SQLite vs JSONL as the main risk.

---

## A. Data correctness

The unit rules are directionally right. They are not complete, and two of them fight the append-only store.

### Claude — keep `message.id` + max `output_tokens` + skip `<synthetic>`; add an in-flight upsert

Live transcripts confirm the census: the same `message.id` is written once per content block, and early blocks carry partial `output_tokens`. Example, `msg_011Ce1Zjdq6pURfj9AZ2Haap`: `output_tokens` is `1` on the text block, `1` on a later `tool_use` block, then `390` on the final block of the same id. Input/cache fields stay identical across those rows. Max-output is the right merge.

That merge **cannot be “write one JSONL event and forget”**. A tick that sees only the thinking/text block will persist `output=1`, advance the byte cursor, and either:

- skip later blocks of the same id (under-count the 27% of messages the research says disagree on output), or
- append a second event for the same id (double-count unless aggregation re-maxes **and** the store has a uniqueness rule).

`cursors.json`’s `lastId` makes this worse if resume treats that id as done.

**Required rule for stage 1:** a Claude unit is not finalized until the file has not grown for one tick (or a later record of that id carries `stop_reason`). Keep an in-flight table keyed by `message.id` (max of each token class, first `at`, model). Only then append the event. On resume, re-open any in-flight id even if `offset` has moved past its first line. Aggregation must still max-merge by `message.id` globally — the research already notes `--continue` in another cwd can create a second file for the same `sessionId` (`docs/research/2026-09-04-token-telemetry-sources.md:107–110`). Census said that has not happened for `message.id`; do not rely on it remaining true.

**`iterations[]`:** live records carry it. On the samples I opened it is a one-element array whose fields equal the top-level `usage` (e.g. `input_tokens: 10`, `output_tokens: 693`, same cache numbers). Summing `iterations` **and** top-level usage double-counts. Spec the rule: **never add `iterations[]`; top-level `usage` only.** I did not find a multi-element `iterations` array in a short scan; treat that shape as unmeasured and still ignore the array.

**Retries / errors / `<synthetic>`:** skip is correct. A live `<synthetic>` refusal has all usage zeros (`model: "<synthetic>"`, `input_tokens: 0`, …). Also skip **any** assistant record whose usage is all zeros, not only `<synthetic>` — that covers error rows without inventing a second code path. Fallback `requestId` then `uuid` (`docs/research/2026-09-04-token-telemetry-sources.md:79`) is fine for records that lack `message.id`; do not use `requestId` to merge a zero-usage error with a later success that has a real `message.id`.

**Subagents:** count them, label them (`isSidechain`, files under `…/subagents/`). They are real API calls (59% of messages). Prune `tool-results` the same way `LocalLimitSignalService` does (`LocalLimitSignalService.swift:45–49`).

**Resumed sessions across project directories:** per-file cursor + global `message.id` max-merge is the right pair. Do not key the store by `sessionId`.

**Needle:** live files are compact (`"type":"assistant"` with no space). I found **no** `"type": "assistant"` under `~/.claude`. The token is also not at the start of the line (`parentUuid` / `message` come first), so a substring needle is correct. Still accept both spacings; format drift is the stated risk (`docs/specs/token-telemetry.md:373–374`).

**Paths:** do not hard-code `~/.claude/projects`. Use `Constants.ClaudePaths.projectsDirectory`, which already honours `CLAUDE_CONFIG_DIR` (`Constants.swift:64–72`). Isolated Claude homes are an acknowledged fleet gap (`docs/specs/ux-revamp.md:898`); the indexer should at least follow the env the rest of the app already follows.

### Codex — index by file, do not sum `last_token_usage`, persist the last *component* snapshot

**Index by file, not `session_meta.id`:** yes. 76 shared ids are subagent/thread rollouts with their own totals (`docs/research/2026-09-04-token-telemetry-sources.md:151–153`). Summing by session id would mix counters. Isolated homes (`Profile.codexHomePath`, `CodexUsageService.isolatedHomesRoot`) stay in the walk even though they had 0 session files on the research night — that is how future in-app logins become attributable by path.

**Do not sum `last_token_usage`:** yes. The research (disagrees with the file’s final total in 294/1,209 sessions, and unchanged re-emits would double-count) is enough. Use it only as a diagnostic, never as a displayed unit.

**Deltas of distinct `total_token_usage`, per-key negatives → 0, drop in `total_tokens` → fresh counter:** keep the per-key clamp. Change the drop rule.

Live counterexample, whole file has a **single** `token_count`:

```132:132:/Users/fernandotn/.codex/archived_sessions/rollout-2026-08-11T12-05-05-019ff236-ce29-72f1-ad4e-5f28a775c7dc.jsonl
… "total_token_usage":{"input_tokens":0, … "output_tokens":0, … "total_tokens":11177} …
```

The previous line is `<EXTERNAL SESSION IMPORTED>`. Components are 0; `total_tokens` is not. Research’s `total = input + output` (`docs/research/2026-09-04-token-telemetry-sources.md:169`) is false for this shape. A “drop / first snapshot → emit `total_tokens` as the delta” rule would book 11,177 tokens that are not input-class and not output — they would vanish from the KPIs or show up as a ghost remainder.

**Rule:** delta the **component** fields (`input`, `cached`, `output`, `reasoning`, and `cache_write_input_tokens` when present). If every component delta is 0, emit nothing, even if `total_tokens` moved. Treat a drop in `total_tokens` as a counter reset **of the components**, not as “the new total is the delta.” First snapshot in a file is a delta from zeros of the components, not of `total_tokens`.

The cursor as spec’d (`path, size, mtime, offset, lastId`) is not enough for Codex. After a committed offset you will not re-read the previous snapshot, so you **must persist the last component vector** on the cursor (or you recompute a delta from 0 on every resume). `lastId` does not substitute.

`cache_write_input_tokens` exists on live rollouts (0 in the files I hit). Spec table hard-codes Codex `cacheWrite` = 0 (`docs/specs/token-telemetry.md:74`). Store the field when non-zero; do not assume the schema stays at 0.

Model from the latest `turn_context` is right (3 sessions switch mid-file; 183 have none → `unknown`). Apply `turn_context` in file order **before** the `token_count` that follows it.

Walk `CodexUsageService.resolvedDefaultCodexHome` (`CodexUsageService.swift:40–56`), not `~/.codex`. `$CODEX_HOME` is already a live contract (audit M11).

### Grok — completed turns only; do not fold `unified.jsonl` in v1

Sum `turn_completed.usage.modelUsage` per turn, keep `costUsdTicks`, label “completed turns.” That is the durable source (1.67 GB, ~30 days). Live `updates.jsonl` matches the research shape; `timestamp` is epoch seconds, with `_meta.agentTimestampMs` beside it — use the seconds field as spec’d.

**Do not fold `~/.grok/logs/unified.jsonl` in stage 1.** Reasons:

- ~3-day rotating window vs ~30-day sessions; mixing retentions makes provenance a lie.
- `inference_done` has no model and no `costUsdTicks` (live line: `prompt_tokens` / `cached_prompt_tokens` / `completion_tokens` / `reasoning_tokens` / `sid` / `loop_index`).
- A `turn_completed` that arrives on the next tick would double-count unless you key by `sid`+`prompt_id` and prefer the turn. That is a second dedup system for a 5–10% gap the footer already discloses.

Optional later: an explicit “in-flight / cancelled” band for `inference_done` rows whose `sid` has no `turn_completed`. Not v1. One Grok account today (`activeGrokProfileId` / `user_id`); keep the same time rule so a second account does not require a rewrite.

`costUsdTicks` is null on some turns (research: 1/8). Count tokens, omit that turn’s cost, do not interpolate.

### Cross-provider footgun (must-test)

The three CLIs do not agree on whether “input” includes cache:

| | Uncached field |
|---|---|
| Claude | `input_tokens` is already uncached |
| Codex | `input_tokens − cached_input_tokens` |
| Grok | `inputTokens − cachedReadTokens` |

The contract table gets this right (`docs/specs/token-telemetry.md:72–76`). A generic `input − cacheRead` on Claude will under-count (and can go tiny/negative). Fixture tests must include one Claude row where `input_tokens=2` and `cache_read_input_tokens` is tens of thousands.

Reasoning is a subset of output on all three. Never add it to output; report it as a share.

---

## B. Store and indexer

JSONL under Application Support is the right SoT. I would **not** choose SQLite anyway for this query shape. I **would** add a small sidecar for the things JSONL is bad at (in-flight Claude ids, last Codex snapshot, crash-atomic cursor). System `SQLite3` is available and is not a new dependency; the spec rejects it for the wrong reason (scan speed, `docs/specs/token-telemetry.md:101`). The real SQLite argument is transactional cursor+event commit and upserts. A JSON sidecar plus “fsync events, then atomic-rename cursors” gets you most of that without a query planner.

### Must-specify failure modes

1. **Partial last line.** Files are being appended while read. A tick that consumes a truncated JSON line must **not** advance `offset` past the last complete `\n`. Next tick retries that suffix. Missing from the spec; this is the default JSONL bug.

2. **Crash order.** If cursors commit before the corresponding events are durable, a crash **drops consumption forever** (offset skipped, units never rewritten). If events commit and cursors do not, a crash **duplicates** unless `message.id` / `(file, prompt_id)` is unique. Required order: append events → fsync → atomic-rename `cursors.json`. On duplicate resume, max-merge Claude; skip identical Codex/Grok units.

3. **File shrink / rewrite.** Spec already re-reads from 0 (`docs/specs/token-telemetry.md:108`). Combined with append-only events that **re-emits every unit in the file** unless the store is keyed. Compaction, truncation, or an editor rewrite will hit this. Global uniqueness (Claude `message.id`, Codex `(file id, snapshot seq)`, Grok `(session, prompt_id)`) is not optional.

4. **Vanished source files.** Claude deletes after 30 days. The store is the archive (`docs/research/2026-09-04-token-telemetry-sources.md:46–49`). A missing file must leave events and rollups alone; only drop the cursor. Spec this so nobody “reconciles” by deleting indexed history.

5. **Gzip vs schema change.** “Months older than three are gzipped and served from `rollups.json`” (`docs/specs/token-telemetry.md:102`) plus “rollups rebuilt on schema change” (`docs/specs/token-telemetry.md:96`) cannot both be true unless gzipped JSONL remains readable. Either keep gzipped events as the rebuild source, or freeze rollup schema and version them. Do not gzip until that month’s rollup has been verified against a full scan.

6. **Local day in rollups.** Buckets are local-calendar days (`docs/specs/token-telemetry.md:137`). Persist events in UTC only. Key persisted rollups by `(localDay, timeZoneIdentifier)` and rebuild on TZ change, or compute buckets at query time from UTC `at`. Index-time `localDay` will be wrong after a travel/TZ change.

7. **First pass vs 200 files / 5 min.** 12,560 Claude files / 200 per tick = 63 ticks. At the default 5 min interval that is **>5 hours**, not “a few minutes” (`docs/research/2026-09-04-token-telemetry-sources.md:278`). The 2 s / 200-file cap is fine; the **idle interval is not**. Catch-up: if a tick hits a bound, schedule the next immediately (still on the serial `.utility` queue). 5 min / 60 s is steady-state only. First-pass ~65 s CPU is believable from the prototype; wall-clock depends entirely on this.

8. **Timer placement.** `Timer.scheduledTimer` on the main run loop is how the sweep works (`MenuBarManager.swift:581–585`, added to `.common`). That is MainActor. Put the indexer timer on the **serial utility queue** (`DispatchSource.makeTimerSource(queue:)`), not on main with a hop. Skipping while `ProfileManager.isSwitchingProfile` needs a main-thread snapshot of `{isSwitching, three pointers, stamps}` at tick start; do not skip the file walk during catch-up — skip only the ownership-log write.

9. **Path.** Use `~/Library/Application Support/com.claudeusagewidget.app/telemetry/` (bundle id in `project.pbxproj`), not `…/Claude Usage/telemetry/`. No UserDefaults, no `NSWindow.autosaveName` (cfprefsd). Window frame, last scope, last query live as a file next to `schema.json`.

10. **Serial queue, line-streamed reads.** Six files exceed 50 MB (max 160 MB). Never `String(contentsOfFile:)`. `FileHandle` from offset, chunked, split on newlines — same discipline as the tripwire, but not a tail.

**Byte-needle prefilter:** keep it. Measure both spacings. `tool-results` pruned.

I would not introduce SQLite in v1. Revisit if uniqueness/upsert in JSON becomes the bug, not if a month of JSONL takes 200 ms to scan.

---

## C. Attribution

Three bands, never redistribute: correct, and the only honest answer given a 30-entry name-only ring that covers ~25 h (`SwitchEvent.swift:8–24`, `SharedDataStore.swift:329–332`, research §5).

The proposed **mechanism** is not.

### Do not poll every 5 min as the primary writer

`activateProfileDetailed` already stamps `SwitchEvent.at` at the moment of the switch (`ProfileManager.swift:910–918`). `claimActiveClaudeOwnership` / `claimActiveCodexOwnership` / `claimActiveGrokOwnership` (`ProfileManager.swift:1016–1037`) are the exact pointer-claim seams. `.providerOwnerChangedExternally` is posted from adoption with `object = newOwner.id` and `userInfo["provider"]` as a **String** (`ProfileManager.swift:1087–1095`).

A 5-min tick that diffs `activeAccountIds(among:)` will timestamp ownership as “when observed,” which is what the spec then has to flag as approximate (`docs/specs/token-telemetry.md:377`). That flag is honest only if you **created** the gap. Write the ownership log **at claim time** (and on the external-owner notification). Keep the tick-diff as a backstop for a missed notification after a crash.

“When observed” + “approximate when bracketing entries are more than one tick apart” is **not** honest enough as the main path. It is acceptable for the backstop.

### Do not seed blindly from `switchHistory_v1`

Holes in the ring, all live in this codebase:

- **Names only, no ids, no provider.** After a rename or two profiles named alike, the seed is a guess. ux-revamp already flags this (`docs/specs/ux-revamp.md:904`).
- **Focus-only rows.** `reason` starting `focus only — … login NOT applied, CLI unchanged` (`ProfileManager.swift:915–917`) is **not** an ownership change. Seeding it will attribute CLI consumption to an account that never owned the login — the exact confusion Viewing vs Active-for exists to prevent (`ProviderActiveSelection.swift:7–11`, `docs/specs/ux-revamp.md:828–831`).
- **Mixed providers.** `rateLimitEventOwnerName` already has to skip Codex/Grok rows to attribute a Claude death (`MenuBarManager.swift:2656–2673`). The seed must do the same: map `from`/`to` through today’s roster, require a unique name in that provider, else leave unattributed.
- **~25 h of history, then a cliff.** Label the unattributed band “before \<first ownership-log time\>”, not “before 09-03” as if that date were a property of the world.

Isolated-home Codex (path → `Profile.codexHomePath`) and single-account Grok are the only cases that may fill history the log does not cover. Default-home Codex on this machine is **not** isolated: research night had 0 files in `~/.codex-accounts/*/sessions`. Say that in the footer so the owner does not expect per-account Codex history from empty homes.

Do **not** write `attribution` onto event lines at index time (`docs/research/2026-09-04-token-telemetry-sources.md:282` vs spec §2.1 “filled by stage 4”). Join at query from `ownership.jsonl`. Pointer repairs then do not require rewriting months of JSONL. Rollups that include attribution must rebuild when the log changes; that is cheaper than a wrong stamp.

Selecting a sidebar account must not call `viewProfile` or `activateProfile`. This window is a scope, not Viewing.

---

## D. The window

**B over A.** 24 profiles (spec sizes to 30–40) cannot live in a header popup. The inspector deep link collapsing to “select this sidebar row” is the right state model (`docs/specs/token-telemetry.md:351–353`). A is a reasonable fallback if 1040 pt is too wide on a given display; do not ship C.

Copy the Settings **window** pattern, not its name: `BorderlessSettingsWindow` is **titled + hidden titlebar**, and the comment is load-bearing (`SettingsView.swift:114–138`). A true `.borderless` window reintroduced the window-server storm. Reuse `isReleasedWhenClosed = false`, the double-open guard, `bringWindowToForeground` (`MenuBarManager.swift:3940–4006`), never `setActivationPolicy(.regular)`. Nil `contentViewController` on close if you recreate; if you truly reuse one instance, do **not** nil it. Spec currently says both (`docs/specs/token-telemetry.md:300–305`). Pick reuse (keeps sidebar selection + scroll).

Do not wait on `WindowCoordinator` — it is listed as dead code in `docs/plans/PLAN-LATENCY-REFACTOR.md:90`.

`.telemetryWindowRequested` posters already exist (`Notification+Extensions.swift:71–77`, `MenuBarManager.swift:699–704`, dashboard header `DashboardView.swift:307`, row menu `DashboardView.swift:603`, popover name menu `PopoverContentView.swift:580–581`). **Register the observer at launch.** A controller created lazily on first post drops that post. Decode `userInfo["provider"]` as `String` **and** as `Profile.ProviderKind`: the telemetry posters pass the enum; `.providerOwnerChangedExternally` already passes `String(describing:)`. `(nil, .claude)` should open the Claude provider scope, not Fleet; the header posts `(nil, nil)` for Fleet.

Vocabulary: `ActiveVocabulary.activeFor` / `viewing` only. Never a plain “Active” badge. The classic popover still has one (`PopoverContentView.swift:262–264`); do not copy it.

### Small multiples at >20× median

Right instinct (no log axis, no dual axis). Wrong trigger as written.

- July 16 is ~35.5 B vs a Codex median day of 38 M ≈ **900×**, so it will fire, but **only on “All indexed.”** Default 7-day will not include those days; do not apply the rule to a 7-day window.
- Median of a sparse series is 0 (Grok, or a quiet provider). `20× 0` is every chart. Use the median of **nonzero** days, or “max > 20× (sum − max) / (n − 1)” with n ≥ 14.
- Fleet stacks by **three** providers, so small multiples are three rows — fine. Do not accidentally apply it to a 24-account stack.

### The four KPIs

Keep **input-class + cache-read share** and **output + thinking share**. Those are the two numbers that stop the window from lying.

**Units (messages / turns)** is noise at Fleet: Claude messages, Codex deltas, Grok turns are not one noun. Spec already hedges (“59% subagents (Claude) or 148 sessions”). Drop it at Fleet; show the provider-native count only inside a provider/account scope (Claude: messages, with subagent share; Codex: sessions; Grok: completed turns).

**≈ Cost** belongs, but the mock is not a computed number. See E.

Four 12-point sparklines **plus** the hero chart is redundant. Keep sparklines off, or only on the metric the chart is not showing.

### Missing in week one (the owner will ask)

- Click a day → that day’s model/account breakdown (the “what was 16 July?” question). Without it the hero chart is a poster.
- Input-class stacked as uncached / cache write / cache read as a **chart metric**, not only a KPI sub-line. Cache is 96.8% of Claude input-class and most of the list-price figure.
- Main vs subagent as a Claude toggle (59% of messages).
- Codex `originator`/`source` (exec / vscode / cli / guardian) — already in the records, cheap, and it explains the July waves.
- Store size + “indexing… N%” is spec’d; also a way to pause the indexer after the first pass hammers the disk.
- Export is not required in v1; a “copy numbers” on the KPI row is.

### Noise to cut

- Rate-limit death markers on a **consumption** chart. Spec correctly refuses to store Codex `rate_limits` because they are quota (`docs/specs/token-telemetry.md:82–84`) then draws `×` for Claude `error: rate_limit` (2,228 on disk, ~60/day). That is the tripwire’s job (`LocalLimitSignalService.swift:50–101`, already harvested every sweep). Default **switches only**; deaths stay on the dashboard. If they come back, collapse to `×N` per day or the axis is unreadable. Switches are ~30/25 h — also collapse.
- Sidebar compact totals while most history is unattributed. Show “—” or omit the number until the ownership log covers the selected window.
- “All indexed” as a control people will click once and then not understand. Keep it; default 7 days is right.

Type: dashboard scale is real (`DashboardView.swift` 12 bold names, 9.5, 9, 8.5). Header on the dashboard is 13 bold / 9 secondary (`DashboardView.swift:289–294`); match **that** for the telemetry header, not DesignTokens (Settings is a different scale). Route new strings through `Localizable.strings` (`"popover.token_usage"` is already `"Token usage…"`). Age strings through `DashboardFormatting.age`.

There is no Swift Charts usage in this tree. A custom `Canvas` stacked-column is implied by hatching, 2 pt gaps, rounded top, under-axis markers, small multiples. Budget for it; it will not fit in the same 600-line PR as the shell.

---

## E. Cost estimate

Show it, labelled. Do not omit it, and do not ship the mock’s `$2,140`.

Subscriptions are flat (Max / ChatGPT / SuperGrok). The figure is a **common unit** across Opus/Fable/Sonnet and across providers, which is the only way question 4 (“how it has impacted”) is comparable. It is also easy to read as a bill.

Label, verbatim in spirit:

> API list-price equivalent · not billed · as of \<date\>
> Cache reads priced at the cache-read rate. Grok share is the CLI’s own `costUsdTicks`.

Put the ⓘ on the tile (price table + `asOf` + “n models unpriced”). Colour is already correctly de-semantic (`docs/specs/token-telemetry.md:220–223`).

**The mock is internally inconsistent with the research.** Last-7-day Claude alone is 76.1 B cache reads + 2.24 B cache writes + 120 M output (`docs/research/2026-09-04-token-telemetry-sources.md:96`). At Opus list (`$0.50 / $6.25 / $25` per M, research §6) that is on the order of **$40k–$55k**, not `$2,140`. Even all-Sonnet cache reads are still five figures. Implementation must run `TokenPriceTable` over the real mix and accept a large number. Shrinking it by omitting cache reads would violate “no synthetic values.”

Grok: use `costUsdTicks`, never recompute, and say “reported by the Grok CLI (list, ≥200k tier).” Mixing Anthropic list + OpenAI list + Grok CLI ticks is three methodologies; the footer should say so.

Claude cache-write 5 m vs 1 h is in the records and in the price table. Use the split. If `cache_creation` is missing, price writes at the **5 m** rate and mark that month’s cost approximate — do not assume 1 h.

`codex-auto-review` unpriced → tokens shown, cost “n/a”, tile “n models unpriced.” Good.

If the owner hates the shock, the already-listed option “behind a toggle” (`docs/specs/token-telemetry.md:359`) is the escape hatch. Default **shown, labelled**; do not default off to hide a correct five-figure number.

---

## F. Staging and codebase fit

Four stages, tests on injected fixtures (see `LocalLimitSignalTests.swift:64–84`): right shape. Reorder and split.

| Change | Why |
|---|---|
| **Ownership-log writes move into stage 1** | Cheap, and stage 3’s sidebar “by account” is empty/unattributed for weeks otherwise. Join + markers stay stage 4. |
| **Split stage 3** | `TelemetryWindowController` + sidebar + KPI row + empty/indexing states as 3a; `StackedColumnChart` + hover + small multiples + light/dark as 3b. 3 as written will blow ~600 lines; this tree has no Charts code. |
| **Stage 1 readers stay `nonisolated` on a `DispatchQueue(.utility)`** | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (`project.pbxproj`). `Task.detached` is what `harvestLocalLimitSignals` uses (`MenuBarManager.swift:2621–2624`) and is exactly the warning storm CLAUDE.md tells you not to add. The regression tell remains: `'async' but is not marked with 'await'` at the call site (`LocalLimitSignalService.swift:24–32`). Assert `!Thread.isMainThread` in tests. |
| **Do not share `LocalLimitSignalService`** | Tripwire is mtime + **256 KB tail** + `"rate_limit"` (`LocalLimitSignalService.swift:55–59`). Indexer is offset-from-cursor + full new bytes + usage needles. Sharing the function would either miss history or re-walk 14 GB on the sweep. Extract a tiny `nonisolated` JSONL cursor helper (offset, partial last line, skip-hidden, prune `tool-results`) if you want one shared primitive; duplicate nothing else. |
| **Observer lives from `setup()`** | Posters are already on main (#75). No observer ⇒ first click is a no-op. |
| **Never UserDefaults** | cfprefsd is a live hazard (`Claude.md` Preferences section; `PreferenceWriteJournal`). |
| **Tests never walk the real home** | Inject roots. A live `telemetry-verify` against `~/.claude` belongs under Lab, not XCTest. |

Do not reorder past “index+store before window.” Do not put the window in stage 1.

Ad-hoc signing is irrelevant to this module (no Keychain). Still: no `security` / `SecItem` on the indexer queue.

`isSwitchingProfile` skip is copied from the sweep (`MenuBarManager.swift:1361–1364`). Correct for ownership writes (contamination during switch is a real incident). Incorrect if it pauses catch-up.

---

## G. What I would change before implementation starts

1. **In-flight Claude upsert + global `message.id` uniqueness.** Append-only JSONL without this under-counts streaming output or duplicates on shrink/resume.
2. **Codex cursor stores the last component vector; ignore `total_tokens` remainder; skip all-zero-component snapshots.** The external-import record is a live trap.
3. **JSONL cursor contract:** last complete newline, events fsynced before cursor rename, vanished files do not delete events, catch-up ticks with no 5 min sleep.
4. **Ownership log written from `claimActive*Ownership` + `.providerOwnerChangedExternally`, ids not names; skip focus-only `SwitchEvent`s; join at query.**
5. **Application Support path = bundle id; window frame in that directory.**
6. **Catch-up scheduling** so the first 27 GB is minutes of wall-clock, not hours.
7. **Cost: compute it, label it, expect five figures; drop the `$2,140` mock.** Cache-read share stays in the number.
8. **Drop Fleet “messages” KPI; default markers = switches only, collapsed.**
9. **Tighten the small-multiples trigger** (nonzero median, windows ≥ 14 days).
10. **Split stage 3; move ownership writes to stage 1; register the window observer at launch; titled window, not borderless.**
11. **Do not fold Grok `unified.jsonl` in v1.**
12. **Resolve roots through `Constants.ClaudePaths` and `CodexUsageService.resolvedDefaultCodexHome`.**
13. **Selecting a sidebar row is scope, not Viewing.**

If those land in the spec, stage 1 is safe to write.

---

### Could not verify

- Census scripts and `proto/scan.swift` are not in this worktree (“the job’s `census/`”). Volumes (259.7 B, 54.2 B, 0.93 B) are taken from the research doc; I did not re-run the 27 GB walk.
- Multi-element `iterations[]` (only one-element arrays in the files I opened).
- Whether Claude compaction **rewrites** a jsonl (shrink path) vs only appends.
- Non-zero Codex `cache_write_input_tokens` (field exists; no non-zero hit in a short search).
- `docs/specs/token-telemetry-checkin.html` and the §8 consult files — not present yet; this review is the Grok consult that section is waiting on.
- Settings is still `720×750` in this tree (`Constants.swift:118`) while ux-revamp wants 820; unrelated, but the telemetry 1040×680 window will be the widest surface in the app.
