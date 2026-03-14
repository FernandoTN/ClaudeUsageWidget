# Claude Usage Widget

A privacy-first macOS menu bar widget that displays your [Claude Max](https://claude.ai) usage metrics at a glance.

Built as a stripped-down fork of [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) (MIT license), with all external telemetry removed.

## What It Does

Claude Usage Widget sits in your macOS menu bar and shows real-time usage percentages for your Claude Max subscription:

- **5-Hour Session** utilization
- **7-Day All Models** utilization
- **7-Day Sonnet** utilization

Supports **two accounts simultaneously** (e.g., work + personal), with color-coded progress indicators:

| Color | Usage |
|-------|-------|
| Green | < 50% |
| Yellow | 50-80% |
| Orange | 80-95% |
| Red | > 95% |

Click the menu bar icon to open a popover with detailed usage breakdown, reset timers, and per-model stats.

## Privacy Guarantees

This fork makes **zero network calls** to anything other than `claude.ai`, `api.anthropic.com`, and `status.claude.com`. Specifically removed:

| Removed | What it did |
|---------|------------|
| Sparkle auto-update | Phoned home to developer's GitHub Pages every 24 hours |
| Feedback form | POSTed user PII to a Cloudflare Worker |
| Mobile interest form | POSTed to a Cloudflare Worker |
| GitHub star nag | Prompted users to star the repo on a timer |
| Donation/support links | External buymeacoffee links |
| GitHub contributor service | Called api.github.com |
| Debug network logger | Developer-only tooling |

Credentials (session keys, OAuth tokens) are stored locally in the app's UserDefaults on your machine.

## Requirements

- macOS 14 (Sonoma) or later
- An active [Claude Max](https://claude.ai) subscription

## Installation

### Build from Source

1. Clone this repository:
   ```bash
   git clone https://github.com/FernandoTN/ClaudeUsageWidget.git
   cd ClaudeUsageWidget
   ```

2. Open in Xcode:
   ```bash
   open "Claude Usage.xcodeproj"
   ```

3. Build and run (`Cmd+R`).

The app will appear in your menu bar (no dock icon).

## Setup

1. **Launch the app** -- it appears in your macOS menu bar.
2. **Open Settings** and select your first profile (e.g., "Gmail").
3. Click **"Sign in to claude.ai"** -- a browser window opens for Google SSO.
4. After signing in (you'll see the Claude chat), click **"Capture Session"** at the bottom of the sheet.
5. Select your organization and save the configuration.
6. Usage percentages appear in the menu bar immediately.

For a second account, switch to the other profile in Settings and repeat steps 3-5. Each login starts fresh -- signing into the second account does not affect the first.

## Configuration

### Refresh Interval

Default: 30 seconds. Configurable per profile in Settings > General.

### Notifications

macOS notifications fire at configurable thresholds (default: 75%, 90%, 95%). Enable/disable per profile in Settings > General.

### Keyboard Shortcuts

Assign global shortcuts in Settings > Shortcuts to quickly check usage without clicking the menu bar.

### Menu Bar Display

Choose which metrics to show as menu bar icons and their display style in Settings > Appearance.

## What Was Removed

~8,700 lines stripped from the original 29,670-line codebase:

| Component | Lines | Reason |
|-----------|-------|--------|
| Sparkle auto-update | ~265 | Privacy: 24h phone-home |
| Feedback form | ~332 | Privacy: PII exfiltration |
| Mobile interest form | ~167 | Privacy: external POST |
| GitHub star nag | ~200 | Bloat: nag UI |
| Support/donation view | ~162 | Bloat: external links |
| GitHub contributor service | ~100 | Privacy: api.github.com calls |
| Usage charts/history | ~1,293 | Bloat: not needed for simple display |
| Statusline service | ~824 | Security: wrote keys in plaintext to disk |
| Auto-start session | ~472 | Unwanted: sent real messages consuming quota |
| Debug network log | ~412 | Bloat: developer tooling |
| Non-English localizations | ~7,500 | Bloat: 8 language files |
| FunnyNameGenerator | ~150 | Bloat: cosmetic |

## What Remains (~21,000 lines)

| Component | Purpose |
|-----------|---------|
| ClaudeAPIService | Fetches usage from claude.ai and api.anthropic.com |
| ClaudeCodeSyncService | Reads OAuth token from Claude Code's Keychain |
| KeychainService | Credential storage |
| ProfileManager + ProfileStore | Multi-account management and persistence |
| MenuBarManager + Icon Renderer | Menu bar UI with color-coded usage percentages |
| PopoverContentView | Dropdown showing detailed usage breakdown |
| SetupWizardView | First-run setup flow with CLI auto-detection |
| NotificationManager | Threshold alerts when approaching limits |
| DesignSystem | Consistent styling across settings views |
| NetworkMonitor | Connectivity detection for error handling |
| LaunchAtLoginManager | Auto-start on macOS login |

## Architecture

```
Claude Usage/
├── App/
│   ├── AppDelegate.swift              App lifecycle, setup wizard trigger
│   └── ClaudeUsageTrackerApp.swift    SwiftUI entry point
├── MenuBar/
│   ├── MenuBarManager.swift           Orchestrates icons, popover, refresh
│   ├── MenuBarIconRenderer.swift      CoreGraphics icon rendering
│   ├── PopoverContentView.swift       Detailed usage popover
│   ├── StatusBarUIManager.swift       NSStatusItem management
│   └── WindowCoordinator.swift        Popover/window lifecycle
├── Views/
│   ├── SetupWizardView.swift          First-run onboarding
│   ├── SettingsView.swift             Tabbed settings window
│   └── Settings/                      Settings tabs and components
└── Shared/
    ├── Services/                      API client, Keychain, profiles, sync
    ├── Models/                        Profile, ClaudeUsage, APIUsage, etc.
    ├── Storage/                       ProfileStore, SharedDataStore
    ├── Utilities/                     Constants, validators, formatters
    ├── Extensions/                    Color, Date, UserDefaults extensions
    └── ErrorHandling/                 Typed errors with recovery
```

## Testing

```bash
xcodebuild test -scheme "Claude Usage" -destination "platform=macOS"
```

6 test suites:
- `ClaudeUsageTests` — Integration tests
- `URLBuilderTests` — URL construction validation
- `SessionKeyValidatorTests` — Key format validation
- `UsageStatusCalculatorTests` — Color/threshold mapping
- `DateExtensionsTests` — Date utilities
- `SharedDataStoreTests` — Preference persistence

## Acknowledgments

This project is a fork of [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) by Hamed Elfayome, licensed under the MIT License. The original project provided the multi-profile OAuth architecture, usage-fetching logic, and menu bar rendering that this widget builds on.

## License

[MIT](LICENSE)
