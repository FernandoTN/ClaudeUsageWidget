> Verdict: **APPROVE WITH REVISIONS.**  
> The Viewing/Active split and I1 inspector are the right foundation.  
> Change 1: make activation provider-scoped and remove every focus-as-authority fallback first.  
> Change 2: ship one permanent selector item with non-suppressible confirmation; drop S2b from v1.  
> Change 3: widen Settings, correct fleet-count semantics, and split Stage 1.

1. **Viewing versus Active**

Yes—the conceptual cut is correct. Keeping the persisted key `activeProfileId` is migration-safe, but keeping `activeProfile` as a broadly accessible semantic API is not. Rename it internally to `viewingProfile` or restrict writes behind `viewProfile`.

Focus still acts as authority in several places:

- A missing Claude owner falls back to Viewing during outgoing adoption: [ProfileManager.swift:497](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Services/ProfileManager.swift:497>).
- A nil Claude pointer is populated from the focused profile: [ProfileManager.swift:1434–1437](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Services/ProfileManager.swift:1434>).
- Codex owner resolution also falls back to focus: [ProfileManager.swift:1632–1636](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Services/ProfileManager.swift:1632>).
- Shared Claude Keychain credentials may be attributed to the viewed profile: [MenuBarManager.swift:1774–1782](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/MenuBarManager.swift:1774>).
- `ClaudeAPIService` chooses `activeProfile` before falling back to the shared login: [ClaudeAPIService.swift:23–49](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Services/ClaudeAPIService.swift:23>).

R1–R5 need four additions:

- Nil owner means unknown/unresolved—not Viewing. Authority comes from verified CLI identity or a successfully completed apply.
- “Make active for Claude” may alter Claude only. The current generic activation gives a non-focused profile an all-provider scope, so a mixed legacy profile can change multiple CLIs: [ProfileManager.swift:459–461](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Services/ProfileManager.swift:459>).
- Pointer, manual-activation notification and history move only after the provider write succeeds.
- One provider identity is one candidate/capacity unit, regardless of how many profiles contain it.

For 30 accounts, names and three-character labels are insufficient. Every chooser needs search, provider grouping, masked email/account-ID suffixes, and a persistent summary of Viewing plus all three owners. R5 should apply per measurement group; repeating provenance beside every gauge would become noise.

2. **Selector**

S2a is the right primary surface. S3 should mirror it; S1 can follow measured event reliability. Remove S2b as a setting in v1.

