# "Focus is never authority" — per-site replacement list

**For:** the fixes session's `fix/focus-is-never-authority` PR (dispatched 2026-09-03
against `ead8c54`). **Line numbers as of `9dca689`** (unchanged by #66 for these
files' sweep regions except where noted). **Spec:** `docs/specs/ux-revamp.md` §1.2 R6.

## The rule

> The account a CLI is using is resolved from the PROVIDER POINTER
> (`activeClaudeProfileId` / `activeCodexProfileId` / `activeGrokProfileId`, or the
> pointer's on-disk identity resolver where one exists). The FOCUSED profile
> (`activeProfile`, soon "Viewing") is used only when the pointer is nil **and** the
> focused profile is the sole credentialed profile of that provider. Otherwise a
> nil pointer means "unknown", never "the one I am looking at".

Suggested helper (ProfileManager, pure, tested):

```swift
/// The profile that owns `provider`'s shared CLI login, by evidence only.
func providerOwnerId(_ provider: Profile.ProviderKind) -> UUID? {
    let pointer: UUID?
    switch provider {
    case .claude: pointer = activeClaudeProfileId
    case .codex:  pointer = activeCodexProfileId
    case .grok:   pointer = activeGrokProfileId
    }
    if let pointer { return pointer }
    let credentialed = profiles.filter { $0.providerKind == provider && $0.hasUsageCredentials }
    if credentialed.count == 1, let sole = credentialed.first,
       activeProfile?.id == sole.id { return sole.id }
    return nil
}
/// True when `id` owns ITS provider's login (never "is focused").
func isProviderOwner(_ id: UUID) -> Bool { activeAccountIds(among: profiles).contains(id) }
```

`activeAccountIds(among:)` keeps its Grok focused-or-sole fallback until an
activation claims the Grok pointer (#66's note) — but with MORE THAN ONE Grok
profile and a nil pointer it must return no Grok id at all (Fable/Grok reviews:
"no active login known", never the viewed one).

## Sites

Legend: **switch** = can rewrite a CLI login or fire the auto-switch; **write** =
credential write; **spend** = spends quota; **display** = what the popover /
single tile shows (Viewing IS the right key — keep); **tuning** = backoff /
inference / notification cadence.

| # | File:line (9dca689) | Current expression | Class | Replacement |
|---|---|---|---|---|
| 1 | `MenuBarManager.swift:1574-1576` | `if profile.id == activeProfile?.id \|\| profile.id == activeClaudeProfileId \|\| profile.id == activeCodexProfileId { checkAutoSwitchIfNeeded(…) }` | **switch** | `if isProviderOwner(profile.id) { … }` — the trigger runs ONLY for the provider owners; a viewed non-owner at 96 % must never move the CLI |
| 2 | `MenuBarManager.swift:1625-1627` | same condition around `checkAutoSwitchIfNeeded(usage: stamped, …)` | **switch** | same as #1 |
| 3 | `MenuBarManager.swift:2633-2634` | `if profile.id == activeProfile?.id \|\| profile.id == activeClaudeProfileId { checkAutoSwitchIfNeeded(…) }` (transcript rate-limit event) | **switch** | `if isProviderOwner(profile.id)` |
| 4 | `MenuBarManager.swift:2671-2672` | same shape (CLI cached usage adoption) | **switch** | `if isProviderOwner(profile.id)` |
| 5 | `MenuBarManager.swift:1959-1967` (single-profile refresh path) | `if let profile = activeProfile { … checkAutoSwitchIfNeeded(usage: newUsage, currentProfile: profile) }` | **switch** | guard `isProviderOwner(profile.id)` before the call; the fetch itself may stay keyed on the viewed profile (that is what single mode displays) |
| 6 | `checkAutoSwitchIfNeeded` (`:3005-3060`) | no owner guard | **switch** | add `guard isProviderOwner(currentProfile.id) else { return }` as the first guard — belt and braces for every caller, incl. `:1709` (candidate re-check) and `:2019` |
| 7 | `MenuBarManager.swift:2280` | `let isActiveClaude = profile.id == (activeClaudeProfileId ?? activeProfile?.id)` → drives `ensureFreshCredentials(adoptSystemKeychain:, syncToSystem:)` | **write** (a viewed profile's refreshed token written into the shared Keychain item when the pointer is nil — reachable after deleting the owner) | `let isActiveClaude = profile.id == providerOwnerId(.claude)` |
| 8 | `MenuBarManager.swift:2726` | `&& profile.id == (activeClaudeProfileId ?? activeProfile?.id)` (header-probe gate) | **spend** (probes the viewed account's quota) | `&& profile.id == providerOwnerId(.claude)` |
| 9 | `MenuBarManager.swift:2528` | `let isActiveClaude = profile.id == (activeClaudeProfileId ?? activeProfile?.id)` | spend/tuning | `providerOwnerId(.claude)` |
| 10 | `MenuBarManager.swift:2594` | `let activeId = activeClaudeProfileId ?? activeProfile?.id` (tripwire attribution) | mislabel | `providerOwnerId(.claude)`; nil → do not attribute |
| 11 | `MenuBarManager.swift:1778` | `if profile.id == (activeClaudeProfileId ?? activeProfile?.id),` (system-Keychain usage fallback paints the shared login's usage onto this profile) | mislabel | `providerOwnerId(.claude)` |
| 12 | `MenuBarManager.swift:2398` | `&& profile.id == (activeClaudeProfileId ?? activeProfile?.id)` (dead-login fetch-skip exemption, Claude) | tuning | `providerOwnerId(.claude)` |
| 13 | `MenuBarManager.swift:2410` | `let exempt = exemptProviderActive && profile.id == activeProfile?.id` (Grok exemption = focus) | tuning | `profile.id == providerOwnerId(.grok)` |
| 14 | `MenuBarManager.swift:1639-1640`, `:2163-2165`, `:2430-2432`, `:2794-2796`, `:2922-2924` | `let isActiveAccount = profile.id == activeProfile?.id \|\| activeClaudeProfileId \|\| activeCodexProfileId` (burst/auth backoff caps, inference streak, inferred-throttle notification) | tuning | `let isActiveAccount = isProviderOwner(profile.id)` — the viewed non-owner gets background cadence and no owner-only notifications |
| 15 | `MenuBarManager.swift:1351` | `let priorityIds = Set([activeProfile?.id, activeClaudeProfileId].compactMap { $0 })` | fetch priority | **keep** (fetching the viewed account every sweep is desirable); add `activeCodexProfileId`/`activeGrokProfileId` if the budget allows, but this is not an owner test |
| 16 | `MenuBarManager.swift:1543-1545`, `:1591-1593`, `:2170-2172`, `:2193-2195` | `if profile.id == activeProfile?.id { self.usage = newUsage }` | display | **keep** — `usage` is what the popover/single tile shows; Viewing is the correct key |
| 17 | `ClaudeAPIService.swift:22-50` `getAuthentication()` | uses `activeProfile`'s CLI token, else the SYSTEM Keychain token (the active account's) — paints the active account's usage under the viewed name | mislabel | fall back to the system Keychain only when `activeProfile?.id == providerOwnerId(.claude)`; otherwise throw `.noCredentials` for that profile |
| 18 | `ProfileManager.swift:221-226` `deleteProfile` | `if activeProfile?.id == id { … await activateProfile(first.id) }` | **switch** (a delete rewrites a CLI login) | `viewProfile(first.id)`; pointers are already released/re-derived by the surrounding code |
| 19 | `ProfileManager.swift:497` | `let outgoingId = activeClaudeProfileId ?? (activeProfile?.cliCredentialsJSON != nil ? activeProfile?.id : nil)` | write (outgoing re-sync; account-matched inside, so low) | `providerOwnerId(.claude)` |
| 20 | `ProfileManager.swift:1434-1437` (`resolveProviderActiveAccounts`) | `if activeClaudeProfileId == nil, let focused = activeProfile, focused.cliCredentialsJSON != nil { activeClaudeProfileId = focused.id }` | **pointer minted from focus** | infer from the shared login's live identity (`adoptSystemLoginByIdentity` already does this); else the sole credentialed Claude profile; else leave nil (= unknown) |
| 21 | `ProfileManager.swift:1632-1636` `resolveOutgoingCodexOwner` | `auth.json account_id → pointer → focused Codex profile → nil` | write (outgoing adoption, account-matched) | drop the focused step unless it is the sole credentialed Codex profile |
| 22 | `ProfileManager.swift:1392-1393`, `:1618-1619` | `if let activeId = activeProfile?.id, let updatedActive = … { activeProfile = updatedActive }` | display | **keep** (refreshing the viewed copy after a reload) |
| 23 | `activateProfileDetailed(userInitiated: false)` | `activeProfile = updated` unconditionally | Viewing yanked | move Viewing only if `activeProfile?.id == outgoing owner of that provider` **and** no Settings window is key / no sheet is presented (Fable R7); user-initiated: always move |
| 24 | `adoptSystemLoginByIdentity` / `adoptCodexLoginByAccountId` | pointer moves, Viewing untouched, no user-visible signal | (fine) + notify | post one `.providerOwnerChangedExternally` notification per episode (object: provider + new owner id) so the UI can show "Active for Claude changed outside the app: now dLeo" |
| 25 | `MenuBarManager.swift:428-496` `$activeProfile` sink → `handleProfileSwitch` | every focus change: `recreatePopover()`, `restartAutoRefreshWithInterval(profile.refreshInterval)`, `refreshUsage()` (full sweep) | Viewing not free | split: on a Viewing change (no pointer changed) do the display work only (`usage` reload, single-mode icon repaint); run the popover recreate / timer / sweep only when a provider pointer changed. **Cross-owner** (popover lifecycle = redesign session): coordinate the `recreatePopover` half with it |
| 26 | `MenuBarManager.swift:3916-3929` `switchToNextProfile` | `activateProfile(nextProfile.id, userInitiated: true)` over `profiles` in array order, cross-provider | **switch** | `viewProfile(next)` over `paintedGroupMembers(for: viewedProvider)` (fallback: ranking order), same provider only. (This one I can take in stage 1b if you prefer — say which.) |
| 27 | `SettingsView.swift:275-284` sidebar picker | `activateProfile(newId, userInitiated: true)` | **switch** | `viewProfile(newId)` — mine (stage 1a) |
| 28 | `SetupWizardView.swift:108-121` | syncs the CLI login into the focused profile without `claimActiveClaudeOwnership` | write | claim ownership after the sync (as `CLIAccountView:291` does), or route through `syncToProfile` + claim |

## Tests the reviews asked for

1. Sweep of a VIEWED non-owner at/over the session threshold does not call
   `checkAutoSwitchIfNeeded` (or it returns at the owner guard) — no candidate walk,
   no `activateProfileDetailed`.
2. An automatic switch moves Viewing only when Viewing was the outgoing owner;
   a user-initiated switch always moves it; CLI-side adoption never does.
3. `deleteProfile` of the viewed profile calls `viewProfile`, never `activateProfile`.
4. Owner resolution: pointer wins; nil pointer + sole credentialed profile of the
   provider that is focused → that profile; nil pointer + two credentialed
   profiles → nil (unknown), even when one is focused.
5. `getAuthentication` with a focused non-owner lacking its own token throws
   rather than reading the shared Keychain login.
6. Grok: nil pointer + two Grok profiles → `activeAccountIds` contains no Grok id.
