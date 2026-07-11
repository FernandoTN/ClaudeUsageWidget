# Shipping Notes

What a downstream user or maintainer must know before adopting this project. The user-facing story is in `README.md`; the engineering invariants are in `CLAUDE.md`.

## Identity

The app ships with neutral identifiers:

| Setting | Value | Where |
|---|---|---|
| Bundle identifier | `com.claudeusagewidget.app` (tests: `.tests`) | `project.pbxproj` |
| GitHub URL | `github.com/FernandoTN/ClaudeUsageWidget` | `README.md` — the repo's public location; changes only if the repo is transferred |

Two **legacy** identifiers from the original author's builds remain in `Shared/Utilities/Constants.swift`, deliberately: they name historical storage locations that one-time migrations read FROM (`legacyBundleIdentifier` = the pre-rename UserDefaults domain, `legacyAppGroupIdentifier` = an ancient app-group suite). They are migration sources only — never write to them, and never "clean them up" while any pre-rename install might still upgrade. The `LICENSE` copyright line also keeps the original author's name (legal attribution).

**If you change the bundle identifier again**: it IS the UserDefaults domain, so you must add another migration like `MigrationService.migrateLegacyBundleDefaultsIfNeeded()` (runs first thing at launch; copies the old domain's keys when the new domain has no `profiles_v3`). Credentials survive any rename: Keychain service names (`com.claudewidget.<key>-<profileUUID>`, `com.claudeusagetracker.*`) never derived from the bundle id.

## Signing model (deliberate)

- The app is **ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`, no `DEVELOPMENT_TEAM`). Anyone can clone and build with zero signing setup.
- Consequence: the code signature changes on every build, so per-app Keychain ACLs ("Always Allow") never survive a rebuild. The app compensates — see "Code signing" and "Credential storage" in `CLAUDE.md`. If you switch to a real Developer ID, those workarounds keep working but become unnecessary; do NOT remove them unless every user has a stable-signature build.
- Hardened runtime is enabled with `com.apple.security.cs.disable-library-validation` and network-client; the app is **not sandboxed** (it must read/write `~/.claude` and `~/.codex` and shell out to `/usr/bin/security`). Sandboxing would break the CLI-sync features.
- No notarization: users who download a built .app (rather than building locally) will hit Gatekeeper. Distribute as source, or sign+notarize with your own Developer ID.

## External surfaces the app depends on

These are reverse-engineered/undocumented and can change under you:

- `api.anthropic.com/api/oauth/usage` — Claude usage for CLI OAuth logins. Rate limit measured at ~2 requests/30s/IP (the sweep budget in `MenuBarManager` assumes this).
- `console.anthropic.com/v1/oauth/token` — Claude Code OAuth refresh (public client id in `ClaudeCodeSyncService`). Refresh tokens rotate on every redemption.
- `claude.ai` internal usage endpoints — session-key based fetches.
- `chatgpt.com/backend-api/wham/usage` + `auth.openai.com/oauth/token` — Codex usage/refresh (public client id in `CodexUsageService`).
- The Claude Code CLI's Keychain item (`Claude Code-credentials`, or `Claude Code-credentials-<hash>` since CLI v2.1.52) and `~/.claude/.credentials.json`; the Codex CLI's `~/.codex/auth.json`.

The two OAuth client ids in the source are the CLIs' **public** identifiers, not secrets.

## Known gaps (state as shipped)

- **Codex onboarding**: the setup wizard only covers Claude. Codex accounts arrive via one-time auto-import of `~/.codex/auth.json` plus manual Settings → Codex Account → Sync for additional accounts.
- **Localization is vestigial**: only `en.lproj` ships, `Localizable.strings` is mostly unused (≈3 `NSLocalizedString` call sites; UI strings are hardcoded in code, e.g. the "Active" badge).
- **Per-sweep UI churn**: every profile's usage save reassigns the `@Published` profiles array (~1 save per fetched profile per sweep), so the popover/Settings re-render more than strictly needed. Cosmetic.
- **`AppDelegate.hasValidSystemCLICredentials`** runs a synchronous `security` subprocess on the main thread during launch, but only when the active profile has no credentials at all (pre-setup states). Worst case is a slow first frame, not a deadlock; left as-is deliberately.
- **Tests are hosted in the app**: `xcodebuild test` launches a live menu-bar instance of the app on the machine running the tests (it reads the same UserDefaults domain). Fine for CI on a throwaway account; know that on a dev machine it briefly runs the real app.
- Pre-existing Swift concurrency warnings in `MenuBarManager`/`AppDelegate` are documented as intentionally left (`CLAUDE.md`).

## Release checklist

1. `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project "Claude Usage.xcodeproj" -scheme "Claude Usage" -configuration Release -destination 'platform=macOS' build`
2. `xcodebuild test` (same style) — all suites must pass.
3. Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.pbxproj`.
4. Verify the privacy claim still holds: `grep -rn "https://" "Claude Usage" --include='*.swift'` should show only the six documented hosts.
5. If distributing a binary: sign with a real identity and notarize, or tell users to build from source.
