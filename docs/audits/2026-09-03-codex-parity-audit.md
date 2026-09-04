# ClaudeUsageWidget — Codex-account parity audit

**Date:** 2026-09-03 (14:00–14:30 PDT)
**Tree audited:** `HEAD = 76c20b0` (`fix(autoswitch): Codex 429 backoff …` #47), the build installed in `/Applications` and running as PID 59348 since 2026-09-01 19:37.
**Question asked:** with two Codex accounts today and many more coming, does every Claude-side behaviour (credential lifecycle, switching, auto-switch, throttling, UI, notifications) work the same for Codex accounts — and what is broken, missing or inconsistent?
**Method:** full reads of `CodexUsageService`, `Profile`, `ProfileManager`, `ProfileStore`, `MenuBarManager`, `StatusBarUIManager`, `PopoverContentView`, the two credential views, `NotificationManager`, `LocalLimitSignalService`, the test suite; a Release build; a full `xcodebuild test` run; 44 hours of the app's unified log; cfprefsd's log; the on-disk and cfprefsd views of the preferences domain; the stored credentials' account ids and JWT claims (decoded locally, never printed); strings in the installed codex CLI binary (0.153.0). No source, app state, Keychain item, CLI login or preference was modified.

Previous audit: `docs/audits/2026-09-01-thorough-audit.md`. Items from it that are still open are cited by their old id (M4, M5 …) rather than re-counted.

## Ground truth

| Probe | Result |
|---|---|
| Release build | **BUILD SUCCEEDED**, 48 warning lines / 23 unique sites (one Codex-specific: `CodexUsageService.swift:511`) |
| `xcodebuild test` | **230 tests, 0 failures, 0 skipped**, 14 s; the test host made no network requests and rewrote no shared login |
| Roster | 21 profiles: 18 Claude, 2 Codex (`Kestrel` <id-1>, `Osprey` <id-2>), 1 Grok; multi-profile display; auto-switch on, session 95 %, weekly default 99 % |
| Codex API shape today | weekly-only (`limit_window_seconds` = 7 d, `secondary_window` null) → `hasSessionWindow = false`, `sessionPercentage = 0` |
| Codex token lifetimes | access token **10 days**, id token 1 h, refresh token rotates |

## Live incident, 2026-09-03 (what the app was doing while this was written)

Reconstructed from the app log, cfprefsd's log, the Keychain-stored credentials and `~/.codex/auth.json`:

1. **All morning `Kestrel` drew a 401 on every sweep** (1,009 "Failed to refresh profile 'Kestrel' … status 401" lines since 04:18, roughly every 30 s — it is a *background* profile with a 60 s interval, and there is no backoff for 401). `Osprey` owned auth.json and read 200 at weekly 95 %.
2. **13:49:57** — `codex login` for Kestrel's account rewrote auth.json. The app adopted it into `Kestrel` (same `account_id`). **13:50:15** — the user activated `Kestrel` (auth.json rewritten with the same bytes). **13:50:22** — Sync in *Codex Account*; log: `'Kestrel' claimed the active Codex login`.
3. **From 13:50:17 `Osprey` 401s on every sweep** and has not recovered. Its stored token was valid at 13:48:53 (200) and is a different account (`<account-id-A>`, JWT issued 09-01 16:30, expires 09-11). The only event between the last 200 and the first 401 is the other account's `codex login`. The retained log contains **no** `Codex: OAuth token refresh` line at all: the app never attempted the 401 forced refresh, because `Osprey` was already in `codexDeadLogins_v1` (set by some earlier 4xx while its 10-day access token kept working). The flag blocks `ensureFreshCredentials`, a 200 never clears it, and the relogin notification is deduped per profile forever — so the account went dark silently.
4. **`codexDeadLogins_v1` on disk still lists both Codex profiles**, including `Kestrel`, whose flag the code removed at 13:49:57 (adoption) and 13:50:22 (sync). See item 5.
5. **cfprefsd rejected the app's writes from 12:33:22 to 12:35:24** ("rejecting write of key(s) … because Path not accessible", 15 times; the app's side logged "Couldn't write values for keys … in CFPrefsPlistSource"). The two-minute episode ended, per-sweep keys land again (`profiles_v3` and `measuredSessionHistory_v1` are current to the minute), **but every single-shot key written since has not reached disk**:

   | Key | On disk / cfprefsd | In memory per the app log |
   |---|---|---|
   | `activeProfileId` (focus) | `Cedar` (12:26:48) | `Kestrel` (13:50:15; `Granite` at 13:00:22 also lost) |
   | `activeClaudeProfileId` | `Cedar` (12:30:48 claim) | `Granite` (13:00:22; the sweep treats Granite as active) |
   | `activeCodexProfileId` | `Osprey` | `Kestrel` (claimed 13:50:15 and 13:50:22) |
   | `switchHistory_v1` | ends at 12:26 | two later activations recorded by `ProfileManager.swift:553` |
   | `codexDeadLogins_v1` | `{Kestrel, Osprey}` | `Kestrel` removed twice |

   The app's degradation detector (`ProfileStore.loadPointer`, `markPreferencesDegraded`) watches **reads** returning nil; reads were fine, so no banner, no notification, no log line. The CFPreferences client-side mechanism that strands only the once-written keys was not determined; the evidence is five keys across two events. Consequence at the next relaunch: `Kestrel` is re-flagged dead (its refresh path stays disabled until a manual re-sync, and it goes dark with no notification when its access token expires on 09-13), focus reverts, two switch records are gone, any setting changed after 12:35 reverts. The owner pointers self-heal at launch (Codex by `account_id` match against auth.json, Claude by the identity repair).

