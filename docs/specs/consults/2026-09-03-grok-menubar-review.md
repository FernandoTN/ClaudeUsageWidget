# Menu-bar redesign — review

**Date:** 2026-09-03  
**Tree:** `feat/menubar-redesign` worktree  
**Brief:** `docs/specs/menubar-redesign.md`  
**Live shape used:** 22 selected / 3 providers / ~600 pt of a 1728 pt bar; 2/3 Codex dead, 1 Claude dead; session 95 % / weekly 99 %

**Verdict in one line:** Ship **B (active tile + fleet dots)** as the default, with the geometry and arming rules below — not B as drawn. Keep **A** as the automatic overflow / oversized-group fallback. Do **not** implement **C as a fourth `NSStatusItem`**. Dashboard **D1**, but not as a tabbed 380 pt clone of today’s popover.

The worktree has already started Stage A (`FleetSummary.swift`, `MenuBarSummaryRenderer.swift`, `barLayout` on `MultiProfileDisplayConfig`, Settings picker, `predictedNextCandidate` / `preflightVerdicts`). That code is useful as a probe of the brief and is currently **not a compiling paint path**: `MenuBarManager` calls `updateMultiProfileButtons(..., context:)` at five sites; `StatusBarUIManager.updateMultiProfileButtons` still has the two-argument signature. The renderer also does not cover `.excluded`, still switches on a removed `.stale` alert, and does not honour the reserved affix slot the model just grew. Treat that as evidence, not as a finished design.

---

## 1. Bar layout: B, with changes — not A, not C

A 22 pt strip that is allowed ~150 pt across three items can answer four questions. Ranked by cost of a wrong answer:

| # | Question | What must be on the bar | What must not |
|---|---|---|---|
| 1 | Is the CLI account about to stall? | The **provider-active** account’s existing tile (session bar, or weekly bar when `!providesSessionWindow`; pace ticks; purple/red label tints) | Per-account percentages for the other 21 |
| 2 | When it stalls, where does the switch go, and is that login live? | Next-candidate affix, only when it matters | 2nd/3rd ranked names |
| 3 | Is anything broken only a human can fix? | Dead / suspected / degraded, as **exceptions** | A 3 pt corner dot competing with the purple label |
| 4 | How much of the fleet is still usable this week? | A pattern or a count | 22 labelled tiles |

Three `NSStatusItem`s (Claude / Grok / Codex) is the right grain. That is already what `setupCompositeGroups` creates, in that order, so Claude stays rightmost and Codex still clips first (`StatusBarUIManager.swift` ~625–668). The redesign must **not change item count**. Composite mode exists because each teardown permanently leaks CAContexts on macOS 26/27 (comments at 56–67, 530–537, 705–711).

### Why B over A and C

- **C drops question 1.** The active bars and pace ticks are the only pixels that have ever told the owner “the account being burned is climbing.” 2026-08-13 died because that number was invisible, not because the roster was. A text item also makes overflow all-or-nothing and, if implemented as a single status item, **tears down the three group items**. Disqualify as a default and as a last-rung *item*.
- **A throws away order.** On this Mac the planning question is not “how many are red” in the abstract — it is “the right side of the Claude group recovers first.” Counts cannot say that. A is the right **degrade** (when dots would be a smear, or when width is gone), not the right default.
- **B is the only option that keeps questions 1, 2 and 4 on one 22 pt strip** without 600 pt of near-identical tiles. The owner selected 22 accounts because he wants to *see the fleet*; 17 coloured dots in burn order is that,  `●4 ▲12 ✕1` is a spreadsheet cell.

B as specified still fails the strip. Changes, in priority order:

### 1. Stop growing the item at 75 % — the brief’s own “fixed length” invariant

`assembleComposites` pins `statusItem.length` so a repaint cannot relayout the bar (1296–1298, 1380–1384). The brief grows the active block from 24 pt idle to ~34 pt armed; the in-progress `FleetBlockGeometry.affixSlotWidth = 36` still adds that 36 pt **only while `armed`**. Arming is exactly when the bar is fullest and Codex is closest to clipping.

**Do this instead:** always reserve the affix slot (active block is 24 + 36 = 60 pt whether idle or armed), **or** — better, cheaper — draw `›Fjo✓` in the unused **label row of the fleet block**. Dots only occupy the top ~10 pt of a 22 pt tile (`createFleetDots`); the bottom 10 pt is empty today. That is ~60 pt of label space, no length jitter, no collision with the 3-letter active label.

Idle → armed must not change `statusItem.length`. Verdict glyph flips (`·`/`✓`/`✕`) must not either.

### 2. Two-row dots destroy “rightmost = next to burn”

`FleetBlockGeometry.dotGrid` fills **left-to-right, first row first**. For 17 others that is 10 + 7. The soonest-reset account is index 16 = row 1, column 6 — **not** the right edge of the block. The 10th-soonest sits at the right edge of row 0 and *looks* like the answer to question 2. The check-in SVG already shows this: a sea of red with the meaningful end of the ranking sitting mid-row.

