# ClaudeUsageWidget — Latency Refactor & De-bloat Plan (v2, post-Codex-review)

**Repo:** `/Users/fernandotn/Projects/ClaudeUsageWidget` (macOS menu-bar app, SwiftUI + AppKit, macOS 14+)
**Problem:** worked fine at 3–4 accounts; at 14 accounts latency makes it almost unusable.
**Core value to preserve:** (1) menu-bar visualizations per account, (2) auto account switching, (3) CLI token tracking for Claude Code / Codex / Grok subscriptions.
**Branch:** `refactor/latency-14-accounts` in worktree `.claude/worktrees/latency-refactor` (baseline build + full test suite verified GREEN).
**Evidence:** live profiling of running app (PID 84112) + 3 parallel code-research reports + Codex (gpt-5.6-sol, reasoning=max) adversarial review (verdict REWORK — all accepted deltas folded into this v2).

---

## 1. Evidence & root-cause analysis (ranked)

Live measurements: app burns **23–30% of a CPU core continuously** (135 CPU-min since Saturday — continues even with the display asleep); ~10k window-occlusion events/min concentrated on ONE window; main thread ~21% of samples in `stepTransactionFlush → CA::Transaction::flush → mach_msg`, plus tracking-area/cursor-rect churn; idle `sample` caught `PopoverContentView.body` evaluating. 14 profiles all selected; **6 of 14 tiles permanently overflow-parked off-screen at x=1701** yet still rendered + TIFF-encoded per repaint. Window census (CGWindowList): popover window persists when closed (layer 25, 306×338); **four anomalous full-width 1728×33 windows at layer 0** spanning the menu-bar strip; one 685×30 window at layer 1000; the per-tile status windows not separately enumerated. One of the full-width strips is the prime suspect for the occlusion-event storm.

| # | Root cause | Evidence | Confidence |
|---|---|---|---|
| R1 | **Standing CA-commit + tracking-area churn tied to the app's window population** (status-item group, persistent popover window, and/or the anomalous full-width strip windows). Owns the continuous ~25% CPU and the main thread that services every click. | sample: 4,441/21,102 main-thread samples in CA flush; occlusion storm on one window; window census above | High that it's window-population-driven; **which window/layer dirties per cycle is unproven → Phase 0 gate** |
| R2 | **Settings/structural events over-trigger:** cosmetic toggles post `.displayModeChanged` → `setupMultiProfileMode()` → full 14-tile teardown/recreate (28 renders, two paints each by design) + full network sweep. 7 cosmetic sites in `ManageProfilesView` (`:127,149,164,179,194,209,224`) + mode/selection sites (`:65,:93`). Additionally ALL THREE manager setters defer mutation via `DispatchQueue.main.async` (`ProfileManager.swift:156` area) while views post notifications synchronously — observers can rebuild from the OLD configuration (race broader than selection). | `MenuBarManager.swift:669,679-706,741,760`; `StatusBarUIManager.swift:141` | High (chain verified by Codex) |
| R3 | **Persistence amplification on the main actor.** `saveClaudeUsage`/`saveAPIUsage` do full 34.7KB decode + pretty-printed encode of all 14 profiles per fetched profile (measured 397 loads + 120 saves / 15 min); Codex fetch calls `loadProfiles()` 3×, Grok 3×, sync 2×. Implicit `@MainActor` (SWIFT_DEFAULT_ACTOR_ISOLATION, Swift 5 mode → violations are only warnings) puts it all on the UI thread. NOTE: the per-save reload is ALSO a load-bearing sync point that adopts provider-side credential rotations into `ProfileManager` — removal must replace it, not delete it. | `ProfileManager.swift:531-589`; `ProfileStore.swift:318-406`; `CodexUsageService.swift:205,306,415`; `GrokUsageService.swift:190,229,249` | High |
| R4 | **SwiftUI publish storm × per-row JSON re-parse.** 2–3 `objectWillChange` per profile save × ~16 shared-manager observer declarations; every `ManageProfilesView` row subscribes to the global manager and re-parses credentials 4–5× per publish (~1,100 JSON parses + ~280 `Date.FormatStyle` calls / 30s with settings open). | `ProfileManager.swift:539,551,555`; `ManageProfilesView.swift:424,556-588`; `PopoverContentView.swift:308-328` | High |
| R5 | **Render path: no icon cache; TIFF-encodes all 14 tiles per repaint** purely for change detection (incl. 6 invisible tiles); 13 `lockFocus` legacy-context sites across `MenuBarIconRenderer.swift:285-1283`. The TIFF comparison DOES correctly suppress downstream churn — keep until a proven replacement exists. | `StatusBarUIManager.swift:748-757` | High |
| R6 | **Startup cliff:** 5 Keychain reads × 14 profiles = 70 serialized `security` spawns (12.2ms each ≈ 0.85s) behind a main-thread `sem.wait(timeout: 2.0)` (ceiling ≈ 33 profiles at current cost, but the wait is already ~1s of blocked main thread today). | `ProfileStore.swift:96-125,267` | High |
| R7 | **Staleness (correctness):** Claude rotation budget pinned at 1 → 10 background Claude profiles refresh every ~5 min (comment claims 2.5 min, written for 6 profiles). Weekly-reset rollover on stale data forces a full rebuild ~2/day at N=14. Sleeps are index-based, not provider-aware. | `MenuBarManager.swift:792-816,843-850`; `Profile.swift:308-314` | High |
| R8 | **Bloat:** ~6,000–6,500 lines (~25%) non-core; some with runtime cost (status.claude.com poll every sweep both modes; per-sweep `debugTileLayout` UserDefaults write + fresh `ISO8601DateFormatter`; ErrorLogger ring buffer nothing reads). | bloat inventory (§Phase 5) | High |

