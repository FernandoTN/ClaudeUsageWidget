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

    // MARK: - Preferences Degradation Resilience
    //
    // cfprefsd can lose access to the plist WHILE the app runs, system-wide:
    // every in-process read then returns nil (see CLAUDE.md "Preferences
    // (cfprefsd) degradation"). A loader that maps nil onto its type default
    // turns that into silent state loss — auto-switch reads as OFF, the switch
    // history as "no switches ever", the projection basis and the user's queued
    // handoff plan as empty. Each of those has a distinct, wrong consequence,
    // and none of them is observable.
    //
    // Same shape as ProfileStore's shadow (PR #42): every save and every
    // successful read records what this process believes; a nil read after a
    // good one is served from the shadow and logged once per episode. With no
    // prior good read the type default still stands — a genuinely unset key is
    // indistinguishable from a wedged one on the first read, and defaulting is
    // what a first launch needs.

    private var lastKnownGoodAutoSwitchEnabled: Bool?
    private var lastKnownGoodSwitchHistory: [SwitchEvent]?
    private var lastKnownGoodMeasuredSessionHistory: [UUID: [(at: Date, pct: Double)]]?
    private var lastKnownGoodAutoSwitchQueue: [UUID]?
    private var lastKnownGoodFleetAlertDefaults: NotificationSettings?

    /// Keys already logged this degradation episode; cleared by the next live
    /// read of that key so a later episode speaks up again.
    private var nilReadLoggedKeys: Set<String> = []

    private func logNilReadOnce(_ key: String) {
        guard !nilReadLoggedKeys.contains(key) else { return }
        nilReadLoggedKeys.insert(key)
        LoggingService.shared.logError(
            "SharedDataStore: preferences read returned nil for \(key) — serving cached value"
        )
    }

    private func noteLiveRead(_ key: String) {
        nilReadLoggedKeys.remove(key)
    }

    /// Clears the in-process last-known-good shadow. Test-only, and the twin of
    /// `ProfileStore.resetPreferencesResilienceStateForTesting`: this store is a
    /// singleton that outlives a test case, so a shadow one test filled answers
    /// the next test's deliberately-absent key and reads as a stale value.
    func resetPreferencesResilienceStateForTesting() {
        lastKnownGoodAutoSwitchEnabled = nil
        lastKnownGoodSwitchHistory = nil
        lastKnownGoodMeasuredSessionHistory = nil
        lastKnownGoodAutoSwitchQueue = nil
        lastKnownGoodFleetAlertDefaults = nil
        nilReadLoggedKeys.removeAll()
    }

    // MARK: - Single-shot writes
    //
    // The read-side shadow above only covers half the failure. On 2026-09-03
    // cfprefsd REJECTED this app's writes for two minutes while every read
    // stayed healthy: `measuredSessionHistory_v1`, rewritten every sweep,
    // healed itself the moment the episode ended, while `switchHistory_v1`,
    // `autoSwitchQueue` and every settings toggle written since were still
    // stale on disk an hour later with nothing reporting it. Every write below
    // that fires ONCE — on a switch, on a settings change — is verified and
    // re-asserted by `PreferenceWriteJournal` (audit C3). The per-sweep keys
    // keep writing straight through: they are their own re-assertion.

    private func writeSingleShot(_ value: Any?, forKey key: String) {
        PreferenceWriteJournal.shared.write(value, forKey: key, in: defaults, owner: .sharedDataStore)
    }

    /// Checks this store's single-shot keys against the preferences store and
    /// rewrites any that are not there. Called once per sweep — the check is
    /// deferred because there is no oracle at write time (see
    /// `PlistPreferenceStoreSnapshot`).
    @discardableResult
    func reassertPendingWrites() -> Int {
        PreferenceWriteJournal.shared.runWriteCheck(owner: .sharedDataStore)
    }

    // MARK: - Setup State

    func saveHasCompletedSetup(_ completed: Bool) {
        writeSingleShot(completed, forKey: Keys.hasCompletedSetup)
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
        writeSingleShot(true, forKey: Keys.hasShownWizardOnce)
    }

    // MARK: - Debug Settings

    func saveDebugAPILoggingEnabled(_ enabled: Bool) {
        writeSingleShot(enabled, forKey: Keys.debugAPILoggingEnabled)
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
                writeSingleShot(data, forKey: key)
            }
        } else {
            writeSingleShot(nil, forKey: key)
        }
    }

    func loadShortcut(for action: ShortcutAction) -> KeyCombo? {
        let key = shortcutKey(for: action)
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(KeyCombo.self, from: data)
    }

    // MARK: - Auto-Switch Profile

    func saveAutoSwitchProfileEnabled(_ enabled: Bool) {
        writeSingleShot(enabled, forKey: Keys.autoSwitchProfileEnabled)
        lastKnownGoodAutoSwitchEnabled = enabled
    }

    /// `bool(forKey:)` cannot tell "the user turned it off" from "the key is
    /// unreadable" — both are false. A wedged read used to switch the whole
    /// rotation off silently, exactly when a burning account needs it (audit
    /// H8), so absence is checked explicitly and answered from the shadow.
    func loadAutoSwitchProfileEnabled() -> Bool {
        if defaults.object(forKey: Keys.autoSwitchProfileEnabled) != nil {
            let live = defaults.bool(forKey: Keys.autoSwitchProfileEnabled)
            lastKnownGoodAutoSwitchEnabled = live
            noteLiveRead(Keys.autoSwitchProfileEnabled)
            return live
        }
        if let cached = lastKnownGoodAutoSwitchEnabled {
            logNilReadOnce(Keys.autoSwitchProfileEnabled)
            return cached
        }
        return false
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
        writeSingleShot(threshold, forKey: Keys.autoSwitchThreshold)
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
        writeSingleShot(threshold, forKey: Keys.autoSwitchWeeklyThreshold)
    }

    func loadAutoSwitchWeeklyThreshold() -> Double {
        let stored = defaults.double(forKey: Keys.autoSwitchWeeklyThreshold)
        guard stored > 0 else { return Self.defaultAutoSwitchWeeklyThreshold }
        return min(max(stored, Self.autoSwitchThresholdRange.lowerBound),
                   Self.autoSwitchThresholdRange.upperBound)
    }

    // MARK: - Popover Settings

    func savePopoverTimeDisplay(_ display: PopoverTimeDisplay) {
        writeSingleShot(display.rawValue, forKey: Keys.popoverTimeDisplay)
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
            writeSingleShot(nil, forKey: Keys.popoverShowRemainingTime)
            return migrated
        }
        return .resetTime
    }

    func saveTimeFormatPreference(_ format: TimeFormatPreference) {
        writeSingleShot(format.rawValue, forKey: Keys.timeFormatPreference)
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

    // MARK: - Switch History

    private enum SwitchHistoryKeys {
        static let history = "switchHistory_v1"
        static let capacity = 30
    }

    /// Appends a switch record, keeping the newest `capacity` entries. The
    /// unified log persists nothing for this process, so this ring buffer is
    /// the only durable answer to "which account was active before, and why
    /// did it change" — never store credentials or tokens in it.
    func recordSwitchEvent(_ event: SwitchEvent) {
        var history = loadSwitchHistory()
        history.append(event)
        if history.count > SwitchHistoryKeys.capacity {
            history.removeFirst(history.count - SwitchHistoryKeys.capacity)
        }
        if let data = try? JSONEncoder().encode(history) {
            writeSingleShot(data, forKey: SwitchHistoryKeys.history)
        }
        lastKnownGoodSwitchHistory = history
    }

    /// Enriches the newest record with attribution only the caller knows
    /// (queued-vs-ranked selection, trigger measurements) — the base record is
    /// written by the single activation seam, which lacks that context.
    func amendLastSwitchEvent(trigger: SwitchEvent.Trigger, reason: String?) {
        var history = loadSwitchHistory()
        guard var last = history.last else { return }
        last.trigger = trigger
        last.reason = reason ?? last.reason
        history[history.count - 1] = last
        if let data = try? JSONEncoder().encode(history) {
            writeSingleShot(data, forKey: SwitchHistoryKeys.history)
        }
        lastKnownGoodSwitchHistory = history
    }

    /// An unreadable key is NOT "no switches ever happened": read that way,
    /// `attributeRateLimitEvent` finds no switch after a transcript rate-limit
    /// event and stamps the CURRENT owner instead of the account that actually
    /// hit the limit (audit M1). The shadow keeps the real history in view for
    /// the rest of the process.
    func loadSwitchHistory() -> [SwitchEvent] {
        guard let data = defaults.data(forKey: SwitchHistoryKeys.history) else {
            if let cached = lastKnownGoodSwitchHistory {
                logNilReadOnce(SwitchHistoryKeys.history)
                return cached
            }
            return []
        }
        let decoded = (try? JSONDecoder().decode([SwitchEvent].self, from: data)) ?? []
        lastKnownGoodSwitchHistory = decoded
        noteLiveRead(SwitchHistoryKeys.history)
        return decoded
    }

    // MARK: - Measured Session History (burn-rate projection basis)

    private enum MeasuredHistoryKeys {
        static let history = "measuredSessionHistory_v1"
    }

    /// Persists the per-profile measured session samples the burn-rate
    /// projection draws from. In-memory-only history died at every relaunch:
    /// a deploy at 20:47 on 2026-08-12 wiped the basis mid-incident, so a
    /// suspected profile's display fell back to its frozen last measurement
    /// (67% at a real 100%). Stored as [uuid: [[epochSeconds, pct]]] — tiny
    /// (≤4 samples per profile), no credentials.
    func saveMeasuredSessionHistory(_ history: [UUID: [(at: Date, pct: Double)]]) {
        let encodable = Dictionary(uniqueKeysWithValues: history.map { key, samples in
            (key.uuidString, samples.map { [$0.at.timeIntervalSince1970, $0.pct] })
        })
        if let data = try? JSONEncoder().encode(encodable) {
            defaults.set(data, forKey: MeasuredHistoryKeys.history)
        }
        lastKnownGoodMeasuredSessionHistory = history
    }

    /// An unreadable key read as "no samples" deletes the burn-rate projection
    /// basis, so a suspected profile falls back to its frozen last measurement
    /// — the literal 2026-08-12 incident this persistence was added to fix
    /// (audit M2).
    func loadMeasuredSessionHistory() -> [UUID: [(at: Date, pct: Double)]] {
        guard let data = defaults.data(forKey: MeasuredHistoryKeys.history),
              let decoded = try? JSONDecoder().decode([String: [[Double]]].self, from: data) else {
            if let cached = lastKnownGoodMeasuredSessionHistory {
                logNilReadOnce(MeasuredHistoryKeys.history)
                return cached
            }
            return [:]
        }
        var history: [UUID: [(at: Date, pct: Double)]] = [:]
        for (key, samples) in decoded {
            guard let id = UUID(uuidString: key) else { continue }
            history[id] = samples.compactMap { pair in
                guard pair.count == 2 else { return nil }
                return (Date(timeIntervalSince1970: pair[0]), pair[1])
            }
        }
        lastKnownGoodMeasuredSessionHistory = history
        noteLiveRead(MeasuredHistoryKeys.history)
        return history
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
        writeSingleShot(queue.map(\.uuidString), forKey: QueueKeys.queue)
        lastKnownGoodAutoSwitchQueue = queue
    }

    /// An unreadable key read as "empty queue" silently discards the user's
    /// queued handoff plan and drops the switch back to ranked selection
    /// (audit M3).
    func loadAutoSwitchQueue() -> [UUID] {
        guard let raw = defaults.array(forKey: QueueKeys.queue) as? [String] else {
            if let cached = lastKnownGoodAutoSwitchQueue {
                logNilReadOnce(QueueKeys.queue)
                return cached
            }
            return []
        }
        let queue = raw.compactMap(UUID.init(uuidString:))
        lastKnownGoodAutoSwitchQueue = queue
        noteLiveRead(QueueKeys.queue)
        return queue
    }

    // MARK: - Key registry (SettingsKeyRegistry, spec §5.2)

    static let registeredKeys: [RegisteredKey] = [
        RegisteredKey(Keys.hasCompletedSetup, .sharedDataStore, .live, ui: "— (setup state)"),
        RegisteredKey(Keys.hasShownWizardOnce, .sharedDataStore, .live, ui: "— (setup state)"),
        RegisteredKey(Keys.debugAPILoggingEnabled, .sharedDataStore, .live, ui: "Advanced › Diagnostics"),
        RegisteredKey(Keys.shortcutTogglePopover, .sharedDataStore, .live, ui: "Advanced › Shortcuts"),
        RegisteredKey(Keys.shortcutRefresh, .sharedDataStore, .live, ui: "Advanced › Shortcuts"),
        RegisteredKey(Keys.shortcutOpenSettings, .sharedDataStore, .live, ui: "Advanced › Shortcuts"),
        RegisteredKey(Keys.shortcutNextProfile, .sharedDataStore, .live, ui: "Advanced › Shortcuts (view next)"),
        RegisteredKey(Keys.autoSwitchProfileEnabled, .sharedDataStore, .live, ui: "Active & Auto-switch"),
        RegisteredKey(Keys.autoSwitchThreshold, .sharedDataStore, .live, ui: "Active & Auto-switch"),
        RegisteredKey(Keys.autoSwitchWeeklyThreshold, .sharedDataStore, .live, ui: "Active & Auto-switch"),
        RegisteredKey(Keys.popoverShowRemainingTime, .sharedDataStore, .migrationFlag),
        RegisteredKey(Keys.popoverTimeDisplay, .sharedDataStore, .live, ui: "Display › Popover"),
        RegisteredKey(Keys.timeFormatPreference, .sharedDataStore, .live, ui: "Display › Popover"),
        RegisteredKey("switchHistory_v1", .sharedDataStore, .live, ui: "Dashboard (switch log)"),
        RegisteredKey("measuredSessionHistory_v1", .sharedDataStore, .live, ui: "Dashboard (burn history)"),
        RegisteredKey("autoSwitchQueue", .sharedDataStore, .live, ui: "Active & Auto-switch › Hand-off queue"),
        RegisteredKey("fleetAlertDefaults_v1", .sharedDataStore, .live, ui: "Alerts › Fleet defaults"),
        RegisteredKey("activeSelectorItem_v1", .sharedDataStore, .live, ui: "Display › Active-account selector"),
    ]

    // MARK: - Fleet alert defaults (docs/specs/ux-revamp.md §5.2, D11)

    private enum FleetAlertKeys {
        /// `NotificationSettings` as JSON. Every profile whose
        /// `followsFleetAlertDefaults` is true resolves to this value.
        static let defaults = "fleetAlertDefaults_v1"
    }

    /// True once the key has been written — the Alerts page seeds it on first
    /// open (`FleetAlerts.seed`); until then reads answer the type defaults.
    func hasFleetAlertDefaults() -> Bool {
        defaults.data(forKey: FleetAlertKeys.defaults) != nil
    }

    func saveFleetAlertDefaults(_ settings: NotificationSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        writeSingleShot(data, forKey: FleetAlertKeys.defaults)
        lastKnownGoodFleetAlertDefaults = settings
    }

    /// A nil read after a good one is served from the shadow: defaulting would
    /// silently re-enable every threshold the owner turned off fleet-wide.
    func loadFleetAlertDefaults() -> NotificationSettings {
        guard let data = defaults.data(forKey: FleetAlertKeys.defaults),
              let settings = try? JSONDecoder().decode(NotificationSettings.self, from: data) else {
            if let cached = lastKnownGoodFleetAlertDefaults {
                logNilReadOnce(FleetAlertKeys.defaults)
                return cached
            }
            return NotificationSettings()
        }
        lastKnownGoodFleetAlertDefaults = settings
        noteLiveRead(FleetAlertKeys.defaults)
        return settings
    }

    // MARK: - ⇄ Active-account selector (docs/specs/ux-revamp.md §2.1)

    private enum SelectorKeys {
        /// `{ "enabled": Bool }` — a dictionary so later fields (e.g. a
        /// per-provider mode) can be added without a second key.
        static let item = "activeSelectorItem_v1"
    }

    /// Whether the ⇄ selector status item is shown. Absent = shown (the item is
    /// what the owner asked for; hiding is the opt-out). Single-shot write,
    /// journaled like every other settings toggle.
    func loadActiveSelectorItemEnabled() -> Bool {
        guard let dict = defaults.dictionary(forKey: SelectorKeys.item),
              let enabled = dict["enabled"] as? Bool else { return true }
        return enabled
    }

    func saveActiveSelectorItemEnabled(_ enabled: Bool) {
        var dict = defaults.dictionary(forKey: SelectorKeys.item) ?? [:]
        dict["enabled"] = enabled
        writeSingleShot(dict, forKey: SelectorKeys.item)
    }

}
