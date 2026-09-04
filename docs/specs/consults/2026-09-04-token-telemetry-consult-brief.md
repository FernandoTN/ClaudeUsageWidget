# Review brief: token-consumption telemetry window for a macOS menu-bar app

You are reviewing a design proposal before implementation. Read-only; you cannot
see any conversation. Investigate the repository as much as you need.

## Context

Repository root is your working directory: "Claude Usage", a privacy-focused macOS
menu-bar agent (SwiftUI + AppKit, macOS 14+, Swift 5 language mode with
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, ad-hoc signed, no dock icon). It shows
subscription usage for a fleet of ~24 accounts across three providers (Claude Code,
OpenAI Codex, xAI Grok) and switches the shared CLI logins between accounts.

The owner asked for a NEW WINDOW showing token CONSUMPTION telemetry over time —
by provider, model, account, in aggregate, with trends — read from the CLIs' own
local logs. Hard rulings: consumption is never presented as quota; no synthetic
values; every number carries its source and age; nothing leaves the machine; the
indexer must run off the main actor (a scanner that hopped to MainActor froze the
UI this week), be incremental and bounded per pass, and store its index in a file
under ~/Library/Application Support (UserDefaults/cfprefsd is a live hazard here).

## Read these first (in this order)

1. `CLAUDE.md` — concurrency model, credential rules, the Preferences-degradation
   section, and the fleet/attribution mechanisms (long; skim the headings, read
   "Concurrency model" and "Preferences (cfprefsd) degradation" fully).
2. `docs/research/2026-09-04-token-telemetry-sources.md` — the measured facts
   about the three data sources on the owner's Mac (record shapes, dedup rules,
   volumes, retention, timings, attribution horizon).
3. `docs/specs/token-telemetry.md` — the proposal under review (data contract,
   store, indexer, aggregation, window layouts A/B/C with B recommended,
   frame-by-frame passes, staged plan, open questions).
4. `Claude Usage/Shared/Services/LocalLimitSignalService.swift` — the existing
   off-main transcript scanner the indexer must follow (`nonisolated` is
   load-bearing).
5. `Claude Usage/MenuBar/DashboardView.swift` (`DashboardFormatting`, style scale),
   `Claude Usage/MenuBar/MenuBarManager.swift` around `preferencesClicked` /
   `bringWindowToForeground` / `requestTokenUsageWindow` (window pattern and the
   `.telemetryWindowRequested` posters that already exist on main),
   `Claude Usage/Shared/Storage/SharedDataStore.swift` (`switchHistory_v1` ring),
   `Claude Usage/Shared/Models/Profile.swift` (identity stamps),
   `Claude Usage/Shared/Models/ProviderActiveSelection.swift` (`ActiveVocabulary`).
6. `docs/specs/menubar-redesign.md` §6 and `docs/specs/ux-revamp.md` §10 — how
   prior consults were recorded, and the vocabulary rulings you must not contradict
   ("Active for <provider>", "Viewing", never plain "Active").

## What to review (answer each; be concrete; cite file:line where relevant)

A. **Data correctness.** Are the dedup/delta rules right and complete?
   - Claude: dedup by `message.id`, max `output_tokens` across block records, skip
     `<synthetic>`. Anything the streaming-write pattern could still double count
     (retries, `iterations[]`, resumed sessions across project directories,
     subagent files)?
   - Codex: deltas between distinct `total_token_usage` snapshots, per-key negative
     deltas clamped to 0, a drop in `total_tokens` treated as a fresh counter,
     model from the latest `turn_context`. Is "index by file, not session id"
     right given 76 shared `session_meta.id`s? Is `last_token_usage` really
     unsafe to sum?
   - Grok: sum `turn_completed.usage.modelUsage` per turn; keep `costUsdTicks` as
     the CLI's own figure; label as "completed turns" with the measured 5–10 %
     gap vs the per-call `unified.jsonl`. Should the per-call log be folded in?
B. **Store and indexer.** Append-only monthly JSONL + cursors + ownership log +
   rollups under Application Support, no SQLite, atomic renames, gzip after three
   months; own `.utility` timer; ≤ 200 files / ≤ 2 s per tick; byte-needle
   prefilter. Failure modes? Would you choose SQLite anyway (no new dependency is
   a constraint; `SQLite3` is in the SDK)? Crash-consistency of cursors vs events?
   Handling of files that are being appended while read (partial last line)?
C. **Attribution.** Records carry no account; attribution is by time from the
   widget's own ownership log (seeded from a 30-entry switch ring covering ~25 h)
   with three bands (attributed / isolated-home or single-account / unattributed,
   never redistributed). Holes? Is "when observed" plus an "approximate" flag when
   bracketing entries are more than one tick apart honest enough?
D. **The window.** Layout B (sidebar scope: Fleet → provider → account →
   Unattributed; report pane: KPI row, stacked daily columns with 7-day mean and
   markers, by-model and by-account tables, provenance footer). Is B right over A?
   Is the ">20× median → small multiples" rule the right answer to the two July
   Codex spike days? Is the KPI framing (input-class with cache share; output with
   thinking share; units; labelled list-price cost) the right four? What is
   missing that the owner will ask for in week one? What is there that is noise?
E. **Cost estimate.** A shipped price table with an `asOf` (Anthropic list,
   OpenAI list for gpt-5.6-sol/terra/5.5, Grok via the CLI's nano-USD ticks).
   Subscriptions are flat — is a list-price "API-equivalent" figure useful or
   misleading? How should it be labelled?
F. **Staging and codebase fit.** Four stages (index+store; report model; window;
   attribution+markers), each ≤ ~600 lines with tests on fixtures. Where does
   this break against this codebase (MainActor default, ad-hoc signing, cfprefsd,
   the `LocalLimitSignalService` reader — share it or duplicate it?, the
   `.telemetryWindowRequested` contract, the Settings window pattern)? Reorder?
G. **Anything else** — what would you change before implementation starts?

## Output

Write a Markdown review with a one-line verdict ("approve", "approve with
revisions", "rethink") followed by sections A–G. Prefer specific, actionable
findings over general advice. Flag anything you could not verify.
