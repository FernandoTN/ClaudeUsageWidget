# Claude Usage Widget

A privacy-first macOS menu-bar app that tracks usage limits for **multiple Claude accounts and OpenAI Codex accounts** at a glance — with automatic account switching when a session limit is hit.

Built as a stripped-down, heavily extended fork of [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) (MIT license), with all external telemetry removed.

## What It Does

The app lives in your menu bar (no dock icon, no main window) and shows live usage for every account you add:

- **5-hour session** utilization and reset time
- **7-day weekly** utilization (all models) and reset time
- Per-model weekly breakdowns (Opus / Sonnet / Fable) where the plan reports them
- **Codex accounts**: 5-hour and weekly windows from the ChatGPT backend

Color coding: green (< 50%), yellow (50–80%), orange (80–95%), red (> 95%). Click any icon for a detailed popover; the popover can be dragged off to float as a small window.

### Multi-account model

- Add as many profiles as you like; each holds ONE provider's account — a Claude login (claude.ai session, Claude Code CLI OAuth, or API Console) **or** a Codex CLI login.
- **Two accounts are "active" at any time** — one Claude and one Codex. The active Claude account owns the Claude Code CLI's shared Keychain login; the active Codex account owns `~/.codex/auth.json`. Switching profiles in the app also switches what the `claude` / `codex` CLIs are logged into.
- In multi-profile display mode every selected account gets its own menu bar icon: Codex accounts grouped at the far left, Claude accounts to their right, and within each group the account whose weekly limit resets soonest sits rightmost ("use it or lose it" ordering).

### Auto-switch

When the active account's 5-hour session hits 100%, the app switches to the best same-provider candidate: soonest weekly reset first, but only if it still has session, weekly, and per-model weekly headroom. Per-profile opt-out is available in Settings. As usage climbs (25/50/75/90% milestones), the predicted next candidate's stored login is validated in the background so the eventual switch never lands on a dead login — if a candidate's refresh token has been revoked, you get a notification while there is still time to `/login` and re-sync.

### Credential self-healing

OAuth tokens rotate. The app adopts silent token refreshes performed by the CLIs, redeems refresh tokens itself when a stored access token goes stale, persists rotations everywhere the old token lived, backs off dead (revoked) logins instead of hammering the token endpoint, and **never applies an expired, unrefreshable login to the shared CLI state** (a gated switch keeps the outgoing login in place and notifies you instead).

## Privacy Guarantees

The app contacts **only**: `claude.ai`, `api.anthropic.com`, `console.anthropic.com`, `status.claude.com`, and — for Codex accounts — `chatgpt.com` (usage) and `auth.openai.com` (token refresh). There is no telemetry, no auto-update phone-home, no analytics.

