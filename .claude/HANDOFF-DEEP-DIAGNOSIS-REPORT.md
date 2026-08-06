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

## Addendum 3 — trigger identified; opaque-backdrop claim RETRACTED; self-healing shipped (2026-07-29, 18:10)

Retro-correlating every churn/quiet epoch of the day against `NSSceneFenceAction` timestamps:
churn begins when a fullscreen menu-bar-reveal fence burst (broadcast to all 42 variant
scenes; fired by mousing to the top edge in a fullscreen space) lands on a live process, and
runs without such bursts stay clean indefinitely. The addendum-2 "opaque event shape fixes
it" A/B/A was burst-timing coincidence (control run caught a burst at 17:45:16, probe run
didn't; the "failing" opaque run caught one at 17:52:55) — claim retracted; the backdrop is
retained as zero-cost defense-in-depth only.

Because the trigger is OS-side and user-activity-driven, PR #21's deliverable is now the
SELF-HEALING watchdog: sustained idle burn → stage 0 (render-cache clear + repaint) → one
2-min verification sample → stage 1 (`cycleTileVisibility()`: isVisible off→on across a
runloop turn for every tile, forcing scene re-establishment) → verification → user
notification only if both stages fail. Manual live-storm trigger for validating the stages:
`distnoted post com.claudeusagewidget.remediate`. Merged PR #20's remap fix keeps the churn
4-10× cheaper when it does occur (contexts pinned at structural 43 vs 172-673 before).

Open validation: the remediation stages have not yet met a live storm — the next fence-burst
ignition is the test (watchdog handles it automatically; logs record stage outcomes).
Escalation path if stage 1 fails: composite tiles (14 items → 1-3 windows).

## Addendum 4 — settings freeze investigation + consolidated fix package (2026-07-29 evening, PR #21)

Owner reported: after an auto account-switch, settings opens got slower, third open froze
(scrollbar thumb shrank, black flash), CPU exploded. Theory fleet: Codex (gpt-5.6-sol xhigh,
5 ranked theories), fable settings-lens, opus lifecycle sweep (empirical AppKit probes) —
full consensus:

1. The storm (8-11%) was ACTIVE throughout — the dominant slowdown. StormWatchdog was silent
   for two arithmetically certain reasons: 12% threshold > storm cost, and the idle gate saw
   settingsWindow != nil the whole time because **the settings window was never closed — it
   was open on screen** (the "three opens" re-foregrounded one window).
2. The switch's ~8-10 publishes re-render the settings sidebar + active tab per publish —
   the amplifier that made settings feel frozen under the storm. Scrollbar shrink = delayed
   completion of the eager 3×14-row layout under starvation, NOT content growth (heap flat).
3. Latent defects found and fixed: close-teardown was an empirical NO-OP (hosting view
   installed as subview; contentViewController was never set); minimize orphaned windows
   (isVisible false + no delegate callback → second window created, first immortal);
   150ms double-open race; Cmd-, SwiftUI Settings scene = second untracked graph.
4. Owner-reported same-tile popover close-and-reopen: real bug (anchor nil'd before animated
   didClose recorded it) — every dismiss ran a full extra popover lifecycle (doubled fence
   exposure). Fixed.
5. E3 completed against the live storm: stage-0 repaint and a clean single-shot stage-1
   visibility cycle both FAILED to clear it (CPU-stack verdict; the occlusion log alone is
   decoupled and must not be used as the success metric — Codex). In-place remediation is
   falsified; the ladder now exists for cheap first attempts + calibrated notification.

Shipped (commits 55aa083 + f4d1567; full suite green after a scripted-edit regression was
caught by the clean test build and repaired): watchdog threshold 6%, window-population idle
gate, pause-not-reset hot streak, ladder re-arm, debounced manual trigger; settings
contentViewController install, reuse-any-existing-window, double-open guard, empty Settings
scene, dead code removed; popover same-tile dismiss.

OPEN DECISION (owner): composite tiles (14 status items → 3 provider-group items) — the only
structural reduction of the wedged-state cost (~9% → ~0.7%) since prevention and remediation
are both impossible. UX trade-off: overflow clips a whole provider group at once. Scoped,
not built.

## Addendum 5 — composite provider-group tiles shipped (2026-07-29, ~20:50)

Owner approved the structural fix. One status item per provider group (Claude/Grok/Codex),
tiles rendered side-by-side in a fixed-length composite image; clicks resolve by x-offset,
popover anchors to the clicked tile's segment, same-tile dismiss keyed by (button, profile).
Ranking = paint order; membership changes = composite resize; items recreated only when a
provider group appears/disappears. Legacy mode: CUW_SEPARATE_TILES=1.
Lab-verified (14 profiles + reshuffle probe): 9 scene windows / 3 buttons / 10 contexts,
stable. Production after install (wedge-gap relaunch): 9 scenes / 3 buttons / 15 contexts,
0.0% CPU, 0 occlusion. Projected wedged-state cost ~2% (vs 9-11% with 14 tiles, vs 15-25%
pre-remap). Suite green. Owner hand-validation list: composite look/spacing, per-tile click
routing + popover anchor, same-tile dismiss, group-level overflow clipping.

