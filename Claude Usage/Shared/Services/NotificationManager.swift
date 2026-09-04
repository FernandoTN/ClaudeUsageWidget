import Foundation
import UserNotifications
import AppKit

/// Manages user notifications for usage threshold alerts
class NotificationManager {
    static let shared = NotificationManager()

    // Track previous session percentage per profile to detect resets
    private var previousSessionPercentages: [String: Double] = [:]

    // Track the last-seen WEEKLY boundary per profile. Weekly-only providers
    // have no >0%→0% transition to detect a new window with, so the boundary
    // moving is what re-arms their alerts (see checkWeeklyRollover).
    private var previousWeeklyBoundaries: [String: Date] = [:]

    // Track which notifications have been sent to prevent duplicates
    // Persisted to UserDefaults to survive app restarts
    private var sentNotifications: Set<String> {
        get {
            Set(UserDefaults.standard.array(forKey: "sentNotifications") as? [String] ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "sentNotifications")
        }
    }

    private init() {}

    /// Sends a notification when approaching usage limits (legacy method)
    func sendUsageAlert(type: AlertType, percentage: Double, resetTime: Date?) {
        // Check if notifications are enabled for the active profile
        guard ProfileManager.shared.activeProfile?.notificationSettings.enabled ?? false else {
            return
        }

        // Map percentage to threshold level to prevent duplicate notifications
        let thresholdLevel: Int
        if percentage >= 95 {
            thresholdLevel = 95
        } else if percentage >= 90 {
            thresholdLevel = 90
        } else if percentage >= 75 {
            thresholdLevel = 75
        } else {
            return // Below all thresholds
        }

        // Create unique identifier based on threshold level, not actual percentage
        let identifier = "\(type.rawValue)_\(thresholdLevel)"

        // Check if we've already sent this notification
        guard !sentNotifications.contains(identifier) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = type.title
        content.body = type.message(percentage: percentage, resetTime: resetTime)
        content.sound = .default
        content.categoryIdentifier = "USAGE_ALERT"

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Show immediately
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error == nil {
                // Mark this notification as sent
                var updated = self?.sentNotifications ?? []
                updated.insert(identifier)
                self?.sentNotifications = updated
            }
        }
    }

    /// Sends a simple notification (for non-usage alerts)
    func sendSimpleAlert(type: AlertType) {
        let content = UNMutableNotificationContent()
        content.title = type.title
        content.body = type.message(percentage: 0, resetTime: nil)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: type.rawValue,
            content: content,
            trigger: nil // Show immediately
        )

        UNUserNotificationCenter.current().add(request) { _ in
            // Notification sent
        }
    }

    /// Sends a brief success notification for user-triggered refreshes
    func sendSuccessNotification() {
        let center = UNUserNotificationCenter.current()

        // Create notification content
        let content = UNMutableNotificationContent()
        content.title = "Claude Usage Updated"
        content.body = "Successfully loaded usage data"
        // Silent notification (no sound)
        content.categoryIdentifier = "SUCCESS_ALERT"

        // Create a trigger to deliver immediately
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)

        // Create the request with a unique identifier
        let identifier = "usage_refresh_success_\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        // Add the notification request
        center.add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to show success notification: \(error)")
            }
        }

        // Auto-remove after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }

    /// The single threshold alert a usage reading earns, or nil when it has
    /// crossed none. PURE — no state, no delivery — so the routing that
    /// decides *which* window and *which* severity is testable on its own.
    ///
    /// The window is chosen by the provider, not by the number: a weekly-only
    /// provider (Codex since OpenAI collapsed its 5h/weekly pair into one
    /// 7-day window, Grok always) reports `sessionPercentage` 0 forever, so
    /// reading the session window alone meant a Codex account could never
    /// cross a threshold at all. Providers that DO have a session window keep
    /// their existing session-only behaviour — Claude users must not start
    /// getting a second, weekly alert stream they never opted into.
    struct ThresholdAlert: Equatable {
        let type: AlertType
        let level: Int
        let percentage: Double
        let resetTime: Date
    }

    static func thresholdAlert(usage: ClaudeUsage, settings: NotificationSettings) -> ThresholdAlert? {
        guard settings.enabled else { return nil }
        let weeklyOnly = !usage.providesSessionWindow
        // Display seam: a SUSPECTED (inferred) rate limit must not fire the
        // "100% reached" usage alerts on an unverified signal.
        let percentage = weeklyOnly ? usage.weeklyPercentage : usage.displaySessionPercentage
        let resetTime = weeklyOnly ? usage.weeklyResetTime : usage.sessionResetTime

        // Highest crossed threshold wins — one alert per reading.
        guard let threshold = settings.sortedThresholds.reversed().first(where: {
            percentage >= Double($0)
        }) else { return nil }

        let type: AlertType
        if weeklyOnly {
            // Only two weekly types exist; cut at the same 95 the session
            // ladder calls critical.
            type = threshold >= 95 ? .weeklyCritical : .weeklyWarning
        } else {
            switch threshold {
            case 95...:
                type = .sessionCritical
            case 90..<95:
                type = .sessionWarning
            default:
                type = .sessionInfo
            }
        }
        return ThresholdAlert(type: type, level: threshold, percentage: percentage, resetTime: resetTime)
    }

    /// True when `current` is a DIFFERENT quota window than `previous`. Same
    /// ±2min tolerance the auto-switch preflight uses: the API reports one
    /// boundary with ±1s jitter, so only a real rollover moves it.
    static func windowRolledOver(previousBoundary: Date?, current: Date) -> Bool {
        guard let previous = previousBoundary else { return false }
        return abs(current.timeIntervalSince(previous)) > 120
    }

    /// Checks usage and sends appropriate alerts (profile-aware).
    ///
    /// Called once per profile per sweep — in multi-profile mode the sweep is
    /// the ONLY caller, and before 2026-09-03 it did not call this at all, so
    /// the per-profile toggles in Settings → General were a no-op for every
    /// account. Repeat calls are idempotent: `sentNotifications` records one
    /// identifier per (profile, type, threshold) and only a window rollover
    /// clears it, so a 30s sweep does not re-notify.
    func checkAndNotify(usage: ClaudeUsage, profileName: String, settings: NotificationSettings) {
        // Check if notifications are enabled for this profile
        guard settings.enabled else {
            return
        }

        if usage.providesSessionWindow {
            checkSessionReset(usage: usage, profileName: profileName, settings: settings)
        } else {
            checkWeeklyRollover(usage: usage, profileName: profileName)
        }

        guard let alert = Self.thresholdAlert(usage: usage, settings: settings) else { return }
        sendProfileAlert(
            profileName: profileName,
            type: alert.type,
            percentage: alert.percentage,
            thresholdLevel: alert.level,
            resetTime: alert.resetTime,
            soundName: settings.soundName
        )
    }

    /// Session-window providers: a reset (>0% → 0%) re-arms every alert for
    /// this profile and announces itself.
    private func checkSessionReset(usage: ClaudeUsage, profileName: String, settings: NotificationSettings) {
        let sessionPercentage = usage.displaySessionPercentage
        let previousPercentage = previousSessionPercentages[profileName] ?? 0.0

        // Check for session reset (went from >0% to 0%)
        if previousPercentage > 0.0 && sessionPercentage == 0.0 {
            // Clear all sent notifications for this profile to allow re-notification
            // in the new session. Match "<name>_" — identifiers are
            // "<name>_<type>_<level>", and a bare-name prefix let profile "Cod"
            // clear profile "Codex (…)"'s records too.
            sentNotifications = sentNotifications.filter { !$0.hasPrefix("\(profileName)_") }

            sendProfileAlert(
                profileName: profileName,
                type: .sessionReset,
                percentage: sessionPercentage,
                resetTime: usage.sessionResetTime,
                soundName: settings.soundName
            )
        }

        // Update previous percentage for this specific profile
        previousSessionPercentages[profileName] = sessionPercentage
    }

    /// Weekly-only providers: there is no >0→0 transition to watch (a fresh
    /// week reports the new boundary while the percentage may already be
    /// non-zero), so the ROLLOVER of the weekly boundary is what re-arms the
    /// alerts — one notification per threshold per window, not per sweep.
    /// No "reset" notification: `sessionReset`'s copy is about a 5h window.
    private func checkWeeklyRollover(usage: ClaudeUsage, profileName: String) {
        let boundary = usage.weeklyResetTime
        if Self.windowRolledOver(previousBoundary: previousWeeklyBoundaries[profileName], current: boundary) {
            sentNotifications = sentNotifications.filter { !$0.hasPrefix("\(profileName)_weekly_") }
        }
        previousWeeklyBoundaries[profileName] = boundary
    }

    /// Checks usage and sends appropriate alerts (legacy, for backwards compatibility)
    func checkAndNotify(usage: ClaudeUsage) {
        // Use the active profile's notification settings
        let settings = ProfileManager.shared.activeProfile?.notificationSettings
            ?? NotificationSettings(enabled: false)

        guard settings.enabled else {
            return
        }

        let profileName = ProfileManager.shared.activeProfile?.name ?? "Default"
        checkAndNotify(usage: usage, profileName: profileName, settings: settings)
    }

    /// Sends a profile-specific usage alert
    private func sendProfileAlert(profileName: String, type: AlertType, percentage: Double, thresholdLevel: Int? = nil, resetTime: Date?, soundName: String = "default") {
        // Use the configured threshold level (not current percentage) to prevent duplicate notifications
        let level = thresholdLevel ?? Int(percentage)

        // Create unique identifier based on alert type and threshold level
        let identifier = "\(profileName)_\(type.rawValue)_\(level)"

        // Check if we've already sent this notification
        guard !sentNotifications.contains(identifier) else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(profileName) - \(type.title)"
        content.body = type.message(percentage: percentage, resetTime: resetTime)
        content.categoryIdentifier = "USAGE_ALERT"

        // Apply sound setting
        // Note: UNNotificationSound(named:) only finds sounds bundled in the app,
        // not system sounds from /System/Library/Sounds/. For custom system sounds,
        // we play via NSSound after the notification is delivered.
        let customSoundName: String? = {
            switch soundName {
            case "none":
                return nil
            case "default":
                content.sound = .default
                return nil
            default:
                return soundName
            }
        }()

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Show immediately
        )

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            if error == nil {
                // Play custom system sound after notification is delivered
                if let name = customSoundName {
                    DispatchQueue.main.async {
                        if let sound = NSSound(named: NSSound.Name(name)) {
                            sound.play()
                        } else {
                            NSSound.beep()
                        }
                    }
                }

                // Mark this notification as sent
                var updated = self?.sentNotifications ?? []
                updated.insert(identifier)
                self?.sentNotifications = updated
            }
        }
    }

    /// Sends a notification when auto-switching profiles due to session limit
    func sendAutoSwitchNotification(fromProfile: String, toProfile: String) {
        let content = UNMutableNotificationContent()
        content.title = "notification.profile_auto_switched.title".localized
        content.body = "notification.profile_auto_switched.message".localized(with: fromProfile, toProfile)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let identifier = "auto_switch_\(Date().timeIntervalSince1970)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send auto-switch notification: \(error)")
            }
        }
    }

    /// Alerts that an ACTIVE account's usage endpoint keeps refusing reads
    /// (inferred account-level throttle). The app deliberately does NOT
    /// auto-switch on inferred evidence — switching invalidates every
    /// concurrent CLI session's prompt cache — so the user decides.
    func sendInferredThrottleNotification(profileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "notification.inferred_throttle.title".localized
        content.body = "notification.inferred_throttle.message".localized(with: profileName)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: "inferred_throttle_\(profileName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send inferred-throttle notification: \(error)")
            }
        }
    }

    /// The ACTIVE account's burn-rate PROJECTION crossed the auto-switch
    /// threshold while its usage endpoint keeps refusing reads. The switch
    /// trigger itself stays measured-only (a projection must never spend the
    /// fleet-wide prompt-cache cost of a switch), so the user gets the signal
    /// and makes the call.
    func sendProjectedExhaustionNotification(profileName: String, projectedPercentage: Double) {
        let content = UNMutableNotificationContent()
        content.title = "notification.projected_exhaustion.title".localized
        content.body = "notification.projected_exhaustion.message".localized(
            with: profileName, Int(projectedPercentage.rounded())
        )
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: "projected_exhaustion_\(profileName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send projected-exhaustion notification: \(error)")
            }
        }
    }

    /// Alerts that a profile's saved Claude Code login is dead (expired access token
    /// and revoked/consumed refresh token) and needs `/login` + a re-sync.
    func sendClaudeReloginNotification(profileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "notification.claude_relogin.title".localized
        content.body = "notification.claude_relogin.message".localized(with: profileName)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: "claude_relogin_\(profileName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send Claude re-login notification: \(error)")
            }
        }
    }

    /// Alerts that a profile's saved Codex refresh token was revoked and the account
    /// needs `codex login` + a re-sync (the app cannot repair a revoked token itself).
    /// `cause` picks the instruction: a login revoked by a `codex login` in the
    /// DEFAULT home must not be repaired by another `codex login` there — that
    /// revokes the next account too. Those users are pointed at an isolated home
    /// plus Import instead.
    func sendCodexReloginNotification(
        profileName: String,
        cause: CodexUsageService.ReloginCause = .unknown
    ) {
        let content = UNMutableNotificationContent()
        content.title = "notification.codex_relogin.title".localized
        let messageKey = cause == .defaultHomeClobbered
            ? "notification.codex_relogin.revoked_by_default_home"
            : "notification.codex_relogin.message"
        content.body = messageKey.localized(with: profileName)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: "codex_relogin_\(profileName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send Codex re-login notification: \(error)")
            }
        }
    }

    /// Explains a focus-only switch: the user picked a profile whose provider
    /// login is dead, so the app now SHOWS that profile (which is what makes the
    /// in-app re-login reachable) while the CLI stays signed in as the account
    /// that still owns the shared login. Without this, moving the focus reads as
    /// a completed switch and the user believes the CLI followed.
    /// `ProfileManager` rate-limits it to one per profile per hour.
    func sendFocusedWithoutLoginNotification(
        profileName: String,
        providerName: String,
        currentOwnerName: String?,
        repairLocation: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = "notification.focus_without_login.title".localized
        if let currentOwnerName {
            content.body = "notification.focus_without_login.message".localized(
                with: profileName, providerName, currentOwnerName, repairLocation
            )
        } else {
            content.body = "notification.focus_without_login.message_no_owner".localized(
                with: profileName, providerName, repairLocation
            )
        }
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: "focus_without_login_\(profileName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send focus-without-login notification: \(error)")
            }
        }
    }

    /// Alerts that a profile's saved Grok refresh token was revoked and the account
    /// needs a fresh `grok` CLI login + re-sync (the app cannot repair it itself).
    func sendGrokReloginNotification(profileName: String) {
        let content = UNMutableNotificationContent()
        content.title = "notification.grok_relogin.title".localized
        content.body = "notification.grok_relogin.message".localized(with: profileName)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: "grok_relogin_\(profileName)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send Grok re-login notification: \(error)")
            }
        }
    }

    /// Tells the user that two or more profiles hold logins for the SAME
    /// Anthropic account, so their tiles show one quota twice. Sent once per
    /// episode (`ProfileManager.refreshDuplicateClaudeAccountGroups`); the
    /// identifier is keyed by the member names so a different pair reports
    /// separately while a repeat of the same pair replaces rather than stacks.
    ///
    /// Deliberately advisory: the app never removes a credential to resolve
    /// this. Which profile keeps the account is the user's call.
    func sendDuplicateClaudeAccountNotification(profileNames: [String]) {
        let names = ListFormatter.localizedString(byJoining: profileNames)
        let content = UNMutableNotificationContent()
        content.title = "notification.duplicate_claude_account.title".localized
        content.body = "notification.duplicate_claude_account.message".localized(with: names)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: "duplicate_claude_account_\(profileNames.sorted().joined(separator: "_"))",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send duplicate-account notification: \(error)")
            }
        }
    }

    /// Alerts that macOS's preferences daemon has stopped serving this app's plist, so
    /// the UI is running on cached values and settings changes will not persist. Sent
    /// once per degraded episode (`ProfileManager.syncPreferencesDegradedState`); the
    /// fixed identifier means a repeat within one episode replaces rather than stacks.
    func sendPreferencesDegradedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "notification.preferences_degraded.title".localized
        content.body = "notification.preferences_degraded.message".localized
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let request = UNNotificationRequest(
            identifier: "preferences_degraded",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to send preferences-degraded notification: \(error)")
            }
        }
    }

    /// Clears notification tracking state for a specific profile
    func clearNotificationsForProfile(_ profileName: String) {
        sentNotifications = sentNotifications.filter { !$0.hasPrefix("\(profileName)_") }
        previousSessionPercentages.removeValue(forKey: profileName)
    }

    /// Schedules a notification 24 hours before the session key expires
    func scheduleSessionKeyExpiryNotification(expiryDate: Date) {
        let center = UNUserNotificationCenter.current()
        let identifier = "api_session_key_expiry"

        // Remove any existing expiry notification
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        // Schedule 24 hours before expiry
        let triggerDate = expiryDate.addingTimeInterval(-24 * 60 * 60)
        guard triggerDate > Date() else {
            // Already within 24 hours of expiry — send immediately
            sendSimpleAlert(type: .sessionKeyExpiring)
            return
        }

        let content = UNMutableNotificationContent()
        content.title = AlertType.sessionKeyExpiring.title
        content.body = AlertType.sessionKeyExpiring.message(percentage: 0, resetTime: expiryDate)
        content.sound = .default
        content.categoryIdentifier = "INFO_ALERT"

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: triggerDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        center.add(request) { error in
            if let error = error {
                LoggingService.shared.logError("Failed to schedule session key expiry notification: \(error)")
            }
        }
    }

    /// Clears all pending notifications
    func clearAllNotifications() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}