6. **Codex CLI transcripts already carry the missing signal.** `~/.codex/sessions/**/*.jsonl` write a `token_count` event with `rate_limits {primary{used_percent, window_minutes, resets_at}, …}` on every turn — 6,612 snapshots in two weeks, 705 today; the 12:52 snapshot reads 95 % weekly, resets 09-08 16:41, i.e. `Osprey`. `LocalLimitSignalService` reads only `~/.claude`.

7. **Why a `codex login` for one account can kill another** (hypothesis, not proven): the installed binary contains `codex_login::auth::manager::logout_with_revoke`, the endpoint `https://auth.openai.com/oauth/revoke` referenced from `login/src/server.rs:671` (the login server), and it sends an `x-codex-installation-id` header from `~/.codex/installation_id`. If the auth server binds sessions to the installation, each new `codex login` invalidates the previous account's tokens on this machine — exactly the symmetric pattern observed (Osprey's login on 09-01 preceded Kestrel's death; Kestrel's login today preceded Osprey's). **Test:** `codex login` as Osprey, then Sync on Osprey; if `Kestrel` starts 401-ing within two sweeps the hypothesis holds, and onboarding many accounts through `codex login` on one machine will need a different mechanism (the app never tried Osprey's *refresh* token, so whether the whole family or only the access token dies is unknown).

## Severity-ranked findings

Lane ids in parentheses map to the four parallel read-only lanes (L1 credential lifecycle, L2 sweep/auto-switch, L3 UI/notifications, L4 tests/signals).

### Critical

