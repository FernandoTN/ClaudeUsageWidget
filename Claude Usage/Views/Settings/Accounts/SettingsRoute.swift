//
//  SettingsRoute.swift
//  Claude Usage
//
//  A typed destination inside the Settings window (docs/specs/ux-revamp.md
//  §5.4): the section, optionally the profile to VIEW first and the Accounts
//  tab to land on. `.settingsSectionRequested` used to carry only a section
//  raw value, so a "Repair…" link from the dashboard opened the Login page of
//  whichever profile happened to be viewed. Both payloads decode: the old
//  string (every existing poster keeps working) and this struct.
//

import Foundation

/// The tabs of the Accounts inspector's detail pane.
enum AccountTab: String, CaseIterable, Hashable {
    case overview, login, alerts, monitoring

    static let available: [AccountTab] = [.overview, .login, .alerts, .monitoring]

    var title: String {
        switch self {
        case .overview: return "accounts.tab.overview".localized
        case .login: return "accounts.tab.login".localized
        case .alerts: return "accounts.tab.alerts".localized
        case .monitoring: return "accounts.tab.monitoring".localized
        }
    }
}

struct SettingsRoute: Hashable {
    var section: SettingsSection
    /// The profile to view (`ProfileManager.viewProfile`) before showing the
    /// section — a deep link that names its account.
    var profileId: UUID? = nil
    var tab: AccountTab? = nil

    /// Decodes a `.settingsSectionRequested` payload: a `SettingsRoute`, or the
    /// legacy section raw value string.
    init?(deepLink object: Any?) {
        if let route = object as? SettingsRoute {
            self = route
        } else if let raw = object as? String, let section = SettingsSection(rawValue: raw) {
            self = SettingsRoute(section: section)
        } else if let raw = object as? String, let alias = Self.legacyAliases[raw] {
            self = alias
        } else {
            return nil
        }
    }

    init(section: SettingsSection, profileId: UUID? = nil, tab: AccountTab? = nil) {
        self.section = section
        self.profileId = profileId
        self.tab = tab
    }

    /// Raw values of the sections deleted in stage 3d, decoded onto the pages that
    /// replaced them (spec §5.5) so every existing poster keeps landing somewhere.
    static let legacyAliases: [String: SettingsRoute] = [
        "manageProfiles": SettingsRoute(section: .accounts),
        "general": SettingsRoute(section: .accounts),
        "cliAccount": SettingsRoute(section: .accounts, tab: .login),
        "codexAccount": SettingsRoute(section: .accounts, tab: .login),
        "appearance": SettingsRoute(section: .display),
        "popover": SettingsRoute(section: .display),
        "appSettings": SettingsRoute(section: .advanced),
        "shortcuts": SettingsRoute(section: .advanced),
    ]
}
