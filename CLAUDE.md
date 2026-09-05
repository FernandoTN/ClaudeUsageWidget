# CLAUDE.md

Working notes for this repository. See `README.md` for the user-facing overview.

Claude Usage Widget is a privacy-focused macOS **menu-bar agent** (SwiftUI + AppKit,
macOS 14+) that shows Claude Max usage. It has no dock icon and no main window — the UI
is a status-bar icon plus a popover, and a `Settings` scene.

## Building & running

`xcodebuild` requires full Xcode. On a machine where `xcode-select` points at the
Command Line Tools, prefix builds with `DEVELOPER_DIR` (avoids a global `sudo xcode-select`):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -configuration Release -derivedDataPath /tmp/cuw_build \
  -destination 'platform=macOS' build
```

Install: replace `/Applications/Claude Usage.app` with the product at
`/tmp/cuw_build/Build/Products/Release/Claude Usage.app`. That `/Applications` copy is what
launches on restart / login.

Tests: `xcodebuild test -scheme "Claude Usage" -destination 'platform=macOS'`

### Verifying a running build

There is no window to inspect — it's a menu-bar agent. Verify runtime health by sampling
the process:

```bash
sample "$(pgrep -x 'Claude Usage')" 3
```

A healthy main thread sits in `NSApplication run` → `mach_msg` (parked in the event loop).
If the main thread is in `SecItemCopyMatching`, a `security` subprocess, or any blocking
call, the UI is frozen. The app logs via `os.log`; read it with
`log show --predicate 'process == "Claude Usage"' --info --last 10m`.

**Idle CPU.** The legitimate steady state is ~1.5 % of a core (measured 2026-09-05 on
pid 91164: a 30 s sweep of ~8 network fetches, the telemetry slices and a repaint). Two
regressions that pushed it to 10 %: the rollout scan reading 55 MB per sweep (#160) and
`ProfileStore.loadProfiles()` decoding the roster 44 times a minute (now served from a
decoded copy while the stored bytes are unchanged).

**Notifications.** Every user notification goes through `NotificationManager.deliver`,
which logs `Notification: <category> id=<dedupe key> title=… profile=…` per send and is
silent under XCTest; the last 64 sends are kept in `recentDeliveries`. Band alerts and
reset notices dedupe through the persisted `sentNotifications` ledger, one key per
(profile, type, threshold) per window.

## Code signing — important

The app is **ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`). Its code signature changes on
*every build*. macOS Keychain ACLs identify trusted apps by signature, so any per-item
ACL or "Always Allow" grant is invalidated by the next rebuild. Keychain items this app
manages must therefore use **permissive ACLs**, not per-app trust (see below).

## Concurrency model — important

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set: every unannotated type and method is
implicitly `@MainActor`. Language mode is Swift 5, so isolation violations are **warnings,
not errors**.

Consequence: blocking work does **not** automatically move off the main thread. Any
Keychain call, `security` subprocess, or synchronous I/O runs on the main thread unless
explicitly dispatched off it — and on the main thread it can freeze the whole UI.

- Move blocking work to a background `DispatchQueue` (see `ProfileStore.keychainQueue` and
  `ProfileManager.runOffMainActor`). The `DispatchQueue` pattern compiles without isolation
  warnings; `Task.detached` does the same job but emits many warnings here.
- Pre-existing concurrency warnings in `MenuBarManager` and `AppDelegate` (timer / observer
  closures touching `@MainActor` state) are known and were intentionally left untouched.

## Credential storage — important

Credentials live **only in the macOS Keychain**, never in UserDefaults:

- `Profile.CodingKeys` deliberately excludes `claudeSessionKey`, `apiSessionKey`, and
  `cliCredentialsJSON`, so they are never serialized into the `profiles_v3` JSON.
- `ProfileStore` keeps an in-memory credential cache. `loadProfiles()` reads the cache —
  **never the Keychain on the calling thread**. All Keychain writes go to `keychainQueue`.
  It also keeps the decoded roster beside the `profiles_v3` bytes it came from: a read
  whose bytes equal the cached bytes is served without a JSON decode (~22 calls per
  sweep, 44 decodes a minute before 2026-09-05), and any writer of the key invalidates
  it by construction. The cfprefsd fallbacks below sit in front of that cache.
- `saveProfiles` uses **merge semantics**: a nil credential field never deletes anything.
  Profiles loaded before the background cache hydration finished carry nil credentials,
  and saving such a stale copy used to diff nil-vs-cached and enqueue Keychain deletions
  (silent total credential loss on a slow Keychain). Intentional removal goes through
  `ProfileStore.clearProfileCredential(_:key:)` — never through saving a nil field.
- `KeychainService.makeUnrestrictedAccess` builds a permissive `SecAccess` (allow-all, no
  prompt) attached to every item it adds, so a changed code signature never triggers a
  modal SecurityAgent prompt.
- `ProfileStore` runs a one-time **v2 migration** (`credentialsRepairedToKeychain_v2`):
  recovers credentials from the old plaintext JSON, strips the leak, and rebuilds the
  per-profile Keychain items with clean ACLs on a background queue.
