# Menu-bar redesign review

## Overall verdict

**Proceed with B, but not exactly as drawn.** The core product decision is right: one stable status item per provider, with the provider-active account, the next executable handoff, and a compact fleet shape. A is the correct compact fallback. C should be dropped from the automatic ladder.

The brief is directionally strong but not implementation-ready in four places:

1. “Ready” is not equivalent to “the auto-switch would accept this account.”
2. `✓` cannot be derived truthfully from today’s preflight path.
3. The proposed summary cannot be fitted into the existing per-profile `tileImages`/`assembleComposites` pipeline without stale images and incorrect click regions.
4. Stage C’s edge/overlap detector and combined-item fallback are both unsafe.

## 1. Menu-bar choice: B versus A and C

### Verdict by option

| Option | Verdict | Why |
|---|---|---|
| **B: active + fleet dots** | **Best primary design after revision** | Preserves fleet gestalt and ordering while reducing roughly 600 pt to a realistic 175–210 pt. It keeps the owner’s reason for selecting many accounts. |
| **A: active + counts** | **Compact fallback** | More legible than dots under severe pressure, but it loses identity/order and the proposed four count buckets are too dense. |
| **C: combined item** | **Drop** | It is not demonstrably narrower than A, removes the most useful bars, creates all-or-nothing overflow, and conflicts with the persistent three-item architecture. |

### The width estimates need correction

The current active progress tile is exactly 24 pt wide. Claude’s two-bar labelled tile is 22 pt high, but a weekly-only Codex/Grok tile is only 16 pt high because the second bar is omitted in [`createMultiProfileProgressBar`](<Claude Usage/MenuBar/MenuBarIconRenderer.swift:995>).

For B:

- Ten 4 pt dots at 6 pt center pitch occupy `4 + 9×6 = 58 pt`, not 54 pt.
- Seventeen other Claude accounts balanced 9/8 occupy 52 pt.
- Including the existing 1 pt composite padding on each edge, live Claude is therefore `24 + 3 + 52 + 2 = 81 pt`.
- The Codex estimate of 39 pt is true only while no next-candidate string is present. An 8 pt `→Fjo✓` is roughly 28–34 pt; `Q→Fjo✓` is closer to 35–42 pt. Armed Codex therefore becomes roughly 58–71 pt.
- Grok is 26 pt in the current composite geometry, not 24 pt, because [`compositeLayout`](<Claude Usage/MenuBar/StatusBarUIManager.swift:504>) adds two edge points.
- A credible total for B is therefore about **175–200 pt before inter-item/system spacing**, still an excellent reduction from 600 pt.

Option A’s “28 pt” count area is also optimistic. Four dot-plus-two-digit count cells need approximately 34–40 pt per row at the proposed fonts. Option C’s illustrated strings likely exceed 180 pt total. Add renderer tests using `NSString.size(withAttributes:)` with the real fonts; do not approve budgets from character counts.

### Recommended B geometry

Keep the existing active image pixel-for-pixel and compose a right-hand information block:

```text
┌────────┬──────────────────────┐
│ active │  fleet dots, 1–2 rows│
│ 24×22  │  →Fjo✓ / Q→Fjo?      │
└────────┴──────────────────────┘
          3 pt gutter
```

- Active block: the existing 24 pt rendered tile.
- Fleet dots: 4 pt diameter, 6 pt pitch, balanced across two rows to minimize width.
- Bottom-right row: the next-candidate string, separate from the active account label. Do not stretch or overwrite the existing label.
- Right-block width: `max(dotMatrixWidth, measuredAffixWidth)`.
- Keep provider width fixed for a given roster/layout. Crossing 75% should repaint pixels, not move every neighboring menu item.
- Draw weekly-only providers as their existing single weekly gauge, vertically centered. Do not imply that the first and second dot rows represent session and weekly state; a thin 3 pt gutter and separation from the active block are important.
- Add a small provider identifier or vetted monochrome mark. If text is used, prefer 7 pt `Cl`, `Cx`, `Gk`; avoid `C/X/G`, where X is ambiguous between Codex and xAI.
- Preserve B for up to 20 “other” accounts, then use `+N` after the final visible dot rather than switching the whole provider to counts at account 21. A discontinuous representation change at 20/21 makes the bar unstable.