| ID | file:line | Defect | Failure scenario | Claude parity | Fix |
|---|---|---|---|---|---|
| **C1** (L1-3, L3-5) | `CodexUsageService.swift:317-319, 402-408, 440-441, 476` | The Codex dead-login flag is set by **one** 400/401/403 from `auth.openai.com`, persisted, and cleared only by same-account adoption of a *fresher* auth.json, a manual Sync, or profile deletion. A 200 usage fetch clears the forced-refresh cooldown (`:476`) but never the flag. | A profile is flagged while its 10-day access token still works; the flag then blocks both the expiry refresh and the 401 forced refresh, so when the token is invalidated (live: `Osprey`, 13:50 today) the app cannot self-heal, sends no second notification, and the tile freezes at the last value. `Kestrel` sits flagged-but-working right now and will go dark on 09-13. Manage Profiles and the popover switcher show "login expired" for the working account. | Same semantics in `ClaudeCodeSyncService.swift:665-679, 883-888`, but Claude tokens live hours, so the window is small; Codex's is ten days. | Clear the flag on any 200 from `wham/usage`; allow one probe redemption per few hours for flagged profiles; treat only `invalid_grant` as terminal; re-notify daily while an active owner stays dead. |
| **C2** (L1-1, L2-2) | `ProfileManager.swift:483-491`; `MenuBarManager.swift:2987-2991`; `CodexUsageService.swift:135-138` | The dead-login gate and candidate preflight decide liveness from the JWT `exp` claim only; `isLoginMarkedDead` is never consulted and no usage probe is made. | `Osprey` is dead-flagged, 401s every sweep, and its JWT says valid until 09-11: a user click or the Codex auto-switch would **write that dead login into auth.json**, and the codex CLI dies with "refresh token was revoked" until a manual `codex login`. Preflight (if it ever ran, see H1) would report it live. | Claude has the same gate shape (`:437`), narrowed by short token life. | Gate on `isLoginMarkedDead(id) || isTokenExpired(json)` for both providers; for Codex, probe `wham/usage` once before applying (own host, cheap). |
| **C3** (live item 5) | `ProfileStore.swift:1016, 1055-1058, 1068-1071`; `SharedDataStore.swift:301`; `CodexUsageService.swift:383-386`; `ProfileStore.swift:1034-1054` (detector) | Single-shot preference writes are fire-and-forget; degradation is detected only on nil **reads**. After a cfprefsd write-rejection episode the once-written keys never reach disk while periodic keys do, and nothing notices. | Both owner pointers, the focus pointer, the switch history and the dead-login sets are stale on disk right now; a relaunch re-flags `Kestrel` dead and loses forensics. With many accounts every switch and every re-sync writes such a key. | Provider-neutral. | Read back after every single-shot write and mark degraded on mismatch; re-assert all single-shot keys from memory once per sweep (cheap: a handful of strings); treat the client's "Couldn't write values" as a degradation signal (banner + notification, the existing seam). |

### High

