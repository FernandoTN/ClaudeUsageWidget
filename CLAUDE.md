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

## Networking

The app contacts only `claude.ai`, `api.anthropic.com`, `console.anthropic.com`,
`status.claude.com`, and — for Codex accounts — `chatgpt.com` (usage) and
`auth.openai.com` (token refresh). There is no telemetry — keep it that way.

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

**Dead-login gate**: `activateProfile` NEVER applies credentials that are still
expired after the pre-apply refresh (both providers). Writing a dead login over the
shared CLI login bricks every running session ("login expired. Please run /login"
in Claude Code — a real incident). A gated switch keeps the outgoing login and the
provider-active pointer in place, notifies once, and returns false so the
auto-switch tries the next ranked candidate instead of no-op'ing.

**Candidate preflight**: as a provider-active account crosses 25/50/75/90% of its
session window, `MenuBarManager.preflightCandidates` validates the auto-switch's
predicted target in the background — refreshing a stale token early (proving the
refresh token is alive, banking a fresh access token) and notifying about dead ones
while there is still headroom to `/login` + re-sync. It never refreshes a candidate
that already owns its provider's shared login (that would rotate the family out
from under the CLI); milestones re-arm when usage falls back below 25%.

**Two accounts are active at any time** — one Claude and one Codex.
`ProfileManager.activeClaudeProfileId` tracks who owns the Claude Code CLI Keychain
login and `activeCodexProfileId` who owns auth.json; `activeProfile` is only the
*focused* profile. Activating a profile replaces ONLY the shared login state of the
provider(s) it carries: the outgoing account of that provider is re-adopted first,
the other provider is never touched. Keychain adoption / syncToSystem decisions key
off `activeClaudeProfileId`, not the focused profile. The session-limit auto-switch
applies the same policy (soonest weekly reset + headroom + per-profile toggle) to
BOTH groups independently and never crosses providers; it fires at a configurable
PROACTIVE threshold (default 95%, `SharedDataStore.loadAutoSwitchThreshold`) so
running CLI sessions never hit the hard limit while the ~30s sweep catches up —
the SAME threshold gates candidate eligibility, which is what makes ping-pong
between two nearly-full accounts impossible. The check runs mid-sweep for the
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
