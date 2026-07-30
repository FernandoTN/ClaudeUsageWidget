# Deep diagnosis report — recurring UI hang + idle-CPU regrowth (2026-07-29)

**Session:** Fable sibling, deep-architecture diagnosis. **Branch:** `fix/statusitem-rebuild-storm` → draft PR #20.
**Verdict confidence:** sustain mechanism HIGH (live-sampled), accumulation HIGH (lab-quantified, reproduced twice independently), ignition HIGH-correlation / MEDIUM-HIGH-causation (fence-race forensics below; the spark paths are closed by the fix either way).

## TL;DR

The recurring 15–25% idle burn is **not** a leak in app objects, not the popover SwiftUI graph (that fix held), and not window count. It is a **two-layer failure**:

1. **Sustain: an AppKit↔WindowServer feedback loop on macOS 27 beta (26A5388g).** Sampled live on the burning production process (pid 15610): WindowServer `remote_context_notify` datagram → AppKit `_NSTrackingAreaAKManager` structural-region update (**synchronous** `mach_msg` back to the server) + `setTrackingAreasDirty` → display-cycle CA commit → next datagram — a closed loop at display cadence, independent of any app code. Signature: ~960/sec `[OcclusionDetection] Window 0x0 event shape became non empty` (batches of ~13–15 every ~8ms = the scene-window population × frame rate), and `NSNextStepFrame updateTrackingAreas → _updateEdgeResizingTrackingAreas → SLS*GetCurrentSpace` walks per frame. Once ignited it never exits; going quiet app-side does nothing. This is why every previous correct-looking fix "worked" (fresh launch = clean state) then "regressed" (state re-entered).