- `ClaudeCodeSyncService.readSystemCredentials` is **Keychain-first**: the CLI writes
  logins and silent token refreshes ONLY to the `Claude Code-credentials` Keychain item,
  never to `.credentials.json` — and this app rewrites that file on every profile switch,
  so reading the file first re-ingests the app's own stale write (this was the bug behind
  "Resync never updates the token" and the forced CLI re-login on every switch). When both
  sources hold valid JSON, the later-expiring token wins. The read shells out to
  `security`, so keep it off the main thread (`readSystemCredentialsOffMain()` exists for
  main-actor callers).
- `ClaudeCodeSyncService.ensureFreshCredentials` **self-heals stale CLI OAuth tokens**:
  it adopts the CLI's silently-refreshed token from the system Keychain (active profile
  only — the shared item always holds the ACTIVE account's login) and, failing that,
  redeems the refresh token against `console.anthropic.com/v1/oauth/token` exactly like
  the CLI does. The refresh token ROTATES on success, so the result must be persisted
  everywhere the old one lived (profile store + system Keychain + credentials file).
  `MenuBarManager` runs this before every usage fetch and `ProfileManager` before every
  profile switch — an expired stored token must never freeze the displayed usage (that
  was the "usage only updates after a manual CLI resync" bug). Correspondingly,
  `Profile.hasUsageCredentials` counts CLI credentials that are expired but carry a
  refresh token as usable.
- `ClaudeCodeSyncService.writeSystemCredentials` syncs credentials to BOTH
  `~/.claude/.credentials.json` and the shared `Claude Code-credentials` system Keychain
  item — the Claude Code CLI reads the Keychain as its source of truth, so an in-app
  account switch only reaches the CLI if that item is updated. The Keychain update
  shells out to `/usr/bin/security add-generic-password -U`: the `security` tool runs
  inside the item's `apple-tool:` partition, so it updates silently. A `SecItem*` write
  from this app (ad-hoc signed, not in that partition) raises a SecurityAgent prompt
  that "Always Allow" cannot defeat, so the API path is deliberately avoided.

**Rule: never read Keychain item *data* on the main thread.** It can raise a modal prompt;
the prompt needs the main thread; the main thread is blocked waiting for it → deadlock.

## Preferences (cfprefsd) degradation — important

macOS's preferences daemon can lose access to plist files **while the app is running**,
system-wide. Verified live 2026-09-01 (root cause that time: ~117k leaked test-suite
plists bloating `~/Library/Preferences`, since removed).

**Symptoms — they read as "the app crashed", but the process is healthy:**

- `defaults read com.claudeusagewidget.app` returns an empty dict (`<dict/>`) while
  `~/Library/Preferences/com.claudeusagewidget.app.plist` is intact on disk (39 KB, all
  keys present).
- IN-PROCESS `UserDefaults.standard` reads return nil for every key too — so the tiles
  and popover go blank and the saved `.progressBar` config repaints as `.concentric`.