**Paint column-major, right-aligned:**

- Columns fill top-to-bottom, new columns grow leftward from the right edge of the fleet block.
- The rightmost column is the soonest weekly reset among *others* (same orientation as `compositePaintOrder` / `CompositeTileLayoutTests.testSoonestWeeklyResetIsPaintedRightmost`).
- Cap at **one row of 12** (12 × 6 pt pitch − overlap = 68 pt) before flipping that provider to counts. Two rows of 4 pt at 6 pt pitch are below reliable colour discrimination, and 20 others is the wrong fallback threshold. Live Claude is 17 others: two right-aligned rows of 9 is acceptable if the rightmost column is the soonest; a 21st other account is not a realistic paint, it is a counts switch.

Pixel budget at 4 pt / 6 pt pitch, **right-aligned two rows**, live roster, **affix in the fleet label row** (active stays 24 pt):

| Provider | Active | Gap | Fleet (glyph 0 — drop it, see below) | Item |
|---|---:|---:|---:|---:|
| Claude (17 others, 9 cols) | 24 | 3 | 8×6+4+2 = 54 | **81** |
| Codex (2 others, 1 row) | 24 | 3 | 1×6+4+2 = 12 | **39** |
| Grok (0 others) | 24 | 0 | 0 | **24** |
| **Total** |  |  |  | **≈ 144 pt** plus system gaps |

That is ~8 % of 1728 pt, down from ~35 %. Do not add the 6 pt provider glyph (`FleetBlockGeometry.glyphWidth`) on B: the three items are already spatially Claude-right / Grok / Codex-left. A 6 pt “C” is Option-C vocabulary leaking into B, and `createFleetDots` does not even offset for it today (dots start at `x = 1`).

### 3. 4 pt hollow vs filled grey is not a dead-login signal

Dead (hollow) vs unknown (filled) at 4 pt with a 1 pt stroke is a 2 px ring on Retina and a smear at 1x. Dead is question 3, the one only a human can fix.

**Glyph, not ring:** dead = 5 pt `✕` (or a filled grey dot with a 1 pt slash). Unknown = filled grey. Ready/low/exhausted/suspected stay 4 pt colour dots. Cost: ~1 pt of pitch on dead members only, or keep 6 pt pitch and accept the slash overlapping the fill.

### 4. Weekly-only active tiles are 16 pt, not 22 pt

`createMultiProfileProgressBar` with `weekPercentage == nil` (the weekly-only path `paintTiles` already takes at 1064–1072) is `4 + 2 + 10 = 16` pt tall. Codex and Grok **have no session bar**. Aligning “row 0 with session, row 1 with weekly” is a Claude-progressBar fiction. For weekly-only, use **one row of dots**, vertically centred on the single bar, and never invent a second row to match a bar that was correctly dropped.

Same hole for `.concentric` / `.compact` / `.percentage`. Fleet summary should either **require `.progressBar`** (what the owner actually runs) or draw a 24×22 active *block* that is not the concentric renderer. Do not glue 4 pt dots to a 22 pt ring and call it a summary.

### 5. Counts (A) as automatic fallback — but do not merge states

A at 55 pt/provider is the right overflow step and the right “>12 others” step. The specified count glyphs are wrong:

| Specified | Problem | Instead |
|---|---|---|
| `▲` = exhausted **+** low, in red | Low is still a valid switch target (80–94 % session). Painting it as exhausted teaches the opposite of the auto-switch rule. | `●` ready, `◐` low (orange), `▲` exhausted (red) |
| `?` = suspected **+** unknown, in purple | Unknown is missing data; purple is the data-quality tint for an inferred throttle. Merging them re-teaches “purple = 100 %”. | `?` unknown (grey), suspected stays a purple `●` (or a `!`) |
| 30 pt for four 7 pt pairs | `●12` at 7 pt semibold is ~18 pt. Two columns of 15 pt clip. In-progress `countsWidth = 30` is already too tight, and adding `glyphWidth` does not help the numbers. | **44 pt** (two columns of 22) or one column of four 8 pt rows in the 22 pt height |

Grok with one account: no fleet block. Correct.

### Option C

Keep as a **paint style of the existing three items** (each group becomes `C  Atl 78·16 ●4 ▲11`, etc.), last rung, still three windows. Never `NSStatusBar.system.statusItem` create/destroy to fold them into one.

---

## 2. Readiness taxonomy, affix, alert dot

### Taxonomy — keep six states, fix the slogan and two encodings

The six states are the right set. The sentence *“ready means exactly the auto-switch would accept this account”* is false in the brief and still false in `ReadinessThresholds`’s doc comment: **`low` is also an accepted target** (`blocksSwitchTarget` is false for `.ready, .low, .unknown`; `findNextAvailableProfile` only rejects at the *switch* thresholds). Say instead:

> **Eligible** = `{ready, low, unknown}` = the walk would take it.  
> **Ineligible** = `{suspected, exhausted, excluded, dead}`.

The in-progress `.excluded` (opt-out / free-plan CLI) is a good addition the brief missed. It is not a capacity colour; draw it as a dim dash or omit it from the dots (an opted-out account is not part of the *fleet the switch can use*). Putting it in the precedence above suspected is right — a dead opted-out login is still dead first.

**Precedence I would ship** (first match):

1. `dead` — flag **or** expired with no refresh token (`ProfileCredentialStatusCache.hasDeadLogin` is the right predicate; it does not touch Keychain).
2. `excluded` — `!isAutoSwitchEnabled` or free CLI plan (same tests as `findNextAvailableProfile`).
3. `exhausted` — server-affirmed `rateLimitedUntil` (`rateLimitedInferred != true`), **or** measured session ≥ session threshold while `providesSessionWindow` (use `sessionPercentage` with a live window, **not** `effectiveSessionPercentage`), **or** `isWeeklyMaxed`.
4. `suspected` — inferred stamp live. After exhausted, so an affirmed stamp can never render purple.
5. `unknown` — `claudeUsage == nil` only. **Not** “older than 60 min”.
6. `low` / `ready` — as specified.

**Staleness is not a seventh colour.** The brief’s `unknown = missing OR >60 min` mis-encodes a weekly-maxed reading whose boundary is still in the future (that is still exhausted; `isWeeklyMaxed` already honours the reset) and a 90-minute-old 42 % (that is not “no information”, it is an old measurement). The in-progress split — keep the colour, set `FleetMember.isStale`, dim the dot — is the right idea for weekly facts. For a **session** reading older than ~15 min that is *not* maxed, I would still force `unknown`: session windows move 15–20 pp in minutes (the 2026-07-29 stale-candidate incident). One `staleAfter` for both windows is too coarse. Two clocks: session 15 min, weekly 60 min.

`classify` must keep using **measured** `sessionPercentage` / `weeklyPercentage` / `isWeeklyMaxed`, never `effectiveSessionPercentage`. That property is 100 while *any* stamp is live, including inferred — it is the decision seam, not the display seam (`ClaudeUsage.swift` 17–80). Using it for digits or colours is a synthetic 100, which is ruled out.

`hasSessionHeadroom` still reads `effectiveSessionPercentage`, so a suspected candidate is correctly refused as a target. Do not “fix” that.

### What the taxonomy still mis-encodes

| Case | Brief / current model | Reality |
|---|---|---|
| Suspected **active** account | Purple label on the active tile (good). Affix arms because `preflightMilestonePercentage` uses `effectiveSessionPercentage` (100). | Auto-switch **does not fire** (`autoSwitchTriggerUsage` strips the inferred stamp, `checkAutoSwitchIfNeeded` ~2932). The bar would say “the switch is coming → Fjo” while the walk will not run. **Arm and `activeDigits` must key off `autoSwitchTriggerUsage` (measured), never `effectiveSessionPercentage`.** Digits of `100` on a suspected tile are a synthetic 100. |
| Codex/Grok weekly-only | Session slot already shows weekly; `preflightMilestonePercentage` correctly keys weekly (H1 is fixed). Arming at 75 % weekly against a 99 % switch means the affix is up for a large fraction of the week. | Acceptable — that *is* the preflight window — but the affix must not imply a 5 h stall. Dashboard copy: “auto-switch at 99 % weekly”, not “at 95 %”. |
| `unknown` as a valid switch target | `blocksSwitchTarget == false`; `hasSessionHeadroom` is `true` when `claudeUsage == nil`. | The walk may land on a never-fetched account. Keep the rule (the 180 s Claude re-fetch in the walk is the safety net) but **do not paint unknown as a green-adjacent filled grey** next to dead-hollow. |
| Fable-maxed Claude | `isWeeklyMaxed` already includes Fable → `exhausted` / light-red label. Active tile **bars** still show session + all-models weekly, both possibly green. | Question 1 as the *auto-switch* asks it (“will a 99 % Fable fire a costly switch?”) is a red label on two green bars. The dashboard must show Fable as a first-class bar; the strip cannot, and should not grow a third bar. |

### Affix (`›Fjo✓`) — signal, if it does not move the item

Question 2 is the second-most expensive wrong answer (dead login under the CLI; or a switch that never comes). The affix is the right channel. Changes:

- **Show it when armed on measured usage, or when a queue entry exists, or when there is no eligible candidate at all** — even at 20 %. Today’s live Codex shape is 2 of 3 dead. Waiting for 75 % to say `›—` hides the only fact that group has. `noCandidate` must not require `armed`.
- **`✓` only for a proving verdict** (`PreflightVerdict.Kind.probed / .refreshed / .ownsLogin / .switched`). The in-progress `provesLive` is correct. The Claude branch still leaves `verdictKind = .expiryOnly` when `ensureFreshCredentials` returns false because the token was *already* fresh (`MenuBarManager.swift` ~3319–3326). That makes a live Claude candidate show `·` forever. If the token is comfortably unexpired after the call, record `.refreshed` (or a `.alreadyFresh`) so the glyph can go green without a forced rotation.
- **30 min TTL is wrong for weekly-only.** Codex 90 % → 99 % can be a day. TTL = “this keyed window” (until `preflightMilestoneBoundary`), not 1800 s. Claude 5 h windows can keep 30 min.
- **`»` for queued** is worth the extra pixel. Do not drop it.
- **`⇄` mid-switch** (in-progress) is good: a switch costs 10–15 % of every concurrent session and can last across a paint. Put it in the affix slot, do not add another channel.
- Draw the 3-letter candidate in the verdict colour, the chevron in white. One colour for `›Fjo✓` (current `createProviderSummaryTile`) makes a green `›Fjo✓` look like Fjo is active.

Drop the trailing `·` for unverified — a grey chevron + name is enough. `·` at 8 pt is noise.

### Alert dot — mostly noise. Drop it.

Four 3 pt colours on the top-right of a 24 pt tile, sitting under a purple or light-red label that already outranks them:

| Alert | Why it loses |
|---|---|
| `noCandidate` | The affix `›—` (red) already says this, and louder. |
| `deadLogins` | Hollow/`✕` dots already say this. Duplicate. |
| `degraded` | Already a popover banner that outranks everything (`PopoverContentView.swift` 176–184). Painting it on **all three** tiles is three amber dots for one daemon. |
| `stale` | 3 pt grey on a dark bar is invisible. Dim the **active bars** (in-progress `activeIsStale`) instead. |

If anything remains, one bit: **red mark iff `›—`**. Everything else is a dashboard/popover banner. The in-progress drop of `.stale` from `FleetAlert` is correct; keep going and drop the corner dot entirely.

---

## 3. Dashboard: D1, not D2 — but not the wireframe as drawn

**D1.** This is a glance surface that must open from the bar and die on outside click. That is already `NSPopover` `.semitransient`, `animates = false`, destroyed on close (`MenuBarManager.ensurePopover` ~569–590, teardown comments at 204–210). D2 is a second window lifecycle next to Settings (`bringWindowToForeground`, orphan paths O1/O2 at 3643–3664). Wrong default.

Detaching is already implemented (`popoverShouldDetach` + `detachableWindow(for:)` builds an `NSPanel` HUD). That *is* the “keep it open” path, at zero new window-policy code — **if Stage B updates the hardcoded 320×600 in three places** (`Constants.WindowSizes.popoverSize`, `ensurePopover`, `detachableWindow(for:)` ~3744–3755). Leaving the detached panel at 320 while the popover is 380 is a real bug waiting.

Do **not** sell “detach = dashboard window at zero cost” without noting: `detachableWindow(for:)` installs a **new** `NSHostingController` (a copy). `@ObservedObject` on `MenuBarManager` / `ProfileManager.shared` still updates it. `StormWatchdog.isNominallyIdle` treats any non-`StatusBar` visible window as busy — a detached dashboard correctly disarms the idle-CPU alarm. Keep that.

### What D1 must show that the brief misses

1. **Which window will fire the switch.** Session 20 % / weekly 16 % / Fable 99 % looks fine on the active tile (two green bars, light-red label). The dashboard’s ACTIVE block needs a Fable bar for Claude, and a single sentence: “auto-switch fires on Fable weekly at 99 %”. Codex/Grok: no session row, no Fable row.
2. **Measured vs inferred vs header-rescue.** Suspected copy is good. Also say when the number came from `/v1/messages` headers (`countsAsEndpointControl: false` path). Otherwise “Updated 28s” on a header-rescue looks like `oauth/usage` recovered.
3. **Opt-out and manual pin.** `includeInAutoSwitch == false`, and `.profileManuallyActivated` / `autoSwitchedProfileIds` (a user-chosen exhausted account is not yanked by the next sweep). Without these, “Make active…” looks like it didn’t stick.
4. **Two actives.** One Claude owner of the CLI Keychain, one Codex owner of `auth.json`, Grok = focused-or-sole (`ProfileManager.activeAccountIds`). The dashboard must not imply a single “ACTIVE”. Provider sections, each with their own active.
5. **Queue is one array, filtered per provider.** `autoSwitchQueue` is a single UUID list (`SharedDataStore`). Show this provider’s slice; do not show a Codex id under Claude.
6. **Switch cost only when it is about to happen** (armed, or the confirm of “Make active…”). A permanent 10–15 % nag on every glance trains the owner to ignore it.
7. **Overflow-hidden provider** (Stage C banner). “Codex hidden by menu-bar overflow.”
8. **Dead login as a verb.** `/login` then Sync, with a button into the existing Settings section (audit M5: notification taps still do nothing; the dashboard can at least deep-link).
9. **Weekly-only roster rows.** Do not draw a session bar at 0 % for Codex/Grok (`hasSessionWindow == false`). Today’s popover still has Codex-adjacent copy that promises a 5 h window (audit L5).

