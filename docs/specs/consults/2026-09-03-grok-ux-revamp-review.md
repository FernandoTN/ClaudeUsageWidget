# Grok 4.6 (xhigh, advisory, read-only) — UX revamp proposal review, 2026-09-03

I'll start by reading the proposal, the sibling redesign, and the engineering ground truth, then check the cited code against the claimed model.The spec is in. Next I’ll trace how `activeProfile` actually drives CLI decisions, then check selector, inspector, and Settings surfaces against the code.I’ve confirmed `activeProfile` is used widely. Next I’ll read the activation, setup, and preference-key paths that the proposal depends on.**Approve with revisions.** The two-concept cut is right and S2a/I1 are the right surfaces. Do not ship Viewing-as-`activeProfileId` until `activeProfile` stops being treated as CLI authority — that is still the live model in several decision paths. Kill `autosaveName`, keep the selector item outside `StatusBarUIManager`’s teardown, and do not copy Login-tab Sync onto a viewed non-owner.

The three changes that matter:

1. **`activateProfileDetailed`’s `.alreadyActive` and the auto-switch trigger still key off `activeProfile`.** Free viewing without those seams will no-op “Make active” and can rotate the CLI off the real owner.
2. **Selector item: no `autosaveName`; create-once outside group cleanup; S2b must not create/destroy items; NSAlert after `Task` needs `activateIgnoringOtherApps`.**
3. **Inspector Login Sync on a viewed non-owner is the 2026-09-03 contamination path.** Gate it. Widen the window. Auto-switch must not steal Viewing.

---

## 1. Two-concept model

Yes — Viewing vs Active-for-‹provider› is the right cut. It matches the owner’s ask and the code’s already-split pointers (`activeClaudeProfileId` / `activeCodexProfileId` vs `activeProfile`). Keep `activeProfileId` as persisted Viewing **only after** the CLI-authority fallbacks die. Today several paths still treat focus as “the account in use”:

**Hard blockers (Viewing is not safe yet):**

```356:359:Claude Usage/Shared/Services/ProfileManager.swift
        if activeProfile?.id == id {
            LoggingService.shared.log("Profile already active: \(profile.name)")
            return .alreadyActive
        }
```

“Make active for Claude” on the account you are already viewing returns `.alreadyActive` and **never applies**, even when that account is not the Claude owner. §5.3 waves at “the `.alreadyActive` fix”; it is not in the requested seams. It has to land **with** `viewProfile`, before any selector/inspector “Make active” row.

```1574:1578:Claude Usage/MenuBar/MenuBarManager.swift
                        if profile.id == self.profileManager.activeProfile?.id
                            || profile.id == self.profileManager.activeClaudeProfileId
                            || profile.id == self.profileManager.activeCodexProfileId {
                            self.checkAutoSwitchIfNeeded(usage: newUsage, currentProfile: profile)
```

`checkAutoSwitchIfNeeded` rotates **away from `currentProfile`**. Once Viewing is a random roster row, a sweep of that row can switch the CLI off the real owner. Trigger + preflight must use **only** the provider-active ids.

**Same fallback, same class of bug** (`activeClaudeProfileId ?? activeProfile?.id` or Grok = focus):

| Path | File:line | What breaks once Viewing moves |
|---|---|---|
| System-Keychain usage fallback | `MenuBarManager.swift:1778` | paints the shared login’s usage onto the viewed account |
| `ensureFreshCredentials(adoptSystemKeychain:)` | `MenuBarManager.swift:2280` | adopts the active Claude token into the viewed profile |
| Header-rescue probe | `MenuBarManager.swift:2725-2726` | spends quota against the wrong account |
| Dead-login fetch skip (Claude) | `MenuBarManager.swift:2397-2398` | |
| Dead-login skip (Grok) | `MenuBarManager.swift:2408-2410` | Grok “active” = focus |
| `activeAccountIds` Grok | `ProfileManager.swift:728-737` | cyan Grok tile follows Viewing |
| Claude pointer inference | `ProfileManager.swift:1270-1272` | nil Claude pointer ← focused CLI profile |
| Outgoing Codex owner | `ProfileManager.swift:1471` | focused Codex profile as last fallback |
| Sweep priority | `MenuBarManager.swift:1351` | viewing steals a Claude fetch slot (this one is actually desirable — keep it, but stop using it as an *owner* test) |
| Single-mode bar | `StatusBarUIManager.swift:1979`, `MenuBarManager.swift:190` | bar shows Viewing, not the CLI |
| Sweep timer | `MenuBarManager.swift:983` | viewing a 60 s profile slows the whole sweep |
| `$activeProfile` observer | `MenuBarManager.swift:431-456` → `handleProfileSwitch:464-502` | every Viewing change rebuilds the bar (single), **destroys the popover**, kicks a refresh |

