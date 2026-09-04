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

    /// Posted when a provider's ACTIVE account changed outside the app — a
    /// `/login` in the terminal (or a `codex login` in an isolated home) that an
    /// adoption pass routed to the matching profile. The view deliberately does
    /// NOT follow such a change, so the UI needs this to be able to say it
    /// happened. object = the new owner's profile UUID; userInfo carries
    /// "provider" (the `Profile.ProviderKind` case name) and "ownerName".
    static let providerOwnerChangedExternally = Notification.Name("providerOwnerChangedExternally")

    /// Posted when the setup wizard should be shown manually (for testing)
    static let showSetupWizard = Notification.Name("showSetupWizard")

    /// Posted when the display mode changes (single/multi profile)
    static let displayModeChanged = Notification.Name("displayModeChanged")

    /// Posted after a profile is deleted (object = the profile's UUID) so
    /// long-lived per-profile tracking state (backoffs, preflight milestones,
    /// notification dedup) can be pruned.
    static let profileDeleted = Notification.Name("profileDeleted")

    /// Posted after a structural multi-profile display change: single↔multi mode
    /// or selection add/remove (anything that changes WHICH status items exist).
    /// userInfo may include "addedProfileIds": [String] (UUID strings) when
    /// selection grew — observers should fetch only those lacking cached usage.
    static let profileDisplayStructureChanged = Notification.Name("profileDisplayStructureChanged")

    /// Posted after a cosmetic multi-profile display change: icon style, show
    /// week/label, time/pace markers, system color, pace coloring — anything
    /// that only changes how existing tiles LOOK. Observers should repaint only
    /// (no teardown, no network).
    static let profileDisplayCosmeticsChanged = Notification.Name("profileDisplayCosmeticsChanged")

    /// Posted when the background Keychain credential load finishes populating the
    /// in-memory cache, so observers can re-read fully-hydrated profiles.
    static let profileCredentialsReady = Notification.Name("profileCredentialsReady")

    /// Posted to jump an already-open settings window to a specific section.
    /// The object is the target SettingsSection's rawValue.
    static let settingsSectionRequested = Notification.Name("settingsSectionRequested")

    /// Posted when `ProfileStore.preferencesDegraded` flips in either direction —
    /// macOS's preferences daemon started refusing reads (cached values are being
    /// served), or a later read succeeded and live values are back.
    static let preferencesDegradedStateChanged = Notification.Name("preferencesDegradedStateChanged")

    /// Posted (object = profile UUID) after a USER-initiated profile activation
    /// succeeds — the auto-switch must respect the explicit choice instead of
    /// yanking an over-threshold account away on the next sweep.
    static let profileManuallyActivated = Notification.Name("profileManuallyActivated")

    /// Posted (userInfo["profileId"] = profile UUID) after a Codex usage-limit
    /// reset is redeemed successfully. The account's windows have just changed
    /// and its cached usage is stale by construction, so an observer should
    /// refresh that profile rather than wait for the next sweep.
    static let codexResetActivated = Notification.Name("codexResetActivated")

    /// Posted to open the token-usage telemetry window (the telemetry
    /// session's surface). object = the profile `UUID` to open filtered to one
    /// account, or nil for the fleet view; userInfo may carry
    /// "provider": `Profile.ProviderKind`. Declared here so the file has one
    /// writer; the observer lives under `Telemetry/`.
    static let telemetryWindowRequested = Notification.Name("telemetryWindowRequested")
}
