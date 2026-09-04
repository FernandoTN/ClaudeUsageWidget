Verdict: **approve with revisions**. The product direction and source formulas are sound, but implementation should not begin until ingestion is idempotent/crash-consistent, ownership gaps are modelled honestly, and attribution moves ahead of the window.

## A. Data correctness

- **Claude’s basic rule is correct:** `message.id` identifies the API response, repeated content-block records must collapse, subagents are real calls, and `<synthetic>` usage should be excluded. The measured 2.09× duplication and partial-output behavior justify max-output dedup ([research:79–87](docs/research/2026-09-04-token-telemetry-sources.md:79)).

- **The incremental rule is incomplete.** The proposed cursor retains only `lastId`, while the store promises one already-deduplicated event ([spec:90–116](docs/specs/token-telemetry.md:90)). If an early block with `output_tokens = 4` is committed and a later block raises it to 1,730, there is no state with which to replace or correct the first event. Persist a pending Claude accumulator containing the full selected usage snapshot, and finalize only after a different message begins or the file has settled. SQLite `UPSERT` by unit ID would make this much simpler.

- Add a stable `unitId` to every event. For Claude, use `message.id`; deduplicate globally, not merely per file, so cross-directory resumes remain safe even though the current census found no cross-file duplicates ([research:101–112](docs/research/2026-09-04-token-telemetry-sources.md:101)). Count retries with distinct message IDs—they are distinct consumption. Do not perform semantic retry deduplication.

- Do not sum `iterations[]`; sampled records show it mirrors the top-level usage breakdown. Before shipping, corpus-check whether `thinking_tokens` and the 5-minute/1-hour cache fields always agree across blocks. The research only explicitly establishes stability for input/cache totals and variability for output ([research:79–84](docs/research/2026-09-04-token-telemetry-sources.md:79)). Prefer the complete snapshot associated with the maximum output rather than independently combining maxima that may never have coexisted.

- **Codex is correctly indexed by file, not `session_meta.id`.** Seventy-six IDs are shared by independent rollout files with independent counters ([research:143–153](docs/research/2026-09-04-token-telemetry-sources.md:143)). `last_token_usage` is unsafe to sum and should remain validation-only ([research:167–175](docs/research/2026-09-04-token-telemetry-sources.md:167)).

- A Codex cursor must persist the **previous complete cumulative vector and current model**, not just an offset. Otherwise the first event after relaunch cannot be differenced or attributed to the latest preceding `turn_context`. Clamp derived uncached input as well as raw fields, enforce `cached ≤ input` and `reasoning ≤ output`, and retain a `counterCorrection`/`counterReset` diagnostic because independent clamping can make component sums exceed the authoritative `total_tokens` delta.

- **Grok completed turns are the right durable canonical source.** Add deduplication using `_meta.eventId`, falling back to `(sessionId, prompt_id)`. The proposal currently says “sum turns” without specifying duplicate protection ([research:216–233](docs/research/2026-09-04-token-telemetry-sources.md:216)).

- Do **not** fold `unified.jsonl` into the canonical total in v1. Its short retention and lack of a demonstrated exact reconciliation key would create a discontinuous hybrid series or double-count calls belonging to completed turns. Expose it later as a separate “all model calls, recent log only” completeness diagnostic; cancelled-turn consumption remains missing from the durable series, explicitly labelled.

## B. Store and indexer

I would choose **SQLite**. `SQLite3` is a system SDK library, not a third-party package, and this archive needs exactly what SQLite provides: a unique event key plus one transaction covering events, markers, cursor state, and rollup invalidation.

Atomic rename does not make JSONL ingestion transactional. If events append before `cursors.json` advances, a crash duplicates them; if the cursor advances first, a crash loses them. “Append-only + atomic writes” does not resolve that boundary ([spec:86–102](docs/specs/token-telemetry.md:86)). If JSONL remains mandatory, use atomically committed per-batch segment files keyed by source-offset range and derive cursors from committed segments; a plain monthly append file is insufficient.

Other required corrections:

- Snapshot the source file’s size when opening it, read no further than that point, and commit the cursor only through the final complete newline. Preserve or reread the trailing fragment next pass. A partial JSON line is normal, not malformed data.

- Bound **bytes and parsing work**, not merely files. One large file can violate the two-second limit. Resume within a file at a newline boundary.

- The first-run timing is currently misstated. At two seconds every five minutes, 65 seconds of work needs roughly 33 ticks—about 2¾ hours—and 12,560 Claude files at 200 per tick needs about 63 ticks—over five hours ([research:277–305](docs/research/2026-09-04-token-telemetry-sources.md:277)). While backlog exists, schedule the next bounded slice promptly after yielding; do not wait for the five-minute steady-state timer.