- **(a)** `NSStatusItem.menu` plus lazy `menuNeedsUpdate` is appropriate. Apple explicitly supports attaching a pull-down menu to a status item, and alternate items are native AppKit behavior: [NSStatusItem](https://developer.apple.com/documentation/appkit/nsstatusitem), [NSMenuItem.isAlternate](https://developer.apple.com/documentation/AppKit/NSMenuItem/isAlternate). Build synchronously on the main thread from one already-computed snapshot—no Keychain, filesystem or network work while opening. Twenty-five submenu rows are fine. Keep an explicit “Queue…” action too; Option must not be the only discoverable path.

- **(b)** Creating the selector first correctly places it rightmost initially. It must remain owned outside `StatusBarUIManager`: `MenuBarManager.setup()` re-enters through cleanup [MenuBarManager.swift:166–175](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/MenuBarManager.swift:166>), while `StatusBarUIManager.cleanup()` removes every item it owns [StatusBarUIManager.swift:305–343](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/StatusBarUIManager.swift:305>). Provider-set changes can still rebuild the composite group [StatusBarUIManager.swift:889–909](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/StatusBarUIManager.swift:889>). Create the selector once, toggle `isVisible`, and split “display reset” from terminal teardown. The proposal’s no-`autosaveName` choice is correct and matches the existing warning [StatusBarUIManager.swift:615–620](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/StatusBarUIManager.swift:615>). S2b would reintroduce item-count churn and should be dropped.

- **(c)** `NSAlert` is workable after the menu closes, but an accessory app must explicitly foreground it. Use the existing `NSRunningApplication.current.activate(.activateIgnoringOtherApps)` pattern [MenuBarManager.swift:3904–3913](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/MenuBarManager.swift:3904>); do not flip activation policy from `.accessory` [AppDelegate.swift:97–98](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/App/AppDelegate.swift:97>). Because switching is costly, confirmation should not be suppressible.

- **(d)** Add separate usage provenance/age and login-verdict source/age. A collapsed `NextCandidate.Verdict` loses whether evidence came from a usage probe, auth-file identity, expiry check or cached state. Also show blind/backoff state and the currently displayed fallback measurement. Keep the cost line. Remove ranked numbers when ordering already communicates rank, duplicate navigation links, and the S2b selector setting.

3. **Inspector**

I1 is right. Widen the window to roughly 800–820 pt and make it resizable with a sensible minimum. The current view is hard-fixed at 720 pt [SettingsView.swift:246](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Views/SettingsView.swift:246>) and the window style omits `.resizable` [SettingsView.swift:150–154](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Views/SettingsView.swift:150>). A 230 + 490 split leaves no room for dividers or padding, and existing Codex sheets are 520 pt wide [CodexAccountSheets.swift:190](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Views/Settings/Credentials/CodexAccountSheets.swift:190>).

Do not embed the current pages whole. Extract login bodies that receive a stable `profileId`; today both are coupled to global `activeProfile` [CodexAccountView.swift:26–38](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Views/Settings/Credentials/CodexAccountView.swift:26>). The Claude sync captures one ID, then updates whichever profile is viewed when the async operation completes [CLIAccountView.swift:273–300](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Views/Settings/Credentials/CLIAccountView.swift:273>). Fix that before roster selection can change mid-sync.

Keep the device-code sheet attached to its captured target account; changing rows must not retarget or tear it down [CodexAccountView.swift:275–285](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Views/Settings/Credentials/CodexAccountView.swift:275>). Replace raw section aliases with a typed route carrying `section`, `profileId` and `tab`; today the listener changes only the section [SettingsView.swift:248–252](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Views/SettingsView.swift:248>).

4. **Counts**

The shape is useful, but the definitions are not yet sound.

- `usableNow = ready + low` excludes `.unknown`, while current readiness explicitly treats unknown as switch-acceptable [FleetSummary.swift:48–53](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Models/FleetSummary.swift:48>). Under the fixed ruling, unknown should not drive an automatic decision; either change that resolver rule or call the count `measuredUsableNow`.
- `live = total - dead - excluded` is wrong. Excluded means auto-switch disabled or free-plan, not non-live [FleetSummary.swift:37–42](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Models/FleetSummary.swift:37>).
- Duplicate profiles remain in `total` and readiness, inflating capacity. Report `profileEntries`, `distinctAccounts`, `duplicateProfiles`, `duplicateGroups` and duplicate excess separately.
- Credentialless profiles fall back to Claude classification [Profile.swift:261–278](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Models/Profile.swift:261>) but are not classified dead by the current credential cache [ManageProfilesView.swift:898–906](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Views/Settings/App/ManageProfilesView.swift:898>).

Use `loginLive`, `autoSwitchEligible`, `measuredUsableNow`, `unknown`, and de-duplicated capacity as separate numbers.

5. **Settings**

The top-level structure is good with three adjustments: keep Quit as a command rather than a destination; put refresh cadence under account monitoring rather than Display; expose auto-switch eligibility in one primary location, not both Accounts › Display and Active & Auto-switch.

Missing or insufficiently named keys:

- Live key missing entirely: `claudeContaminatedLogins_v1` [ClaudeCodeSyncService.swift:1036](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Services/ClaudeCodeSyncService.swift:1036>).
- Replace generic “bundle-migration flag” with its literal name, `legacyBundleDefaultsMigrated_v1` [MigrationService.swift:18](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Services/MigrationService.swift:18>).
- Unclassified legacy `Constants` keys: `claudeUsageData`, `notificationsEnabled`, top-level `refreshInterval`, `apiUsageData`, `apiTrackingEnabled`, `apiSessionKey`, `apiOrganizationId`, `showIconNames`, `showNextSessionTime`, and all `session*`, `week*`, and `api*` icon enabled/style/order/display keys [Constants.swift:17–48](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Utilities/Constants.swift:17>). If genuinely dormant, register them as legacy/tombstoned rather than silently omitting them.

A manually maintained registry plus “every registered key has a reader” cannot discover private service keys. Make it the source of truth or aggregate service-owned registries.

Fleet defaults plus per-profile override is better than bulk-apply alone. Preserve existing profiles by decoding the opt-in as optional/default-false; new profiles may default true. Add “Use fleet defaults for all/selected” as a bulk action. Do not seed defaults from whichever account happens to be Viewed. Centralize `effectiveNotificationSettings(for:)`; current consumers read profile settings directly [MenuBarManager.swift:1562–1566](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/MenuBarManager.swift:1562>).

Route every new key through the preference write journal and last-known-good degradation handling; the current shadow covers only four families [SharedDataStore.swift:73–76](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Storage/SharedDataStore.swift:73>).

6. **Interaction model**

Remaining activation leaks:

- Settings picker: [SettingsView.swift:275–284](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Views/SettingsView.swift:275>).
- Popover account menu: [PopoverContentView.swift:510–517](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/PopoverContentView.swift:510>).
- Manage Profiles button: [ManageProfilesView.swift:696–701](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Views/Settings/App/ManageProfilesView.swift:696>).
- Next-profile hotkey: [MenuBarManager.swift:3916–3929](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/MenuBarManager.swift:3916>).
- Deleting the viewed profile activates the first remaining profile: [ProfileManager.swift:220–225](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Services/ProfileManager.swift:220>).
- Setup wizard imports the shared Claude login into Viewing: [SetupWizardView.swift:107–116](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Views/SetupWizardView.swift:107>).
- Grok currently defines active via focus/sole-account inference: [ProfileManager.swift:845–853](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Services/ProfileManager.swift:845>).

`handleProfileSwitch` is display-only, but it starts a refresh [MenuBarManager.swift:464–499](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/MenuBarManager.swift:464>), and single-profile refresh subsequently runs auto-switch logic for the viewed profile [MenuBarManager.swift:1958–1967](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/MenuBarManager.swift:1958>). Gate that on the provider owner.

D5 is right for an explicit manual switch, but wrong as a blanket auto-switch rule. Use sticky follow:

- Manual Make active: Viewing follows.
- Auto-switch: follow only if Viewing equalled the outgoing owner when switching began.
- External adoption: preserve Viewing and show the owner-change banner.

Also remove `focus-only` from the proposed switch log; R2 says viewing never creates a `SwitchEvent`, while §4 still lists that trigger.

7. **Staging**

Stage 1 is materially larger than 600 lines. Reorder it:

- **1A:** `viewProfile`, provider-scoped activation, Grok ownership, removal of all focus fallbacks, and semantic tests.
- **1B:** pure `ProviderActiveSelection` and corrected `FleetCounts`.
- **1C:** one permanent selector item, menu, confirmations and outcome routing.
- **2A:** typed Settings routing plus widened/resizable shell and roster.
- **2B:** Overview/Alerts/Display account tabs.
- **2C:** profile-ID-based Login components and sheet lifecycle.
- **3A–C:** Active page, fleet alerts, then Display/Advanced/key registry.
- Split Stage 4 into persistence/model and presentation PRs.

`settingsLayout_v2` is sensible. Selector enablement must use `isVisible`; remove the per-provider mode and confirmation-suppression keys.

The requested seams are necessary but not sufficient:

- Activation needs a provider parameter, not just `activateProfileDetailed(id:)`.
- Nil Grok ownership must not fall back to focus. Derive it by matching `~/.grok/auth.json`’s `user_id`; persist a non-secret `grokUserId` for identity and duplicate detection.
- The proposed “same-user_id merge rule” is wrong for explicit activation. That guard currently prevents an inactive profile refresh from overwriting a different active Grok login [GrokUsageService.swift:276–279](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/Shared/Services/GrokUsageService.swift:276>). An explicit switch must adopt the outgoing account, atomically replace the auth file, verify the target `user_id`, then claim the pointer.
- Give the Grok pointer the same cfprefsd shadow/journal protection as the existing pointers.

8. **Missing operator capabilities**

Add:

- Multi-select bulk actions for auto-switch eligibility, bar visibility, alert-default enrollment and verification.
- Archive/offboard state distinct from destructive deletion.
- Duplicate resolution across all providers: choose canonical profile, merge metadata/queue/display settings, then remove or archive the duplicate.
- Saved filters/tags/favorites and keyboard-first type-ahead navigation.
- A rate-limited “Verify fleet now” operation with explicit verified/total progress and no quota-spending idle probes.
- Durable audit records keyed by profile UUID and provider, including actual old/new owner, outcome, evidence and measurement snapshot. Current history stores names, and dashboard provider attribution is reconstructed from the current name map [DashboardModel.swift:193](</Users/fernandotn/Projects/ClaudeUsageWidget/.claude/worktrees/ux-revamp/Claude Usage/MenuBar/DashboardModel.swift:193>)—renames and duplicate names break forensics.
- Non-secret configuration export/import for disaster recovery.

Reviewed read-only at HEAD `a67c519`; no files were modified.

