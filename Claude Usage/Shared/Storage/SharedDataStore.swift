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
        static let autoSwitchThreshold = "autoSwitchThreshold"
        static let autoSwitchWeeklyThreshold = "autoSwitchWeeklyThreshold"

        // Popover Settings
        static let popoverShowRemainingTime = "popoverShowRemainingTime" // legacy bool key
        static let popoverTimeDisplay = "popoverTimeDisplay"
        static let timeFormatPreference = "timeFormatPreference"
    }

    init() {
        // Same XCTest isolation as ProfileStore: test runs must never touch the
        // user's real settings — SharedDataStoreTests' tearDown was deleting the
        // live auto-switch thresholds on every suite run before this.
        let isTestRun = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        if isTestRun, let suite = UserDefaults(suiteName: "com.claudeusagewidget.tests") {
            self.defaults = suite
            LoggingService.shared.log("SharedDataStore: Using isolated TEST defaults suite")
        } else {
            self.defaults = UserDefaults.standard
            LoggingService.shared.log("SharedDataStore: Using standard app container storage")
        }
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

    /// SESSION-window usage percentage at which the auto-switch fires (and
    /// above which a candidate is no longer an eligible target). Below 100 the
    /// switch is PROACTIVE: the remaining headroom is forfeited so running
    /// Claude Code sessions never see "You've hit your session limit" —
    /// detection is sweep-based (~30s), so a reactive 100% trigger always
    /// lands after sessions have already started erroring. Cheap to forfeit:
    /// a session window regenerates within 5 hours.
    static let defaultAutoSwitchThreshold: Double = 95
    /// WEEKLY-window (all-models and Fable) switch threshold. Deliberately
    /// tighter than the session threshold: forfeited weekly headroom is gone
    /// for the rest of the week, so only the last sliver is traded for
    /// continuity.
    static let defaultAutoSwitchWeeklyThreshold: Double = 99
    static let autoSwitchThresholdRange: ClosedRange<Double> = 80...100

    func saveAutoSwitchThreshold(_ threshold: Double) {
        defaults.set(threshold, forKey: Keys.autoSwitchThreshold)
    }

    func loadAutoSwitchThreshold() -> Double {
        // double(forKey:) returns 0 for a never-written key; clamping also
        // guards against an out-of-range value hand-edited into the plist.
        let stored = defaults.double(forKey: Keys.autoSwitchThreshold)
        guard stored > 0 else { return Self.defaultAutoSwitchThreshold }
        return min(max(stored, Self.autoSwitchThresholdRange.lowerBound),
                   Self.autoSwitchThresholdRange.upperBound)
    }

    func saveAutoSwitchWeeklyThreshold(_ threshold: Double) {
        defaults.set(threshold, forKey: Keys.autoSwitchWeeklyThreshold)
    }

    func loadAutoSwitchWeeklyThreshold() -> Double {
        let stored = defaults.double(forKey: Keys.autoSwitchWeeklyThreshold)
        guard stored > 0 else { return Self.defaultAutoSwitchWeeklyThreshold }
        return min(max(stored, Self.autoSwitchThresholdRange.lowerBound),
                   Self.autoSwitchThresholdRange.upperBound)
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

    /// Probe formatter for the system 12/24-hour preference. DateFormatter
    /// construction is expensive and this is called from render paths — build
    /// it once (cheap staleness: a changed system locale setting applies on
    /// next launch, same as most menu-bar apps).
    private static let systemTimeProbeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Returns whether 24-hour time should be used, resolving the system preference
    func uses24HourTime() -> Bool {
        switch loadTimeFormatPreference() {
        case .system:
            let formatter = Self.systemTimeProbeFormatter
            let timeString = formatter.string(from: Date())
            // If the system-formatted time contains AM/PM, it's 12-hour
            return !timeString.contains(formatter.amSymbol) && !timeString.contains(formatter.pmSymbol)
        case .twelveHour:
            return false
        case .twentyFourHour:
            return true
        }
    }

    // MARK: - Auto-Switch Queue

    private enum QueueKeys {
        static let queue = "autoSwitchQueue"
    }

    /// Consumable FIFO queue of profile UUIDs for the auto-switch: entry #1 is
    /// the IMMEDIATE next switch target; each auto-switch consumes the entry it
    /// tried. Empty queue = default behavior (soonest weekly reset). Persisted
    /// so a queued handoff plan survives relaunches.
    func saveAutoSwitchQueue(_ queue: [UUID]) {
        defaults.set(queue.map(\.uuidString), forKey: QueueKeys.queue)
    }

    func loadAutoSwitchQueue() -> [UUID] {
        (defaults.array(forKey: QueueKeys.queue) as? [String] ?? [])
            .compactMap(UUID.init(uuidString:))
    }

}