`handleProfileSwitch` is the other half of the `viewProfile` seam. There is already a **different** `MenuBarManager.viewProfile` (`MenuBarManager.swift:681-691`) that only sets `clickedProfileId` and is documented *not* to tear the popover down. Do not unify that with persisted Viewing. Tile-click / ‹ › navigator stay ephemeral (`clickedProfileId`). Inspector / hotkey / selector “View X” persist `activeProfileId`. Writing the journaled single-shot key on every arrow-key step is a cfprefsd footgun.

**R1–R5:** right direction, not complete.

- **R1** is missing Manual Sync (`CLIAccountView.swift:264-291`, `CodexAccountView.swift:301-317`) — copies the *shared* login into the viewed profile and `claimActive*Ownership`. Wizard (`SetupWizardView.swift:109-115`) is the same. Identity adoption is covered by “CLI-side login”; Sync is not.
- **R2** is false until the table above is gone. Also `activateProfileDetailed` still posts `.profileManuallyActivated` and records a `SwitchEvent` **before** returning `.focusedWithoutApplying` (`ProfileManager.swift:596-616`). `viewProfile` must not go through that function.
- **R3** caption is the right UI. Cyan already means provider-active (`activeAccountIds`); keep it that way. Grok is the exception until the pointer exists.
- **R4** yes, once viewing is focus-only. Today a user click still runs the gate and may notify.
- **R5** yes — `ClaudeUsage.provenance` is already `.ownEndpoint` / `.headerRescue` / `.cliCache` (`ClaudeUsage.swift:281-290`). The selector mock’s `"own · 28 s ago"` is weaker than `DashboardFormatting.provenance` (`DashboardView.swift:89-95`). Use that. Blind window = age + provenance, never a live-looking number.

**What still confuses a 30-account operator:** three actives plus Viewing (four pointers); duplicate pairs that look like two quotas; a global `autoSwitchQueue` mixing providers; single-profile mode where the bar is Viewing, not the CLI; Grok still focus-as-active until D8 lands. The caption in R3 is the antidote — put it on the inspector header, selector, dashboard, and popover, not only one of them.

Keeping the key is fine. Treating the *value* as CLI authority is not.

---

## 2. Selector surface

**S2a is the right default.** S1 is correctly deferred (synthesized-center clicks). S3 as the *only* selector would re-merge switching into the viewing surface. S2b as a setting is fine **only if it does not change the `NSStatusItem` count at runtime** (macOS 27 CAContext leak). Pre-create three items and hide two, or require a relaunch. 54 extra points buy nothing the fleet tiles don’t already show; keep S2b off by default.

**(a) `NSStatusItem.menu` + `menuNeedsUpdate`:** sound, if the snapshot is **precomputed on the sweep** (`ProviderActiveSelection.build` from the same inputs as the dashboard). `menuNeedsUpdate` must be a map from snapshot → items, no ranking, no Keychain, no `predictedNextCandidate` from scratch (that function is side-effect free — `MenuBarManager.swift:3580` — but it still walks the roster). Set `autoenablesItems = false` or the disabled owner/duplicate rows will fight AppKit. `isAlternate` ⌥ rows work if each alternate immediately follows its primary. Attributed titles are fine on 14+. 25-row submenus scroll. Do **not** set both `statusItem.menu` and `button.action` — `menu` steals left-click; that is what you want for ⇄.

Unmeasured: scene-hosted items on macOS 27. Unlike S1 this path does not depend on click-x, so it is the safer bet, but it still needs one measurement pass before calling it done.

**(b) Create-first vs `StatusBarUIManager`:** the *direction* is right (first created = rightmost; leftmost clips). The *ownership* is wrong if the item lives in `StatusBarUIManager`’s dictionaries.

