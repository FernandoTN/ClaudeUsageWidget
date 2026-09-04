//
//  FleetAlerts.swift
//  Claude Usage
//
//  Fleet-wide alert defaults with a per-account override (docs/specs/ux-revamp.md
//  §5.2 `fleetAlertDefaults_v1`, decision D11): 25 accounts cannot be configured
//  one by one, and a profile whose settings were never touched should follow
//  whatever the fleet decides. Resolution lives in ONE place —
//  `Profile.effectiveNotificationSettings(fleet:)` — used by every notify path.
//

import Foundation

extension Profile {
    /// Whether this profile's alerts come from the fleet defaults instead of
    /// its own `notificationSettings`. Migration rule for profiles saved before
    /// the flag existed (`usesFleetAlertDefaults == nil`): untouched defaults
    /// follow the fleet, customized settings keep their override. New profiles
    /// are created following (`Profile.init` default).
    var followsFleetAlertDefaults: Bool {
        get { usesFleetAlertDefaults ?? (notificationSettings == NotificationSettings()) }
        set { usesFleetAlertDefaults = newValue }
    }

    /// The settings the notifier applies to this profile.
    func effectiveNotificationSettings(fleet: NotificationSettings) -> NotificationSettings {
        followsFleetAlertDefaults ? fleet : notificationSettings
    }
}

enum FleetAlerts {
    /// The value the fleet key is seeded with the first time it is needed:
    /// the type defaults — or, when EVERY profile carries identical settings,
    /// those, promoted (the owner configured them once each; the fleet key
    /// inherits that). Never from whichever row happens to be viewed.
    static func seed(from profiles: [Profile]) -> NotificationSettings {
        guard let first = profiles.first?.notificationSettings else { return NotificationSettings() }
        return profiles.allSatisfy { $0.notificationSettings == first } ? first : NotificationSettings()
    }

    struct OverrideRow: Hashable {
        var id: UUID
        var name: String
        var summary: String
        /// False when the override happens to equal the fleet defaults — the
        /// account can follow the fleet with nothing changing today.
        var differsFromFleet: Bool
    }

    /// The profiles that keep their own alert settings, in roster order.
    static func overrides(in profiles: [Profile], fleet: NotificationSettings) -> [OverrideRow] {
        profiles.filter { !$0.followsFleetAlertDefaults }.map {
            OverrideRow(id: $0.id, name: $0.name, summary: summary($0.notificationSettings),
                        differsFromFleet: $0.notificationSettings != fleet)
        }
    }

    static func followerCount(in profiles: [Profile]) -> Int {
        profiles.filter(\.followsFleetAlertDefaults).count
    }

    /// One line for a settings value: "75 · 90 · 95 % · default sound",
    /// "50 · 90 % · no sound", or "off".
    static func summary(_ settings: NotificationSettings) -> String {
        guard settings.enabled else { return "alerts.summary_off".localized }
        let thresholds = settings.sortedThresholds.map(String.init).joined(separator: " · ")
        let sound: String
        switch settings.soundName {
        case "none": sound = "alerts.summary_no_sound".localized
        case "default": sound = "alerts.summary_default_sound".localized
        default: sound = settings.soundName
        }
        if thresholds.isEmpty { return "alerts.summary_no_thresholds".localized(with: sound) }
        return "alerts.summary".localized(with: thresholds, sound)
    }
}
