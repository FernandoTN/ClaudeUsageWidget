//
//  Notification+Extensions.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-20.
//

import Foundation

extension Notification.Name {
    /// Posted when the menu bar icon configuration changes (metrics enabled/disabled, order, styling, etc.)
    static let menuBarIconConfigChanged = Notification.Name("menuBarIconConfigChanged")

    /// Posted when credentials are added, removed, or changed (Claude.ai or API Console)
    static let credentialsChanged = Notification.Name("credentialsChanged")

    /// Posted when the setup wizard should be shown manually (for testing)
    static let showSetupWizard = Notification.Name("showSetupWizard")

    /// Posted when the display mode changes (single/multi profile)
    static let displayModeChanged = Notification.Name("displayModeChanged")

    /// Posted when the background Keychain credential load finishes populating the
    /// in-memory cache, so observers can re-read fully-hydrated profiles.
    static let profileCredentialsReady = Notification.Name("profileCredentialsReady")

    /// Posted to jump an already-open settings window to a specific section.
    /// The object is the target SettingsSection's rawValue.
    static let settingsSectionRequested = Notification.Name("settingsSectionRequested")
}