- `setupMultiProfile` calls `cleanup()` unless `canReuseCompositeGroups` (`StatusBarUIManager.swift:567-577`). `cleanup()` removes **every** item it owns (`305-350`).
- `MenuBarManager.setup()` re-entry also `cleanup()`s (`166-175`, `355-404`).
- `handleDisplayStructureChange` → `setupMultiProfileMode` rebuilds groups (`1156-1161`).
- `cycleTileVisibility` only cycles `multiProfileStatusItems + groupItems` (`377-378`).
- `hasValidStatusBar` will not see an item it doesn’t own.

**The selector must be a `MenuBarManager`-owned item, created once before `setupMultiProfileMode()`, never passed through `StatusBarUIManager.cleanup()`.** Then group recreate still lands `[Codex][Grok][Claude][⇄]`. Put it *after* group setup and it becomes leftmost and dies first on overflow — the opposite of the claim.

**Drop `autosaveName`.** Explicitly forbidden:

```609:614:Claude Usage/MenuBar/StatusBarUIManager.swift
            // Create one status item per selected profile. Deliberately NO
            // autosaveName: naming the items makes the window server remember
            // per-name positions in a private store the app cannot reliably
            // clear or overwrite — a pinning experiment (2026-07-17) left the
            // group SPLIT across remembered positions with no code-side way
            // back. Anonymous items always place by fresh creation order.
```

⌘-drag of a named ⇄ against anonymous groups will split the cluster. Length: use a **fixed** 24 pt, not `variableLength`.

**(c) `NSAlert` from an accessory app:** confirmation **synchronously** from the menu action (grant still live) is OK. Outcome alerts after `await activateProfileDetailed` are not — same trap as settings:

```3904:3913:Claude Usage/MenuBar/MenuBarManager.swift
    /// Foreground a window from this ACCESSORY app assertively. Since macOS 14,
    /// `NSApp.activate()` is cooperative — called from a menu-bar app after a
    /// dispatch delay, the click's interaction grant has expired and the system
    /// DENIES the activation, so the window opens BEHIND the frontmost app
```

Use `bringWindowToForeground` / `activateIgnoringOtherApps` before `runModal`. Never sheet it on a status item. Don’t dispatch the confirmation itself onto a `Task` before the alert. Suppressible-per-provider is right; still force-ask when the candidate is `unverified` / `dead` / duplicate — those are the expensive mistakes.

**(d) Menu content:**

Must show, currently omitted: **provenance of the owner number** (own vs headers vs CLI cache) and its age (R5 / tonight’s 3 min blind window); **suspected caveat + last measured, not a live-looking %**; **verdict kind** (probed / refreshed / owns-login / expiry-only — `PreflightVerdict.Kind` at `FleetSummary.swift:133-145`); **manual pin** (`autoSwitchedProfileIds`); **cfprefsd** (banner already exists; the ⇄ tint should include it); **in-flight switch**. Codex duplicates have no group type today (only `duplicateClaudeAccountGroups`).

Noise: the auto-switch policy paragraph on every open (one line + “Active & Auto-switch” link is enough); “View ‹owner›” in every section; an 18-row Claude submenu with no filter (type-select is the only search NSMenu gives you). Drop “View” from the selector; Viewing belongs in the inspector/dashboard. Keep Repair…, Switch…, Queue, and the three owner rows.

---

## 3. Inspector

**I1 is right** (one window lifecycle, logins need a window that survives a browser hop, deep links stay in Settings). I2 is the orphan/activation-policy mess this app already paid for. I3 is a 380 pt popover that closes on outside click — device-code login dies.

**230 + 490 inside a fixed 720 is not workable.** The window is **not resizable**:

```129:131:Claude Usage/Views/SettingsView.swift
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                   backing: backing, defer: flag)
```

```246:246:Claude Usage/Views/SettingsView.swift
        .frame(minWidth: 720, maxWidth: 720, maxHeight: .infinity)
```

```117:117:Claude Usage/Shared/Utilities/Constants.swift
        static let settingsWindow = NSSize(width: 720, height: 750)
```

Sidebar today is 190 (`SettingsView.swift:209`). 230 for `● Marlin (dev)  95  Cx` plus a 7-icon bottom bar (Accounts / Active / Alerts / Display / Advanced / About / Quit) is overflow. **Widen to ~840** (roster ~260, detail ~580), **add `.resizable`**, and replace the 7-icon strip with **text rows** under the roster (System Settings pattern). 720 with a 200 pt roster only works if the bottom bar stays 2–3 items.