Credentials (session keys, OAuth tokens) live **only in the macOS Keychain** on your machine. They are never written to UserDefaults, and never sent anywhere except the provider endpoints listed above. (The one deliberate exception: activating a profile writes that profile's credentials to `~/.claude/.credentials.json` / the shared Claude Code Keychain item / `~/.codex/auth.json` — that is how the CLIs are switched between accounts, and it mirrors what the CLIs themselves store.)

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16+ (full Xcode, not just Command Line Tools) to build
- At least one of:
  - a Claude subscription (claude.ai session or Claude Code CLI login), and/or
  - an OpenAI Codex CLI login (`codex login`)

## Build & Install

### Option A: Xcode

```bash
git clone https://github.com/FernandoTN/ClaudeUsageWidget.git
cd ClaudeUsageWidget
open "Claude Usage.xcodeproj"
```

Build and run (`Cmd+R`). The app appears in your menu bar (no dock icon).

### Option B: command line

`xcodebuild` needs full Xcode. If `xcode-select` on your machine points at the Command Line Tools, prefix with `DEVELOPER_DIR` (avoids a global `sudo xcode-select`):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -configuration Release -derivedDataPath /tmp/cuw_build \
  -destination 'platform=macOS' build
```

Then copy the product to Applications:

```bash
cp -R "/tmp/cuw_build/Build/Products/Release/Claude Usage.app" /Applications/
open "/Applications/Claude Usage.app"
```

The project is **ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`) with no development team, so it builds from a clean clone with no signing setup. See [Troubleshooting](#troubleshooting) for what ad-hoc signing means for the Keychain.

## First-Run Setup

### Claude accounts

1. Launch the app — the setup wizard opens on first run.
2. If you are logged into the Claude Code CLI, the wizard detects it and can import that login directly.
3. Alternatively, sign in to claude.ai through the in-app browser sheet and capture the session, then pick your organization.
4. For more accounts: create a profile in Settings → Profiles, then either capture another claude.ai session, or log the CLI into the other account (`/login`) and use Settings → CLI Account → Sync.

### Codex accounts

There is no wizard step for Codex (yet):

1. If `~/.codex/auth.json` exists (you ran `codex login`), the app auto-imports it once as a "Codex (email)" profile.
2. For additional Codex accounts: `codex login` with the other account, create a new profile, then Settings → Codex Account → Sync.

### Configuration

- **Refresh interval** — default 30s, per profile (Settings → General).
- **Notifications** — thresholds default to 75/90/95%, per profile.
- **Menu bar display** — single-profile (one set of metric icons) or multi-profile (one icon per account), styles in Settings → Appearance.
- **Auto-switch** — global toggle plus per-profile eligibility.
- **Keyboard shortcuts** — Settings → Shortcuts.
- **Launch at login** — Settings → General.

## Troubleshooting

**Keychain password prompts after rebuilding.** The app is ad-hoc signed, and its code signature changes on *every build*. macOS Keychain ACLs identify apps by signature, so "Always Allow" grants die on the next rebuild. The app works around this by attaching permissive ACLs to the Keychain items it creates and by using the `security` CLI (which runs inside the `apple-tool:` partition) for the shared Claude Code item. If you ever see a repeating prompt after replacing the app, click "Always Allow" once — the app repairs its own items' ACLs on launch.

**"login expired. Please run /login" in Claude Code.** The account that owns the CLI login has a dead token. Run `/login` in Claude Code, then Settings → CLI Account → Sync on that profile.

**"refresh token was revoked" from the codex CLI.** Same story: `codex login`, then Settings → Codex Account → Sync.

**Usage looks frozen.** Check the logs:

```bash
/usr/bin/log show --predicate 'process == "Claude Usage"' --info --last 10m
```

**Is the app healthy?** There is no window to inspect. A healthy main thread parks in the event loop:

```bash
sample "$(pgrep -x 'Claude Usage')" 3   # main thread should sit in NSApplication run → mach_msg
```

**Claude usage rate limits (429).** The usage endpoint sustains only ~2 requests per 30s window per IP. With many Claude profiles the app round-robins background fetches (each background profile refreshes every couple of minutes); this is by design.

## Testing

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project "Claude Usage.xcodeproj" -scheme "Claude Usage" \
  -destination 'platform=macOS'
```

Note: tests are hosted in the app, so the suite briefly launches a menu-bar instance.

Suites: credential/token parsing (Claude expiresAt ms-vs-s, Codex JWT expiry, `last_refresh` fractional seconds), weekly-reset projection, menu bar ranking/quantization, session-key validation, URL building, usage status calculation, date utilities, preference persistence, integration tests.

## Architecture

```
Claude Usage/
├── App/                    App lifecycle, setup wizard trigger
├── MenuBar/
│   ├── MenuBarManager      Orchestration: refresh sweeps, auto-switch, preflight
│   ├── StatusBarUIManager  NSStatusItem management + weekly-reset ordering
│   ├── MenuBarIconRenderer CoreGraphics icon rendering
│   └── PopoverContentView  Detailed usage popover
├── Views/                  Setup wizard, Settings window and tabs
└── Shared/
    ├── Services/           ClaudeAPIService, ClaudeCodeSyncService (CLI credential
    │                       sync + OAuth refresh), CodexUsageService, KeychainService,
    │                       ProfileManager, NotificationManager
    ├── Storage/            ProfileStore (profiles + Keychain-backed credential cache)
    ├── Models/             Profile, ClaudeUsage, APIUsage, icon config
    └── Utilities/          Constants, validators, formatters
```

`CLAUDE.md` documents the load-bearing invariants (Keychain threading rules, token-rotation hazards, the two-active-accounts model) in detail — read it before changing credential or menu bar code. `SHIPPING.md` covers what a downstream user/maintainer must know.

## Acknowledgments

This project is a fork of [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) by Hamed Elfayome, licensed under the MIT License. The original provided the multi-profile architecture, usage-fetching logic, and menu bar rendering this app builds on. This fork removed the original's telemetry/update/feedback networking (~8,700 lines) and added Codex support, per-provider active-account tracking, OAuth self-healing, auto-switch, and rate-limit-aware refresh scheduling.

## License

[MIT](LICENSE)
