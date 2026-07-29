# Deep diagnosis report — recurring UI hang + idle-CPU regrowth (2026-07-29)

**Session:** Fable sibling, deep-architecture diagnosis. **Branch:** `fix/statusitem-rebuild-storm` → draft PR #20.
**Verdict confidence:** sustain mechanism HIGH (live-sampled), accumulation HIGH (lab-quantified, reproduced twice independently), exact final ignition spark MEDIUM (two candidate sparks, both closed by the fix).

## TL;DR

The recurring 15–25% idle burn is **not** a leak in app objects, not the popover SwiftUI graph (that fix held), and not window count. It is a **two-layer failure**:

1. **Sustain: an AppKit↔WindowServer feedback loop on macOS 27 beta (26A5388g).** Sampled live on the burning production process (pid 15610): WindowServer `remote_context_notify` datagram → AppKit `_NSTrackingAreaAKManager` structural-region update (**synchronous** `mach_msg` back to the server) + `setTrackingAreasDirty` → display-cycle CA commit → next datagram — a closed loop at display cadence, independent of any app code. Signature: ~960/sec `[OcclusionDetection] Window 0x0 event shape became non empty` (batches of ~13–15 every ~8ms = the scene-window population × frame rate), and `NSNextStepFrame updateTrackingAreas → _updateEdgeResizingTrackingAreas → SLS*GetCurrentSpace` walks per frame. Once ignited it never exits; going quiet app-side does nothing. This is why every previous correct-looking fix "worked" (fresh launch = clean state) then "regressed" (state re-entered).