**Folding CLI/Codex bodies into Login:** they will keep working **if** roster selection is `viewProfile` (they already bind `activeProfile` and reload on its id — `CLIAccountView.swift:257`, `CodexAccountView.swift:272`). Device-code sheet is on the Settings window (`CodexAccountView.swift:275-286`) — stays open. `loginTarget` (`CodexLoginService.swift:129-131`) keys off the viewed profile; keep that. Pick the body by `providerKind`; don’t show both on a Claude row (`isProviderLocked` already hides the other — `CLIAccountView.swift:19-22`, `CodexAccountView.swift:25-28`).

**What breaks:**

1. **Sync on a viewed non-owner is contamination.** `syncFromCLI` copies the *shared* Keychain login into `activeProfile` and claims ownership (`CLIAccountView.swift:264-291`). Codex twin at `CodexAccountView.swift:301-317`. Manual Sync is deliberately ungated vs account-match (CLAUDE.md) because `/login` + re-sync is the repair — that assumes Viewing **is** the account you just logged in. Free Viewing makes “Sync” on the wrong row steal the pointer and overwrite the row’s credentials. **Disable Sync unless Viewing is the provider owner, or confirm “import the current CLI login into ‹this› profile”.** Repair for a dead non-owner is isolated-home login / Import, not Sync.
2. **`.settingsSectionRequested` only sets `selectedSection`** (`SettingsView.swift:248-252`). Aliases must also select the Login tab **and** leave the roster on the viewed profile. Custom `init?(rawValue:)` (or a mapper) so `.cliAccount` / `.codexAccount` / `.manageProfiles` still decode — B2 posts those.
3. Selecting another roster row while `CodexLoginSheet` is up does not dismiss the sheet; the sheet still holds the old `viewedProfile`. Freeze the target at present, or dismiss on id change.
4. Grok has no page body today — that is new work, not a fold.

---

## 4. Counts

Taxonomy reuse is right (`AccountReadiness.classify`, first-match `dead → excluded → exhausted → suspected → unknown → low → ready`). `stale` orthogonal is right.

Fixes:

- **`usableNow = ready + low` under-counts the walk.** The walk accepts `{ready, low, unknown}` (`FleetSummary.swift:49-54`, redesign §2.1). Either add unknown as “unmeasured” in the sentence, or rename usableNow to “known headroom.” Don’t silently drop unknown.
- **`live = total - dead - excluded` double-counts duplicate pairs.** Two profiles, one `claudeAccountUUID`, one quota — `live += 2`. Stage 4 `capacityRemaining = Σ(100 − weekly)` over live makes it worse. Dedup by account stamp (`claudeAccountUUID` / `codexAccountId` / Grok `user_id`) for live and capacity. Keep `duplicates` as a separate histogram so the ⧉ strip still shows.
- A dead+excluded profile classifies as **dead** (first match) — not double-counted in `byReadiness`. Good.
- `queued` / `onBar` / `stale` are orthogonal. Good.
- Codex/Grok have no `duplicate*Groups` publisher — `⧉` will be 0 for them until that exists. Don’t pretend otherwise.

Strip glyph vocabulary must stay identical to the bar (`● ◐ ▲ × ⧉`); don’t invent a second alphabet.

---

## 5. Settings restructure

Top level is right: **Accounts / Active & Auto-switch / Alerts / Display / Advanced / About**. Active & Auto-switch as its own page is the one addition that earns its slot (policy + three owner cards + queue). Don’t bury thresholds under Accounts.

**Keys in the map, named wrong or not at all:**

| Key | Where | Map |
|---|---|---|
| `legacyBundleDefaultsMigrated_v1` | `MigrationService.swift:18` | mentioned as “bundle-migration flag”, not the real name |
| `claudeUsageData`, `notificationsEnabled`, `refreshInterval`, `apiUsageData`, `apiTrackingEnabled`, `apiSessionKey`, `apiOrganizationId` | `Constants.swift:17-24` | missing. `refreshInterval` is still read (`UserDefaults+Extensions.swift:6`) |
| `showIconNames`, `showNextSessionTime`, `sessionIconEnabled/Style/Order`, `weekIconEnabled/Style/Order`, `weekDisplayMode`, `apiIconEnabled/Style/Order`, `apiDisplayMode` | `Constants.swift:32-48` | missing. Only `menuBarIconStyle` + `monochromeMode` are still migrated (`MenuBarIconConfig.swift:591-617`) — register the rest as **legacy, unread** so the “no key lost” test doesn’t fail or silently drop them |