### What D1 must not show

- Credentials, tokens, JSON, Keychain state.
- Per-model Opus/Sonnet weekly (Fable is the one that fires the switch; the rest is Settings).
- Pace ticks on 17 roster rows (keep bars + %).
- Display-style / layout / threshold editors (Settings).
- A synthetic 100 anywhere. Roster percentages = `displaySessionPercentage` / weekly, never `effectiveSessionPercentage`.
- The classic popover’s Claude status URL under a Codex account.

### Wireframe problems (fix in Stage B, don’t paint them)

- **380 pt is too narrow for the roster row as drawn** (`● Fjo  bar 12  bar 70  Fable 99  Mon 09:41  ›`). Two-line rows: line 1 identity + chip + reset; line 2 the bars. Or drop Fable % from the row and keep it on the ACTIVE block + a red chip.
- **Provider tabs hide the fleet.** The point of a *fleet* board is all three groups. **Stacked sections with sticky headers**, default-scroll to the clicked provider. Tabs are a second click to see Codex while you are on Claude — the opposite of “one click away.”
- **`NavigationStack` inside an `NSPopover` with a fixed `contentSize`.** Today’s popover is a single `PopoverContentView` sized 320×600. Pushing the classic view as a destination will not resize the popover; it will clip or scroll badly. Stage B should be an enum on one view (`roster` / `account(id)`), not a NavigationLink into the current body.
- **`createContentViewController() -> NSHostingController<PopoverContentView>`** (~593) cannot grow a `DashboardView` without a type eraser (`NSViewController` / `AnyView`). Budget for that in the Stage B line count.
- **Same-button dismiss** (`togglePopover` ~792–805): one segment per provider is a *fit* — a re-click on the Claude tile dismisses, which is what you want for a dashboard. Do not reintroduce per-account segments in fleet mode just to preserve tile-to-account click; the navigator/dashboard owns that.

D2 later, if the detached HUD is genuinely too small for 30+ accounts. Not now.

---

## 4. Implementation risk against this codebase

The composite pipeline is a skip-not-replace machine with a hard “never change the item set on a repaint” rule. The staged plan as written walks into that machinery in five places.

### 4.1 `paintTiles` + `assembleComposites` will paint 600 pt of tiles *and* the dots, or skip the dots entirely

`paintTiles` (~989–1282) renders **every** `isSelectedForDisplay` profile into `tileImages` and bumps `tileImageSeq`. `assembleComposites` (~1300–1386) concatenates **every** member of `compositePaintOrder` for that provider. `CompositeKey` is `(members, seqs, isTemplate, scaleQ)` — equal ⇒ no redraw.

If Stage A only wraps the existing composite with a dots image, you still have a 488 pt Claude item. If Stage A paints only the active tile but leaves `CompositeKey` as-is, a readiness change on a *non-active* member does not bump any seq → **stale dots until the active account’s 0.1 % tick**. That is the same class of bug as the suspected-tint skip (`TileRenderKey.isSuspected` exists specifically because skip-not-replace left the previous tint on screen, 169–171).

**Do this instead:**

- Keep `paintTiles` able to render any profile (classic layout; dashboard rows can reuse the images later).
- In fleet mode, **do not** put non-active tiles into the composite. Build one summary `NSImage` per provider from the active tile + fleet block.
- New memo, not `TileRenderKey` / `CompositeKey` reuse:

```text
SummaryKey = activeSeq + [(id, readiness, isStale)] + affix + verdict
           + alert + armed + layout + scaleQ + isTemplate
```

`TileRenderKey` already embeds the whole `MultiProfileDisplayConfig` (so `barLayout` flips correctly miss the cache). That is necessary but not sufficient: member readiness is not on the key.

### 4.2 One click segment will empty the popover navigator

`groupSegments` is the source of truth for:

- click routing (`profileId(for:atX:)`, ~1522)
- popover anchoring (`anchorRect`, ~1559)
- **painted order** (`paintedGroupMembers`, ~1587) which `PopoverContentView.groupMembers` uses so chip N means tile N (`CompositeTileLayoutTests` “navigator follows the painted order”, audit M10)

The brief: “ONE summary tile with ONE click segment (the active account).” After that, `paintedGroupMembers` returns `[activeId]`. The classic popover’s ‹ › walk and the dashboard roster, if they keep that helper, show one account.

**Do this instead:** split the two arrays that today happen to be the same:

- `groupSegments` — clickable ranges. Fleet mode: one range `0..<totalWidth` → the provider’s active id (already the ambiguous-click fallback, ~1532–1533).
- `groupPaintOrder[provider]: [UUID]` — every selected member, left-to-right, updated every assemble, **independent of segments**. Navigator + dashboard + Stage A tests (“dot order = painted order”) read this.

Pointer mapping stays. Scene-hosted buttons still synthesize the event at the centre (`pointerLocalX`, comments at 1502–1511); with one segment that trap becomes harmless.

### 4.3 `strandedTileDetected` does not run in composite mode at all

Look at `updateMultiProfileButtons` ~869–910: the composite branch paints and **returns**. `strandedTileDetected` (~734–803) only runs in the `CUW_SEPARATE_TILES=1` else-leg. It also iterates `multiProfileStatusItems`, which is empty in composite mode (audit H7). Stage C cannot “gain a composite branch” inside that function without first **calling it** from the composite path.

Worse: if you naively reuse `layoutDivergesFromCreationOrder` on three group windows, a hidden Codex parked at x=1701 with Grok at x=1400 **looks stranded**. The heal path then `setupMultiProfile(forceRecreate: true)` — the exact CAContext leak the composite exists to avoid, rate-limited to two rebuilds per launch (705–711) and then only a log. Overflow must never enter the heal-rebuild path.

### 4.4 `predictedNextCandidate` is the right seam; do not call `peekQueuedSwitchTarget` from paint

`peekQueuedSwitchTarget` (~3415 in the earlier shape; `selectQueuedSwitchTarget` now) **writes the queue** when it drops deleted ids. A 30 s paint that peeks would persist. The in-progress `predictedNextCandidate` (~3426) already uses `selectQueuedSwitchTarget` and discards `cleaned` — keep it that way. Tests should pin: paint does not call `saveAutoSwitchQueue`.

`findNextAvailableProfile` logs per skipped candidate unless `quiet: true`. Paint must stay on the quiet path or a 22-account sweep doubles the auto-switch log.

`predictedNextCandidate` excludes provider-actives. Good (the walk is `after currentProfile`). Preflight of a candidate that *is* the provider-active now records `.ownsLogin` (~3278) — good.

### 4.5 `preflightVerdicts` as `@Published` will rebuild the popover hosting tree every milestone

`MenuBarManager` is an `ObservableObject`. The popover’s `PopoverContentView` is `@ObservedObject var manager`. Publishing a verdict dictionary every 25/50/75/90 % rebuilds the whole SwiftUI tree while the popover is open. Fine if small; Stage B’s 18-row dashboard will not be. Write verdicts without `objectWillChange` if the bar is the only consumer, or isolate a `FleetSummaryContext` snapshot that `StatusBarUIManager` holds by value.

`FleetSummaryContext.isLoginDead` / `isExcluded` are closures. They cannot go in a `Hashable` render key. Precompute `[UUID: AccountReadiness]` (and the stale set) on the manager side, once per paint, and pass that. `ProfileCredentialStatusCache` is the right dead predicate (no Keychain, hydration-aware). Do not parse credential JSON on the paint path beyond what the cache already did.

### 4.6 `MultiProfileDisplayConfig` decode is the one part of Stage A I would ship as written

Custom decoder, `decodeIfPresent` / `try?` → `.everyAccount` (419–421). Matches every other field on that struct (`useSystemColor`, `showTimeMarker`, …). Rollback is “Every account” in Settings. The Settings picker already exists (`ManageProfilesView.swift` 156–186) and correctly posts a **cosmetics** change — provider item set is unchanged. Combined Option C as a layout enum case would be a **structure** change (item count) and must not ride this picker.

Missing: `MenuBarConfigDecodeCompatTests` does not yet cover `barLayout` absent / unknown. That test belongs in Stage A (the brief listed it) and is cheap.

### 4.7 Line budget: Stage A as specified does not fit

Already in the tree, before a working paint path: `FleetSummary.swift` ~430 lines, `MenuBarSummaryRenderer.swift` ~157, config + strings + Settings picker, `predictedNextCandidate` + context + verdict writes. Wiring `StatusBarUIManager` properly (summary key, paint branch, segment/order split) is another 150–250. Tests on top.

**Split Stage A:**

- **A1 (≤600):** `AccountReadiness` / `ProviderSummary` / geometry, tests (precedence, arming on *measured* %, dot order = paint order including wrap, affix rules, width budget, config decode). No AppKit paint. The renderer can live here as lockFocus-free functions tested via bitmap fixtures, or wait.
- **A2 (≤600):** `StatusBarUIManager` paint/assemble/click + `MenuBarManager` context + Settings already done. Tests: `SummaryKey` miss on readiness change; one segment covers `0..<width`; `paintedGroupMembers` still returns all ids.

Do not put dashboard types in A. Do not put overflow in A.