The dots should represent the **provider’s switch-relevant fleet**, not merely `isSelectedForDisplay`. Today the switch resolver considers all profiles, while [`multiProfileCreationOrder`](<Claude Usage/MenuBar/StatusBarUIManager.swift:417>) and group creation filter selected profiles. Otherwise the bar can show twelve ready accounts while the actual next candidate is an unrepresented thirteenth account. In fleet layouts, always include the provider-active and predicted-next accounts even if deselected; keep `isSelectedForDisplay` as the legacy every-account filter.

### A and C

For A, show only:

- usable/fresh count, such as `●12`;
- blocked-or-unknown count, such as `!4`;
- the same next-candidate row.

Do not combine `exhausted + low` under one triangle: one is unusable, the other remains usable. Likewise, `suspected + unknown` merges two materially different conditions.

Drop C as the fallback. The safer ladder is:

```text
fleet dots → fleet counts → per-provider compact
```

The final rung should still retain three persistent provider items, for example provider mark + primary gauge/value + next-state glyph. Do not consolidate three items into one at runtime.

## 2. Readiness taxonomy, affix, and alert

### The taxonomy conflates three independent axes

A single `dead/suspected/exhausted/low/unknown/ready` enum mixes:

1. **Operability:** login live, dead, missing, excluded, owner unknown.
2. **Capacity:** ready, low, confirmed exhausted.
3. **Evidence quality:** fresh measurement, stale, unknown, suspected inference.

That creates several wrong encodings:

- `ready` ignores `Profile.isAutoSwitchEnabled`, Claude free-plan exclusion, missing credentials, credential hydration, and queue-specific behavior. [`findNextAvailableProfile`](<Claude Usage/MenuBar/MenuBarManager.swift:3330>) checks some of these separately.
- No cached usage is treated as candidate headroom by [`hasSessionHeadroom`](<Claude Usage/MenuBar/MenuBarManager.swift:3506>), but that is uncertainty, not green readiness.
- The proposed 60-minute stale boundary conflicts with the actual switch path, which considers Claude candidate data stale after **three minutes** and tries to refresh it before switching.
- `suspected` currently outranks confirmed weekly/Fable exhaustion in the proposed table. A hard measured exhaustion should not disappear because the session endpoint is also suspect. The existing tile precedence correctly gives weekly-maxed red priority over suspected purple.
- A selected profile with no usable credentials is neither “unknown usage” nor necessarily “dead login.”
- Auto-switch-disabled accounts need a visible neutral/excluded state; otherwise the green fleet count overstates usable capacity.

Use a small pure snapshot with separate fields, for example:

```swift
struct AccountState {
    var operability: Operability       // live, dead, missing, excluded, unknown
    var capacity: Capacity             // ready, low, exhausted, unknown
    var evidence: Evidence             // measured, headerMeasured, stale, suspected
}
```

For a single dot, use this precedence:

```text
dead/missing → confirmed exhausted → suspected → stale/unknown → low → ready
```

But preserve orthogonal facts in shape:

- solid green/orange/red: measured capacity;
- purple fill or rim: suspected data quality;
- gray hollow ring: unknown/stale;
- orange/red ×: dead login;
- dim dash: intentionally excluded.

A 4 pt hollow gray circle is too easy to confuse with unknown and too quiet for “requires `/login`.” Dead should be visibly actionable.

### `›Fjo✓`

**Keep the next-candidate concept; change its semantics and notation.**

Use:

- `→Fjo` — ranked candidate;
- `Q→Fjo` — queued candidate;
- `✓` — definitive positive login evidence;
- `?` — untested, expired verdict, or inconclusive network result;
- `×` — definitively dead;
- `→—` — no executable candidate.

`Q→` is more legible than distinguishing `›` from `»` at 8 pt.

The candidate label’s tint should describe quota evidence:

- green: fresh measured headroom;
- orange: measured but near threshold;
- gray: stale or no quota measurement;
- red: no executable candidate.