- Every `UserDefaults` write is rejected. A settings change appears to take, then
  reverts. The daemon's own log says `rejecting write of key(s) … because Path not
  accessible`.
- It can begin MID-RUN (measured: 26 minutes after a launch that loaded 20 profiles
  fine). `ProfileStore.loadProfiles()` runs many times per 30-second sweep, so one nil
  read empties the UI.
- No crash report is produced and the main thread is parked normally in
  `NSApplication run` — `sample` shows a healthy process.

**What the app does about it** (`ProfileStore`, "Preferences degradation resilience"):

1. **Last-known-good shadow.** Every successful read and every write records what the
   process believes. A read that comes back absent while the shadow holds a value is
   served from the shadow — profiles, display mode, multi-profile config, and the three
   active-profile pointers. Serving cached values logs once per episode and never
   demotes to a type default.
2. **Cold-launch plist fallback.** With nothing yet in the shadow, `profiles_v3` is read
   straight out of `~/Library/Preferences/<bundle id>.plist` with
   `PropertyListSerialization`. **Read-only, always** — the app never writes that file.
   Disabled under XCTest unless a test injects a path.
3. **Empty-overwrite guard.** `saveProfiles([])` is refused while a non-empty roster is
   known, which is the actual data-loss path: hold an empty list because of a wedge,
   persist it after the daemon recovers, lose the real roster. A deliberate delete-all
   passes `allowEmpty: true` (no in-app caller does today —
   `ProfileManager.deleteProfile` refuses to delete the last profile).
4. **Degradation signal.** `ProfileStore.preferencesDegraded` posts
   `.preferencesDegradedStateChanged`; `ProfileManager` republishes it and fires one
   user notification per episode, and the popover shows a banner that outranks the
   other status banners. Reads and writes are tracked as separate halves: the read
   half clears on the first read that agrees with the shadow, the write half on the
   first sweep that finds every single-shot key in the store, and the banner shows
   while either is open. The app never restarts cfprefsd itself.
5. **Single-shot write check** (`PreferenceWriteJournal`, added for the 2026-09-03
   episode). Writes fail INDEPENDENTLY of reads: cfprefsd rejected writes for two
   minutes while every read stayed healthy, so the shadow above saw nothing. Keys
   rewritten every sweep (`profiles_v3`, `measuredSessionHistory_v1`) healed
   themselves; keys written ONCE — the three active-profile pointers,
   `switchHistory_v1`, `autoSwitchQueue`, settings toggles — were still stale on disk
   an hour later. Every such write is now remembered with its intended value and
   checked once per sweep from `MenuBarManager.refreshUsage`; a key missing from the
   store is rewritten on the spot and raises the banner on a second consecutive miss.
   **There is no oracle at write time** — measured 2026-09-03, every in-process
   read-back (`UserDefaults`, `CFPreferencesCopyAppValue`, `CFPreferencesCopyMultiple`,
   a fresh `UserDefaults(suiteName:)`) returns the value the daemon threw away and
   both synchronize calls return `true`, while the on-disk plist, the only source
   that disagrees, lags a HEALTHY write by 2.5–10 s. Hence the deferred check and the
   20 s flush grace; an immediate read-back reported 39 of 41 healthy writes as
   rejected. The three `*DeadLogins_v1` sets still write straight to
   `UserDefaults.standard` from their services and are NOT covered yet — route them
   through the journal when those files are next touched.

**Manual recovery (operator):**

```bash
cp -p ~/Library/Preferences/com.claudeusagewidget.app.plist ~/Desktop/cuw-prefs-backup.plist
pkill -x "Claude Usage"          # kill the app FIRST — never let it persist an empty roster
killall -9 cfprefsd
open -a "Claude Usage"
defaults read com.claudeusagewidget.app | grep -c profiles_v3   # expect 1
log show --predicate 'process == "Claude Usage"' --info --last 2m | grep "Loaded .* profiles"
```

The `defaults read` count and the "Loaded N profiles" log line are the two checks that
confirm recovery — N must match the real roster, not 1.

## Networking

The app contacts only `claude.ai`, `api.anthropic.com`, `console.anthropic.com`,
`status.claude.com`; for Codex accounts — `chatgpt.com` (usage) and
`auth.openai.com` (token refresh); and for Grok accounts —
`cli-chat-proxy.grok.com` (usage/billing) and `auth.x.ai` (token refresh).
There is no telemetry — keep it that way.

## Grok accounts

`GrokUsageService` is the third provider, mirroring the Codex design: a
profile's `grokCredentialsJSON` (Keychain key `grok-creds`) holds a full copy
of `~/.grok/auth.json` — an OIDC login keyed `"<issuer>::<client_id>"` whose
entry carries `key` (JWT access token, ~6h), a rotating `refresh_token`,
ISO-8601 `expires_at` (6-digit fractional seconds — `parseISODate` normalizes),
and identity (`user_id`/`email`/`team_id`). Usage comes from
`GET cli-chat-proxy.grok.com/v1/billing?format=credits` (Bearer +
`x-grok-client-mode: grok-build` — the CLI's own billing call, endpoints
reverse-engineered from the grok binary's `billing.rs` strings and verified
live 2026-07-17): `config.currentPeriod` (WEEKLY for SuperGrok) →
`weeklyResetTime`, `creditUsagePercent` (omitted while zero; numeric fields
may be `{"val": n}`-wrapped) → `weeklyPercentage`. Grok has no 5h session
window, so `sessionPercentage` is 0 with the period end as its reset. Token
refresh: `POST auth.x.ai/oauth2/token` with the entry's client_id; rotated
refresh tokens persist to the profile store AND back to auth.json
(same-`user_id` only). A one-time auto-import (`grokAutoImported_v1`) creates
a profile named "GROK" from an existing CLI login. Grok is its own
auto-switch/menu group (`Profile.providerKind`); the menu order is
right-to-left Claude → Grok → Codex, so a freshly-added Grok tile stays
visible next to the Claude group and Codex clips first when the bar
overflows. With one account there is nothing to rotate.

**Shared-login pointer (added with `viewProfile`).** Grok now has the
third provider-active pointer, `ProfileManager.activeGrokProfileId`,
journaled and shadowed exactly like the other two
(`ProfileStore.saveActiveGrokProfileId`). Activating a profile that
carries Grok credentials adopts the outgoing owner's rotated auth.json,
refuses a login that is still expired after the pre-apply refresh (the
CLAUDE side's rule — a ~6h Grok token means expiry IS evidence, unlike
Codex's ~10-day one), writes `~/.grok/auth.json` via
`GrokUsageService.applyProfileCredentials` and claims the pointer with
no awaits in between. The launch resolver matches auth.json's `user_id`
(falling back to the non-secret `grokEmail` stamp before Keychain
hydration) to a profile; it deliberately does NOT run Codex's
exactly-one-profile inference, because nothing wrote that file before
this pointer existed. **Nil is not "no pointer exists" — it is "no Grok
login has ever been applied on this install"**, and
`activeAccountIds(among:)` then falls back to the old focused-or-sole
rule.

## Codex accounts

`CodexUsageService` mirrors the Claude CLI sync design for OpenAI Codex accounts:
a profile's `codexCredentialsJSON` (Keychain key `codex-creds`) holds a full copy of
`~/.codex/auth.json`. Usage comes from `GET chatgpt.com/backend-api/wham/usage`
(`Authorization: Bearer` + `ChatGPT-Account-Id` headers; `rate_limit.primary_window` →
5-hour session, `secondary_window` → weekly) and is stored in `profile.claudeUsage` so
all existing rendering works unchanged. Token refresh uses the Codex CLI's public
client id against `auth.openai.com/oauth/token`; refresh tokens ROTATE, so results are
persisted to the profile store and back to auth.json when it holds the same
`account_id`. Activating a profile with Codex credentials rewrites auth.json (that is
how multi-account switching works); leaving one adopts auth.json back (same-account
check). A one-time auto-import (`codexAutoImported_v1`) creates a "Codex (email)"
profile from an existing CLI login.

**Dead-login lifecycle (2026-09-03 incident).** The dead flag
(`codexDeadLogins_v1`) is a state with BOTH transitions, not a one-way latch:
any 200 from `wham/usage`, any successful refresh, an adoption of a CLI-side
`codex login`, or a manual Sync clears it (`markLoginRevived`), and only a
DEFINITIVE verdict on the refresh grant sets it (`invalid_grant`, or a 401 from
the token endpoint — `refreshFailureIsTerminal`). A usage-endpoint 401 never
flags on its own; it forces one cooldown-gated refresh (allowed even while
flagged) and only that refresh's verdict counts. Before this, one 4xx flagged a
profile forever: the flag then blocked the refresh that would have healed it and
deduped the notification for good, so an account whose 10-day access token was
invalidated externally went dark silently for hours. Because a Codex access
token lives ~10 days, **expiry is not evidence of liveness**: the activation gate
and the candidate preflight both call `isSafeToApplyLogin`, which reuses a 200
measured in the last 5 minutes or probes `wham/usage` once (`livenessVerdict` /
`applyDecision` — 401/403 refuses, a 429/5xx/transport failure is no evidence and
only a standing dead flag refuses on it). A 401 sweep failure now registers a
fetch backoff (5 min doubling to 60; the provider-active account stays at 5) —
one dead profile drew 1,009 401s in nine hours without it. The Codex owner is
re-derived from auth.json's `account_id` at the END OF EVERY SWEEP
(`ProfileManager.adoptCodexLoginByAccountId`, the twin of
`adoptSystemLoginByIdentity`), so `codex login` alone revives a profile. Syncing
is refused when another profile already holds the same `account_id`; the
non-secret `Profile.codexAccountId` stamp makes that match work before Keychain
hydration.

**Multiple accounts: isolated homes, never a second `codex login` in `~/.codex`.**
`codex login` REVOKES, server-side, whatever credentials sit in the home it runs
in before it opens the browser (`codex-rs/cli/src/login.rs`: `login_with_chatgpt`
→ `clear_existing_auth_before_login` → `logout_with_revoke(codex_home, …)`), so a
second login in the default home kills the account the widget applied there —
three died that way on 2026-09-03. The CLI honours `$CODEX_HOME`, so each extra
account is logged in under its own home (`CODEX_HOME=~/.codex-accounts/<name>
codex login`, nothing there to revoke). Two entry points, both landing in
`importFromCodexHome` (same parser, same duplicate-account guard as Sync, stamps
the non-secret `Profile.codexHomePath`): **Import from another Codex home** for a
login the user ran themselves, and **Log in a new Codex account** —
`CodexLoginService` spawns the CLI with `CODEX_HOME` set to a fresh
`~/.codex-accounts/<slug>` (binary resolved from the Homebrew paths then
`zsh -lc 'command -v codex'`, because a GUI app inherits launchd's PATH; 5-minute
timeout; Cancel terminates it; exit 0 with no auth.json is a failure, not a
success). **The login TARGETS THE VIEWED PROFILE** (`loginTarget`) whenever that
profile has no Codex account or its login is flagged dead — replacing dead
tokens in place is the repair, and creating a second profile beside it would
leave an empty or broken one to clean up; only a profile holding a WORKING
account sends the login to a new profile named by a typed label. The isolated
home is the profile's remembered `codexHomePath` when it has one, else one named
after the profile (`loginHome` — `Juniper (dev)` → `~/.codex-accounts/juniper-dev`);
reusing it revokes only that profile's own dead grant, and a remembered path
equal to the default home is refused rather than reused. The duplicate guard runs
BEFORE any profile is created and excludes the destination, so re-logging the
same account into the profile that holds it is a repair, not a duplicate. Neither path writes `~/.codex/auth.json` nor claims the Codex owner
pointer: the widget stays the single writer of the default auth.json, and
activating the profile is what switches the CLI. The default home itself is
`$CODEX_HOME` when set, else `~/.codex` (`resolvedDefaultCodexHome`, audit M11) —
the CLI honours that variable and a hard-coded path would make the two sides
disagree about which file a switch rewrites. The refresh grant sends the CLI's
exact body — `{client_id, grant_type, refresh_token}`, NO `scope`
(`refreshRequestBody`, matching `codex-rs/login/src/auth/manager.rs`
`request_chatgpt_token_refresh`) — because a supplied scope can only narrow the
grant (RFC 6749 §6) and the widget's old `openid profile email` dropped the
`offline_access` the refresh itself depends on. When a dead login's owner no longer matches the account in the
default home, `reloginGuidance` switches the re-login notification to the
isolated-home instruction rather than telling the user to repeat the login that
caused it.

**Rotation hazards** (each learned from a real "refresh token was revoked" CLI
failure): the CLI can rotate ONLY the refresh token, so adoption freshness compares
`last_refresh` as well as the access-token expiry; activation refreshes the target's
tokens first when they expire within 24h (`ensureFreshCredentials(freshFor:)`) so the
CLI is never handed a nearly-expired token whose refresh token may have rotated away;
a 4xx from the token endpoint means the stored refresh token is revoked (e.g. by
`codex logout`) — unrecoverable app-side, so the user gets one notification telling
them to `codex login` + re-sync (same pattern for dead Claude logins → `/login`).
Syncing INTO a profile claims the provider-active pointer
(`claimActiveCodexOwnership` / `claimActiveClaudeOwnership`), and the launch
repair re-derives the Codex owner from auth.json even when a pointer is already set.

**Account identity (Claude)**: the Claude credentials JSON carries NO account id, so
Keychain adoption used to trust the provider-active pointer blindly — during a
switch's suspension points a sweep could copy the incoming account's login into the
outgoing profile (cross-account contamination; a real incident silently relabeled
one account's Max login as another's free profile). Now
`ClaudeCodeSyncService.fetchAccountIdentity` resolves a token's account uuid via
`api.anthropic.com/api/oauth/profile` (cached per token); profiles carry a persisted
`claudeAccountUUID` stamp, every adoption path is account-matched (Codex-style), the
provider pointer is claimed immediately after each apply with no awaits in between,
sweeps never run mid-switch, and a launch repair re-derives the true owner of the
shared login from its live identity — clearing byte-identical contaminated copies
from other profiles (never touching the token itself).

**Duplicate accounts (2026-09-03)**: `stampAccountIdentity` only ever ran for the
profile being APPLIED to the CLI, so a profile synced once and never activated
carried no `claudeAccountUUID` — and every account-keyed check reads nil as "no
evidence". Two live profiles held logins for ONE Anthropic account, invisible to
all of them: one quota drawn as two tiles, two auto-switch candidates that share
it, and an owner who read two exhausted accounts where the API said 19%. Three
mechanisms close it. (1) `ClaudeCodeSyncService.stampNextUnstampedIdentity`, run
at sweep end, resolves ONE unstamped login per sweep, oldest first, with that
PROFILE'S OWN token — never the system Keychain fallback, which holds the ACTIVE
account's login and would stamp every profile with it and manufacture the
duplicates. Ineligible: already stamped, flagged dead, or an expired token (a
background refresh rotates a refresh token the CLI may still hold). Costs nothing
in steady state. (2) `ProfileManager.duplicateClaudeAccountGroups` groups stamped
profiles by account on every roster mutation, logs and notifies once per episode,
and captions the rows in Manage Profiles / CLI Account. It never touches
credentials — which profile keeps the account is the user's call. (3) The
auto-switch candidate filter drops a candidate whose `claudeAccountUUID` matches
the provider-active (or outgoing) profile's: same account, same quota, no
headroom to gain. Consequences for the contamination dedupe in
`adoptSystemLoginByIdentity`: two profiles can now carry the SAME stamp, so
ownership resolves by evidence (stored token == the shared login, then the
standing pointer, then the stamp) instead of array order, and a same-account
profile whose own login is still usable is REPORTED rather than cleared — only
byte-identical copies and dead same-account tokens are still wiped.

**Identity-verified credential writes (the mechanism behind that duplicate)**:
`adoptionAccountMatches` is the guard both AUTOMATIC write paths share — the
pre-switch re-sync of the OUTGOING profile (`resyncBeforeSwitching`, reached from
`activateProfileDetailed`) and the Keychain adoption inside
`ensureFreshCredentials`. It used to return true whenever either side was
unidentifiable, and an UNSTAMPED profile is unidentifiable, so "no evidence"
read as permission. That is how the contamination happened: during the
2026-09-03 cfprefsd write-rejection episode the on-disk active-profile pointers
were stale, the outgoing re-sync trusted the pointer to name the outgoing
profile, and the CLI's login was written into an unstamped profile that held a
different account. The guard now resolves the target from its OWN stored token
first (`stampAccountIdentity`, never from the incoming credentials — that would
make every comparison trivially agree), then decides:
`ClaudeCodeSyncService.credentialWriteDecision` returns `.write` on agreement,
`.refuse` on disagreement, and `.noEvidence` only when neither side can be
identified at all (unchanged behaviour — refusing there would break every
legitimate adoption on a network failure). The CLI login's account comes from
the identity endpoint, falling back to `~/.claude.json`'s cached
`oauthAccount.accountUuid` so a refused network call does not silently downgrade
the guard. A refusal logs once per (profile, refused account) pair and is
counted in `refusedCredentialWrites`, which the duplicate/contamination log line
reports. **Manual Sync has its own guard, the Codex twin, not this comparison**:
`syncToProfile` clears the stamp by design because an explicit sync may bring a
different account (that is the documented `/login` + re-sync repair), so gating
it on the profile's previous account would refuse the repair. It is gated on the
other axis instead: `syncToProfile` refuses when ANOTHER profile is already
stamped with the incoming account (`duplicateAccountHolder` →
`ClaudeCodeError.accountAlreadySynced`, naming the holder), exactly like Codex's
`account_id` check. Evidence is `~/.claude.json`'s `oauthAccount.accountUuid` —
the CLI's own record of who it is logged in as, the parallel of Codex reading
`account_id` out of auth.json: local, non-secret, no network on a user-blocking
path. Absent or unreadable is NO EVIDENCE and permits the sync; the forced
re-stamp that follows then surfaces a duplicate through the detector. `adoptSystemLoginByIdentity`
(identity adoption and the launch repair) needs no separate gate: it already
writes only into the profile whose stamp equals the shared login's live
identity.

**Which side of a shared account to fix**: the duplicate caption says two
profiles share an account; `ProfileManager.profilesNeedingAccountRelogin` says
which one to re-login, and only when the evidence names it. Two sources:
`ClaudeCodeSyncService.isLoginContaminated` — the profile carried a stamp and its
OWN token later reported a different account, which is a write that moved another
account's login into it (recorded at the moment `stampAccountIdentity` sees the
disagreement, because the very next line heals the stamp to match the token and
erases the evidence; persisted under `claudeContaminatedLogins_v1`, cleared on
agreement or an explicit sync) — and, for a duplicate group that CONTAINS the
profile owning the shared CLI login, every other member of it. A duplicate group
the active login is not part of flags nobody: which member is the impostor is
genuinely unknown there, and guessing would tell the user to re-login the profile
they meant to keep. Nothing is ever cleared automatically; the caption
("Re-login needed…") appears on the Manage Profiles row and the CLI Account page.

**Dead-login gate**: `activateProfile` NEVER applies credentials that are still
expired after the pre-apply refresh (both providers). Writing a dead login over the
shared CLI login bricks every running session ("login expired. Please run /login"
in Claude Code — a real incident). A gated switch keeps the outgoing login and the
provider-active pointer in place, notifies once, and returns false so the
auto-switch tries the next ranked candidate instead of no-op'ing.
**The FOCUS is a separate question from the login, and the two answers differ by
who asked.** An AUTOMATIC gated switch moves nothing — pointing the UI at an
account the CLI was never switched to, once per retry, is exactly the confusion
the gate exists to avoid. A USER-initiated one moves the focus and only the focus
(`ActivationOutcome.focusedWithoutApplying`; the Bool wrapper still returns false,
and the candidate walk maps it onto `.credentialsRefused`): the in-app re-login
screens operate on `activeProfile`, so refusing to focus a dead profile made the
one profile that needed repairing the one profile the user could not open —
reported live 2026-09-03, three clicks, three refusals. The user gets one notice
per profile per hour naming which CLI stayed put and where to repair it, and the
generic re-login alert is no longer force-redelivered on that click (the focus
moving is itself the feedback the `force` flag existed to provide).

**Account-level usage throttling (2026-07-16 incident)**: a heavily-used or
exhausted account 429s its OWN `oauth/usage` endpoint — the widget cannot read
the account's state exactly when it matters, and the cached percentages
silently freeze at pre-throttle values (an account sat at a cached 16% while
`/usage` showed 100%). The 429 is therefore treated as usage information,
through two detectors:
- **Header-based**: `stampAccountThrottleIfNeeded` records
  `ClaudeUsage.rateLimitedUntil` when Retry-After ≥ 60s (the 2026-07-16 shape,
  measured 2918s). `effectiveSessionPercentage` reports 100% while the stamp
  is live (propagating to tiles, popover, auto-switch trigger AND candidate
  eligibility through the one shared seam), and sweeps skip fetching the
  throttled profile until the stamp expires.
- **Inferred / SUSPECTED (2026-08-11/12 incidents)**: exhausted accounts were
  also observed refusing usage reads with `retry-after: 0` — indistinguishable
  from per-IP burst noise by header alone (a tile froze at a stale 74% while
  the account had zero capacity). But the reverse also happened: a live probe
  measured 89% on an account DURING its own inferred stamp — the endpoint
  flaps per-request under ambient IP load, so the inference is **evidence of
  suspicion, never proof of exhaustion**. `shouldInferAccountThrottle` marks a
  profile suspected when its consecutive-429 streak reaches 2 (3 for the
  ACTIVE profile — it fetches every sweep and collides with the IP cap first),
  a different Claude profile fetched successfully within the last 90s, AND the
  cached usage is consistent with exhaustion (fresh cache must already read
  ≥85% on some window; a stale cache >15 min old proves nothing and does not
  block). What a suspected stamp (`ClaudeUsage.rateLimitedInferred`) does:
  - **Display shows the last MEASURED value — or, when the account was
    visibly burning, a BURN-RATE PROJECTION — never a synthetic 100**
    (`ClaudeUsage.displaySessionPercentage`, `projectedSessionPercentage`) —
    the tile label turns PURPLE (data-quality tint, precedence: weekly-maxed
    red > suspected purple > active cyan) and the popover explains; a fake
    100% caused a costly manual switch (~10-15% of every concurrent session's
    quota re-reading context), while a FROZEN measured value under-reported
    ('Harbor' displayed 67% for 22 blind minutes at a real 100%,
    2026-08-12). `projectSessionPercentage` extrapolates from the last
    measured samples (needs ≥2 points ≥25s apart, rising ≥0.2pp/min, same
    session window; clamps at 100); the ACTIVE account's projection crossing
    the switch threshold fires a one-shot notification — the switch trigger
    itself stays measured-only.
  - **Never fetch-skipped**: sweeps and manual refresh keep fetching a
    suspect — the next fetch IS the confirmation; a 200 clears everything
    (only server-affirmed stamps skip fetches, they carry a real Retry-After).
  - **Never displaces the active account**: `autoSwitchTriggerUsage` strips
    inferred stamps before the switch trigger; only a measured percentage or
    a server-affirmed stamp may switch away. Candidate headroom checks DO see
    the stamp, so a suspect is never switched INTO. Active account gets a
    one-shot-per-episode notification; `lastUpdated` is never bumped by a
    stamp (no fake freshness).

**Switch forensics + queue**: every successful `activateProfile` records a
`SwitchEvent` (from/to/trigger/reason) into a 30-entry ring buffer
(`SharedDataStore.recordSwitchEvent`, key `switchHistory_v1`) — the unified
log persists nothing for this process, so this is the only durable answer to
"which account was active before". The auto-switch queue (`autoSwitchQueue`)
is consumed ONLY on successful activation (`consumeQueuedSwitchTarget`);
entries ineligible right now stay queued for later walks, and only deleted
profiles are dropped (the old consume-on-try semantics silently ate a user's
queued handoff plan when the target wore a false inferred "100%").

A burst-class 429 that doesn't (yet) meet the inference bar still stops the
sweep from re-fetching every 30s (a real profile drew 90 identical 429s in an
hour): `registerBurstBackoff` backs that profile's usage fetch off
exponentially (2min doubling to an 8min cap for background profiles;
the ACTIVE account retries EVERY SWEEP — 30s cap — because its usage moves
fastest exactly when the shared IP is busiest, and exhausted accounts DO
answer usage reads ('Fjord' returned 200 at a real 100%), so reading
through the noise is safe; in-memory, cleared by the first successful
fetch; a manual popover refresh expires the wait but keeps the streak).

**Blind active account → Messages-API header rescue (2026-08-13 incident)**:
retrying `oauth/usage` through the 429 noise is not enough. 'Iris'
(06:36→06:59) and 'Kite' (12:41→13:40) were burned from a fresh window to
a hard 100% session limit by ~30 parallel CLI sessions while the widget's
gating number for those accounts never even reached the 25% preflight
milestone (log-proven: not one `Preflight[…]`/`AutoSwitch:` line in the 6
hours covering both burns, from code that emits them correctly at 25/50/75%
the next morning) — so no proactive switch was ever armed, the fleet died on
the wall, and the account stayed active for another 36 minutes. The account's
own usage endpoint refuses most reads exactly then: measured live 2026-08-14,
7 refusals (429, `retry-after: 0`) in 8 attempts.

`/v1/messages` is a DIFFERENT rate-limit bucket — the one the fleet's own
requests ride, so it answers whenever the fleet is alive — and its
`anthropic-ratelimit-unified-*` response headers ARE the enforcement counters
(verified live: `unified-5h-utilization: 0.86` in the same minute
`oauth/usage` was refusing everything). So when a 429 blinds the
provider-active CLAUDE account, the sweep (and the manual popover refresh)
falls back to `ClaudeAPIService.fetchUsageFromMessageHeaders` and treats the
result as a real measurement: it takes the full success path — staged usage,
burn history, suspicion cleared, auto-switch checked.

Guards, because this is the only path in the app that SPENDS quota to measure
it (`MenuBarManager.shouldProbeMessageHeaders`): provider-active Claude
account only; its session window must already be OPEN and NON-ZERO — a
request against an idle account would START its 5-hour window and steal
headroom from a reserved switch target; at most one probe per 60s; only after
`oauth/usage` refused. Cost per probe is a `max_tokens: 1` Haiku call (~8
in / 1 out). Header measurements are folded on with
`ClaudeUsage.mergingHeaderMeasurement` — the headers carry no per-model
windows, and a wholesale replace would zero the Fable/Opus weekly
percentages that gate `isQuotaExhausted` — and they do NOT count as
`lastClaudeUsageSuccess` control evidence (different host bucket, so they
prove nothing about `oauth/usage` for other accounts). A 429 on the header
probe whose `unified-5h-status` is no longer `allowed` means the account's
own sessions are being rejected: server-affirmed exhaustion, stamped and
actionable by the auto-switch.

Related: the transcript tripwire's attribution walks PAST Codex/Grok entries
in the shared switch-history ring (`rateLimitEventOwnerName`) — a Codex
switch landing between the Claude death event and the next Claude switch
used to drop the event as "not attributable".

**Transcript events belong to whoever's window they name, not to whoever owns
the login now (2026-09-04 22:53 incident).** Running sessions keep the
previous owner's token for a while after a switch, so a transcript 429 in the
minutes after one is usually the OUTGOING account's. `TranscriptLimitAttribution`
matches the event's parsed reset against the cached `sessionResetTime` of the
owner at event time and of the previous owners from the switch history (15 min
lookback, ±3 min); a previous-owner match stamps THAT profile and never
switches; the current owner is re-measured live first and a reading with
headroom is `contradicted` (no stamp, no switch); for 120 s after a switch an
event that does not match the new owner is never actionable. The switch
history's `from` is now the outgoing OWNER, not the focused profile. Spec:
`docs/specs/transcript-limit-attribution.md`.

**Menu-bar overflow vs stranded tiles**: when the bar overflows, macOS hides
the clipped status items and parks them all at one shared off-edge frame —
`strandedTileDetected` treats duplicate minX values as "overflow-hidden" and
never heals on them (a rebuild cannot make the tiles fit; retrying every
rate-limit window flickered the whole group every ~5 minutes for days). The
failed-heal signature is quantized to 10pt buckets so usage repaints drifting
tile widths a few points can't mint a "new" broken layout each evaluation.

**Candidate preflight**: as a provider-active account crosses 25/50/75/90% of its
session window, `MenuBarManager.preflightCandidates` validates the auto-switch's
predicted target in the background — refreshing a stale token early (proving the
refresh token is alive, banking a fresh access token) and notifying about dead ones
while there is still headroom to `/login` + re-sync. It never refreshes a candidate
that already owns its provider's shared login (that would rotate the family out
from under the CLI); milestones re-arm when usage falls back below 25%.

**One account per provider is active at any time** — Claude, Codex and (since
the Grok pointer landed) Grok. `ProfileManager.activeClaudeProfileId` tracks who
owns the Claude Code CLI Keychain login, `activeCodexProfileId` who owns
`~/.codex/auth.json` and `activeGrokProfileId` who owns `~/.grok/auth.json`;
`activeProfile` is only the *focused* profile, and `ProfileManager.viewProfile`
moves that focus WITHOUT touching credentials, pointers, the switch history or
the `.profileManuallyActivated` mark. Activating a profile replaces ONLY the shared login state of the
provider(s) it carries: the outgoing account of that provider is re-adopted first,
the other provider is never touched. Keychain adoption / syncToSystem decisions key
off `activeClaudeProfileId`, not the focused profile. The session-limit auto-switch
applies the same policy (soonest weekly reset + headroom + per-profile toggle) to
BOTH groups independently and never crosses providers; it fires at configurable
PROACTIVE thresholds — session default 95% (`loadAutoSwitchThreshold`),
weekly/Fable default 99% (`loadAutoSwitchWeeklyThreshold`; tighter because
forfeited weekly quota is gone until the weekly reset) — so running CLI
sessions never hit the hard limit while the ~30s sweep catches up. The SAME
per-window thresholds gate candidate eligibility, which is what makes
ping-pong between two nearly-full accounts impossible. A USER-initiated
activation is never yanked away by the next sweep even when the chosen
account is over a threshold (`.profileManuallyActivated` marks it in
`autoSwitchedProfileIds`; the mark clears once the account regains
headroom). The check runs mid-sweep for the
provider-active accounts (not just at sweep end), and a sweep ends early if a
switch starts while it is walking profiles (Keychain-adoption contamination
hazard); in multi-profile mode both
provider-active accounts are checked after each refresh sweep.

The multi-profile menu bar mirrors that grouping: Codex items sit together at the
far LEFT, Claude items to their right, and within each group the account whose
weekly limit resets soonest is rightmost (`StatusBarUIManager.
multiProfileCreationOrder` — status items are created right-to-left and cannot be
moved, so the group is torn down and recreated when fresh usage reshuffles the
ranking). The ranking key is quantized to the MINUTE: the usage API reports the
same weekly boundary with ±1s jitter across fetches, and two accounts sharing a
boundary would otherwise flip order (= full rebuild = visible flicker) on every
sweep. After a rebuild the icons are repainted on the next runloop — freshly
created buttons report a provisional effectiveAppearance and would otherwise bake
black labels into a dark menu bar. `refreshAllSelectedProfiles` has a reentrancy
guard: sweeps can outlast the timer interval, and overlapping sweeps double API
load (429s) and race token redemptions. Both services also hold a per-profile
refresh mutex and back off dead (revoked) refresh tokens until re-sync.

## Layout

`README.md` has the directory tree. Key areas:

- `Shared/Services/` — `ClaudeAPIService` (usage fetch), `KeychainService`,
  `ProfileManager`, `ClaudeCodeSyncService` (CLI credential sync).
- `Shared/Storage/` — `ProfileStore` (profiles + credential cache), `SharedDataStore`.
- `Shared/Models/` — `Profile`, `ClaudeUsage`, `APIUsage`, icon config.
- `MenuBar/` — `MenuBarManager` (orchestration), `MenuBarIconRenderer` (CoreGraphics).
- `Views/` — `SettingsView`, `SetupWizardView`, `Settings/`.