- Handle Codex files moving into `archived_sessions`. Path is not durable file identity. Use stable event IDs plus APFS resource identity/basename metadata so a move or copy cannot re-import the rollout.

- Do not advance a cursor after an unreadable line, store failure, disk-full error, or parser-shape failure. Publish per-provider counts for unreadable files, malformed complete lines, unknown shapes, and backlog; never render those failures as zero consumption.

- Keep raw compressed events as the recoverable ledger and rollups as disposable derived data. Time-zone changes, attribution repairs, and future dimensions otherwise cannot rebuild older history.

- Create the telemetry directory as `0700` and files as `0600`; paths, project names, account names, and activity times are private even without credentials.

## C. Attribution

The three-band policy is correct, but “when observed + approximate” currently overstates what is known.

The legacy switch record contains only timestamp, `from`/`to` names, trigger, and reason—no UUID, account stamp, or provider ([SwitchEvent:18–23](Claude%20Usage/Shared/Models/SwitchEvent.swift:18)). Seed it only when each name maps uniquely to one current profile and one provider. Renamed, deleted, duplicated, or cross-provider names must remain unattributed.

Going forward:

- Record an exact typed ownership event inside the successful activation seam immediately after the provider pointer is claimed. Include provider, previous/new profile IDs, account stamps, cause, and certainty.

- Treat `.providerOwnerChangedExternally` as an observation, not the actual switch time. Its existing contract names only the newly observed owner ([Notification extensions:17–23](Claude%20Usage/Shared/Extensions/Notification+Extensions.swift:17)). If owner A was last seen at 10:00 and B is first seen at 10:05, events in that interval are unattributed—not assigned to B with an “approximate” badge.

- Persist periodic owner observations/heartbeats so uncertainty intervals are bounded. App-downtime gaps and an external switch away-and-back between ticks cannot be reconstructed.

- Record the evidence basis: exact app switch, external observation, authoritative pointer, sole-account inference, or isolated home. The current resolver deliberately distinguishes a persisted pointer from a sole credentialed-profile fallback ([ProfileManager:1131–1156](Claude%20Usage/Shared/Services/ProfileManager.swift:1131)).

- Keep attribution out of immutable `TelemetryEvent`. Store raw time/source identity and resolve ownership when constructing rollups. Otherwise stage 4 must mutate an append-only stage-1 ledger ([spec:64–80](docs/specs/token-telemetry.md:64)).

- Reuse `CodexUsageService.defaultCodexHome`, not hard-coded `~/.codex`; the application already honors `$CODEX_HOME` ([CodexUsageService:36–55](Claude%20Usage/Shared/Services/CodexUsageService.swift:36)).

## D. The window

**B is the right layout.** Twenty-four accounts already make A’s popup awkward, and B supplies a stable deep-link target and an honest home for Unattributed. The current revision’s Fleet-default `Split` mode correctly addresses Claude making Codex and Grok one-pixel slivers ([spec:240–250](docs/specs/token-telemetry.md:240)).

The remaining chart problem is temporal: splitting by model does not stop a 35 B `gpt-5.6-sol` day from flattening every ordinary day in that same model row. Revise the policy to:

- Today: hourly; 7/30 days: daily; All indexed: weekly initially, monthly as history grows.
- Require enough non-zero completed buckets before applying a median ratio.
- Add an explicit “typical range / include outliers” control or annotated overflow treatment. Small multiples solve cross-series scale, not within-series outliers.
- Exclude today’s partial bucket from the 7-day mean, or draw its contribution as provisional.
- Compare partial periods with the same elapsed portion of the preceding period.

The KPI pair “input-class + cache share” and “output + thinking share” is strong. Define input-class visibly as uncached input + cache writes + cache reads. The other two should vary by scope:

- Fleet: API-equivalent estimate and **coverage**—attributed share, source freshness, and incomplete-source warning.
- Provider/account: provider-specific messages/deltas/completed turns and the estimate.

A fleet “units” total is noise because Claude messages, Codex counter deltas, and Grok completed turns are not comparable units.

Also revise provenance. One global “indexed 12 s ago” line is not enough to satisfy the ruling that every number carries source and age. Track both `scannedAt` and `dataThrough` per provider; a fresh scan of a stale or unreadable source is not fresh data.

Likely week-one asks:

- By project/cwd and Codex surface/originator.
- Main vs subagent consumption.
- Refresh now, pause indexing, delete telemetry archive, and export CSV/JSON.
- Scan-health details and storage size.
- Marker clustering—this fleet can generate dozens of switches per day.
- A visible attribution/completeness figure, not footer-only caveats.

The four KPI sparklines are probably redundant beside the hero chart and can be cut first if the 680-point layout feels crowded.

