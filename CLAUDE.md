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
- `KeychainService.makeUnrestrictedAccess` builds a permissive `SecAccess` (allow-all, no
  prompt) attached to every item it adds, so a changed code signature never triggers a
  modal SecurityAgent prompt.
- `ProfileStore` runs a one-time **v2 migration** (`credentialsRepairedToKeychain_v2`):
  recovers credentials from the old plaintext JSON, strips the leak, and rebuilds the
  per-profile Keychain items with clean ACLs on a background queue.
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

The app contacts only `claude.ai`, `api.anthropic.com`, `console.anthropic.com`, and
`status.claude.com`. There is no telemetry — keep it that way.

## Layout

`README.md` has the directory tree. Key areas:

- `Shared/Services/` — `ClaudeAPIService` (usage fetch), `KeychainService`,
  `ProfileManager`, `ClaudeCodeSyncService` (CLI credential sync).
- `Shared/Storage/` — `ProfileStore` (profiles + credential cache), `SharedDataStore`.
- `Shared/Models/` — `Profile`, `ClaudeUsage`, `APIUsage`, icon config.
- `MenuBar/` — `MenuBarManager` (orchestration), `MenuBarIconRenderer` (CoreGraphics).
- `Views/` — `SettingsView`, `SetupWizardView`, `Settings/`.
