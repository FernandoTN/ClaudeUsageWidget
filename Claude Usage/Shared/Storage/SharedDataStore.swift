//
//  SharedDataStore.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-10.
//

import Foundation

/// Manages app-wide settings that are shared across all profiles
class SharedDataStore {
    static let shared = SharedDataStore()

    private let defaults: UserDefaults

    private enum Keys {
        // Language & Localization
        static let languageCode = "selectedLanguageCode"

        // Statusline Configuration
        static let statuslineShowModel = "statuslineShowModel"
        static let statuslineShowDirectory = "statuslineShowDirectory"
        static let statuslineShowBranch = "statuslineShowBranch"
        static let statuslineShowContext = "statuslineShowContext"
        static let statuslineContextAsTokens = "statuslineContextAsTokens"
        static let statuslineShowUsage = "statuslineShowUsage"
        static let statuslineShowProgressBar = "statuslineShowProgressBar"
        static let statuslineShowResetTime = "statuslineShowResetTime"
        static let statuslineShowProfile = "statuslineShowProfile"
        static let statuslineShowPaceMarker = "statuslineShowPaceMarker"
        static let statuslinePaceMarkerStepColors = "statuslinePaceMarkerStepColors"
        static let statuslineShowContextLabel = "statuslineShowContextLabel"
        static let statuslineUse24HourTime = "statuslineUse24HourTime"
        static let statuslineShowUsageLabel = "statuslineShowUsageLabel"
        static let statuslineShowResetLabel = "statuslineShowResetLabel"
        static let statuslineColorMode = "statuslineColorMode"
        static let statuslineSingleColorHex = "statuslineSingleColorHex"

        // Setup State
        static let hasCompletedSetup = "hasCompletedSetup"
        static let hasShownWizardOnce = "hasShownWizardOnce"

        // Debug Settings
        static let debugAPILoggingEnabled = "debugAPILoggingEnabled"

        // Keyboard Shortcuts
        static let shortcutTogglePopover = "shortcutTogglePopover"
        static let shortcutRefresh = "shortcutRefresh"
        static let shortcutOpenSettings = "shortcutOpenSettings"
        static let shortcutNextProfile = "shortcutNextProfile"

        // Auto-Switch Profile
        static let autoSwitchProfileEnabled = "autoSwitchProfileEnabled"

        // Popover Settings
        static let popoverShowRemainingTime = "popoverShowRemainingTime" // legacy bool key
        static let popoverTimeDisplay = "popoverTimeDisplay"
        static let timeFormatPreference = "timeFormatPreference"
    }

    init() {
        // Use standard UserDefaults (app container)
        self.defaults = UserDefaults.standard
        LoggingService.shared.log("SharedDataStore: Using standard app container storage")
    }

    // MARK: - Language & Localization

    func saveLanguageCode(_ code: String) {
        defaults.set(code, forKey: Keys.languageCode)
    }

    func loadLanguageCode() -> String? {
        return defaults.string(forKey: Keys.languageCode)
    }

    // MARK: - Statusline Configuration