The suffix should describe login evidence. This allows `→Fjo✓` with a gray candidate label: login verified, quota headroom stale.

Today’s code cannot truthfully issue the proposed checkmark:

- Codex’s [`isSafeToApplyLogin`](<Claude Usage/Shared/Services/CodexUsageService.swift:607>) returns `true` for an inconclusive probe when no dead flag exists. “Safe under uncertainty” is not “verified live.”
- Claude preflight mainly verifies token expiry/refreshability, not positive account authorization.
- Grok preflight verifies expiry after refresh, not billing-endpoint liveness.
- Claude session-key-only candidates fall through with `alive = true` without any OAuth preflight.
- A candidate that already owns the provider login returns “OK” without creating a fresh verdict timestamp.
- Preflight does not establish fresh quota headroom; it only starts from the cached candidate ranking.

Publish the actual evidence type, not a Boolean:

```swift
enum LoginVerdict {
    case live(at: Date, source: EvidenceSource)
    case dead(at: Date, reason: DeadReason)
    case inconclusive(at: Date, reason: InconclusiveReason)
    case untested
}
```

Tie it to credential revision/account identity so a token rotation invalidates the verdict. Thirty minutes is also too broad for every provider; use the underlying evidence TTL, including Codex’s current five-minute positive-success cache.

The queue needs two outputs: the first queued entry and the first executable target. [`selectQueuedSwitchTarget`](<Claude Usage/MenuBar/MenuBarManager.swift:3392>) skips blocked queued entries but leaves them queued. Showing a ranked fallback without indicating `queue head blocked` would misrepresent the user’s plan.

### Alert dot

Drop the generic 3 pt alert dot in its current form.

- `noCandidate` is already conveyed more clearly by red `→—`.
- Dead logins are already fleet marks.
- Suspected and stale should show evidence age.
- Repeating the global cfprefsd state once per provider is noise.
- A 3 pt red/orange dot overlaps the same visual vocabulary as usage and pace markers.

If a residual alert remains, make it a single 5 pt `!`/diamond on the rightmost persistent provider item. Use it only for global conditions such as cfprefsd degradation or an untracked provider owner. Its accessible label/tooltip should contain the real condition.

The current B also fails to show suspected age on the bar. At minimum, preserve the measured bar fill and add a purple age such as `12m`; the dashboard can provide the exact measured value, timestamp, and projection.

## 3. Dashboard: D1 versus D2

**Choose D1 for the first release.** A provider-scoped popover is the correct default for a glance-and-act menu-bar agent. D2 becomes useful only when this evolves into historical analysis, bulk management, or a genuinely sortable 50+ account table.

“Detachable at zero extra window-management cost” is overstated, however. The app already has the lifecycle, but the current detached panel is hard-coded to 320×600 and creates a fresh controller in [`detachableWindow`](<Claude Usage/MenuBar/MenuBarManager.swift:3631>). The current root is fixed to 280 pt in [`PopoverContentView`](<Claude Usage/MenuBar/PopoverContentView.swift:151>), while `ensurePopover` uses the shared 320×600 constant. Dashboard and classic sizes must be independent.

### What D1 must add

The dashboard’s top section should answer:

- Which account actually owns this provider’s CLI login?
- Is that different from the focused/viewed profile?
- Is auto-switch enabled, manually suppressed, or currently in flight?
- Which quota window triggers this provider: Claude session/weekly/Fable versus Codex/Grok weekly?
- What is the next **executable** target?
- Is it queued or ranked?
- Is the queue head blocked, and why?
- What exactly did preflight prove, from which source, and how old is that evidence?
- How old is the quota measurement separately from the login verdict?
- What will happen at the configured threshold?
- Is the provider owner untracked or deselected?
- Is this provider hidden because of menu-bar overflow?

The roster should show, in two lines if necessary:

- account label/name;
- provider-active, queued position, or excluded marker;
- primary capacity and reset;
- secondary/Fable capacity only when applicable;
- measurement age/provenance;
- dead/missing-login remediation;
- explicit blocker reason such as “auto-switch disabled,” “free plan,” “login dead,” or “quota unknown.”