### 4.8 Renderer details that will look wrong on the real bar

- `createFleetDots` / `createProviderSummaryTile` use `NSImage.lockFocus`. `assembleComposites` abandoned lockFocus because it follows the **main screen** scale, not the menu-bar display (1391–1397). Draw the summary into the same `NSBitmapImageRep` path as `compositeImage`, or the fleet block will be soft on a non-main menu bar and the TIFF guard will flap.
- `opaqueEventShapeBackdrop` must cover the **full** summary width (active + affix slot + gap + fleet). Gaps in alpha make the event shape a comb; that was a real click-routing bug and is why `applyEventShapeBackdrop` exists (688–694).
- `createProviderSummaryTile` currently sizes the affix to text metrics (grows/shrinks). Even after A1 reserves 36 pt, the renderer must draw into that slot, not add `affixSize.width`.

### 4.9 `ProfileManager` / switch cost

`activateProfile` is the only mutation the dashboard’s “Make active…” should call (dead-login gate, adoption, `SwitchEvent`). Do not add a second path. Confirm UI must use `activateProfileDetailed` so a `credentialsRefused` does not look like a no-op (the walk already maps that via `walkReaction`).

---

## 5. Stage C overflow detection — the proposed rule is not sound

### What the code has actually measured

Per-tile items (`CUW_SEPARATE_TILES=1`):

- Visible tiles have distinct ~27 pt frames.
- Overflow **parks every clipped item at one shared off-edge frame** (comment: four of twelve at `x=1701` on a 1728 pt display) — `containsOverflowParkedTiles` / `overflowParkedProfileIds`.
- `window.frame.minX > 0` is required or the evaluation bails `unmeasurable` (~750).
- Lab census: three window states — never-laid-out `h=0`, parked `y=-33`, on-bar (`HANDOFF-DEEP-DIAGNOSIS-REPORT.md`).

Composite groups: **one window per provider**, tens to hundreds of points wide, created Claude → Grok → Codex. Codex clips first. **A single hidden group does not share minX with anyone.** Duplicate-minX never fires. That is H7.

### Why “overlaps another group OR parked at the right screen edge” fails

- **Overlap with a *visible* group does not happen.** Hidden items overlap *each other* at the parking slot. One hidden group (the common case: Codex gone, Claude+Grok visible) overlaps nothing.
- **“Right screen edge” is also where the clock lives, and where Claude — the rightmost *visible* group — sits.** `x=1701` on one 16" 2x display is a parking stub (~27 pt from `screen.frame.maxX`). Claude at ~81 pt sits hundreds of points left of that, because Control Center / clock / Wi-Fi occupy the trailing edge. On a 14" (1512 pt), a 27" 1x, a notched menu bar, or a secondary display with the bar on it, 1701 is a magic number. `strandedTileDetected` already refuses to judge off-screen / other-display windows.
- **Order-divergence** (Codex.minX > Grok.minX because Codex is parked at 1701) is the *stranded* heuristic. Feeding it to the heal-rebuild path leaks CAContexts and cannot make the item fit.

### Rule I would implement (pure `hiddenGroupProviders`, fixture-tested)

An item is **hidden** if any of these hold. None of them require tearing the item down.

1. **`button.window == nil` or `window.screen == nil`.**
2. **Never laid out:** `window.frame.height < 2` (lab `h=0`).
3. **Parked off the bar:** `window.frame.maxY < screen.frame.maxY - thickness - 8` (lab `y=-33`; menu bar is at the top of `screen.frame`).
4. **Stub / clipped:** `window.frame.width + 1 < statusItem.length * 0.5` **or** `window.frame.maxX > screen.frame.maxX + 4`. A pinned 81 pt item whose window is a ~27 pt stub at the trailing edge is overflow-hidden. A visible Claude item’s window width matches `statusItem.length`.
5. **Duplicate minX among group windows** (the existing per-tile signature), as a belt for “two groups hidden.”

Then: **creation-order x must strictly descend among the *visible* items**. If it doesn’t, that is stranded, not overflow — and in composite mode you still **do not rebuild**; you log. Two heal-rebuilds per launch was the right cap for 14 legacy items; for 3 group items it is not worth a single teardown.

Do **not** set `NSStatusItem.behavior = .removalAllowed` just to read `isVisible`. That opts the item into user-draggable removal / extras overflow and is a behaviour change, not a detector. If you later observe `isVisible` KVO on a machine where the system already flips it without that behaviour, use it as an additional signal, not the definition.

### Degrade ladder, without changing item count

On hidden:

1. Log at default level; dashboard/popover banner; one notification per episode (same shape as inferred-throttle: `inferredThrottleNotifiedIds`).
2. Step **that provider’s effective layout** `fleetDots → fleetCounts → active-only` (24 pt). Same `NSStatusItem`. Length shrinks; macOS may re-show the item. That is the point.
3. Hysteresis: one step per 5 min is fine, but **do not share `lastLayoutHealAt`** with the stranded-heal limiter — different failures. Latch: if a step-up hides again within ~30 s, stay narrow until selected-count or screen change.
4. Never create/destroy items. Never fold into Option C as a fourth/single status item.