Non-findings (do NOT spend effort): minute-quantized ranking keys work; stranded-tile heal correctly suppressed at overflow (no loop); no per-second timers; network volume (~12–20 req/min) fine; `lastImageData` works as a change-detector.

---

## 2. Goals / non-goals

**Goals:** idle CPU near 0%; settings interactions instant (no rebuild/no network on cosmetic changes); main thread free of sweep-driven codec/persistence; startup without the main-thread block; 14 accounts tracked with bounded, budget-respecting staleness; ~25% of the codebase removed.
**Non-goals (this pass):** Grok settings UI (separate feature TODO); condensed/aggregated tile mode (owner UX decision — promoted to Phase 1b if Phase 0 proves static window count is causal); full Swift 6 strict-concurrency migration of the whole app (we DO enable strict checking for touched persistence components); auto-switch policy changes.

---

## 3. Phased implementation

Per phase: Grok write-children implement from prescriptive packets in the worktree; Claude audits every diff line-by-line, builds (`DEVELOPER_DIR=... xcodebuild`), runs tests, iterates, commits. Grok children never build, never commit, never touch credential-merge logic unreviewed.

### Phase 0 — Causality gate for R1 — **EXECUTED 2026-07-28, VERDICT IN**
Lab harness results (synthetic tiles, separate bundle id `com.claudeusagewidget.lab`, 120s steady-state each): 14 frozen static tiles **0.0% CPU / 0 CA flushes**; 7 frozen **0.0%**; 14 tiles with full repaint every 30s (14 renders + 14 TIFF + 14 assignments, counter-verified) **4.3%**; 14 frozen + open popover with stub content **0.0%**. Production app same moment: **23.5%**.
**Conclusions:** (a) static NSStatusItem window population — even overflowed — is free; R1's "structural window count" branch is FALSIFIED; condensed tile mode is NOT needed for CPU (remains a UX option only). (b) The repaint path accounts for only ~4%. (c) The dominant ~19% comes from what the lab omitted: sweep-driven persistence amplification + SwiftUI publish storm re-rendering the popover's live `PopoverContentView` while closed (idle `sample` caught its body evaluating; the stub-content popover cost 0%). **Phase ordering updated: Phase 2 (persistence/publish) is the primary CPU fix and runs FIRST, joined by popover content-teardown-on-close; Phase 1 render work follows for the repaint ~4% and settings-interaction latency.**