// MARK: - Alert Types

extension NotificationManager {
    enum AlertType: String {
        case sessionInfo = "session_info"  // 75% threshold
        case sessionWarning = "session_warning"  // 90% threshold
        case sessionCritical = "session_critical"  // 95% threshold
        case sessionReset = "session_reset"
        case weeklyWarning = "weekly_warning"
        case weeklyCritical = "weekly_critical"
        case opusWarning = "opus_warning"
        case opusCritical = "opus_critical"
        case sessionKeyExpiring = "session_key_expiring"
        case notificationsEnabled = "notifications_enabled"

        var title: String {
            switch self {
            case .sessionInfo:
                return "Usage Info"
            case .sessionWarning:
                return "notification.session_warning.title".localized
            case .sessionCritical:
                return "notification.session_critical.title".localized
            case .sessionReset:
                return "notification.session_reset.title".localized
            case .weeklyWarning:
                return "notification.weekly_warning.title".localized
            case .weeklyCritical:
                return "notification.weekly_critical.title".localized
            case .opusWarning:
                return "notification.opus_warning.title".localized
            case .opusCritical:
                return "notification.opus_critical.title".localized
            case .sessionKeyExpiring:
                return "API Session Expiring"
            case .notificationsEnabled:
                return "notification.enabled.title".localized
            }
        }