H7’s “wrap into a second Codex item” is also a create. Reject it.

---

## 6. Missing from first principles (ranked by value / effort)

| Rank | Item | Why | Effort |
|---|---|---|---|
| 1 | **`NSStatusBarButton.toolTip` and `accessibilityTitle` per group.** The brief says “dot tooltip is not possible.” Per-dot is not; **per-item is** (`button.toolTip = "Claude: Atl 78 % → Fjo verified. 4 ready, 12 exhausted, 1 dead"`). VoiceOver today gets a nameless image. Highest-value line of Stage A after the dots themselves. | S |
| 2 | **Arm / digits on measured usage** (`autoSwitchTriggerUsage`), never `effectiveSessionPercentage`. Otherwise the bar prints a synthetic 100 and announces a switch the walk will not do. | S |
| 3 | **Affix width always reserved, or affix in the fleet label row.** Length jitter at 75 % is an overflow bug. | S |
| 4 | **Right-aligned / column-major dots; weekly-only = one row.** Otherwise “rightmost = next to burn” is a lie the first time Claude has >10 others, i.e. today. | S |
| 5 | **`groupPaintOrder` vs `groupSegments`.** Without it Stage A breaks the popover navigator the tests exist to protect. | S |
| 6 | **`›—` even when not armed**, if eligible others = 0. Live Codex is this shape. | S |
| 7 | **Fable bar on the dashboard ACTIVE block; weekly-only rows without a fake session bar.** The strip cannot show Fable; the click-away surface must. | M |
| 8 | **Right-click / long-press menu on the group item:** “Switch to Fjo (costs ~10–15 % of running sessions)”, “Open dashboard”, “Open Settings”. The expensive action should not require parsing a 380 pt board. `NSStatusItem.menu` is the AppKit seam; watch the same-button-dismiss interaction. | M |
| 9 | **Confirm of “Make active…” must go through `activateProfileDetailed`** and show `credentialsRefused` as “login dead — /login then Sync”, not a silent stay. | M |
| 10 | **Header-rescue and suspected provenance on the dashboard.** | M |
| 11 | **Manual-pin and opt-out chips.** Otherwise the dashboard disagrees with the next sweep. | M |
| 12 | **Stacked providers, not tabs.** | M |
| 13 | **Do not offer fleet layouts for `.concentric` / `.compact` until there is a 24×22 active block for them.** Default `iconStyle` on `MultiProfileDisplayConfig` is still `.concentric`. | S |
| 14 | **Stage C detector as §5, not overlap-or-right-edge; no item-count ladder.** | M |
| 15 | **Shortcut “next profile” stays provider-scoped** (audit M7). A dashboard “next” that walks Codex from Claude rewrites `auth.json` under running sessions. | S (existing bug, don’t make it worse) |
| 16 | **Bartender / Ice / hidden extras.** Third-party movers produce the same parked frames. Banner copy should say “not visible in the menu bar”, not only “overflow”. | S copy |
| 17 | **Notification `didReceive` → dashboard on the dead account** (audit M5). The bar can finally have a place to land. | M, Stage B |

Drop, relative to the brief:

- Alert corner dot (four colours).
- Provider glyph on B.
- Option C as a new `NSStatusItem`.
- 20-dot / 2×10 grid as the counts fallback threshold (use 12, one row, or 2 right-aligned rows).
- `unknown` meaning “stale”.
- `ready` meaning “the only accepted switch target”.
- Dashboard tabs; NavigationLink into `PopoverContentView`; detached panel left at 320 pt.

---

## Consult log (for spec §6.1)

- **Question:** B vs A vs C on a 22 pt strip for 20+ accounts × 3 providers; readiness/affix/alert; D1 vs D2; implementation risk in the composite pipeline; Stage C overflow rule.
- **This review:** B with a stable-width active block, right-aligned dots, measured-only arming, no corner alert; A as degrade only; C as paint-style of the existing three items never as a new item. D1 stacked, not tabbed, Fable-aware, no synthetic 100. Do not rebuild status items. Overflow = stub/off-bar/nil-screen, never “overlaps Claude.”
- **Already-in-tree corrections that should be kept:** `.excluded`, `PreflightVerdict.Kind` / `provesLive`, `activeIsStale` dimming, `isSwitching` affix, decode back-compat for `barLayout`.
- **Already-in-tree defects to fix before A merges:** 3-arg `updateMultiProfileButtons` has no implementation; renderer incomplete vs model; affix slot only while armed; Claude preflight `expiryOnly` when already fresh; `classify` still documented as if `ready` = walk-eligible.