Present in the map and confirmed: `profiles_v3` and per-profile fields, the three (soon four) active pointers, `profileDisplayMode`, `multiProfileDisplayConfig`, the three Keychain-migration flags, `hasCompletedSetup`, `hasShownWizardOnce`, `debugAPILoggingEnabled`, the four shortcut keys, auto-switch trio + `autoSwitchQueue`, popover time keys, `switchHistory_v1`, `measuredSessionHistory_v1`, three `*DeadLogins_v1`, `sentNotifications`, `codexAutoImported_v1`, `grokAutoImported_v1`, `grokDisplayBackfill_v1`, `menuBarIconConfiguration`, `debugTileLayout`, `NSQuitAlwaysKeepsWindows`, `autoSwitchCustomOrder*`.

**Journal the new single-shot keys** (`activeGrokProfileId`, `fleetAlertDefaults_v1`, `activeSelectorItem_v1`, `activeSelectorConfirm_v1`, `settingsLayout_v2`) through `PreferenceWriteJournal`. Dead-login sets still write raw `UserDefaults` — already an open item; don’t pretend the registry fixes that.

**Fleet alert defaults:** the design is right (25 accounts cannot be configured one-by-one); bulk-apply as the *only* model is worse. Two migration bugs to close:

1. **Do not seed from Viewing on first read.** That makes fleet defaults = whichever row was focused when Alerts is first opened. Seed from `NotificationSettings()` defaults, or: if every profile’s settings are identical, promote that set and set `usesFleetAlertDefaults = true`; if they differ, leave overrides on and flag false.
2. Defaulting the new flag to `true` **throws away existing per-account toggles on upgrade.** Default to `false` (keep current behaviour), with an explicit “Use these for all accounts” on the Alerts page.

Sweep already notifies per profile with **that** profile’s settings (`MenuBarManager.swift:1562-1566`). Resolve fleet-vs-override **there**, not in the legacy `checkAndNotify(usage:)` that still reads Viewing (`NotificationManager.swift:33, 258-260`). Kill or re-route the legacy path.

`includeInAutoSwitch` on both Display and Active & Auto-switch is fine if it is one binding. Per-account `refreshInterval` in the inspector is misleading: there is one timer, and it follows Viewing (`MenuBarManager.swift:983`). Either say so, or stop pretending it is per-account once Viewing is free.

---

## 6. Interaction model

Paths that still **apply a login or mark a manual activation** if you only rename the picker:

| Surface | File:line | Today |
|---|---|---|
| Settings picker | `SettingsView.swift:275-284` | `activateProfile(..., userInitiated: true)` |
| Popover name menu | `PopoverContentView.swift:514-516` | same (B2.1 is supposed to flip this) |
| Manage Profiles rocket | `ManageProfilesView.swift:688-691` | same |
| Hotkey | `MenuBarManager.swift:349-350, 3916-3929` | walks **all** profiles in array order, cross-provider, `userInitiated: true` |
| Delete viewed profile | `ProfileManager.swift:221-226` | `activateProfile(first.id)` — **switches the CLI** |
| `$activeProfile` observer | `MenuBarManager.swift:431-456` | `handleProfileSwitch` → popover destroy, single-mode bar rebuild, refresh |
| `.profileManuallyActivated` | `ProfileManager.swift:596-598` | posted even for `.focusedWithoutApplying` |
| Grok cyan | `ProfileManager.swift:728-737` | focus-as-active |
| Wizard | `SetupWizardView.swift:109-115` | Sync into `activeProfile` |
| Login Sync | `CLIAccountView.swift:264-291` / `CodexAccountView.swift:301-317` | claim ownership |
| Auto-switch trigger | `MenuBarManager.swift:1574-1578` | viewing as “from” |
| Single-profile mode | `MenuBarManager.swift:188-210` | bar + credentials gate follow Viewing |

