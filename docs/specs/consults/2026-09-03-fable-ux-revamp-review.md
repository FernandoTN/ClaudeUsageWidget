# Fable (independent session, read-only) — UX revamp proposal review, 2026-09-03

Reviewed `docs/specs/ux-revamp.md` v1 against tree `a67c519` (= `9dca689` + the docs commit).

## Verdict: approve with revisions

The Viewing / Active-for-provider cut is right and the code already half-supports it (`ProfileManager.needsProviderApply`, `ProviderOwnership.grok`, `MenuBarManager.viewProfile`). But the spec's central claim — "Viewing is free" while `activeProfileId` stays the Viewing store — is false today: `MenuBarManager` runs its whole switch path on every `$activeProfile` change, and about a dozen sweep/backoff/auto-switch decisions still key on focus, one of which can rewrite the CLI login. The spec's base is also stale (#63/#64/#65 landed; #63 already fixed the `.alreadyActive` symptom the spec treats as in flight). Three changes that matter most:

1. **Make `viewProfile` actually free.** Split `MenuBarManager.handleProfileSwitch` (464–496) into focus-only (repaint) vs switch-landed (popover teardown, full sweep, timer re-arm), and pick ONE Viewing store (popover `clickedProfileId` vs `activeProfileId`) — today there are two.
2. **Retire focus as a fallback authority before Viewing may roam:** MenuBarManager:2280 (`syncToSystem` on the viewed profile), 2725 (header probe spends the viewed account's quota), 1574/2170 (auto-switch trigger runs for the viewed non-owner), ProfileManager:224 (`deleteProfile` → `activateProfile`), 1435 (nil pointer → focus becomes owner); derive the Grok owner from `~/.grok/auth.json` `user_id`, not focus.
3. **Confirmation and keys.** No `NSAlert.runModal` (pauses the default-mode sweep timer; needs explicit activation in an accessory app) and no "don't ask again" (contradicts the deliberate-switch ruling); add the two keys landed after the base (`claudeContaminatedLogins_v1`, `debugGroupExposure`); mark ~20 dead `Constants.UserDefaultsKeys` so the registry test can pass.

## 1. Viewing vs Active — model, R1–R5, focus-as-authority

**Cut:** right. `ProfileManager.swift:24-30` already documents focus ≠ owner; #63 (`46bc36a`) added `needsProviderApply` (358-372) so `.alreadyActive` requires focus **and** ownership (443-447) — §0 and §5.3 last row are stale; the "second click" is merged and is exactly the seam "Make active for Claude…" on a viewed non-owner needs. `ProviderOwnership.grok` (328-344) is the pre-built slot for `activeGrokProfileId`.

**Invariant gaps:**
- **R1** misses two changers of belief/ownership: `adoptSystemLoginByIdentity` (1501) moves the pointer *and clears credentials from other profiles*; `resolveProviderActiveAccounts` (1435) makes the **focused** profile the Claude owner when the pointer is nil. Both must be named, or Viewing-at-launch decides ownership.
- **R2** "never posts `.profileManuallyActivated`, never records a `SwitchEvent`": the legacy user path does both even for `.focusedWithoutApplying` (post at 708 precedes the `focusOnly` branch) — fine once every UI path is `viewProfile`, but say so and retire `focusedWithoutApplying` from the UI explicitly.
- **R3** is false for Grok today: `activeAccountIds` (845-853) inserts the **focused** Grok profile; `shouldSkipFetchForDeadLogin` .grok (MenuBarManager:2408-2411) and `predictedNextCandidate` (excludes `activeIds`) inherit it. Interim rule needed until the pointer lands: nil pointer and >1 Grok → "no active login known", never the viewed one.
- Add **R6**: a Viewing change costs no network request and changes no timer. Add **R7**: an automatic switch never moves Viewing while a Settings sheet is presented (see D5, §6).

**Focus used as authority (grep of `activeProfile` in ProfileManager, MenuBarManager, services):**

| Site | What focus decides | Severity |
|---|---|---|
| MenuBarManager:428-496 `$activeProfile` sink → `handleProfileSwitch` | `recreatePopover()` (kills an open popover), `refreshUsage()` → `refreshAllSelectedProfiles()` (full sweep), `restartAutoRefreshWithInterval(profile.refreshInterval)` — sweep cadence follows the viewed profile (Codex/Grok imports default 60 s vs 30 s); `startAutoRefresh` 983 seeds from focus | Breaks "Viewing is free" |
| MenuBarManager:2280 `isActiveClaude = pointer ?? focus` → `ensureFreshCredentials(adoptSystemKeychain:, syncToSystem:)` | With a nil pointer the **viewed** profile's refreshed token is written to the shared Keychain item (ClaudeCodeSyncService:691-700, not account-matched). Nil pointer is reachable via `deleteProfile` of the owner (205-208) | **Unsafe write** |
| MenuBarManager:1574-1578, 1620-1624, 2170-2180 | `checkAutoSwitchIfNeeded(currentProfile: viewed)` runs for the focused profile; `checkAutoSwitchIfNeeded` (3006-3095) has no owner guard → an exhausted **viewed non-owner** can fire `activateProfileDetailed(candidate)` (3153) and rewrite the CLI login | **Unsafe write** (latent today because focus ≈ owner) |
| MenuBarManager:2725-2726 `probeUsageViaMessageHeaders` | `isActiveClaudeAccount = pointer ?? focus` → spends the viewed account's quota when the pointer is nil | Quota spend |
| ClaudeAPIService:22-50 `getAuthentication` | Single-mode fetch uses focus's token, else the **system Keychain** token → active account's usage displayed under the viewed name | Wrong-account display |
| MenuBarManager:1778, 2398, 2594 | Read-side `pointer ?? focus` fallbacks (Keychain-token fetch, dead-login skip exemption, tripwire attribution) | Mislabel |
| ProfileManager:221-227 `deleteProfile` → `activateProfile(first.id)` | Deleting the viewed profile **applies** the first profile's login (auto path) | **Unsafe write** — must be `viewProfile` |
| ProfileManager:497, 1632-1637 | Outgoing owner resync/adoption falls back to focus (account-matched inside → safe, but focus-derived) | Low |
| MenuBarManager:1351 `priorityIds = [focus, activeClaude]` | Viewed account fetched every sweep; consumes a slot of `rotationBudget = max(1, 2 − priority)` — viewing a background Claude account halves background rotation | State it |
| MenuBarManager:1639, 2430, 2794, 2922 `isActiveAccount` includes focus | Viewed account gets the active backoff cap / 3-streak inference / inferred-throttle **notification** — noise for a non-owner | Low |
| NotificationManager:33, 260-267 | Legacy alert path reads focus's settings; the sweep uses per-profile (MenuBarManager:1562-1566) | Feeds D11 |
| SetupWizardView:108-121 | Syncs the CLI login into the focused profile without `claimActiveClaudeOwnership` (CLIAccountView:291 does claim) | Low |

Keeping `activeProfileId` as Viewing is acceptable **only** after the three unsafe rows are fixed and `getAuthentication`'s fallback is restricted to `activeClaudeProfileId` (mirror 1778). Introducing a fourth pointer instead would orphan every Settings page that reads `activeProfile`; the spec's choice is right with those as prerequisites.

## 2. Selector (§2.1)

**S2a is the right call.** Corrections:

(a) `NSStatusItem.menu` + `menuNeedsUpdate`: works; the rebuild runs synchronously on main while the menu opens — the snapshot inputs are all in-memory, so no Keychain/network — fine. ⌥ alternates: `isAlternate = true`, same (empty) `keyEquivalent`, `keyEquivalentModifierMask = .option`, placed immediately after the primary — works in status-item menus. Submenus (~85 items total) built eagerly in the parent's `menuNeedsUpdate` — fine. **Drop `autosaveName`** (StatusBarUIManager:609-614 records the 2026-07-17 pinning experiment).

(b) Creation order: new items land left of existing ones (StatusBarUIManager:634-637, 657-670), so creating the selector first in `MenuBarManager.setup()` keeps it rightmost through every rebuild because `StatusBarUIManager.cleanup()` (305-360) only removes its own dictionaries. Conflicts: `MenuBarManager.setup()` re-entry (166-176; AppDelegate:136 delayed retry, :312 post-wizard) calls `cleanup()` (355-407) — it must remove the selector or re-entry duplicates it; `cycleTileVisibility` (376-395) and #65's exposure telemetry don't know the item — a hidden selector is silent. Recommend one class owns every `NSStatusItem`, created before groups and exempt from the group teardown — negotiate with the redesign session.

(c) `NSAlert` from a menu action in an accessory app: `runModal` works but (1) the panel opens behind the frontmost app unless `NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])` first — `bringWindowToForeground` (MenuBarManager:3899-3913) exists for this; never flip activation policy; (2) **`runModal` spins `NSModalPanelRunLoopMode`; the sweep timer is `Timer.scheduledTimer` in `.default` mode (566-575, 983-989) and does not fire while the alert is up** — an alert left open stops the auto-switch clock. Use a non-modal confirmation, or at minimum schedule the timer in `.common`. Drop the "Don't ask again" (D3) and `activeSelectorConfirm_v1`: the ruling wants the cost visible on every manual switch. Also align #63's `CodexActivationOffer.activate` — it calls `activateProfile(userInitiated: true)` with no cost sentence.

(d) Omits: the in-flight state `⇄` (`isSwitchingProfile`, rows disabled); the manual pin (`autoSwitchedProfileIds`); provenance on the owner row when the value is a header rescue; #64's `needsAccountRelogin` caption on `⧉` rows. Over-shows: the auto-switch doctrine row (one line); "View dRir" for the owner only — drop it (Viewing is the inspector's job). S2b as the same builder filtered — cheap. S1 deferred — right.

## 3. Inspector (§2.2)

**I1 is right.** Issues:

- Width: `SettingsView:246` fixes 720; 230 + 490 leaves the detail 40 pt narrower than today's 530 content pane, and `AboutView:132`, `ShortcutsSettingsView:143`, `AppSettingsView:42` are hard-framed at 520 wide. Go to 800 or a 200 pt roster.
- Folding the CLI/Codex bodies into a Login tab works **only because** Viewing == `activeProfileId` — they read `activeProfile` at CLIAccountView:20, 33, 257, 265, 282, 313, 322, 337 and CodexAccountView:26, 38, 272, 277, 288, 302, 330. Provider exclusivity must be reproduced (`showsClaudeSections`/`showsCodexSection` + `normalizeSelection`, SettingsView:605-673; `isProviderLocked`); a credential-less profile offers both.
- Device-code sheet: `CodexLoginSheet(viewedProfile: …)` captures the destination at presentation — safe — but `.onChange(of: activeProfile?.id)` (272) reloads the page under it, and #63's `CodexActivationOffer.destination` requires `activeProfile?.id == profileId`: a Viewing move during the 5-minute flow makes the offer silently vanish.
- Deep links: `.settingsSectionRequested` carries only a section raw value — **no profile id**, so "Repair…" on row X opens the Login page of whichever profile is viewed. The payload must become (section, profileId) or the dashboard must `viewProfile(X)` before posting. `SettingsView.init` default `.appearance` → `.accounts`. Keep the `EmptyView` Settings scene (orphan path O3).

## 4. Counts (§3)

`byReadiness` is a true partition — no dead/excluded double count. Problems: `duplicates` is orthogonal and the strip reads as a sum — caption it; `usableNow` omits `unknown`, which the walk accepts; `live` and `capacityRemaining` count a duplicate pair twice — dedupe per account group; `excluded` merges "toggle off" (still manually usable) with "free plan" (not capacity) — split; #64's `needsAccountRelogin` is a human-action state outside the taxonomy — count it or fold it into the ⧉ caption; expose `DashboardSnapshot.build`'s readiness so there is one classification per paint. The bar's `fleetCounts` layout drops unknown/suspected/excluded by design — the inspector histogram and the bar will disagree on totals; say so.

## 5. Settings (§5)

Top level: fine. Key map verified against SharedDataStore, ProfileStore, the dead-login keys, `sentNotifications`, the one-time flags, `MenuBarIconConfiguration.load()`, `debugTileLayout`, `NSQuitAlwaysKeepsWindows`. **Missing:** `claudeContaminatedLogins_v1` (ClaudeCodeSyncService:1036, #64); `debugGroupExposure` (StatusBarUIManager:1708, #65); the literal name `legacyBundleDefaultsMigrated_v1`. **Registry hazard:** ~20 `Constants.UserDefaultsKeys` have no reader except the unused `UserDefaults.refreshInterval` extension — mark legacy-unused. Journal: `PreferenceWriteJournal.Owner` has only `.profileStore`/`.sharedDataStore`; new keys need an owner; Claude/Grok/contaminated dead-login sets write `UserDefaults.standard` directly. `fleetAlertDefaults_v1` + per-profile `usesFleetAlertDefaults`: `decodeIfPresent`; default should be `notificationSettings == NotificationSettings()` so customized profiles keep their override; do not seed from Viewing; resolution in one `Profile.effectiveNotificationSettings(fleet:)` used by both the sweep (MenuBarManager:1562) and the legacy path (NotificationManager:33/260); add a one-shot "Apply to all". `activeGrokProfileId`: shadow + journal + `deleteProfile` release + `currentProviderOwnership.grok`. `activeSelectorConfirm_v1`: drop.

## 6. Interaction model (§6) and D5

Still-activating "viewing" paths: `deleteProfile` (ProfileManager:224); hotkey `switchToNextProfile` (MenuBarManager:3916-3930, cross-provider — walk `paintedGroupMembers(for:)` like `cycleGroup`); `ProfileSwitcherCompact` (PopoverContentView:514-517); Settings sidebar picker (SettingsView:275-285) — **stage 1 relabels it "Viewing" but leaves it activating; rewire in the same PR**; `CodexActivationOffer` (#63) activates without cost confirmation; **single-profile display mode** (`getSelectedProfiles()` returns `[activeProfile]`; the single refresh path fetches via `getAuthentication` and runs `checkAutoSwitchIfNeeded` on the viewed profile) — define single mode; Grok focus-as-active (845-853); wizard write without claim; `.profileManuallyActivated` posted for focus-only outcomes (708).

**D5:** right for user switches; wrong for auto switches while the user works in the inspector. Refine: follow on user-initiated; on auto, follow only when Viewing was the outgoing owner **and** no Settings window is key / no sheet is up; otherwise stay and let the header say "Active for Claude: dJormun (changed 12 s ago)".

## 7. Staging (§8) and seams

Base is stale (#63/#64/#65 merged). Stage 1 at ≤600 lines is not credible; split: **1a** `ProviderActiveSelection` + `FleetCounts` + tests (pure) + the sidebar-picker rewire; **1b** `ActiveSelectorMenu` + item lifecycle + confirmation + toggle. Insert **stage 0.5 (fixes session, prerequisite for 1b's "View" rows and all of 2):** `viewProfile`; the `handleProfileSwitch` split (a cross-owner seam); the unsafe focus fallbacks (2280, 1574/2170, deleteProfile, `getAuthentication`); Grok owner derived from auth.json `user_id` (`extractUserId`, GrokUsageService:82-84) the way `codexOwnerFromAuthFile` does. Seams: `viewProfile` — right place; must not touch `lastUsedAt`, must not trigger the heavy observer path, must reconcile with the existing `MenuBarManager.viewProfile` / `clickedProfileId`. Grok: `applyProfileCredentials` mirrors Codex ✓; the Grok branch also needs outgoing `adoptAuthFileIfSameAccount(for:)` before the overwrite, the gate, and `RefusedProvider.grok`. Missing seam: a notification for "Active for X changed outside the app" — the two adoption paths log but post nothing.

## 8. What a 30–40-account operator still lacks

1. **Adding a Claude account without displacing the CLI login** — Claude Code honours `CLAUDE_CONFIG_DIR`; an isolated-config "Log in a new Claude account" flow, twin of the Codex one, is the largest gap in either spec.
2. **Fetch-budget scaling** — `rotationBudget` = 2 background Claude fetches per 30 s sweep: with 30 Claude accounts each is measured every ~7 min, `staleAfter = 180 s` dims nearly every dot permanently. Cadence tiers (hot/warm/cold) and a sortable "measured N ago" column.
3. **Bulk roster operations** (multi-select → show-on-bar, eligibility, alerts, delete, label).
4. **Per-provider auto-switch enable/thresholds** — `autoSwitchProfileEnabled` is global.
5. **Roster backup/restore** (profiles_v3 + Keychain items); `profiles_v3` is rewritten every sweep with 40 usage snapshots (plist churn was the cfprefsd incident's substrate).
6. **Name-keyed state**: `SwitchEvent.from/to` and `sentNotifications` key on profile names — renames break attribution and dedupe; 3-char `menuBarLabel` collisions have no uniqueness check.
7. **Notification digests / quiet hours** — one-per-episode × 40 accounts after wake is a storm.
8. **Account lifecycle and tier**: archive distinct from exclude/delete; plan tier for weighted capacity.
9. **Grouping by org/identity** (personal vs team subscriptions).
10. **"Why not the others"** — each block's evidence and age in one place before a manual switch.