*(Original gate design, retained for reference:)*
Staged isolation, each step changing ONE variable, measuring steady-state CPU (`ps`) + CA-flush share (`sample`) + occlusion rate (`log stream`):
- 0.1 **Window census & identification.** Instrumented build (env-gated `CUW_RENDER_LOG=1`, os_log signposts) that logs every NSWindow the app creates (class, frame, level) — identify the four 1728×33 layer-0 strips, the 685×30 layer-1000 window, and map the occlusion-storm window number to a concrete window. (These may be AppKit status-bar internals or app-created; must know before optimizing.)
- 0.2 **Popover isolation.** Compare: popover window fully destroyed (not just closed) vs. persistent-closed vs. open, at constant tile count. The persistent window + idle `PopoverContentView.body` evaluation makes this a prime suspect.
- 0.3 **App-work freeze.** Env flag suspending all app-driven work (timer sweeps, renders, image assignment, diagnostics, network) while keeping 14 static status items alive. If CPU stays high → the cost is structural (window population), not app code.
- 0.4 **Parked-item isolation.** Hide only the 6 parked items (item removal, not selection change; persisted config untouched).
- 0.5 If still ambiguous: minimal harness app with 7 vs 14 static `NSStatusItem`s.
- **Decision gate:** if static window count is causal → promote overflow-item REMOVAL (`isVisible = false` / item removal for parked tiles) and/or condensed representation (Phase 1b, owner decision) AHEAD of renderer caching. If app-driven repaint is causal → Phase 1 as written. If the popover panel is causal → destroy-on-close becomes a Phase 1 item.
- Notes: instrumented copy takes the single-instance lock (guard is launch-date-based; relaunch production copy afterward) and SHARES UserDefaults with production — restore any touched state; screen-asleep measurement baseline differs — measure with display awake.
- Accept: written before/after numbers per step in the PR; the churning window identified by class.