    func saveStatuslineShowModel(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowModel)
    }

    func loadStatuslineShowModel() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowModel) == nil {
            return true  // Default to true (checked)
        }
        return defaults.bool(forKey: Keys.statuslineShowModel)
    }

    func saveStatuslineShowDirectory(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowDirectory)
    }

    func loadStatuslineShowDirectory() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowDirectory) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.statuslineShowDirectory)
    }

    func saveStatuslineShowBranch(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowBranch)
    }

    func loadStatuslineShowBranch() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowBranch) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.statuslineShowBranch)
    }

    func saveStatuslineShowUsage(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowUsage)
    }

    func loadStatuslineShowUsage() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowUsage) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.statuslineShowUsage)
    }

    func saveStatuslineShowProgressBar(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowProgressBar)
    }

    func loadStatuslineShowProgressBar() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowProgressBar) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.statuslineShowProgressBar)
    }

    func saveStatuslineShowResetTime(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowResetTime)
    }

    func loadStatuslineShowResetTime() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowResetTime) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.statuslineShowResetTime)
    }

    func saveStatuslineShowContext(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowContext)
    }

    func loadStatuslineShowContext() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowContext) == nil {
            return true  // Default to true (checked)
        }
        return defaults.bool(forKey: Keys.statuslineShowContext)
    }

    func saveStatuslineContextAsTokens(_ asTokens: Bool) {
        defaults.set(asTokens, forKey: Keys.statuslineContextAsTokens)
    }

    func loadStatuslineContextAsTokens() -> Bool {
        if defaults.object(forKey: Keys.statuslineContextAsTokens) == nil {
            return false  // Default to false (percentage)
        }
        return defaults.bool(forKey: Keys.statuslineContextAsTokens)
    }

    func saveStatuslineShowProfile(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowProfile)
    }

    func loadStatuslineShowProfile() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowProfile) == nil {
            return false  // Default to false (new feature)
        }
        return defaults.bool(forKey: Keys.statuslineShowProfile)
    }

    func saveStatuslineShowPaceMarker(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowPaceMarker)
    }

    func loadStatuslineShowPaceMarker() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowPaceMarker) == nil {
            return true  // Default to true
        }
        return defaults.bool(forKey: Keys.statuslineShowPaceMarker)
    }

    func saveStatuslinePaceMarkerStepColors(_ useStepColors: Bool) {
        defaults.set(useStepColors, forKey: Keys.statuslinePaceMarkerStepColors)
    }

    func loadStatuslinePaceMarkerStepColors() -> Bool {
        if defaults.object(forKey: Keys.statuslinePaceMarkerStepColors) == nil {
            return false
        }
        return defaults.bool(forKey: Keys.statuslinePaceMarkerStepColors)
    }

    func saveStatuslineShowContextLabel(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowContextLabel)
    }

    func loadStatuslineShowContextLabel() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowContextLabel) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.statuslineShowContextLabel)
    }

    func saveStatuslineUse24HourTime(_ use24Hour: Bool) {
        defaults.set(use24Hour, forKey: Keys.statuslineUse24HourTime)
    }

    func loadStatuslineUse24HourTime() -> Bool {
        return defaults.bool(forKey: Keys.statuslineUse24HourTime)
    }

    func saveStatuslineShowUsageLabel(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowUsageLabel)
    }

    func loadStatuslineShowUsageLabel() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowUsageLabel) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.statuslineShowUsageLabel)
    }

    func saveStatuslineShowResetLabel(_ show: Bool) {
        defaults.set(show, forKey: Keys.statuslineShowResetLabel)
    }

    func loadStatuslineShowResetLabel() -> Bool {
        if defaults.object(forKey: Keys.statuslineShowResetLabel) == nil {
            return true
        }
        return defaults.bool(forKey: Keys.statuslineShowResetLabel)
    }

    func saveStatuslineColorMode(_ mode: StatuslineColorMode) {
        defaults.set(mode.rawValue, forKey: Keys.statuslineColorMode)
    }

    func loadStatuslineColorMode() -> StatuslineColorMode {
        guard let raw = defaults.string(forKey: Keys.statuslineColorMode),
              let mode = StatuslineColorMode(rawValue: raw) else {
            return .colored
        }
        return mode
    }

    func saveStatuslineSingleColorHex(_ hex: String) {
        defaults.set(hex, forKey: Keys.statuslineSingleColorHex)
    }

    func loadStatuslineSingleColorHex() -> String {
        return defaults.string(forKey: Keys.statuslineSingleColorHex) ?? "#00BFFF"
    }

    // MARK: - Setup State

    func saveHasCompletedSetup(_ completed: Bool) {
        defaults.set(completed, forKey: Keys.hasCompletedSetup)
    }

    func hasCompletedSetup() -> Bool {
        // Check if flag is set
        if defaults.bool(forKey: Keys.hasCompletedSetup) {
            return true
        }

        // Also check if session key file exists as fallback (legacy)
        let sessionKeyPath = Constants.ClaudePaths.homeDirectory
            .appendingPathComponent(".claude-session-key")

        if FileManager.default.fileExists(atPath: sessionKeyPath.path) {
            // Auto-mark as complete if session key exists
            saveHasCompletedSetup(true)
            return true
        }

        return false
    }

    func hasShownWizardOnce() -> Bool {
        return defaults.bool(forKey: Keys.hasShownWizardOnce)
    }

    func markWizardShown() {
        defaults.set(true, forKey: Keys.hasShownWizardOnce)
    }

    // MARK: - Debug Settings

    func saveDebugAPILoggingEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.debugAPILoggingEnabled)
    }

    func loadDebugAPILoggingEnabled() -> Bool {
        return defaults.bool(forKey: Keys.debugAPILoggingEnabled)
    }

    // MARK: - Keyboard Shortcuts

    private func shortcutKey(for action: ShortcutAction) -> String {
        switch action {
        case .togglePopover: return Keys.shortcutTogglePopover
        case .refresh: return Keys.shortcutRefresh
        case .openSettings: return Keys.shortcutOpenSettings
        case .nextProfile: return Keys.shortcutNextProfile
        }
    }

    func saveShortcut(_ combo: KeyCombo?, for action: ShortcutAction) {
        let key = shortcutKey(for: action)
        if let combo = combo {
            if let data = try? JSONEncoder().encode(combo) {
                defaults.set(data, forKey: key)
            }
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    func loadShortcut(for action: ShortcutAction) -> KeyCombo? {
        let key = shortcutKey(for: action)
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    // MARK: - Auto-Switch Profile

    func saveAutoSwitchProfileEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.autoSwitchProfileEnabled)
    }

    func loadAutoSwitchProfileEnabled() -> Bool {
        return defaults.bool(forKey: Keys.autoSwitchProfileEnabled)
    }

    // MARK: - Popover Settings

    func savePopoverTimeDisplay(_ display: PopoverTimeDisplay) {
        defaults.set(display.rawValue, forKey: Keys.popoverTimeDisplay)
    }

    func loadPopoverTimeDisplay() -> PopoverTimeDisplay {
        // Check new key first
        if let rawValue = defaults.string(forKey: Keys.popoverTimeDisplay),
           let display = PopoverTimeDisplay(rawValue: rawValue) {
            return display
        }
        // Migrate from old boolean key
        if defaults.object(forKey: Keys.popoverShowRemainingTime) != nil {
            let oldValue = defaults.bool(forKey: Keys.popoverShowRemainingTime)
            let migrated: PopoverTimeDisplay = oldValue ? .remainingTime : .resetTime
            savePopoverTimeDisplay(migrated)
            defaults.removeObject(forKey: Keys.popoverShowRemainingTime)
            return migrated
        }
        return .resetTime
    }

    func saveTimeFormatPreference(_ format: TimeFormatPreference) {
        defaults.set(format.rawValue, forKey: Keys.timeFormatPreference)
    }

    func loadTimeFormatPreference() -> TimeFormatPreference {
        guard let rawValue = defaults.string(forKey: Keys.timeFormatPreference),
              let preference = TimeFormatPreference(rawValue: rawValue) else {
            return .system
        }
        return preference
    }

    /// Returns whether 24-hour time should be used, resolving the system preference
    func uses24HourTime() -> Bool {
        switch loadTimeFormatPreference() {
        case .system:
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let timeString = formatter.string(from: Date())
            // If the system-formatted time contains AM/PM, it's 12-hour
            return !timeString.contains(formatter.amSymbol) && !timeString.contains(formatter.pmSymbol)
        case .twelveHour:
            return false
        case .twentyFourHour:
            return true
        }
    }

}