At 380 pt, the illustrated one-line row containing label, two bars, two percentages, Fable, reset time, and state chip will not fit legibly. Use a compact first line and a secondary metrics line, or reveal secondary windows on expansion.

Recent switches should include provider, trigger, measured reason, and whether the switch actually completed. Keep the section collapsed by default.

The cfprefsd banner must remain first, but do not reproduce the current `else-if` behavior where it suppresses every other problem. Show the degradation banner, then a compact health summary for dead logins, no candidate, or overflow.

### What it should not show

- Raw tokens, account IDs, credential JSON, or full emails by default.
- Every model window on every collapsed row.
- Pace markers and time ticks in every roster row.
- Speculative switch times presented as promises.
- A projected number without the purple suspected provenance.
- Full queue editing, credential operations, thresholds, or notification settings.
- A one-click “Make active” without a confirmation that switching costs approximately 10–15% across running sessions.

The classic detail should be extracted into a reusable account-detail component. Embedding the entire current `PopoverContentView` under a back chevron would duplicate its header, navigator, fixed width, and profile switcher.

## 4. Implementation risks in this codebase

### Do not duplicate the switch resolver

The brief says the ranking is “already static,” but only [`rankAutoSwitchCandidates`](<Claude Usage/MenuBar/MenuBarManager.swift:3487>) is pure. Candidate selection also depends on:

- provider;
- per-profile eligibility;
- free-plan exclusion;
- three headroom checks;
- queue semantics;
- reset rollover;
- exclusions from the current walk.

Do not add a second `predictedNextCandidate(for:)` implementation. Extract one pure `AutoSwitchPlan.resolve(snapshot:)` that returns:

```text
queue head
queue-head blocker
executable target
source: queued/ranked
headroom evidence and age
login verdict
other blocked candidates
```

Use that same result in [`checkAutoSwitchIfNeeded`](<Claude Usage/MenuBar/MenuBarManager.swift:2913>), [`preflightCandidates`](<Claude Usage/MenuBar/MenuBarManager.swift:3246>), the bar, and dashboard.

Queue writes currently have no notification or publisher: `ManageProfilesView` saves directly into `SharedDataStore`. The bar affix and an open dashboard will otherwise remain stale until an unrelated sweep. Add a typed queue/threshold-change notification or an observable switch-plan store.

### Build a separate provider-summary render pipeline

Do not represent the summary as one active-profile image inside the existing `tileImages` dictionary.

[`paintTiles`](<Claude Usage/MenuBar/StatusBarUIManager.swift:989>) and [`assembleComposites`](<Claude Usage/MenuBar/StatusBarUIManager.swift:1300>) assume:

- one image per selected profile;
- membership derived from all selected profiles;
- one sequence number per tile;
- one click segment per member.

If summary mode stores only the active image, old non-active `tileImages` remain because `pruneTileState` keeps all selected IDs. They can reappear in the composite. Segment and anchor state can likewise remain stale.

Add independent state keyed by provider:

```text
summaryImages
summaryRenderKeys
summaryImageSeq
summaryClickTargets
```

Branch before `paintTiles`, and let summary mode assign one provider image and one full-width click target explicitly. Clear `groupSegments`, `groupCompositeSize`, and the correct memo when switching layouts.

The summary render key must include only discrete visible inputs:

- active ID and active render key;
- ordered member state/shape vector;
- executable candidate/source/verdict;
- global/provider alert;
- appearance and backing scale.

Do not include raw `Date()` or every age second. Quantize only displayed age buckets. Also keep `clickSurface` out of the image render key; changing dashboard versus classic should not redraw status images.

A separate-file extension of `MenuBarIconRenderer` cannot use that file’s `private` drawing helpers. The simplest pixel-stable composition is to render the existing active tile unchanged, then draw the dots/affix beside that image on a new full-canvas bitmap using the same backing-scale and event-shape rules.

### Preserve status items and stable widths

A bar-layout setting must travel through [`handleDisplayCosmeticsChange`](<Claude Usage/MenuBar/MenuBarManager.swift:1103>), never the structural setup path.