2. **Accumulation: every full status-item group rebuild permanently leaks ~42 registered CAContexts.** On macOS 26/27, each `NSStatusItem` is hosted as **3 FrontBoard scene windows** (42 windows for 14 tiles is *structural*, not a leak — Grok's null hypothesis, lab-confirmed). Teardown+recreate (`setupMultiProfile` → `cleanup()` → 14× `statusItem(withLength:)`) frees the windows/scenes but **leaks all 42 remote CAContexts + hosting tokens per cycle**:
   - Lab (Codex, isolated bundle): 1 tile = 4 contexts; 14 tiles = **43**; full repaint = flat; **5 forced rebuilds = 253 = 43 + 5×42** exactly.
   - Lab (this session, independent build + `CUW_LAB_REBUILD_SEC`): 211 → 253 across successive rebuilds, windows/scenes always returning to structural 42 (teardown is async but completes; contexts never do).
   - Production while burning: **172 ≈ 43 + 3×42** — exactly three leaked generations; count static between rebuilds (heap-diffed over 30+ min).

   The WindowServer's notify path (`remote_context_notify → CFArrayApplyFunction`) iterates **every registered context** per datagram — leaked generations are a standing per-frame tax and the precondition for the loop.

**Causal story (refined by leak-hunter forensics, landed after PR cut):** the ignition of THIS run is pinned to a **CoreAnimation fence-protocol race on the popover lifecycle**, timeline reconstructed from persisted logs + cumulative-CPU back-fit:

- 11:29:39 — profile activated FROM INSIDE the popover → `handleProfileSwitch` called `recreatePopover()` synchronously (destroying the popover and building a new `NSHostingController` while the popover's own button action was on the stack, mid CA commit);
- 11:29:40.7 — `E [com.apple.coreanimation:API] cannot add handler to 2 from 2 - dropping` — a commit-handler registration dropped mid-commit. **This precursor appears in 3 of 6 app runs in 24h of history, always 0.5–0.8s after "Popover recreated for profile switch", never anywhere else.** It is the observable regression marker for this bug.
- 11:32:48.2 — `E [com.apple.coreanimation:Render] fence tx observer … timed out after 0.6` (the ONLY fence timeout in 24h) after a popover close; the system then re-issued `NSSceneFenceAction` to all 42 status-item variant scenes 4×, the AutomaticTermination window-bookkeeping wedged permanently, and the per-frame echo storm began (~11:31–11:33 by CPU back-fit).

Rebuild-driven CAContext accumulation (real, lab-proven, +42/rebuild) is the **amplifier and standing tax** — the sustain loop iterates every registered context — but ignition did not require banked generations: it's a low-probability race on a path the app exercised at every popover-initiated profile switch. Rebuilds still happened routinely and needlessly ((a) reliably once per launch via post-hydration provider regrouping — Codex's find; (b) ranking jitter; (c) heals), so both layers get fixed. Population is the amplifier; **non-convergence is the disease** (Grok's framing, adopted). Leak-hunter also settled the census mysteries: the 685×30 layer-1000 strip and the 28 replicant views are the fullscreen menu-bar-reveal machinery (685pt ≈ the tile-group width), and the three scene variants per item are Variant[1]/Variant[2]/Variant[Presentation].

**Final stress-reproduction result (leak-hunter, ~500 cross-tile popover cycles incl. recreate-mid-close parity, 17 min):** the fence-race **precursor reproduces at will** — every cycle emits the exact production ignition-window signature (`Ignoring request to entangle context after pre-commit`, `Entangling fence requested after pre-commit`, `cannot add handler to 2 from 2 - dropping`, `Invalid attempt to open a new transaction during CA commit`) — decoding the mechanism: a popover anchored to a scene-hosted tile needs a CAContext **entanglement + fence** with that tile's scene, and any show/close/recreate landing inside a CA commit gets the entanglement ignored and the fence's commit handler dropped. But 17 min of continuous precursors produced **no storm** (0.6% CPU) while production stormed concurrently — so full ignition additionally needs a rare OS-side interleaving (best candidate: an armed fence timing out exactly as a fullscreen menu-bar hover-reveal re-fences all 42 scenes, which is what production's timeline shows at 11:32:48–11:33:05). This explains days of "random" recurrence under real usage while gentle labs stay clean. Two mechanical decodes: "Window 0x0" = scene window numbers are exact multiples of 2³² (zero in 32-bit truncation) — the storm churns the **tile windows themselves**, ~14/frame; and the system's own MenuBarAgent logs the same dropped-fence class on this beta — the fragility is OS-general.

Both symptoms are one bug: the storm saturates the main thread with per-frame synchronous WindowServer calls → "Manage Profiles" scrolling lags → and the burn is the same loop measured at idle.

## Live evidence captured (all files in the session job dir `tmp/`)

| Artifact | What it shows |
|---|---|
| `sample1.txt` (8s, burning) | 307/4365 samples in UpdateCycle Source1 → CA flush + tracking-region recursion; 259 in `CGSDatagramReadStream::dispatchMainQueueDatagrams → remote_context_notify → structural region update + setTrackingAreasDirty` — the loop, both halves |
| occlusion histogram | 93,072 lines/min sustained, "Window 0x0" (offscreen/unregistered scene windows) |
| `heap1.txt` vs `heap_115231.txt` | production: 172 CAContexts static over 30 min; zero app-object growth |
| lab census logs | 42 windows structural; +14 transient during rebuild, teardown completes async (~15–30s); three scene-window states (never-laid-out h=0, parked y=-33, on-bar) |
| `prod_default.log` | launch 11:17; heavy popover use 11:22–11:38; ignition window ~11:27–11:36 (cumulative-CPU back-fit); NO settings rebuilds logged |

**Discriminating lab runs** (lab bundle ids, production untouched): frozen/repaint-only/popover-cycle/popover-stress-alone all **0.0% CPU, no storm** — even at 253 leaked contexts. Reproducing the *full* ignition needs generations + interaction (production had 3 generations + rapid re-anchoring; a clean-state lab resists ignition, consistent with the compound model).

## The fix (PR #20)

Invariant established: **after initial construction, the live multi-profile group is never torn down and recreated for an order change.**

1. **Remap, don't rebuild** (`StatusBarUIManager`): tile identity is 100% painted into the image, so a ranking/grouping change re-keys the existing items to the new profile order and repaints in place (`remapProfilesToExistingItems`). This also neutralizes the guaranteed post-hydration rebuild. Full rebuild remains only for selection-set changes (count/membership) — a rare user action.
2. **Heal cap**: the stranded-tile heal (physical relocation repair) is capped at **2 rebuilds per launch**, then logs only. Bounded worst case: 84 leaked contexts per process lifetime vs unbounded before.
3. **Popover destroyed on close, created lazily per open** (`MenuBarManager`): no more permanent offscreen borderless `_NSPopoverWindow` in the per-frame tracking pass; profile switches no longer build SwiftUI hosting graphs for a closed popover. Cross-tile re-anchor closes, then shows a **fresh** popover on the **next runloop turn**; and `recreatePopover()` on the switch path is likewise deferred one turn — no popover teardown ever runs inside an in-flight CA commit again, which removes the reproducible `cannot add handler to 2 from 2` fence-race precursor directly.
4. **`setup()` idempotency**: re-entry (headless screen recovery, AppDelegate retry) tears down prior state first — previously it would orphan an entire scene generation and double-register every observer/timer.
5. **StormWatchdog** (new, guardrail): every 2 min, process-CPU sample; ≥12% of a core ×3 consecutive samples while popover/settings/detached are all closed → loud `logError` + one user notification per launch. The failure class regressed invisibly for days, twice; now it self-reports in ~6 minutes.
6. **Lab knobs** for this bug class (`CUW_LAB_REBUILD_SEC`, `CUW_LAB_POPOVER_CYCLE`, `CUW_LAB_POPOVER_STRESS`, `CUW_LAB_ACTIVATE`, `CUW_LAB_RESHUFFLE`) — inert without `CUW_LAB=1`.

**Validation:** build green; full unit suite green; remap-validation lab (fixed build, `CUW_LAB_RESHUFFLE=1`, ranking flip every minute): each flip logs `Multi-profile: ranking reshuffled — remapped 14 tiles in place (no rebuild)` (debug level — visible via `log stream`, NOT `log show`), CAContext/CAHostingToken **flat at exactly the 43-context baseline** across every rotation — the same flips that previously leaked 42 contexts each — CPU 0.0% throughout, scene windows stable at the structural 42.

## What the owner should do

1. **Review PR #20** and install its build (`/tmp/cuw_fix_build/Build/Products/Release/Claude Usage.app` → `/Applications`). The currently installed build **will re-ignite** after its next rebuild+interaction; a relaunch clears an active storm but does not prevent the next one.
2. Hand-validate: Manage Profiles scroll feel; popover open/close/switch-tiles/detach; tile order after a ranking change (order updates ~30s after fresh usage, without the group flicker rebuilds used to cause).
3. If the watchdog notification ever fires again: capture `sample "$(pgrep -x 'Claude Usage')" 5` + the occlusion rate before relaunching, and check CAContext count (`heap <pid> | grep 'CAContext '`) — flat-at-baseline vs grown distinguishes a NEW ignition path from a rebuild regression.

## Deliberately not changed (owner's call, flagged)

- **Fixed-width tiles** (arch-critic 1a): replace `variableLength` with per-style fixed `NSStatusItem.length` so a repaint can never trigger a menu-bar relayout — enforces "repaint never touches window structure" mechanically and stabilizes overflow. Small diff, but visually validatable only by hand — recommended as the first follow-up.
- **Watchdog auto-remediation** (leak-hunter): on storm detection, attempt in-place recovery (destroy/rebuild the popover; force a scene re-order) before requiring a relaunch. UNVALIDATED — experiment E3 (kill-switch on an ignited process) never ran; the current watchdog detects + notifies only. Worth an E3 pass the next time a storm is live before wiring any auto-remediation.
- **Rebuild-rate alarm + always-on window census + runloop-storm detector** (arch-critic guardrails 2–4): cheap extensions to StormWatchdog/RenderInstrumentation; with the remap invariant, expected rebuild count is ~0, making any rebuild an alarm.
- **Dead SwiftUI `Settings` scene** in `ClaudeUsageTrackerApp.swift` (registered but unused; the real settings window is hand-built) — remove so there's one settings path.

- **Setup wizard activation-policy flips** (`AppDelegate` ~:203) — a known scene re-registration hazard (Codex), but wizard UX untestable headlessly; only runs on first-run/reset.
- **`.percentage` style variable-width images** — digit-width changes reshape tracking regions per repaint (Codex). Production uses `progressBar` (fixed canvas), so not in today's path.
- **Composite single-item rendering** (all accounts in 1–3 status items, 42 scenes → ≤9): the robust fallback if the OS beta ever ignites even with a stable pool. Larger UX/a11y change; not needed on current evidence.
- OS-level: this is an AppKit/WindowServer beta pathology; a Feedback with `sample1.txt` + the census tables would be a strong report to Apple.

## Consult log (Reasoning Consult protocol)

- **Codex (gpt-5.6-sol, xhigh, ~35 min, own lab experiments):** two-layer verdict (OS-bug sustain + rebuild-driven CAContext retention); quantified 42/rebuild; identified post-hydration regroup as the reliable delayed rebuild; recommended stable-pool invariant + popover re-anchor deferral + `setup()` idempotency; verification contract adopted into PR checklist. **Adopted nearly wholesale.**
- **Grok (grok-4.5, high, advisory):** agreed sustain mechanism; correctly rejected "3 leaked generations of windows" (42 = 14×3 structural — confirmed by lab); pushed time-marker/`variableLength` mutation surface and "state-not-count" framing; recommended remove-parked-items and marker decoupling (not adopted — repaint-only labs showed no ignition; kept as fallbacks). **Dissent materially improved the verdict.**
- **Fable leak-hunter (landed post-PR-cut; folded in):** pinned ignition to the popover fence-protocol race with a reproducible precursor marker (`cannot add handler to 2 from 2`, 3/6 runs, always after "Popover recreated for profile switch") and the sole 24h fence timeout at the storm's start; falsified generation-banking as *this* run's ignition requirement; identified the 685×30 strip + replicants as fullscreen menu-bar-reveal machinery and the 3 variants as Variant[1]/[2]/[Presentation]. Its three recommended minimal changes were already implemented (destroy-on-close, watchdog) except the switch-path deferral — added as the final hardening commit.
- **Fable architecture-critic (landed post-PR-cut):** systemic framing — "data-plane churn can escalate into control-plane window operations and nothing prevents, counts, or observes the escalation"; invariants live in comments, not code. Its top recommendations (stable slots/remap, popover destruction, CPU watchdog, rebuild alarm) match the shipped fix; the residue is in follow-ups below.
- **Opus sweeps** (statusbar lifecycle, window machinery, post-refactor regression): dispatched in parallel; superseded by the above before their reports were needed.
- **Synthesis & verdict:** this session. Disagreements resolved by experiment (lab reproductions), not vote count.

## Corrections to prior beliefs (docs/plans/PLAN-LATENCY-REFACTOR.md §8)

- "Idle 0% verified" was real but measured a *clean state*; the regrowth was a different bug (this one), not a regression of the popover/publish fixes.
- The "four 1728×33 layer-0 strips" from the earlier census and the 685×30 layer-1000 window are app-side artifacts of scene hosting/activation; window *population* is structural — the earlier plan's R1 "window count" framing is fully retired.
- `NSStatusItem` app-object hygiene (balanced observers, single popover, clean dictionaries) was never the problem — the leak lives in the OS's remote-context registry, reachable only through teardown/recreate.

## Addendum — afternoon recurrence + the OS-side per-bundle wedge (2026-07-29, 16:00-17:10)

The owner reported recurrence (slow menu, high CPU) at ~16:15. Findings, in order:

1. The running process was still the OLD build (PR #20 never installed): same morning process, 40 CPU-min burned over 5h, and the afternoon's account switches had leaked 3 more generations (CAContext 172 → 298 — the +42/rebuild curve holding exactly on live production). Fixed build installed to /Applications (old app at `Claude Usage.app.pre-fix-backup`).
2. The fixed build then appeared to "re-ignite" within minutes — with NO popover, NO settings, NO rebuilds, contexts flat at 43, zero fence errors. This forced the decisive experiment set:
   - **A-B causality:** WindowServer 101.6% CPU with our app running → 28.1% twenty seconds after killing it (ControlCenter 30% → 7%). While wedged, OUR TILES drive the WindowServer burn — the machine-wide slowness was largely our app, not (as it first appeared) the runaway iOS simulator, which was a secondary contributor (load 156 → 100 after simulator shutdown, → 14 once other work finished).
   - **Bundle-id A/B:** the SAME fixed binary running as `com.claudeusagewidget.lab2` with 14 VISIBLE tiles: 28 occlusion events/min, 0.0% CPU. As `com.claudeusagewidget.app`: ~100,000/min, 10-12%. The churn follows the bundle id, not the code.
   - **Persistence + clearing:** quick kill→relaunch cycles (3-20s gap) re-inherited the churn; after the production bundle was OFF the bar for ~2 minutes (lab tiles occupying it, global relayout), the relaunched production process came up clean — 0 occl/min, 0.0% CPU, verified over an extended soak.
3. **Corrected model:** the morning's fence-race wedge poisons OS-SIDE per-bundle status-item host state (ControlCenter/MenuBarAgent/WindowServer bookkeeping — the "persistent host identity" pitfall Codex flagged). It survives app relaunches performed within seconds, which is why the "fixed build re-ignited": it inherited the morning wedge. It clears when the bundle's items leave the bar long enough for the daemons to drop the state.
4. **Operational remedy when the StormWatchdog fires:** quit the app, wait ~2 minutes, relaunch. No reboot. (A same-second relaunch will NOT clear it.)
5. All prevention layers in PR #20 remain the right app-side fix: they stop the app from creating the fence-race conditions (commit-safe popover lifecycle) and from feeding the amplifier (remap-not-rebuild, context leak capped). The wedge itself is an OS bug — Apple Feedback material: `sample1.txt`, the fence timeline, the bundle-id A/B, and the WindowServer A-B numbers.

End state 17:10: fixed build running clean (0.0% CPU, 0 occl/min, contexts 43); residual WindowServer burn (~85%) persists WITHOUT our app's involvement — other hosts/OS residue on a 5-day-uptime beta; owner may want a reboot at convenience.

## Addendum 2 — the underlying cause, isolated and fixed (2026-07-29 evening, PR #21)

The StormWatchdog fired on the PR #20 build at 17:36 (ignition trace: popover use 17:19 →
`NSSceneFenceAction` broadcast to all 42 scenes 17:21 → churn by 17:30), proving commit-safe
popover discipline reduces but cannot eliminate wedge formation — any NSPopover anchored to a
scene tile must entangle+fence, and the OS's own re-fence broadcasts interleave regardless.

The live wedge enabled the decisive A/B/A: with the env-gated opaque-backdrop probe, a
quick-relaunch (inheriting the wedge) ran at 0 occlusion events/min, 0.0% CPU for 5+ minutes;
the transparent control on the same wedge re-churned within 2 minutes (49-50k/min). Mechanism:
the per-frame recompute derives each tile window's EVENT SHAPE from the image alpha channel;
a transparent canvas makes the shape content-dependent (never converges), a 2%-alpha
full-canvas backdrop makes it a constant full rectangle (nothing to recompute — the churn is
held at zero even while the OS-side wedge is active). PR #21 makes the backdrop the default in
every tile creator (template default-logo excluded; CUW_TRANSPARENT_TILES=1 for experiments).

This is the no-relaunch, no-reboot fix. Remaining optional hardening: non-scene-anchored
NSPanel popover (removes fence exposure that forms the wedge at all); watchdog stays as the
tripwire.