Tile click already does **not** activate (`togglePopover` sets `clickedProfileId` only). Don’t “fix” that by persisting Viewing.

**D5: follow on user-initiated Make-active; do not follow on auto-switch.** Auto-switch stealing Viewing yanks the inspector off a Login repair the moment a background rotation fires — the 2026-09-03 “can’t open the dead profile” incident in reverse. User-initiated follows (you switched to look at it). CLI-side adoption should **not** move Viewing either; the “changed outside the app” banner is enough.

Hotkey: view-next **within the viewed provider**, painted order not `profiles[]` order. Never `userInitiated` activate.

---

## 7. Staging

Stage 1 as written is over budget (two models + NSMenu builder + confirmation + outcome alerts + setup hook + strings + tests). Split:

| Order | Contents | Why |
|---|---|---|
| **0** | spec (this) | |
| **fixes, blocking** | `viewProfile`; **`.alreadyActive` compares provider pointer, not focus**; auto-switch/preflight/header-probe/Keychain-fallback drop `?? activeProfile`; split `handleProfileSwitch` so Viewing does not destroy the popover or post `.profileManuallyActivated`; Grok pointer + `applyProfileCredentials` | without this, stage 1’s “View” and “Make active” are wrong |
| **1a** | `ProviderActiveSelection` + `FleetCounts` + tests, no UI | ≤600, unblocks dashboard B2.1 |
| **1b** | `ActiveSelectorMenu` + create-once hook + confirmation | item **off** until 1a + fixes merge; then on |
| **2** | inspector | after Settings PRs; Login Sync gated |
| **3** | Settings IA + registry + fleet defaults migration | flag, then delete old pages |
| **4** | insights | reset timeline first |

Do not ship selector “View …” rows until `ProfileManager.viewProfile` exists — they would call `activateProfile`. Grok section read-only until apply lands is correct.

**Requested seams:** `viewProfile` is necessary and correctly specified. `activeGrokProfileId` + `claimActiveGrokOwnership` + store load/save is the minimum to stop Grok-as-focus; also add it to `isProviderActive`, `activeAccountIds`, `deleteProfile` clearing, `resolveProviderActiveAccounts`, `RefusedProvider`, and the auto-switch trigger set. `GrokUsageService.applyProfileCredentials` is required (`writeAuthFile` is `private` and only used after refresh — `GrokUsageService.swift:50, 278`); same-`user_id` merge as the refresh write-back. Also request **`.alreadyActive` uses the provider pointer** and **auto-switch trigger ignores Viewing** — those are not optional.

`focusedWithoutApplying` stays as a safety net; no UI path should produce it once viewing is focus-only.

`settingsLayout_v2` dual UI is expensive; cheaper to ship Accounts as a new section and delete Manage Profiles in 3b after a few days, without keeping two full Settings trees.

---

## 8. Missing for a 30–40-account operator

Neither spec covers:

- **Codex (and Grok) duplicate groups** — Claude-only today; two Codex homes for one `account_id` are the same quota-twice bug.
- **Reset timeline** (stage 4) is the actual planning view; ship it before burn sparklines / incident rings.
- **Capacity remaining deduped by account stamp**, not by profile row.
- **Per-provider queue** (or at least a provider filter on the global queue) — one list of 30 mixed UUIDs is how a Codex hand-off gets stuck behind Claude names.
- **Manual-pin visibility** on selector + inspector (“you picked this; auto-switch won’t leave until it has headroom”).
- **Filter/search in the selector submenu** (18 Claude rows); inspector filter is specified, the menu isn’t.
- **Ephemeral vs persisted Viewing** (popover navigator vs inspector) — conflating them writes `activeProfileId` on every ‹ ›.
- **Login Sync gated on owner**, isolated-home re-login as the dead-non-owner repair (already the Codex rule; the inspector must not offer the other button).
- **Drift banner** when `auth.json` / Keychain identity ≠ pointer (adoption already repairs; the UI should say it).
- **Resizable Settings** and a roster that can show email.
- **S2b/item-count invariance** and **no `autosaveName`** (platform, not IA, but they will leak or split the bar).

Not missing: fleet dots, candidate affix, dashboard roster, cfprefsd banner, dead-login gate, isolated `CODEX_HOME` login — those are the sibling spec / current code. This proposal should consume them, not redo them.
