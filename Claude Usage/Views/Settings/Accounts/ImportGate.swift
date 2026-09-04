//
//  ImportGate.swift
//  Claude Usage
//
//  The rule behind the inspector's "Import the CLI's current login into this
//  profile…" button (docs/specs/ux-revamp.md §2.2, D13). Importing copies the
//  CLI's CURRENT login — the account that is Active for the provider — into the
//  viewed profile and claims the pointer. With free Viewing that is the
//  2026-09-03 contamination shape (the owner's login copied into whichever row
//  happened to be viewed), so the copy is allowed silently only when it cannot
//  mix accounts, and otherwise asks first, naming both.
//

import Foundation

enum ImportGate {
    enum Decision: Hashable {
        /// The profile holds no login and carries no account stamp: a fresh import.
        case allowed
        /// The CLI's login IS this profile's account: the documented repair
        /// (`/login` then import), no question asked.
        case repair
        /// The CLI holds a different account than this profile: ask, naming both.
        case confirmDifferent(cliAccount: String, profileAccount: String)
        /// One side cannot be identified (no CLI identity cached, or an
        /// unstamped login already on the profile): ask before copying.
        case confirmUnknown

        var asksFirst: Bool {
            switch self {
            case .allowed, .repair: return false
            case .confirmDifferent, .confirmUnknown: return true
            }
        }
    }

    /// - Parameters:
    ///   - cliAccount: the account behind the CLI's current login (Claude:
    ///     `cliCachedAccountUUID`; Codex: `auth.json`'s `account_id`), nil when unknown.
    ///   - profileAccount: the profile's persisted stamp (`claudeAccountUUID` /
    ///     `codexAccountId`), nil when never learned.
    ///   - profileHasLogin: whether the profile already stores a login for the provider.
    static func decision(cliAccount: String?, profileAccount: String?, profileHasLogin: Bool) -> Decision {
        if !profileHasLogin, profileAccount == nil { return .allowed }
        guard let cliAccount, !cliAccount.isEmpty, let profileAccount, !profileAccount.isEmpty else {
            return .confirmUnknown
        }
        return cliAccount == profileAccount ? .repair : .confirmDifferent(cliAccount: cliAccount, profileAccount: profileAccount)
    }

    /// "…9f3a" — the last four characters, enough to tell two accounts apart
    /// without printing an identifier.
    static func suffix(_ account: String) -> String {
        "…" + String(account.suffix(4))
    }
}