The current composite branch still recreates every provider item when the provider set changes in [`updateMultiProfileButtons`](<Claude Usage/MenuBar/StatusBarUIManager.swift:869>). Stage A should not add another path through `setupMultiProfile` or `cleanup`.

Likewise, do not implement C by removing two `groupItems`. If an ultra-compact combined drawing is ever retained, it must be rendered into an already-existing host while the other persistent items remain allocated. The better answer is the per-provider compact rung.

Reserve stable summary width across readiness and affix changes. [`assembleComposites`](<Claude Usage/MenuBar/StatusBarUIManager.swift:1380>) changes `statusItem.length` whenever image width changes; this does not leak a CAContext, but it does relayout the bar at exactly the moment an account becomes critical.

### Active account and selection are not the same thing

[`ProfileManager`](<Claude Usage/Shared/Services/ProfileManager.swift:22>) distinguishes focused profile from provider-active Claude and Codex owners. The summary must use the provider owner, not `activeProfile`.

If the provider-active account is deselected, the existing renderer omits it because [`groupActiveIds`](<Claude Usage/MenuBar/StatusBarUIManager.swift:1021>) is built only from selected profiles. A fleet summary whose active block disappears is a fatal semantic failure. Include it regardless of display selection or render a prominent “owner hidden/untracked” state.

Add `clickedProvider` separately from `clickedProfileId`. Stage B must be able to open a provider dashboard even if there is no valid active profile to use as a fake click segment.

Grok also lacks a persisted provider-active pointer, and `ProfileManager.activateProfileDetailed` has no Grok auth-file apply branch. With the current single Grok profile that is harmless; do not expose multi-Grok “Make active,” queue, or auto-switch behavior as if it changed the Grok CLI login until that seam exists.

### Configuration and popover hosting

Adding `barLayout` via `decodeIfPresent(... ) ?? .everyAccount` is correct. For Stage B:

```swift
clickSurface =
    decodeIfPresent(...)
    ?? (barLayout == .everyAccount ? .classic : .dashboard)
```

Keep the existing custom defaults for older `showPaceMarker` and `usePaceColoring`; do not accidentally replace the custom decoder with synthesized decoding.

[`createContentViewController`](<Claude Usage/MenuBar/MenuBarManager.swift:587>) currently returns `NSHostingController<PopoverContentView>`. Selecting between two unrelated roots requires `NSViewController`, `NSHostingController<AnyView>`, or a shared enum-backed root view.

Use one dashboard model for the lifetime of an open surface. Detachment currently constructs a new controller, so provider tab, route, expanded rows, and scroll state will otherwise reset when the popover becomes a panel.

### Test discipline

Follow the existing pure-function style in [`CompositeTileLayoutTests`](<Claude UsageTests/CompositeTileLayoutTests.swift:1>). The highest-value tests are:

- active-but-deselected account;
- excluded/free/missing-credential states;
- confirmed weekly exhaustion plus suspected session;
- weekly-only provider;
- no cache versus stale cache;
- blocked queue head plus executable fallback;
- inconclusive preflight versus positive liveness;
- fixed width before/after 75%;
- dot order and overflow `+N`;
- backward config decoding.

Keep defaults isolated; this repository has prior history of tests contaminating the production `profiles_v3` domain.

## 5. Stage C overflow detection

The proposed rule is **not sound**.

