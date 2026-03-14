# Claude Usage Widget

A privacy-first macOS menu bar widget that displays your [Claude Max](https://claude.ai) usage metrics at a glance.

Built as a stripped-down fork of [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) (MIT license), with all external telemetry removed and credentials moved to secure Keychain storage.

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

All credentials (session keys, OAuth tokens) are stored exclusively in the **macOS Keychain** with `kSecAttrAccessibleWhenUnlocked` protection -- not in UserDefaults plist files.

## Requirements

- macOS 14 (Sonoma) or later
- An active [Claude Max](https://claude.ai) subscription
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed (for OAuth token capture)

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

The app will appear in your menu bar.

## Setup

1. **Launch the app** -- it appears in your macOS menu bar.
2. **Open Claude Code** in your terminal and log in: `claude`
3. **Open Settings** in the widget and click "Capture" on your first profile slot.
4. The widget reads your OAuth token from Claude Code's macOS Keychain entry.
5. Usage percentages appear in the menu bar immediately.

For a second account, log out of Claude Code (`claude logout`), log in with the other account, and capture on the second profile slot.

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
| KeychainService | Secure credential storage |
| ProfileManager + ProfileStore | Multi-account management |
| MenuBarManager + Icon Renderer | Menu bar UI with usage percentages |
| PopoverContentView | Dropdown showing detailed usage breakdown |
| SetupWizardView | First-run setup flow |
| NotificationManager | Threshold alerts when approaching limits |
| DesignSystem | Consistent styling across settings views |

## Acknowledgments

This project is a fork of [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker) by Hamed Elfayome, licensed under the MIT License. The original project provided the multi-profile OAuth architecture, usage-fetching logic, and menu bar rendering that this widget builds on.

## License

[MIT](LICENSE)