## Addendum 6 — composite tiles verified, fixed and hardened (2026-07-29 ~21:30, PR #21)

Ultracode sibling pass over addendum 5's composite work: a 12-agent verification
workflow (6 dimensions — ordering, click/segment math, paint pipeline, lifecycle,
auto-switch integration, efficiency — each followed by an adversarial refute agent),
plus the two council consults the dispatcher had started (Codex gpt-5.6-sol xhigh:
**NEEDS-FIXES**, 6 findings; Grok advisory: 6 findings). 22 findings survived
refutation; the duplicates across sources collapse to the list below. Both council
voices and the workflow's ordering agent independently found the same BLOCKER.

**Verdict on addendum 5 as shipped: correct in structure, wrong in three
user-visible details, and quietly more expensive per sweep than the tiles it
replaced.** All fixed in commit `3935429`.

### Correctness
1. **BLOCKER — within-group order was inverted.** `multiProfileCreationOrder` ranks
   soonest-weekly-reset FIRST because legacy status items are created right-to-left
   (first created = rightmost); a composite image draws left-to-right, so the same
   array painted in order put the soonest-reset account at the LEFT edge. Every
   provider group read backwards versus the build the owner had been using, and the
   bar's rightmost Claude tile became the account with the MOST runway — the
   opposite of the "burn the rightmost first" signal the owner steers by. Addendum
   5's "ranking = paint order" claim was the error: rank order and paint order are
   mirror images. Fixed by one named pure function (`compositePaintOrder`) that the
   popover navigator also consumes, with 17 unit tests
   (`CompositeTileLayoutTests`) pinning orientation and segment geometry. The
   pre-existing ordering tests could not have caught it — the rank array is
   identical either way.