- “Overlaps another group” detects only some duplicate parking cases. A single hidden Codex group can overlap another app’s status item while none of this app’s three frames overlap.
- “Parked at the right screen edge” will false-positive the legitimate rightmost provider group.
- `1701` is an observation from one 1728 pt screen, not an invariant across displays, notches, scaling, menu-bar placement, Spaces, or auto-hide.
- A hidden item may retain a stale plausible frame rather than move to the observed parking slot.
- `NSStatusItem.isVisible` cannot solve this: Apple explicitly says it remains true when an item is temporarily hidden because the menu bar lacks space. [Apple documentation](https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible?changes=l_8)
- `NSWindow.occlusionState` is only supporting evidence: Apple notes it can call a window visible when merely part of its bounding box is exposed, including transparent windows. [Apple documentation](https://developer.apple.com/documentation/appkit/nswindow/occlusionstate-swift.struct?language=objc)

### Better detector: screen-point hit testing

For each provider button:

1. Convert three interior points—25%, 50%, and 75% of button width at mid-height—from button coordinates to screen coordinates.
2. At each point call `NSWindow.windowNumber(at:belowWindowWithWindowNumber: 0)`.
3. The provider is exposed if at least one point resolves to its own `window.windowNumber`.
4. Treat absent window/screen, screen transitions, menu tracking, or unsettled geometry as `unknown`, not hidden.

Apple defines that API as returning the frontmost window that would receive a mouse-down at the screen point. [Apple documentation](https://developer.apple.com/documentation/appkit/nswindow/windownumber%28at%3Abelowwindowwithwindownumber%3A%29?changes=_9)

This codebase is unusually well-suited to that probe: [`applyEventShapeBackdrop`](<Claude Usage/MenuBar/MenuBarIconRenderer.swift:688>) deliberately gives the entire composite a nontransparent event shape. Interior hit tests should therefore resolve across gaps as well as drawn pixels.

Use the existing duplicate-frame signature only as secondary evidence. Avoid `CGWindowListCopyWindowInfo` in the 30-second sweep unless profiling proves it cheap; Apple describes full window-list dictionary generation as relatively expensive. [Apple documentation](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo%28_%3A_%3A%29?language=_5)

Operational rules:

- Sample only after AppKit has completed the length/image update—next run-loop turn or the next sweep.
- Require two consecutive hidden verdicts before banner/notification/degrade.
- Require several consecutive visible verdicts before clearing.
- Log window number, frame, screen ID, sampled points, and returned window IDs.
- Validate with an intentional oversized composite on notch/non-notch, multiple displays, menu auto-hide, fullscreen, and menu-open states.
- Degrade monotonically for the current screen configuration. Reset upward on screen-parameter change or through a deliberate later probe; “visible in counts, therefore immediately try dots again” creates a five-minute dots/counts oscillation.
- Notify once per hidden episode.

Merely adding a branch inside `strandedTileDetected` is insufficient: the composite path returns at line 910 and never invokes that function. The exposure probe must be called from the composite branch of [`updateMultiProfileButtons`](<Claude Usage/MenuBar/StatusBarUIManager.swift:851>) and publish hidden providers back through a delegate/observable state for the dashboard.

## 6. Missing items, ranked by value and effort

| Priority | Addition | Value | Effort |
|---|---|---:|---:|
| 1 | One shared `AutoSwitchPlan` resolver used by execution and UI | Very high | Medium |
| 2 | Separate login, capacity, and evidence axes | Very high | Medium |
| 3 | Include active/next candidates independent of display selection | Very high | Low–medium |
| 4 | Truthful preflight evidence with revision-based invalidation | Very high | Medium |
| 5 | Fixed-width, real-font layout measurements | High | Low |
| 6 | Surface auto-switch suppression and blocked queue heads | High | Low–medium |
| 7 | Provider-owner missing/untracked state | High | Low |
| 8 | Replace combined fallback with three compact persistent items | High | Low |
| 9 | Accessibility shapes plus full status-item accessibility labels | Medium–high | Low |
| 10 | Grok shared-login ownership/application before multi-Grok controls | High when roster grows | Medium |
| 11 | Failed-switch/preflight history, not only completed switches | Medium | Medium |
| 12 | Overflow lab fixtures and cross-display verification | Medium | Medium |

The staged order remains sensible, but scope should be tightened:

- **Stage A:** shared switch-plan semantics, corrected state model, B/A rendering, stable widths, config compatibility.
- **Stage B:** read-only dashboard plus confirmed switch/queue actions, with a reusable classic detail component.
- **Stage C:** hit-test-based provider exposure, banner/episode notification, and `dots → counts → provider-compact` degradation.

I would mark the brief **“approve direction, revise before implementation.”** B and D1 are the correct product choices; the revisions above are chiefly about ensuring that the UI never claims stronger evidence than the switching engine actually has and never regresses the status-item lifetime invariant.

Review was read-only against `5580649`; no build or tests were run.