| ID | file:line | Defect | Failure scenario | Claude parity | Fix |
|---|---|---|---|---|---|
| **H1** (L2-1) | `MenuBarManager.swift:2926-2935` | Preflight milestones (25/50/75/90 %) read `effectiveSessionPercentage`; weekly-only Codex reports session 0 forever, so `preflightCandidates` never runs for the Codex owner. | Dead Codex candidates are discovered only inside the auto-switch walk, one full activation attempt each, at the 99 % weekly trigger; no early "re-login while you have headroom" notification, which is the feature's whole point. | Claude preflights on session milestones. | Key milestones off `max(session, weekly)` (weekly alone when `!providesSessionWindow`). |
| **H2** (L2-4) | `MenuBarManager.swift:1413-1417, 2196` | The dead-login fetch skip is `!isCodexOnlyProfile && !isGrokOnlyProfile`; a dead-flagged Codex profile is fetched every sweep, and 401 (unlike 429) registers no backoff. | `Kestrel` drew 1,009 401s today, ~2,900/day per dead profile, each an error log line and a `chatgpt.com` request; a 15-minute forced-refresh attempt per dead profile on top. At 10–20 Codex accounts with a few dead this is most of the app's traffic. | #29 added the skip for Claude only. | Extend the skip to `CodexUsageService.isLoginMarkedDead` / Grok (keep the provider-active exemption); add a 401 backoff. |
| **H3** (L2-5, L3-3) | `MenuBarManager.swift:1490-1497, 1563-1570, 1636-1641`; `PopoverContentView.swift:173-178`; `StatusBarUIManager.swift:135-139` | An unmeasurable Codex owner (401 on every sweep) produces only `credentialErrorProfileIds` → a popover banner for the *viewed* profile. No tile tint, no repeat notification, no "owner unmeasurable for N sweeps" escalation, and the auto-switch trigger keeps reading the stale cache (which eventually stops being "exhausted" as its reset passes). | The account the CLI is logged into can be at 100 % while the widget shows a stale green number for hours. | Claude has the active-account Keychain fallback (`:1636`) and the sweep-end identity adoption (`:1591`); Codex has neither. | Codex twin: at sweep end re-read auth.json, match `account_id`, route the pointer and adopt (H4); tint dead/unmeasurable tiles; notify after N consecutive failed owner reads. |
| **H4** (L1-2) | `ProfileManager.swift:1028-1093` (sole caller `:1021`, launch) | The Codex owner is re-derived from auth.json's `account_id` only at launch; no sweep-time equivalent of `adoptSystemLoginByIdentity`. | A CLI-side `codex login` (the documented dead-login recovery) or a running codex session of a non-owner account refreshing auth.json flips the CLI's real login while the app keeps watching the old owner; preflight then refuses to validate the real owner "because it already owns the login" (`MenuBarManager.swift:2971-2976`); `codex login` alone never revives a dead profile. | Claude's `/login` revives a profile via `markLoginRevived` (`:1171`) every sweep. | Run the `account_id` match + same-account adoption at sweep end (file read, no network). |
| **H5** (L2-3, L3-1) | `MenuBarManager.swift:1811`; `NotificationManager.swift:125-181, 472-479` | Usage-threshold notifications are computed from `displaySessionPercentage` only and are called only on the single-profile path. `weeklyWarning`/`weeklyCritical` alert types have zero callers. | No Codex account ever gets a 75/90/95 notification (session is always 0), and in multi-profile mode (the user's mode) no account of any provider does; the per-profile toggles in Settings → General are a no-op. | Claude gets them only in single-profile mode. | Call `checkAndNotify` per profile from the sweep; add a weekly branch for weekly-only usage. |
| **H6** (L2-6, L1 Q7) | `MenuBarManager.swift:1279-1306, 1435`; `CodexUsageService.swift:180, 311, 422` | No fetch budget, staleness scheduler or pacing for Codex: every Codex profile is fetched every sweep, each fetch running `ensureFreshCredentials` → `adoptAuthFileIfSameAccount` → three full roster decodes (35 KB JSON + 21-profile hydration each) and an auth.json parse on the main actor. | 20 Codex accounts ⇒ ~60 roster decodes and 20 back-to-back `chatgpt.com` requests per sweep from one IP, behaviour under a per-IP cap unmeasured (the #47 429 branch would at least back off). Launch hydration spawns five `security` subprocesses per profile against a 15 s deadline (`ProfileStore.swift:62`); 40 profiles risk a partial warm. | Claude has the 2-per-30 s budget, staleness scheduler and 2 s spacing. | A Codex rotation budget mirroring the Claude scheduler (owner every sweep, background by staleness); cache the decoded roster per sweep. |
| **H7** (L3-4) | `StatusBarUIManager.swift:70, 629-656, 734-800, 1378-1380` | Composite mode (default) renders each provider as ONE fixed-width status item; Codex is created last so it clips first; `strandedTileDetected` reads `multiProfileStatusItems`, empty in composite mode, so overflow is `unmeasurable` and `overflowParkedIds` stays empty. | At 10–20 Codex tiles (~300–600 pt) macOS hides the whole Codex item at once; no log, popover or debug layout says so. | Provider-neutral, but Codex is the group that clips. | Measure group item windows too; cap composite width or wrap into a second Codex item; show "N tiles hidden" in the popover. |
| **H8** (L1-5) | `CodexUsageService.swift:152-172`; `ProfileManager.swift:1060-1065` | Sync copies auth.json into any profile with no `account_id` check against other profiles; owner resolution is `profiles.first(where:)`. | Syncing the same Codex account into two profiles yields two tiles for one quota, double fetch load, both in the same auto-switch group (a "switch" that changes nothing), and roster order decides the owner. Auto-import is guarded (`carriesCodexAccount`), manual Sync is not. | Claude dedupes via `claudeAccountUUID` and contamination clearing (`ProfileManager.swift:1177-1197`). | Refuse or move ownership when another profile holds the same `account_id`; persist a non-secret `codexAccountId` on `Profile` for pre-hydration matching. |
| **H9** (L3-7) | `AppDelegate.swift:136-164`; `SetupWizardView.swift:6-10, 155-167`; `ProfileManager.swift:81-88, 1216-1253` | The wizard knows only Claude; setup-complete means the focused profile has credentials. | A Codex-only install auto-imports "Codex (email)" as a third profile but the focus stays on the empty "Account 1", so "Claude Code login required" reopens on every launch until the user activates the Codex profile manually. | n/a | Treat any credentialed profile (or a valid auth.json) as setup-complete; add a Codex detection tile. |

### Medium

| ID | file:line | Defect | Failure scenario | Fix |
|---|---|---|---|---|
| **M1** (L1-4; audit M8 open) | `CodexUsageService.swift:461-471` | A 401 force-rotates the refresh-token family (`freshFor` 10 y) once per 15 min even for the active owner whose running CLI holds the old refresh token in memory; the cooldown is burned (`:467`) before `ensureFreshCredentials` can return `false` on a mutex loss or dead flag. | Reuse detection can revoke the family under the CLI (a plausible origin of the dead flags); a lost race blocks the forced refresh for 15 min. Claude never force-refreshes on 401. | Adopt from auth.json and re-fetch before any forced redemption for the owner; set the cooldown only when a redemption was attempted. |
| **M2** (L2-8, L3-2) | `MenuBarManager.swift:2625-2639, 3171`; `StatusBarUIManager.swift:1064-1071`; `PopoverContentView.swift:752-786` | A server-affirmed Codex 429 stamp (`rateLimitedUntil`) drives the trigger and candidate exclusion via `effectiveSessionPercentage`, but weekly-only tiles paint `weeklyPercentage`, `isWeeklyMaxed` ignores the stamp, the popover's throttle caveat lives inside the hidden session block, and a stamped `.empty` loses `hasSessionWindow`. | The app switches away from a Codex account whose tile shows a green stale 57 %, "for no reason". | Honour `rateLimitedUntil` in the weekly-only render path and `isWeeklyMaxed`; carry `hasSessionWindow` into the stamped `.empty`. |
| **M3** (L3-8) | `StatusBarUIManager.swift:1132-1136`; `PopoverContentView.swift:379`; `ProfileManager.swift:1233`; `NotificationManager.swift:134, 203` | Tile labels are the first three letters of the name; every import is "Codex (email)" → "Kestrel"; `menuBarLabel` exists but no view edits it; renaming changes the notification dedup key (keyed by name). | With many Codex accounts the user must invent three-letter names by hand (already did: "Kestrel", "Osprey"). | A label field in the profile row; derive a unique default label for imports; key dedup by profile id. |
| **M4** (L3-6) | `StatusBarUIManager.swift:1669-1716`; `MenuBarIconRenderer.swift:151-176` | Single-profile mode renders the session metric from `displaySessionPercentage` with no `providesSessionWindow` branch. | Focusing a Codex profile in single mode shows "S 0 %" with a seven-day "next session" countdown. | Substitute the weekly gauge when `!providesSessionWindow`. |
| **M5** (L3-9) | `AppDelegate.swift:282-289`; `Localizable.strings:245, 247` | No `didReceive` handler: notification taps do nothing; the "re-sync in Settings → Codex Account" instruction is prose only. | A dead-login notification cannot take the user to the fix. | Implement `didReceive` → `.settingsSectionRequested`. |
| **M6** (L2-7) | `MenuBarManager.swift:2346-2358` | `attributeRateLimitEvent` uses the first switch after a Claude transcript event in the provider-mixed history. | Once Codex switches are frequent, server-affirmed Claude exhaustion events are dropped whenever a Codex switch came first. | Filter the history to Claude profiles before `first(where:)`. |
| **M7** (L2-10) | `MenuBarManager.swift:3310-3323` | The "next profile" hotkey walks the array regardless of provider and marks the switch user-initiated. | "Next" from a Claude account can be a Codex profile, silently rewriting auth.json under running codex sessions and suppressing auto-switch-away. | Cycle within the focused profile's provider group. |
| **M8** (audit M4, M5, M6, M7, M9-analog, L7 — all still open) | `CodexUsageService.swift:302 (mutex returns false), 337 (try? writeAuthFile), 63 (chmod swallowed), 560/582 (fabricated reset: now / now+7 d), 135-138 vs 316 (undecodable JWT = "valid" vs `.distantPast`), 47 (main-actor Data(contentsOf:))` | Unchanged since 2026-09-01. | The fabricated reset feeds `nextWeeklyReset`, hence the auto-switch ranking and the tile countdown; the write-back swallow is the "refresh token was revoked" path. | As in the previous audit; the Claude side's `unknownResetSentinel` is the model for the reset case. |
| **M9** (L4-1; live item 6) | `LocalLimitSignalService.swift:11-20, 47, 175` | Zero-network limit signals are Claude-only; the Codex CLI writes richer per-turn `rate_limits` snapshots than Claude does. | The CLI's own account can be at 95 % while the widget cannot read it (401 loop) — the Codex twin of the 2026-08-12 'Harbor' incident. `session_meta` has no account field; the stable `limit_id` per account (6,577 of 6,612 samples share one) could be stamped at sync time, or attribution can follow `switchHistory_v1` as for Claude. | Read the latest `token_count.rate_limits` from `~/.codex/sessions` for the Codex owner. |
| **M10** (L3-13) | `ProfileManager.swift:206-209` | Deleting the active Codex owner nils the pointer and leaves auth.json intact. | The CLI stays logged into an untracked account; no Active badge, no auto-switch owner, no prompt to sync or log in. | Notify and offer Sync-into-new-profile. |
| **M11** (L4-5) | `CodexUsageService.swift:36-40`; `Constants.swift` | `CODEX_HOME` (honoured by the codex CLI) is ignored; no Codex constants are centralised. | A relocated Codex home is silently unsupported. | Resolve `CODEX_HOME` like `ClaudePaths` does `CLAUDE_CONFIG_DIR`. |
| **M12** (L1-10) | `ProfileManager.swift:388-392` | Outgoing Codex re-adoption keys only on `activeCodexProfileId` (Claude falls back to the focused profile) and saves the roster off the main actor. | A nil pointer mid-run skips adoption and can strand a rotated refresh token. | Mirror the Claude fallback and the main-actor save. |

### Low

| ID | file:line | Note |
|---|---|---|
| **L1** (L2-9) | `MenuBarManager.swift:2718-2721, 2880-2893` | Weekly-only Codex has no proactive trigger: the 95 % session threshold is meaningless, only the 99 % weekly threshold fires, and a candidate at 98 % weekly is eligible. Correct under the shared-threshold rule, but the "switch before sessions stall" goal is lost. Consider a per-provider primary-window threshold. |
| **L2** (L2-11) | `:2705-2712` | `autoSwitchWalkInFlight` is one flag across providers; a long Claude walk defers a Codex trigger to the next sweep. |
| **L3** (L2-12) | `:2840-2843` | All candidates ineligible → log line only, retried every trigger; no notification for any provider. |
| **L4** (L2-13) | live plist | `autoSwitchCustomOrder`/`autoSwitchCustomOrderEnabled` reference no code (0 hits); stale keys. |
| **L5** (L3-10/11/12) | `PopoverContentView.swift:575-592`; `ManageProfilesView.swift:568`; `SettingsView.swift:~236`; `Localizable.strings:226, 253` | Claude status line and URL under a Codex popover; Claude-only "connected" seal; ~12 hard-coded Codex-adjacent strings; `codex.benefit_1`/`codex.subtitle` still promise "5-hour session and weekly windows". |
| **L6** (L4-2/3) | `AppError.swift:263-268`; `ErrorRecovery.swift` | `.apiUnauthorized` recovery text is Claude session-key wording; `shouldRetry`/`executeWithRetry`/`isCircuitOpen` have zero callers. |
| **L7** (L4-4) | `CodexUsageService.swift:511` | `.localized` (main-actor) referenced from `nonisolated static usageFetchError`; the only Codex-specific isolation warning, an error under Swift 6. |
| **L8** (audit H10 open) | `ProfileManager.swift:1217-1218, 1249` | One-time import flags bypass the test-suite isolation; the host reads the real system Keychain 27× per run. |
| **L9** (L4-7) | Keychain | 66 orphaned `com.claudewidget.*` items beyond the 21-profile roster (48 `cli-creds`); `deleteProfile` does not remove items. |
| **L10** (audit L2 open) | `ProfileManager.swift:195-230` | No `forgetProfile` for Claude dead logins; `claudeDeadLogins_v1` grows unbounded. |
| **L11** | `CodexUsageService.swift:591` | `Codex: usage parsed …` carries no profile name; with two accounts the only way to attribute a line was the percentage. |
| **L12** (L3-14) | — | `switchHistory_v1` has no UI consumer. |

## Provider-parity table

Line refs are `MenuBarManager.swift` unless noted.

| Behaviour | Claude | Codex | Grok |
|---|---|---|---|
| Switch trigger checks the provider owner | yes 1487/1580 | yes 1487/1580 | only with ≥2 Grok profiles 2685 |
| Session eligibility | yes 3217 | vacuous (session 0) | vacuous |
| Weekly eligibility | yes 3225 | yes 3225 | yes |
| Fable-weekly check | yes 3235 | pass-through | pass-through |
| Candidate preflight | yes 2926 | **never fires** (H1) | never |
| Preflight / gate liveness | JWT expiry | JWT expiry — **wrong for 10-day tokens** (C2) | JWT expiry |
| Inferred (suspected) throttle | yes 1520 | no, by design | no |
| Header 429 stamp | yes 2625 | yes, but **display-blind** (M2) | same as Codex |
| Burst backoff | yes 2447 | yes 2447 (#47) | yes |
| Burn-rate projection | yes 2280 | no (gated 2236) | no |
| Local zero-network signals | yes 2324 | **none, data exists** (M9) | none |
| Threshold notifications | single-profile mode only 1811 | **never** (H5) | never |
| Switch notification | yes 2812 | yes 2812 | yes |
| Dead-login fetch skip | yes 1413 | **no** (H2) | no |
| Fetch budget / staleness scheduler | yes 1279 | **none** (H6) | none |
| Unmeasurable-owner rescue | Keychain fallback 1636 + identity adoption 1591 | **none** (H3) | none |
| Owner re-derivation at sweep end | yes (identity) | **launch only** (H4) | n/a |
| `/login` or `codex login` revives a dead profile | yes (`markLoginRevived`) | **no** | no |
| Duplicate-account guard on Sync | yes (identity) | **no** (H8) | no |
| Queue / manual-activation protection | yes | yes | yes |
| Credential views (Sync, Remove, claim owner, masked token, last-synced, inline error) | yes | yes | yes |
| Wizard | yes | **no** (H9) | no |

## Test coverage (Codex behaviours without a test)

Adoption freshness (`adoptAuthFileIfSameAccount` same-account gate, `last_refresh`-only rotation, cross-account refusal); refresh rotation and auth.json write-back; dead-flag set/clear/persist; 401 forced refresh and its cooldown; missing-`reset_at` handling; auto-import; the activation gate for a Codex target; owner-pointer resolution with ≥3 Codex profiles; the auto-switch trigger with a real weekly-only fixture (`hasSessionWindow = false`, session 0, weekly 99); popover rendering for a Codex profile. `testCodexStyleUsageWithoutFableWindow` models only `fableWeeklyPercentage = nil`. Three `last_refresh` tests assert only non-nil (audit L13).

## Verified sound

- The same-provider rule is airtight in the auto-switch: `findNextAvailableProfile`, the queue and trigger arming all key on `providerKind`; only the hotkey (M7) crosses providers.
- `activateProfileDetailed` takes the switch guard before its first await, claims the Codex pointer synchronously after the apply, and sweeps bail on `isSwitchingProfile`; a gated switch keeps the outgoing login and pointer.
- `adoptAuthFileIfSameAccount` is `account_id`-matched and freshness-checked on both expiry and `last_refresh`; a new-family `codex login` for the matching account adopts correctly (observed live at 13:49:57).
- `ProfileStore` gives `codexCredentialsJSON` the same guarantees as `cliCredentialsJSON`: Keychain-only, merge-on-save, explicit clear with tombstone, hydration fill, `flushKeychainWrites` after redemption.
- `resolveProviderActiveAccounts` prefers auth.json's `account_id` over the persisted pointer and treats absence as evidence only after hydration is `.ready`; `codex logout` (missing auth.json) is benign.
- Codex fetches never consume the Claude 2-per-30 s budget or pacing; burst backoff streaks are per profile; `recordClaudeUsageSuccess` counts only Claude fetches as IP-control evidence; inference/projection never stamp Codex.
- Audit items H2, H3, H4, H5, H6, H8, M1–M3 are closed at HEAD and covered by tests (`RetryAfterTests`, `CodexUsageServiceTests`, `AutoSwitchExhaustionTests`, `SharedDataStoreTests`).
- Codex notification identifiers cannot collide with Claude/Grok ones; the popover hides the session row and per-model rows for Codex and shows the Codex email note; group navigator chips follow painted order and scroll.
- The test suite writes to the isolated `com.claudeusagewidget.tests` suite for profiles and pointers, makes no network requests and rewrites no shared login (only the one-time import flags leak, L8).

## Recommended order of attack

1. **C1 + C2** — dead-flag lifecycle and a flag-aware, probe-backed gate/preflight. This is what took `Osprey` down today and it will happen to every account added through `codex login`.
2. **C3** — write verification and per-sweep re-assertion of single-shot keys; extend the degradation signal to write failures.
3. **H4 + H3** — sweep-end Codex owner re-derivation and adoption; unmeasurable-owner escalation and tile tint.
4. **H2 + H6** — dead-login skip / 401 backoff and a Codex fetch budget, before the roster grows past a handful of Codex accounts.
5. **H1 + H5** — preflight and threshold notifications on the weekly window.
6. **H7 + M3** — composite overflow measurement and tile labels; visible the day a third Codex tile appears.
7. **H8, H9, M1, M2, M9**, then the rest.

## Operator notes for the live state

- **`Osprey` is dark and will stay dark** until `codex login` as Osprey followed by Settings → Codex Account → Sync on Osprey. Running that is also the experiment in live item 7: watch whether `Kestrel` starts 401-ing afterwards.
- **Do not rely on the on-disk pointers or dead sets** until C3 lands; the running process is right. A relaunch will re-flag `Kestrel` — press Sync on `Kestrel` afterwards. The CLAUDE.md cfprefsd recovery (kill app, kill cfprefsd) would discard the correct in-memory state for the stale on-disk one, so it is the wrong tool for this episode.
- `defaults read com.claudeusagewidget.app activeCodexProfileId` should name the profile whose `account_id` matches `~/.codex/auth.json`; today it does not.