Vocabulary is correct in the proposal: use `ActiveVocabulary.activeFor`, never plain “Active” ([ActiveVocabulary:24–54](Claude%20Usage/Shared/Models/ProviderActiveSelection.swift:24)). Be careful not to copy the existing dashboard’s literal `ACTIVE` label ([DashboardView:419–425](Claude%20Usage/MenuBar/DashboardView.swift:419)).

## E. Cost estimate

It is useful as a **comparative workload equivalent**, but misleading as “cost” or savings. Use this exact framing:

> **API list-price equivalent — not billed**  
> Rates published 4 Sep 2026; selected models or pricing modifiers may be unpriced.

Prefer it behind the chart metric or an opt-in KPI, not as a primary spend number.

The shipped table’s base prices are current, but OpenAI’s current Sol pricing also has a long-context multiplier above 272K and a cache-write premium that the proposed Codex event schema cannot reconstruct. Sol’s price is also explicitly promotional, making effective dates important ([OpenAI GPT-5.6 Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol)). Anthropic’s cache-tier values, including Fable 5.1’s reduced cache-read price, are directly supported by its current model documentation ([Anthropic Fable 5.1](https://platform.claude.com/docs/en/models/fable-5-1/overview)). xAI’s short/long-context tiers likewise match the research table ([xAI pricing](https://docs.x.ai/developers/pricing)).

Therefore:

- Codex should say “base-rate estimate; excludes unobserved cache-write and long-context modifiers,” not imply precision.
- Grok ticks should say “Grok CLI-reported list-price equivalent.”
- A Fleet total mixing computed Claude/Codex estimates and Grok-reported ticks must expose that mixed methodology.
- Decide whether history is priced at rates effective on the event date or uniformly “at rates as of X.” I recommend the latter for comparison, with versioned tables and no silent repricing within an app release.

## F. Staging and codebase fit

The current order breaks because Layout B’s account sidebar and tables ship before attribution. Move attribution ahead of the window:

1. Transactional ledger/schema, stable unit IDs, partial-line state, ownership recorder.
2. Three readers, bounded catch-up scheduler, corpus verification.
3. Attribution resolver, markers, report model, pricing and time bucketing.
4. Window shell/sidebar/tables.
5. Chart, hover, accessibility, render QA.

The existing ≤600-line stages are too broad, particularly index+store+three readers and the entire interactive window ([spec:323–331](docs/specs/token-telemetry.md:323)).

Concurrency requirements:

- Keep readers, ledger access, rollup rebuilds, and report generation off-main—not only directory scanning. `nonisolated` is demonstrably load-bearing in the existing scanner ([LocalLimitSignalService:21–33](Claude%20Usage/Shared/Services/LocalLimitSignalService.swift:21)).
- Use a serial `.utility` `DispatchSourceTimer`; pass immutable, `Sendable` owner snapshots from `@MainActor`. Never reach into `ProfileManager` from that queue; the class is explicitly main-actor isolated ([ProfileManager:12–36](Claude%20Usage/Shared/Services/ProfileManager.swift:12)).
- Share a small nonisolated transcript primitive—directory pruning, candidate enumeration, newline framing, timestamp parsing—with `LocalLimitSignalService`. Do not make the 30-second exhaustion tripwire depend on the five-minute telemetry indexer until equivalence is proven.
- Instantiate the telemetry window observer at startup so the existing notification cannot be dropped. Reuse the existing minimized-window, double-open, foregrounding, and no-activation-policy-flip behavior ([MenuBarManager:3940–4006](Claude%20Usage/MenuBar/MenuBarManager.swift:3940)). If close releases the hosting controller, reopening must reinstall it.
- Inject all source roots and the store URL in tests. Never let an XCTest index the real home or Application Support. The codebase already isolates test defaults for exactly this class of production-state hazard ([SharedDataStore:41–52](Claude%20Usage/Shared/Storage/SharedDataStore.swift:41)).

Ad-hoc signing is not a blocker for these files, and the app is not sandboxed. cfprefsd is avoided correctly.

## G. Anything else

Before implementation:

- Freeze the unit-ID and transactional-commit design.
- Make raw events attribution-independent.
- Add data-quality fields: dedup basis, parser version, certainty, source health, and missing/unpriced counts.
- Index everything currently on disk, using prompt bounded catch-up slices; otherwise “All indexed” permanently discards available Codex history.
- Add pause/delete controls because this privacy-focused app is creating a durable behavioral archive.
- Commit redacted fixtures and the census/prototype tools. The research says `census/*.py` and `proto/scan.swift` were kept for reruns, but none are present in this worktree ([research:13–15](docs/research/2026-09-04-token-telemetry-sources.md:13)). I therefore could not independently reproduce the corpus totals or all rare-shape claims. I spot-checked local Claude `iterations[]` and Grok event/cost shapes, but that is not a corpus proof.
- No implementation exists yet, so crash recovery, throughput, memory bounds, and rendering could not be verified by build or test.

No files were changed.