2. **Keyboard-shortcut popover showed the wrong account.** With `sender == nil`,
   `togglePopover` looked up the focused profile's button and then threw that
   knowledge away, resolving the profile by tile POSITION (group's last segment).
   The intended profile is now passed through explicitly.
3. **Click routing assumed button space == image space.** An `NSButton` scales its
   image proportionally DOWN to fit its bounds and centres the result, so a
   composite taller than the bar's content height is drawn NARROWER than the
   composite width and every segment boundary shifts. `imageScaling` is pinned at
   creation and clicks/anchors map through the actual drawn rect
   (`compositeDrawnRect`).
4. **The composite lost the event-shape backdrop.** Tiles carry the 2%-alpha
   full-rect backdrop across their own rect only, so the 3pt gaps, 1pt pads and
   vertical centring bands were transparent — the group window's alpha-derived
   event shape became a comb of N rectangles, re-opening the surface addendum 2's
   backdrop closes. (Kept as defence-in-depth; addendum 3's retraction stands.)
5. **Monochrome mode stopped being tinted** — template tiles were composited into a
   non-template image. **`lockFocus` used the MAIN screen's scale**; the composite
   is now drawn into an explicit `NSBitmapImageRep` at the scale of the display the
   bar is on, with that scale in the re-assembly key. **Fractional tile widths**
   (`.percentage` sizes to text metrics) put later tiles on half-pixels; advances
   are whole points now.
6. **The empty-profiles placeholder was blank** in BOTH multi-profile modes (the
   logo path in `updateAllButtons` only covers single-profile `statusItems`) — the
   app looked like it had left the bar. **Stale segments** of an emptied group could
   route a click to a deselected/deleted profile; they are cleared.
7. **StormWatchdog had gone silent again.** Composites cut the wedged-state cost to
   ~2%, i.e. back UNDER the 6% threshold set for 14-tile storms. Now 1.5% — above
   the measured 0.0% idle baseline, below the projected composite storm cost.
8. **Lab probes repaired**: popover-stress anchored to the whole group button and
   so no longer reproduced tile-to-tile re-anchoring (it anchors per segment
   again); the rebuild probe now forces a real teardown so it still measures one.

### Efficiency (the composite path was doing MORE work per sweep than 14 tiles)
`assembleComposites` ran unconditionally once per sweep: one NSImage + lockFocus
bitmap + N tile draws + a full-strip `tiffRepresentation` and Data compare, per
group, every 30s, even with nothing changed. It is now memoized on (members,
per-tile render sequence, template flag, backing scale) — an idle sweep does no
drawing at all. A profile-selection toggle no longer recreates every group item
(`canReuseCompositeGroups`): composite mode absorbs membership changes as a
repaint. Items are still recreated when the provider SET changes, deliberately —
creation order is the only handle on left-to-right group placement, so a re-added
Grok item created last would land at the wrong end of the bar. Per-tile images,
render keys and sequences are pruned when a profile stops being displayed.

### Owner-requested affordance (new)
A whole provider group now lives in ONE status item, so selecting an account by
clicking its ~20pt segment is fiddly and nothing showed WHICH account of a group
is active. The popover gained a **group navigator**: ‹ › buttons, left/right arrow
keys, and one chip per group member ordered exactly as the tiles are painted. The
active account's chip carries the same cyan its tile label uses; the viewed one is
filled. Selecting a chip changes only the published selection — it never re-anchors
or re-shows the popover, which would add a scene fence/entanglement cycle per
navigation. "Active" is now ONE definition (`ProfileManager.activeAccountIds`)
shared by the tile painter and the popover (a Grok account could previously draw a
cyan tile while the popover called it inactive). An open popover's numbers were a
snapshot frozen at click time; the viewed account's usage is re-read after each
sweep, only while something is displaying it.

### Validation
- Release build green; full suite green — **148 tests, 17 new**.
- Lab (14 synthetic profiles, `CUW_LAB=1 CUW_LAB_TILES=14 CUW_LAB_FREEZE=1`):
  **9 scene windows, 3 group items, 0.0% CPU, 89 MB RSS, 14 tile renders → 3 image
  assignments** (one per group).
- Within-group order confirmed **visually** on a live 2-member Codex group in the
  fixed build (`Cd2` left, `Cd1` right, where `Cd1` resets sooner) — screenshot in
  the session job dir. A larger group could not be photographed: with production's
  ~15 accounts already on the bar, a second instance's wide Claude group is
  overflow-hidden behind the system chevron.
- Production (pid 68958, the addendum-5 build) was left running and untouched;
  read-only probes only. Group-level order there is correct (left→right Codex,
  Grok, Claude).
- Build product for the owner to install:
  `/tmp/cuw_sibling_build/Build/Products/Release/Claude Usage.app`.

### NOT fixed — flagged for the owner
- **A whole provider group can be hidden.** Observed live: with the bar crowded, an
  11-tile (~277pt) Claude composite was clipped ENTIRELY behind the system overflow
  chevron while the 1- and 2-tile groups stayed visible. Group-level clipping was
  the approved trade-off, but "the largest and most important group disappears as a
  unit" is worse than losing one tile. Follow-up worth scoping: split a group that
  exceeds a width budget into chunks of N tiles (several items, same paint
  pipeline) so overflow degrades tile-by-tile again.
- **`.percentage` style breaks the fixed-length invariant**: digit-width changes
  (9→10%, 99→100%) resize the composite and so can trigger a bar relayout. Not in
  today's path (production runs `progressBar`), and the memo means the length only
  moves when a tile genuinely changes size.
- **One rebuild per launch remains**: group items are created from pre-hydration
  `providerKind`, so the post-hydration regroup still recreates them once (9 scene
  windows' worth, versus 42 before).
- **The popover navigator is compile- and logic-verified but NOT visually
  verified** — exercising it means clicking real tiles, and the only running
  instance is the owner's production app doing live auto-switching. Arrow-key
  cycling in particular depends on the popover holding focus; the ‹ › buttons and
  chips are the guaranteed affordance.

### Consult log (Reasoning Consult protocol)
- **Codex (gpt-5.6-sol, xhigh, read-only, live probes):** NEEDS-FIXES — ordering
  BLOCKER; shortcut-toggle wrong account; blank placeholder; lab stress no longer
  meaningful; unconditional re-assembly + missing pruning; `.percentage` length
  invariant. Confirmed WORKING: segment routing/clamping, pair-keyed
  dismiss-vs-switch, provider-set rebuild detection, appearance invalidation, TIFF
  guard, legacy and single-profile modes, auto-switch untouched (verified against
  live production logs), watchdog window-class gate. **Adopted in full.**
- **Grok (grok-4.5, high, advisory):** same ordering BLOCKER, plus the transparent
  inter-tile gaps (event shape), the button-space/image-space mapping gap, the
  `lockFocus` retina hazard, and the fixed-length claim. **Its dissent produced
  three fixes the workflow ranked only NIT** — the highest-value advisory output so
  far in this investigation.
- **Verification workflow (12 agents, 6 dimensions + adversarial refute):**
  reproduced the ordering BLOCKER from three independent dimensions, killed the
  weaker claims, and added the AppKit image down-fit hazard, the
  selection-toggle-rebuild waste, the re-silenced watchdog threshold, the
  Grok "Active" inconsistency, and the stale deferred anchor rect.
- **Disagreement resolved by measurement, not vote:** the "9 scene windows / 0.0%
  CPU" claim held; the "ranking = paint order" claim did not.
- **Concurrency note:** the dispatching session had applied two uncommitted edits
  (reversed paint order, composite backdrop) from Grok's verdict before handing the
  worktree over. Both were re-expressed in the refactored structure rather than
  kept as-is, since a build on the mixed state had failed; intent preserved, credit
  recorded here.

## Addendum 7 — final verification, merge, and live deployment (2026-07-29 night, Fable sibling 2)

Mission: independent final gate over addendum 6's hardened composite work, then —
owner-authorized — merge PR #21 and deploy live.

### Council closeout (all 18 findings individually verified on the tip)
Every finding from the composite council round was traced to code on the branch tip:
- **Fixed and verified**: within-group ordering (`compositePaintOrder`, reverse-of-rank,
  shared with the popover navigator via `onScreenGroupMembers`); keyboard-shortcut
  account pass-through (`intendedProfileId`); click routing through the drawn rect
  (`compositeDrawnRect`, `imageScaling` pinned at creation); full-canvas event-shape
  backdrop; template/monochrome tinting; `NSBitmapImageRep` at the bar display's scale
  (scale in the memo key); whole-point tile advances; empty-profiles placeholder
  (`paintPlaceholderLogo`); stale-segment clearing (incl. `[]` on emptied groups);
  assembly memoization (`CompositeKey`) + state pruning (`pruneTileState`);
  deterministic `button(for:)` (own-provider resolution); deferred-anchor re-resolution
  inside the async re-show; per-segment lab popover-stress anchors; forced-teardown
  rebuild probe; watchdog threshold 1.5%.
- **Deferred with rationale (unchanged)**: `.percentage` variable-width relayout (not in
  today's path); whole-group overflow clipping (follow-up: chunk wide groups); one
  rebuild per launch (pre-hydration `providerKind`).
- Docs nit: addendum 6 claims "17 unit tests"; `CompositeTileLayoutTests` adds 14
  (suite total 148 is correct).

### Verification evidence
- Full suite from clean derivedDataPath: **148/148 green**, twice (tip, then amended tip).
- Lab (`com.claudeusagewidget.lab2`, `CUW_LAB=1 CUW_LAB_TILES=14 CUW_LAB_RESHUFFLE=1
  CUW_RENDER_LOG=1`): **9 scene windows pinned across 4 ranking reshuffles**, each flip
  logging `ranking reshuffled — composite paint order updated (no window changes)`;
  counters showed 14 tile renders → 3 image assignments per sweep; **0.0% CPU,
  0.25 CPU-seconds total**, zero occlusion churn, `strandedTileDetected=0`.
- **Ordering pixel checks (the round-3 BLOCKER)**: screenshots of the drawn composites.
  Codex group `Cd2 | Cd1` (Cd1 = sooner weekly reset → RIGHTMOST ✓). With bar space
  freed, the full 6-tile lab layout read `C03 C02 C01 | Cd2 Cd1 | Grk` — C01 (soonest)
  rightmost in the Claude group ✓.
- Lab-environment artifact, documented not fixed: with TWO same-named instances sharing
  the bar (lab + production), group-level item placement interleaves by provider and the
  lab instance's groups can sit in non-policy order. Single-instance behavior (the only
  production configuration) is correct — verified on the deployed app below.
- Diff blast radius: `ProfileManager` gains only the read-only `activeAccountIds`
  helper; `Profile.ProviderKind` gains conformances. **No credential seam, sync,
  Keychain, or auto-switch code is touched.**

### Final council round (full diff, consult log)
- **Grok (grok-4.5 high, advisory, read-only fence): SHIP.** Independently re-verified
  every prior fix as real. Residuals: watchdog 1.5% may sit close to the real
  multi-account idle baseline (RUSAGE_SELF includes background sweep work) → checked
  empirically in the soak below; notification copy said "a relaunch clears it"
  (contradicts the addendum-1 wedge model) → fixed; whole-group overflow reiterated;
  ghost-strip edge when a live group paints zero members → follow-up; one-runloop
  segment lag after membership reuse → harmless.
- **Codex (gpt-5.6-sol xhigh, read-only): NEEDS-FIXES**, adjudicated:
  1. "BLOCKER: popover re-show races the animated close" (one dispatch turn vs
     `popoverDidClose` after fade-out; `ensurePopover` can return the closing popover).
     **Pre-existing on merged main** — the identical `performClose` → one-turn async →
     `ensurePopover` pattern shipped in PR #20 and ran in production all day; this
     branch only improved its anchor resolution. The branch never claims to eliminate
     fence exposure (addendum 2/3 retraction) — it makes the wedge cheap and
     self-detected. **Follow-up, not a merge blocker**: drive the re-show from
     close-completion.
  2. Blank `Settings { EmptyView() }` scene reachable via ⌘, — the documented
     addendum-4 trade-off (SwiftUI requires ≥1 Scene); the app is an accessory with no
     main menu, so the shortcut is effectively unreachable. Follow-up: remove entirely.
  3. **Fixed pre-merge (`a455550` → merged as part of `8126794`)**: a transient
     composite bitmap/context failure was memoized as success (empty strip assigned,
     `CompositeKey` recorded) — a provider group could stay blank until an unrelated
     tile changed. `compositeImage` now returns nil on failure; the caller keeps the
     previous image/segments and skips the memo.
  4. **Fixed pre-merge**: watchdog notification copy (claimed ~6 min — the ladder
     notifies at ~18; advised a plain relaunch — now states the ~2-minute-gap remedy).
- **Synthesis**: SHIP after the small amendment; disagreement resolved by provenance
  (git archaeology on main) and measurement, not vote count.

### Merge + deployment
- Amendment committed and pushed; suite re-verified green; PR comment logs the gate.
- **Merged**: `gh pr merge 21 --rebase` → main tip **`8126794`**; remote branch deleted.
- Release built from merged main in a clean worktree + derivedDataPath.
- Backups: `Claude Usage.app.pre-composite-final` (the addendum-5 build that was
  running) + this morning's `.pre-fix-backup` retained. Two intermediate same-day
  backups (`.prev` 19:23, `.prev2` 20:42) were removed — NOTE: the brief said remove
  pre-today backups and these were today's; both were superseded intermediate builds,
  reproducible from git, but recording the deviation honestly.
- **Wedge-gap relaunch**: killed 21:51:53, installed during the gap, relaunched
  21:54:40 (gap 167s ≥ 150s).

### Post-install soak (15.5 min, 21:54:40-22:10:03)
- CPU: 0.0% at every 60s sample (a single 0.1% reading); cumulative 1.76 CPU-seconds
  over the soak = **~0.19% average** - an order of magnitude under the 1.5% watchdog
  threshold, so Grok's false-fire concern is empirically retired at the current
  account count (the real 14-profile idle baseline is ~0.2%, not the ~1.3% the old
  build's storm-era cumulative average suggested).
- Occlusion: **4 events over the whole soak (~0.26/min)**; storms run ~100k/min.
- StormWatchdog: **zero lines** (armed, silent).
- Scene census (heap, mid-soak): **9 NSStatusBarWindows** (3 group items x 3 variant
  scenes - structural) and **13 CAContexts**, flat; one documented post-hydration
  rebuild at launch (1 -> 3 group items).
- App-level errors: only one expected `Rate limit exceeded` for profile 'BBR' (the
  429 burst-backoff path doing its job); everything else in the stream was OS-daemon
  noise.
- Deployed-bar screenshot: group order Codex -> Grok -> Claude left-to-right (Claude
  rightmost per policy); within-group order is the exact REVERSE of the addendum-5
  build that was running - Claude reads `201 jsk Sta BBR Goo Com 202 Mem Out Ai Las`
  (rightmost = soonest weekly reset), Codex reads `Cod | Dex`. All 11 Claude tiles
  visible, no overflow clipping at deployment time. Active-account cyan labels render.
- No clicks occurred during the soak (owner away), so popover click-routing and the
  group navigator remain compile/logic/lab-verified only - they head the
  hand-validation list below.

### Hand-validation list for the owner
1. Within each provider group the RIGHTMOST tile is the account with the soonest weekly
   reset — this is the visible change vs the addendum-5 build you were running (its
   order was inverted).
2. Click tiles left/middle/right in the widest Claude group — the popover must show the
   clicked account; same-tile click dismisses; cross-tile click switches.
3. Popover group navigator: ‹ › buttons and chips cycle the group (arrow keys work when
   the popover has focus); the active account's chip is cyan; numbers keep updating
   while open.
4. Monochrome ("use system color") mode still tints the whole strip.
5. If the StormWatchdog notifies: quit, wait ~2 minutes, relaunch (do NOT relaunch
   immediately); if it false-fires on a healthy app, the 1.5% threshold needs a bump —
   see Grok's RUSAGE_SELF note above.
6. Escape hatch if the wide Claude group overflow-clips as a unit: `CUW_SEPARATE_TILES=1`.

### Follow-ups (ranked)
1. Chunk overflow-wide groups into several composite items (restores tile-by-tile
   overflow degradation).
2. Drive the cross-tile popover re-show from `popoverDidClose` completion (closes the
   animated-close race Codex flagged; pre-existing since PR #20).
3. Watchdog: corroborate CPU with occlusion rate / main-thread state before stage 1,
   or raise the threshold if the soak/first week shows false fires.
4. Remove the `Settings` scene entirely; clear `button.image` when a live group paints
   zero members.

## Addendum 8 — composite-click misroute ROOT-CAUSED and fixed; group re-click dismisses (2026-07-30, Fable sibling 3)

Mission: resolve the owner's two morning reports on the deployed PR #23 build —
S1 "Google is active but if I click it, it now opens Commits" and S2 "if a group
is open and I click again on the group, it should close it" — from first
principles, without inheriting the prior sessions' hypotheses.

### Root cause (with evidence): the click's NSEvent never carried the click location

The unified log destroyed the "clicks carry a location that we convert wrong"
premise that addenda 5-7 (A1 ambiguous-fallback, A2 defensive conversion) were
built on:

- **14 consecutive physical clicks between 08:10:12 and 08:18:16 all logged
  `Composite click: rawX=148 mapped=148 → segment hit`** — fourteen identical
  integer coordinates across 8 minutes of separate clicks on different tiles.
  A physical pointer cannot do that; rawX was a CONSTANT.
- 148 == compositeWidth/2. The Claude group had 11 selected tiles ≈ 26.9pt each
  (~296pt total). Reconstructing the paint order from the owner's live
  `profiles_v3` (soonest weekly reset rightmost) gives left→right:
  2010, jskxkxjssh, Stanford, BBR, Google, **Commits**, 2026, Memori, Outlook,
  Ai, Last. The button's CENTER (5.5 tile-widths) falls in tile index 5 —
  **'Commits'**. Every click "opened Commits" because every click was resolved
  at the button's center, regardless of where the owner clicked.
- WHY the event lies: each production click is immediately preceded in the log by
  FrontBoard delivering **`NSMenuBarNavigateAction` to
  `NSMenuBarNavigationSceneExtension`**, then AppKit `trackMouse send action on
  mouseUp`. On macOS 26/27 the scene-hosted status-item click arrives as a scene
  ACTION, which AppKit re-dispatches through the button cell's tracking with a
  **synthesized NSEvent positioned at the button's center**. `NSApp.currentEvent`
  at action time simply does not contain the physical click location — so every
  event-coordinate fix (A1's fallback re-target, A2's screen-route conversion)
  was aimed below the broken layer. A2's conversion was in fact "working":
  mapped==rawX means the math faithfully converted the synthetic center point.
- The static mapping itself was never wrong: the CUW_LAB_CLICKPROBE sweep at 11
  tiles is exact and contiguous (`Lab Claude 8[0-25] … Lab Claude 1[176-199]`,
  grok/codex equally clean) — consistent with addendum 7's pixel verification.

### Fix (branch fix/click-misroute, folded into PR #23)

1. **Resolve clicks from the physical pointer, not the event.**
   `StatusBarUIManager.pointerLocalX(in:)` reads `NSEvent.mouseLocation` (the
   window server's pointer position at action time — where the user actually
   clicked), converts it via `window.convertPoint(fromScreen:)` +
   `button.convert`, and returns nil when the pointer is not on the button
   (±4pt slop). `togglePopover` uses it as the only coordinate source; nil →
   ambiguous → the group's ACTIVE account (the A1 fallback, now reachable for
   keyboard-activated toggles and forwarded scene actions too). The lab click
   probe logs the pointer pipeline alongside the legacy event pipeline.
2. **Group re-click DISMISSES (S2, owner spec).** The dismiss decision keys on
   the BUTTON only: any click on a group whose popover is open closes it —
   switching accounts with the popover open is the group navigator's job.
   Previously "same tile" required the re-click to resolve to the exact anchor
   profile; any resolution scatter turned the dismiss into close + fresh popover.
3. **Swallow stamp at close INITIATION.** The .semitransient popover auto-closes
   on the dismissing click's mouse-DOWN, but the stamp that lets the mouse-UP
   action swallow the re-open was only written in `popoverDidClose` — which,
   with `animates=true`, arrives after the fade-out, i.e. typically AFTER the
   mouse-up action already ran, found no stamp, and re-opened the popover (the
   383ms close/re-open pair in the 08:11:58 trace). The stamp now writes in
   `popoverWillClose` — and ONLY there (see the validation rounds below for
   the precise arming condition; `didClose` never stamps).
4. **Superseded didClose can no longer orphan a live popover.** A group switch
   re-shows a (possibly reused) popover before the old animated `didClose`
   lands; unconditionally clearing `currentPopoverButton` there made the next
   same-group click read as "different button" → close + re-open. The
   anchor-state clear is now gated on `!closed.isShown && (closed === popover ||
   popover == nil)` — the same pattern as the deferred destroy.

### GPT-5.6 validation (codex exec, gpt-5.6-sol, xhigh — three rounds to convergence)

- **Round 1** (full diff): FIX FIRST. Finding 1 (MAJOR): the swallow stamp armed on
  EVERY close — open group → click desktop → click group within 0.5s = swallowed
  legitimate open. Finding 2 (MAJOR): the didClose "extend the window" stamp re-armed
  a stamp the dismissing mouse-up had already consumed → next click swallowed.
  Finding 3 (MINOR): pointer sampled at action time can drift from the physical click
  in the scene-action dispatch gap — accepted as residual (millisecond window; a
  captured mouse-down location is unobtainable precisely because scene-hosted items
  don't deliver those events; the miss degrades to open-wrong-tile, recoverable).
- **Fixes**: arm the stamp ONLY in `popoverWillClose` and only when the close is
  provably the anchor-click auto-close — `NSEvent.pressedMouseButtons == 1` (exactly
  left; the status buttons use the default left-mouse-up action mask, so no action
  ever follows a right-button press to consume a stamp) AND pointer on the anchor;
  `popoverDidClose` never stamps.
- **Round 2**: confirmed findings 1+2 resolved and the intended dismiss intact;
  flagged the right-button/drag-off arming residual → left-only restriction applied.
- **Round 3**: **VERDICT: SHIP.** "The normal sequences work: desktop dismiss →
  reopen does not arm; anchor re-click arms and consumes the stamp on mouse-up; the
  following click reopens." Drag-off/edge-slop residual judged "[LOW — ACCEPTED] …
  not a realistic normal-use blocker" (self-expires in 0.5s; next click recovers).
- First codex run wedged (no output growth 24 min, killed + relaunched once per the
  anti-stall watchdog rules); relaunch completed normally.

### Verification

- Unit suite green twice (after the main fix and after the codex-finding fixes):
  `** TEST SUCCEEDED **`, all suites passed.
- Lab (this branch, `com.claudeusagewidget.lab2`, CUW_LAB_TILES=11 + CLICKPROBE):
  static mapping still exact and contiguous —
  `ClickProbe sweep claude: width=199 Lab Claude 8[0-25] … Lab Claude 1[176-199]`,
  grok `[0-24]`, codex `Cod 2[0-25] Cod 1[26-49]`. The probe now also logs the
  pointer-based pipeline (`pointerX=…→name`) next to the legacy event-based one, so
  the next real lab click shows both side by side.
- The reconstruction was cross-checked against addendum 7's deployed-bar screenshot:
  `201 jsk Sta BBR Goo Com 202 Mem Out Ai Las` — 'Com' is tile 6 of 11, dead center,
  exactly where a synthesized-center event resolves.

### Merge + deployment

- PR #23 fast-forwarded to include the four fix commits and **rebase-merged**
  (linear history): main tip **`849161d`** —
  `046c967` pointer-based resolution + group-dismiss, `572007f` superseded-didClose
  guard, `9cca759` precise swallow arming, `849161d` left-button-only arming, on top
  of the two prior PR #23 commits.
- Release built from merged main; rollback copy at
  `/Applications/Claude Usage.app.pre-click-fix` (the PR #23-tip build that was
  running; the older `.pre-clickfix` backup retained).
- The running build was in the churn state at deploy time (StormWatchdog firing:
  idle CPU 4-7% of a core, 9-10 windows, ~2:13 CPU-min over 66 min ≈ 3.3% avg), so
  the **wedge-gap relaunch** was used: killed 09:19:01, installed during the gap,
  relaunched after ≥165s off the bar.

### Post-install soak (8 min, 09:21:46-09:30)

- Pre-deploy state was the CHURN state (watchdog firing at 4-7% idle CPU since
  ~08:15); post-relaunch: **0.0% CPU at every 60s sample**, 0.88 cumulative
  CPU-seconds over 8 min ≈ **0.18% average** — the documented clean baseline. The
  165s wedge gap cleared the OS-side state again, exactly as addendum 1 predicts.
- Heap census: **9 NSStatusBarWindows, 13 CAContexts** — identical to addendum 7's
  healthy baseline. Main thread parked in the run loop.
- StormWatchdog: silent post-relaunch.
- No physical clicks had occurred yet at writing time (owner away) — the deployed
  build logs every click at default level, now including the new outcomes
  ("Composite click: rawX=… → segment hit", "…pointer off-button → ambiguous
  (active-account fallback)", "Popover: same-group re-click → dismiss", "Popover:
  re-click after auto-close swallowed → dismissed"), so the next owner clicks are
  directly verifiable in `log show`.

### Hand-validation list for the owner (2 minutes)

1. Click the GOOGLE tile (or any specific tile) — the popover must open on that
   account, not 'Commits'. Try left/middle/right tiles of the Claude group.
2. With a group's popover open, click that group again — it must CLOSE (owner spec:
   same-group click = dismiss; switching accounts with the popover open is the
   navigator's ‹ › job).
3. Open a popover, click the desktop, then immediately click a tile — it must OPEN
   (the old code could swallow this).
4. `log show --predicate 'process == "Claude Usage"' --info --last 10m | grep -E
   "Composite click|Popover:"` shows exactly what each click resolved to.

### Residuals (accepted, documented in code)

- Pointer position is sampled when the scene action reaches the app (ms after the
  physical click); moving the pointer a full tile-width in that window would open
  the neighbor tile. Unobtainable otherwise: scene-hosted items do not deliver the
  real mouse events to the app — that IS the root cause.
- A left-press on the anchor that drags off and releases outside arms a swallow
  stamp nothing consumes; it self-expires in 0.5s and at worst eats one click.

### Addendum 8.1 — live falsification of the swallow-arming gate; PR #24 (2026-07-30, ~13:15)

The owner's hand-validation confirmed HALF of addendum 8: the misroute is fixed —
the live trace shows rawX varying per click and resolving correctly (123→Google,
14→2010, 190→Memori, 39→jskxkxjssh, 94→BBR…). But every same-tile re-click still
closed AND re-opened (owner report; trace 13:06:41→13:06:45 'Google' pair with no
dismiss/swallow lines).

Diagnosis from the trace: at action time the popover was already auto-closed and
the swallow was NOT armed. The `NSEvent.pressedMouseButtons == 1` arming gate
(added for Codex round-2's finding) can NEVER hold on macOS 27: the scene-routed
click is processed by the app after the physical mouse release — the same
event-timing decoupling that caused the original misroute also invalidated the
"mouse currently pressed" check. A condition designed for classic event timing was
accepted without re-testing it against the scene-routed world; lesson recorded.

Fix (PR #24, rebase-merged, main `6e311d4`): arm on pointer-on-anchor ALONE —
which by itself still excludes the desktop-click closes Codex round 1 worried
about — and log armed/not-armed at default level so every future click trace shows
the arming decision directly. Codex gpt-5.6-sol xhigh round 4: **VERDICT: SHIP**
("pointer-on-anchor alone is the correct practical arming gate; the removed
pressed-button condition could never succeed during the affected path"); unit
suite green. Residuals (LOW, accepted): a keyboard/programmatic close with the
cursor resting on the anchor, or a right-click/drag-off, arms a stamp nothing
consumes — self-expires in 0.5s, at worst one swallowed click.

Redeployed from merged main with the wedge-gap procedure (churn had re-ignited:
45 watchdog lines since 09:22, ~2.3% avg CPU; killed 13:15:52, ≥165s gap).
Owner re-validation: click a tile → popover opens on it; click the same group
again → popover CLOSES and stays closed. The trace now must show
"Popover: willClose — swallow armed (pointer on anchor)" followed by
"Popover: re-click after auto-close swallowed → dismissed" (or
"Popover: same-group re-click → dismiss" when the auto-close loses the race).

**Owner-confirmed 13:19 (addendum 8.1 closeout):** same-tile click opens, re-click
closes and stays closed. Trace note for future sessions: the dismiss usually
produces ONLY "willClose — swallow armed (pointer on anchor)" with NO
"swallowed → dismissed" line — on this build the anchor re-click's auto-close
consumes the click and no trailing action is delivered, so there is nothing to
swallow. The armed swallow is the backstop for when the OS does deliver the
action (as it demonstrably did in the 08:11 trace). A lone "swallow armed" line
after an open IS the successful dismiss signature, not a missing log.

## Addendum 9 (2026-08-06) — workflow audit: storm recurrence root-caused as a monitoring gap; leak/waste remediation (PR #25)

**Trigger.** The deployed 6.5-day process re-entered the storm state (~4-5%
idle CPU, occlusion datagrams every ~300ms, CA fence timeouts, windows=11) and
burned overnight in silence. Owner-reported symptom: 20+ seconds from menu-bar
click to responsiveness. Watchdog history showed WHY it was silent: stage 0
fired 19:24, stage 1 fired 00:10 (both ineffective — consistent with E3), and
the once-per-launch notification had been spent days earlier. This is a
monitoring gap, not a new storm mechanism: the wedge class is known and
OS-side; the app's job is to detect, notify, and keep its own cost minimal.

**Method.** 45-agent workflow (7 subsystem auditors → adversarial verifier per
finding): 73 confirmed findings, 1 refuted. High/medium fixes shipped in
PR #25 (branch audit/resource-leaks), then a codex gpt-5.6-sol xhigh
adversarial review of the diff found 1 high + 2 medium + 3 low defects in the
remediation itself — all fixed in 2eabe7a before merge. Notable:

- StormWatchdog: per-EPISODE notification (re-armed after 3 clean samples),
  GLOBAL 6h re-notify floor (flap-proof), auto ladder reduced to the stage-0
  repaint (stage 1 = falsified cure + CAContext-leaking op class; manual-only
  now), 1-sample rung latency (was 3 — a live storm took 4.8h between rungs),
  30-min cap on the hot-while-UI-open pause (stranded-window disarm).
- Global outside-click monitor leaked on every popover close that bypassed
  closePopover (semitransient auto-close, Esc, Settings/Manage buttons) —
  each leaked monitor is a system-wide per-click callout; plausible direct
  contributor to the owner's click lag. Removed in popoverDidClose (universal
  funnel, guarded so a stale close can't kill a new popover's monitor);
  install made idempotent.
- Cross-profile refresh contamination (codex-found): single-profile refresh
  saved to whichever profile was active at COMPLETION. Now saves against the
  captured id; stale completions discarded, refresh re-queued.
- security dump-keychain pipe-deadlock (drain before waitUntilExit, stderr to
  null device); NWPathMonitor recreated per start (cancel() is terminal);
  Grok dead-login backoff + 401 forced-refresh cooldown (Codex-twin parity);
  cleanupProfile actually wired (had no call sites) via .profileDeleted and
  extended to all per-profile state incl. persisted dead-login flags;
  identity cache bounded; notification-dedup prefix fix; popover backdrop
  no-op guard; per-sweep chatter demoted to .info.

**Deliberately untouched (credential seams — owner decision pending):**
per-sweep security-subprocess adoption cadence (~10k fork/execs/day),
ProfileStore hydration 15s deadline with no retry, clearProfileCredential's
lone SecItemDelete divergence, launch wizard gate racing async hydration,
SetupWizardView main-actor security reads, single-profile paid Messages-API
probe. Each sits inside the nil-never-deletes/adoption seams.

**Deploy.** 148/148 tests both rounds; installed to /Applications; quit
13:06:37 + wedge-gap ≥150s + relaunch. Live verification recorded at merge.