2. **Accumulation: every full status-item group rebuild permanently leaks ~42 registered CAContexts.** On macOS 26/27, each `NSStatusItem` is hosted as **3 FrontBoard scene windows** (42 windows for 14 tiles is *structural*, not a leak — Grok's null hypothesis, lab-confirmed). Teardown+recreate (`setupMultiProfile` → `cleanup()` → 14× `statusItem(withLength:)`) frees the windows/scenes but **leaks all 42 remote CAContexts + hosting tokens per cycle**:
   - Lab (Codex, isolated bundle): 1 tile = 4 contexts; 14 tiles = **43**; full repaint = flat; **5 forced rebuilds = 253 = 43 + 5×42** exactly.
   - Lab (this session, independent build + `CUW_LAB_REBUILD_SEC`): 211 → 253 across successive rebuilds, windows/scenes always returning to structural 42 (teardown is async but completes; contexts never do).
   - Production while burning: **172 ≈ 43 + 3×42** — exactly three leaked generations; count static between rebuilds (heap-diffed over 30+ min).

   The WindowServer's notify path (`remote_context_notify → CFArrayApplyFunction`) iterates **every registered context** per datagram — leaked generations are a standing per-frame tax and the precondition for the loop.

**Causal story:** rebuilds happened routinely — (a) **reliably once per launch**: profiles paint before Keychain hydration, so Codex/Grok profiles briefly classify `.claude`; hydration regroups them → creation order changes → full rebuild (Codex's find; fits "clean at launch, burning by minute ~15" on *every* run); (b) weekly-reset ranking jitter; (c) stranded-tile heals. Each rebuild banks a generation. With generations banked, an interaction spark — production ignited *during* a burst of rapid cross-tile popover re-anchoring (three tiles within 6s at 11:30, same-turn `performClose`+re-show) — tips AppKit into the non-converging tracking-region loop. Population is the amplifier; **non-convergence is the disease** (Grok's framing, adopted).

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
3. **Popover destroyed on close, created lazily per open** (`MenuBarManager`): no more permanent offscreen borderless `_NSPopoverWindow` in the per-frame tracking pass; profile switches no longer build SwiftUI hosting graphs for a closed popover. Cross-tile re-anchor now closes, then shows a **fresh** popover on the **next runloop turn** (the same-turn re-anchor across scene-hosted buttons was the strongest interaction-spark candidate).
4. **`setup()` idempotency**: re-entry (headless screen recovery, AppDelegate retry) tears down prior state first — previously it would orphan an entire scene generation and double-register every observer/timer.
5. **StormWatchdog** (new, guardrail): every 2 min, process-CPU sample; ≥12% of a core ×3 consecutive samples while popover/settings/detached are all closed → loud `logError` + one user notification per launch. The failure class regressed invisibly for days, twice; now it self-reports in ~6 minutes.
6. **Lab knobs** for this bug class (`CUW_LAB_REBUILD_SEC`, `CUW_LAB_POPOVER_CYCLE`, `CUW_LAB_POPOVER_STRESS`, `CUW_LAB_ACTIVATE`, `CUW_LAB_RESHUFFLE`) — inert without `CUW_LAB=1`.

**Validation:** build green; full unit suite green; remap-validation lab (fixed build, `CUW_LAB_RESHUFFLE=1`, ranking flip every minute): each flip logs `Multi-profile: ranking reshuffled — remapped 14 tiles in place (no rebuild)` (debug level — visible via `log stream`, NOT `log show`), CAContext/CAHostingToken **flat at exactly the 43-context baseline** across every rotation — the same flips that previously leaked 42 contexts each — CPU 0.0% throughout, scene windows stable at the structural 42.

## What the owner should do

1. **Review PR #20** and install its build (`/tmp/cuw_fix_build/Build/Products/Release/Claude Usage.app` → `/Applications`). The currently installed build **will re-ignite** after its next rebuild+interaction; a relaunch clears an active storm but does not prevent the next one.
2. Hand-validate: Manage Profiles scroll feel; popover open/close/switch-tiles/detach; tile order after a ranking change (order updates ~30s after fresh usage, without the group flicker rebuilds used to cause).
3. If the watchdog notification ever fires again: capture `sample "$(pgrep -x 'Claude Usage')" 5` + the occlusion rate before relaunching, and check CAContext count (`heap <pid> | grep 'CAContext '`) — flat-at-baseline vs grown distinguishes a NEW ignition path from a rebuild regression.

## Deliberately not changed (owner's call, flagged)

- **Setup wizard activation-policy flips** (`AppDelegate` ~:203) — a known scene re-registration hazard (Codex), but wizard UX untestable headlessly; only runs on first-run/reset.
- **`.percentage` style variable-width images** — digit-width changes reshape tracking regions per repaint (Codex). Production uses `progressBar` (fixed canvas), so not in today's path.
- **Composite single-item rendering** (all accounts in 1–3 status items, 42 scenes → ≤9): the robust fallback if the OS beta ever ignites even with a stable pool. Larger UX/a11y change; not needed on current evidence.
- OS-level: this is an AppKit/WindowServer beta pathology; a Feedback with `sample1.txt` + the census tables would be a strong report to Apple.

## Consult log (Reasoning Consult protocol)

- **Codex (gpt-5.6-sol, xhigh, ~35 min, own lab experiments):** two-layer verdict (OS-bug sustain + rebuild-driven CAContext retention); quantified 42/rebuild; identified post-hydration regroup as the reliable delayed rebuild; recommended stable-pool invariant + popover re-anchor deferral + `setup()` idempotency; verification contract adopted into PR checklist. **Adopted nearly wholesale.**
- **Grok (grok-4.5, high, advisory):** agreed sustain mechanism; correctly rejected "3 leaked generations of windows" (42 = 14×3 structural — confirmed by lab); pushed time-marker/`variableLength` mutation surface and "state-not-count" framing; recommended remove-parked-items and marker decoupling (not adopted — repaint-only labs showed no ignition; kept as fallbacks). **Dissent materially improved the verdict.**
- **Fable subagents:** leak-hunter (live forensics — captured `prod_default.log`, the production default-level history that pinned the ignition window; ran independent lab instances), architecture-critic (invariants/guardrail lens → StormWatchdog). Three Opus research sweeps (statusbar lifecycle, window machinery, post-refactor regression) were dispatched in parallel; their reports had not landed when the PR was cut — anything material they add will be appended to the PR as comments.
- **Synthesis & verdict:** this session. Disagreements resolved by experiment (lab reproductions), not vote count.

## Corrections to prior beliefs (docs/plans/PLAN-LATENCY-REFACTOR.md §8)

- "Idle 0% verified" was real but measured a *clean state*; the regrowth was a different bug (this one), not a regression of the popover/publish fixes.
- The "four 1728×33 layer-0 strips" from the earlier census and the 685×30 layer-1000 window are app-side artifacts of scene hosting/activation; window *population* is structural — the earlier plan's R1 "window count" framing is fully retired.
- `NSStatusItem` app-object hygiene (balanced observers, single popover, clean dictionaries) was never the problem — the leak lives in the OS's remote-context registry, reachable only through teardown/recreate.