        func message(percentage: Double, resetTime: Date?) -> String {
            let percentStr = String(format: "%.1f%%", percentage)
            let resetStr = resetTime.map { "Resets \(FormatterHelper.timeUntilReset(from: $0))" } ?? ""

            switch self {
            case .sessionInfo:
                return "You've used \(percentStr) of your session limit. \(resetStr)"
            case .sessionWarning:
                return "notification.session_warning.message".localized(with: percentStr, resetStr)
            case .sessionCritical:
                return "notification.session_critical.message".localized(with: percentStr, resetStr)
            case .sessionReset:
                return "notification.session_reset.message".localized
            case .weeklyWarning:
                return "notification.weekly_warning.message".localized(with: percentStr, resetStr)
            case .weeklyCritical:
                return "notification.weekly_critical.message".localized(with: percentStr, resetStr)
            case .opusWarning:
                return "notification.opus_warning.message".localized(with: percentStr, resetStr)
            case .opusCritical:
                return "notification.opus_critical.message".localized(with: percentStr, resetStr)
            case .sessionKeyExpiring:
                if let resetTime = resetTime {
                    let formatter = RelativeDateTimeFormatter()
                    formatter.unitsStyle = .full
                    let relative = formatter.localizedString(for: resetTime, relativeTo: Date())
                    return "Your API session key expires \(relative). Please re-authenticate to avoid interruption."
                }
                return "Your API session key expires soon. Please re-authenticate to avoid interruption."
            case .notificationsEnabled:
                return "notification.enabled.message".localized
            }
        }
    }
}