### Phase 1 — Render path (R1/R2/R5)
- 1.1 **Typed structural-vs-cosmetic event split, mutation-before-notification.** Manager setters are already main-actor — make them mutate synchronously and post typed notifications AFTER mutation (fixes the deferred-mutation/sync-post race for selection, display mode, AND multi-profile config — `ProfileManager.swift:156` area). Remove view-owned posts (`ManageProfilesView`, `AppearanceSettingsView`); views call manager methods, manager emits `.structuralConfigChanged` (rebuild allowed) or `.cosmeticConfigChanged` (repaint only, NO teardown, NO network). Selection change: rebuild + repaint from cached usage + fetch ONLY newly-selected profiles lacking cached usage.
- 1.2 **Render-key icon cache (parity-gated).** Style-specific `Hashable` keys built from the EXACT pixel-quantized renderer inputs (per style: quantized fractions at the style's own pixel resolution — ring angles/bar widths use full Doubles today (`MenuBarIconRenderer.swift:787,1063`) so quantize at backing-scale pixel granularity — plus status levels, pace states, marker positions, 3-char label, appearance name, backing scale, `MultiProfileDisplayConfig`). Cache `[UUID: (key, NSImage)]`. **Pixel-equivalence tests (render twice, compare bitmaps for a matrix of inputs per style) BEFORE the TIFF comparison is removed**; until parity is proven, keep `lastImageData` as the final guard. Invalidate on cleanup + appearance change (preserve `:170-173`, `:740` semantics).
- 1.3 **Stop rendering parked tiles** (or, per Phase 0 gate, REMOVE their status items). Never skip a tile with no image yet; un-parked tiles re-render next repaint; recompute parked set on screen-parameter change — and CHANGE the screen-parameter observer to also refresh the parked set (today it only heals an invalid status bar, `MenuBarManager.swift:710-721`).
- 1.4 Per-sweep diagnostic waste: `debugTileLayout` write only on verdict change; `static let` ISO8601DateFormatter (`StatusBarUIManager.swift:366-367`).
- 1.5 Popover: destroy-on-close if Phase 0 implicates the persistent window; otherwise reuse the hosting controller instead of rebuilding per open (`MenuBarManager.swift:498,508`).
- Tests: render-key equality matrix; pixel-parity per style; parked-set derivation; typed-notification routing (cosmetic ⇒ zero `setupMultiProfile` calls, zero fetches — assert via injected spy).
- Accept: flipping "show week" at 14 accounts ⇒ 0 status-item recreations, 0 HTTP; steady-state repaint ⇒ 0 renders when no displayed pixel changed.

### Phase 2 — Persistence & publish storm (R3/R4) — *design revised per Codex findings 2/3/7/8*
- 2.1 **Atomic usage-patch API instead of read-modify-write.** New repository operation `applyUsagePatches([ProfileID: UsagePatch])` executing on the persistence component's serial executor: reads the LATEST snapshot, patches ONLY usage fields by UUID, encodes, writes — **never merges, caches, or writes credentials** (closes the stale-non-nil-credential overwrite race with concurrent Codex/Grok rotation + Claude sync writes; plain `saveProfiles` with a reconstructed array is forbidden for usage flushes). Credential mutations and usage patches get SEPARATE APIs with defined ordering.
- 2.2 **Replace the per-save reload's sync role explicitly.** `pendingUsageByProfileID` overlay reapplied after every `loadProfiles()`; repository emits credential-revision events so `ProfileManager` adopts provider-side rotations without full reloads. **Defined flush boundaries:** end of multi-profile sweep, end of single-profile refresh, sweep error/cancellation, before profile switch, app termination — not just the happy path.
- 2.3 In-memory usage updates stay immediate (auto-switch reads mid-sweep); only the disk write batches. Drop `.prettyPrinted` (`ProfileStore.swift:365`).
- 2.4 **Publish reduction via value-passing:** rows/subviews receive profile VALUES + callbacks instead of the global manager (~16 observer declarations today); publish one coherent update per applied patch-batch; store `activeProfileID` and derive `activeProfile` instead of independently republishing it.
- 2.5 **Credential-revision-keyed caches.** Per-profile credential revision owned by the repository; token-status/`providerKind` caches keyed by revision (recomputed atomically with the credential snapshot — never persisted independently; a stale `providerKind` would route a profile to the wrong provider). Invalidation event distinct from `.credentialsChanged` (which triggers network work today, `MenuBarManager.swift:602-633`). Single-parse `extractTokenExpiry`/`extractRefreshToken`; precompute row date strings.
- 2.6 De-duplicate `loadProfiles()` within one fetch (Codex 3×, Grok 3×, sync 2×) by passing snapshots down.
- Tests: concurrent rotation-vs-usage-flush race test (rotation lands between snapshot and flush ⇒ rotation survives); pin the nil-never-deletes invariant; flush-boundary tests (error/cancel/switch paths); publish-count ≤1 per batch; revision-cache invalidation.
- Accept: os_log ≤1 store write per sweep; 0 loads from row rendering; credential rotation during a sweep provably survives the flush.

### Phase 3 — Isolation & startup (R3-thread/R6) — *design revised per Codex findings 4/10*
- 3.1 **Dedicated persistence actor, not bare DispatchQueue hops.** UI state stays explicitly `@MainActor`; persistence + credential cache + ordering live in one actor (the serial executor Phase 2.1's atomic ops run on); immutable `Sendable` snapshots + typed patch commands across the boundary; only pure codec/file helpers become `nonisolated`. **Enable complete strict-concurrency checking for touched components; new warnings fail the phase.** (Existing `runOffMainActor` closures calling implicitly-main-actor services are precisely the unsoundness to eliminate, not replicate — `ProfileManager.swift:692`.)
- 3.2 **Async hydration with explicit tri-state readiness.** Replace the main-thread `sem.wait(2.0)` (`ProfileStore.swift:124`) with async hydration exposing `.loading / .ready / .failed` per profile — "not loaded" is NEVER represented as nil credentials (a not-yet-hydrated Codex/Grok profile must not classify as Claude). Gate sweeps, auto-switch, provider routing, and dead-login warnings on `.ready`. Batch/chunk the 70 `security` reads.
- Tests: readiness-gating (sweep against `.loading` profile is a no-op); hydration-completion convergence (final cache state byte-identical to synchronous path); nil-never-deletes under async hydration.
- Accept: cold launch with no main-thread stall (signpost-measured); no SecurityAgent prompts; no provider misroutes during hydration.

### Phase 4 — Sweep cadence & correctness (R7) — *scope corrected per Codex finding 6*
- 4.1 **Provider-aware monotonic rate limiter (token bucket) replacing index-based sleeps** (`MenuBarManager.swift:843-850`): Claude-bound requests keep today's effective per-account and per-IP pacing (2s spacing between CLAUDE calls, unchanged aggregate rate); Codex/Grok fetches no longer inherit Claude spacing (cuts ~6s/sweep) and cannot cause Claude calls to land back-to-back.
- 4.2 **Staleness SLO stays ~5 min** for background Claude profiles at 14 accounts (the 2.5-min target would require the 3-Claude-requests-per-sweep burst already associated with 429s). Make the budget N-aware and EXPLICIT: compute and log the achievable SLO from N and the request budget; surface it in the UI tooltip ("updated Xm ago") so staleness is visible instead of silent. Owner may later trade active-profile cadence for background freshness.
- 4.3 `status.claude.com` poll on its own 5-min cadence (`MenuBarManager.swift:835,1129`).
- 4.4 Restore `tolerance` on the timer-restart path (`MenuBarManager.swift:407`).
- Tests: token-bucket pacing under mixed provider order; budget math N ∈ {3,11,20} + saturation guard (sweep < interval); cadence tests.
- Accept: sweep wall-clock < 30s at N=14; no 429-rate regression over a 1h soak; per-tile "updated Xm ago" honest.

### Phase 5 — De-bloat (R8) — *hazards added per Codex findings 11/12/13*
- 5.1 Pure dead code (~875 lines, zero references, Codex-verified safe): `ConsoleAuthWebView.swift` (249); popover dead views `ProfileSwitcherBar`/`ClaudeStatusRow`/`SmartFooter` (213); `WindowCoordinator.swift` (183); `SettingsHeader.swift` (52) + `SettingsDesignSystem.swift` (62); `ClaudeAPIService.saveSessionKey` + `sendInitializationMessage` (~85); `StatusBarUIManager.updateButton(for:)` (~35). (Xcode 16 filesystem-synced groups ⇒ deletion needs no pbxproj surgery.)
- 5.2 API Console billing cluster (~1,716+): **two-step enum retirement** — first make `.api` a deprecated decode-tolerant case with a migration test against a fixture captured from the real `profiles_v3` blob; then remove rendering/UI. Cut inventory must ALSO cover the `.api` touchpoints in `Profile`, `ProfileManager`, `ProfileStore`, `MenuBarManager`, and the obsolete `apiSessionKey` Keychain read — not just the service + views.
- 5.3 claude.ai session-key cluster (~2,350 incl. tests): **`organizationId` is load-bearing for credential-contamination repair** (identity-adoption fallback for unstamped profiles, `ProfileManager.swift:798`) — preserve it (or migrate to an explicit identity field) when cutting the session-key UI/fetch path. Characterization tests required BEFORE deleting any related field: unstamped profiles, nil credentials, stale non-nil credentials, mid-switch adoption, cross-account rejection.
- 5.4 Structural trims: SetupWizard non-CLI steps (~474); `DataStore.swift` after extracting `loadMenuBarIconConfiguration` + `migrateFromLegacySettings` (~427); `URLBuilder`+tests (~423); design-system consolidation onto `DesignTokens` (~262); `ErrorLogger` → **no-storage forwarder** (the ring buffer itself is the runtime cost — removing only the query API leaves it) + `ErrorPresenter.showToast`/details (~200); wizard-only `MigrationService` members (KEEP `migrateLegacyBundleDefaultsIfNeeded` + `resetAppData` — startup migration ordering is load-bearing); `Constants` widget vestiges.
- 5.5 Owner-choice defaults: shortcuts KEEP; `LocalizationManager` KEEP; `ClaudeStatusService` KEEP (feeds SmartHeader; only cadence changes).
- Accept per PR: build + tests green; zero remaining references (grep); identical core behavior.

### Phase 6 (follow-up TODOs, not this refactor)
Grok settings UI parity; condensed tile mode (if Phase 0 shows window count is the hard ceiling, this becomes the strategic fix — owner decision); '2026' profile missing-credentials surfaced in UI instead of failing every rotation turn; debug entitlements alignment (drop `cs.allow-unsigned-executable-memory` from debug).

---

## 4. Verification protocol (every phase)
1. Build + full test suite green (worktree; DEVELOPER_DIR prefix). Baseline verified green pre-refactor.
2. Isolation: no new concurrency warnings beyond the known pre-existing set; strict checking on for touched persistence components (Phase 3+).
3. Runtime (0–4): ≥10 min with 14 accounts, display awake; `ps` %CPU, `sample` CA-flush share, os_log rates. Targets: idle CPU <3% (vs ~25%), ≤1 store write/sweep, 0 occlusion storm.
4. Credential-safety regression after Phases 2/3: profile switch + CLI resync round-trip; no Keychain deletions enqueued (os_log watch); concurrent-rotation race test green.
5. Final 1h soak: no 429 regression, auto-switch fires (threshold tweak test), tiles correct after forced ranking reshuffle, no dead-login false positives during hydration.

## 5. Risks & mitigations
- **Credential loss (highest severity):** Phases 2/3 touch the seams behind real silent-credential-loss incidents. Mitigations: atomic usage-patch API (never writes credentials), separate credential/usage command paths, race tests pinned BEFORE refactoring, Claude line-by-line review of every diff in these areas (Grok children never modify merge logic unsupervised).
- **Isolation regressions:** Swift 5 mode compiles unsound hops silently → dedicated actor + strict checking on touched components (Phase 3), not ad-hoc queue hops.
- **Renderer parity:** TIFF comparison stays until pixel-equivalence tests prove the render-key replacement.
- **Persisted-config decode breakage:** two-step `.api` retirement + real-blob fixture migration test.
- **Single-instance guard:** test/instrumented builds take over the lock (launch-date wins) — relaunch production copy after each measurement run; instrumented copy shares UserDefaults — restore state.
- **Identity-repair weakening:** `organizationId` preserved through the session-key cut; characterization tests first.

## 6. Open decisions for Fernando (defaults chosen; flag if wrong)
1. Cut claude.ai session-key support (5.3, keeping `organizationId`)? Default YES.
2. Cut API Console billing (5.2, two-step)? Default YES (0 profiles configured).
3. Keep keyboard shortcuts? Default KEEP.
4. Staleness: accept explicit ~5-min SLO for background Claude tiles with visible "updated Xm ago" (4.2)? Default YES.
5. If Phase 0 proves window count is the ceiling: condensed tile mode design pass? (Phase 1b/6 fork.)

## 7. Consult log
- **Codex (gpt-5.6-sol, reasoning=max), 2026-07-28: verdict REWORK.** 14 findings; all accepted and folded into v2: Phase 0 redesigned as a staged causality gate (popover/freeze/parked/harness) after finding the original experiment confounded; Phase 2 redesigned around an atomic `applyUsagePatches` repository op + pending-usage overlay + credential-revision events (stale-non-nil overwrite race; per-save reload's hidden sync role); Phase 3 upgraded from queue-hops to a persistence actor + tri-state hydration readiness + strict checking on touched components; Phase 4 staleness target corrected to respect the 429 budget (5-min SLO, provider token bucket); Phase 5 hardened (two-step `.api` enum retirement, `organizationId` preservation, ErrorLogger forwarder); settings race generalized to all three deferred manager setters; renderer cache keys made pixel-quantized + parity-gated; line-anchor/count corrections applied.
- Fable (this session): synthesized v1 from 3 research reports + live profiling; pre-Codex self-review caught selection-fetch gap, first-paint skip hazard, in-memory-immediacy requirement for auto-switch, shared-UserDefaults experiment hazard, toggle-ordering smell.
