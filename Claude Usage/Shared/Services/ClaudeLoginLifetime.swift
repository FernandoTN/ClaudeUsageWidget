//
//  ClaudeLoginLifetime.swift
//  Claude Usage
//
//  What a stored Claude Code login says about its own lifetime, and when the
//  widget may redeem its refresh token. Pure and nonisolated: the candidate
//  filters run it on every paint, and the CLI-store reads run off the main
//  actor. Nothing here reads or logs a token value.
//

import CryptoKit
import Foundation

enum ClaudeLoginLifetime {

    // MARK: - Fields

    /// A login whose server deadline falls inside this margin is not a switch
    /// target. One hour, the same horizon as `ClaudeRefreshPolicy.handoffFreshness`:
    /// a hand-off promises the CLI at least an hour of working login, and a
    /// login that ends inside that hour cannot keep the promise if the server
    /// ends its access token with it (the evidence neither confirms nor rules
    /// that out). It also absorbs the gap between the local clock the deadline
    /// was computed on and the server's. Longer would bench accounts that can
    /// still serve for hours.
    nonisolated static let deadlineMargin: TimeInterval = 3600

    nonisolated static func oauth(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["claudeAiOauth"] as? [String: Any]
    }

    /// An epoch timestamp the CLI stores in milliseconds; seconds are accepted
    /// too (anything below 1e12 is seconds — year 33658 in seconds versus 2001
    /// in milliseconds). Numeric strings are tolerated.
    nonisolated static func epochDate(_ value: Any?) -> Date? {
        let raw: Double?
        switch value {
        case let number as NSNumber: raw = number.doubleValue
        case let text as String: raw = Double(text)
        default: raw = nil
        }
        guard let raw, raw.isFinite else { return nil }
        return Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
    }

    /// `claudeAiOauth.expiresAt` — when the access token stops working.
    nonisolated static func accessExpiry(_ json: String) -> Date? {
        epochDate(oauth(json)?["expiresAt"])
    }

    /// `claudeAiOauth.refreshTokenExpiresAt` — the server's deadline for the
    /// whole login. After it the refresh grant is refused and only `/login`
    /// renews the account. Nil when the field is absent (older CLIs).
    nonisolated static func deadline(_ json: String) -> Date? {
        epochDate(oauth(json)?["refreshTokenExpiresAt"])
    }

    /// The CLI's "login expired" marker: when its refresh grant is refused it
    /// rewrites the stored login with both tokens empty and `expiresAt: 0`.
    /// It is a verdict on the pair that WAS there, not a login.
    nonisolated static func isDeadMarker(_ json: String) -> Bool {
        guard let oauth = oauth(json) else { return false }
        let access = oauth["accessToken"] as? String ?? ""
        let refresh = oauth["refreshToken"] as? String ?? ""
        return access.isEmpty && refresh.isEmpty
    }

    /// Whether the login carries a refresh token, i.e. whether it can renew.
    nonisolated static func hasRefreshToken(_ json: String) -> Bool {
        !(oauth(json)?["refreshToken"] as? String ?? "").isEmpty
    }

    /// An access token and nothing else: no refresh token, no expiry. The
    /// store read rebuilds exactly this from a Keychain payload the `security`
    /// tool truncated. It can serve requests until its token dies and can
    /// never renew, so no adoption, sync or apply takes it.
    nonisolated static func isPartial(_ json: String) -> Bool {
        guard let oauth = oauth(json) else { return false }
        return !(oauth["accessToken"] as? String ?? "").isEmpty
            && (oauth["refreshToken"] as? String ?? "").isEmpty
            && oauth["expiresAt"] == nil
    }

    /// A short tag for a login, derived one-way from its refresh token with a
    /// domain prefix. It is persisted with the profile (the account stamp's
    /// binding, the consumed-pair record), so it is never the in-memory
    /// `fingerprint` and never the token. Nil without a refresh token.
    nonisolated static func loginTag(_ json: String?) -> String? {
        guard let json, let token = refreshToken(json), !token.isEmpty else { return nil }
        return String(fingerprint("cuw-login-tag-v1:" + token).prefix(32))
    }

    // MARK: - Deadline (cause A)

    /// True when the login's server deadline has passed or falls within
    /// `deadlineMargin`. A credential without the field is never blocked.
    nonisolated static func deadlineBlocksSwitch(_ json: String?, now: Date) -> Bool {
        guard let json, let deadline = deadline(json) else { return false }
        return deadline <= now.addingTimeInterval(deadlineMargin)
    }

    // MARK: - Ordering (the login the CLI holds wins)

    /// Whether the login's server deadline has passed. A credential without
    /// the field never lapses here.
    nonisolated static func isLapsed(_ json: String, now: Date) -> Bool {
        deadline(json).map { $0 <= now } ?? false
    }

    /// What is known about whether the CLI's login and a stored one belong to
    /// the same account. A KNOWN different account never reaches the ordering:
    /// the account guard refuses it first. Only token-bound evidence verifies:
    /// the identity the CLI login's own token reports, against a profile stamp
    /// bound to the login the profile holds (`Profile.claudeStampIsBound`).
    enum AccountMatch {
        /// Both sides resolve to one account by token-bound evidence: the
        /// account guard's `.write`, or the identity adoption's verified owner.
        case verified
        /// The two are not known to differ, but neither is proven: the
        /// guard's `.noEvidence` (a side unidentified, or known only from
        /// `~/.claude.json` or an unbound stamp).
        case unverified
    }

    /// Whether the login the CLI's store holds replaces a profile's stored one.
    ///
    /// For one account, the login the CLI holds is authoritative. The widget
    /// never redeems a login the CLI holds (`ClaudeRefreshPolicy`), so the
    /// CLI's copy can only be the widget's or a newer one: the CLI renews its
    /// own login, and a `/login` replaces it. The one way the CLI ever held an
    /// OLDER pair was a predecessor the widget had consumed (2026-10-02), which
    /// that policy prevents and `cliLoginConsumed` still refuses.
    ///
    /// The deadline never ranks two live logins. Three `/login`s into one
    /// account within seven minutes (2026-10-12) recorded deadlines out of
    /// login order: the second's was the earliest by two and a half days, the
    /// third's three hours before the first's. Ranking by it kept a superseded
    /// pair over the one the CLI was using. It only drops a lapsed login.
    ///
    /// 1. The CLI's dead marker, a partial login (`isPartial`) and a pair this
    ///    app redeemed are never adopted.
    /// 2. A profile with no stored login takes the CLI's.
    /// 3. A lapsed CLI login never replaces a stored one, and a login without a
    ///    refresh token never replaces one that has one. A live one replaces a
    ///    stored one that is lapsed, the marker, or known dead
    ///    (`storedLoginDead`: the caller's own evidence, e.g. a refused refresh).
    /// 4. Two live, different logins: the CLI's wins when the account match is
    ///    verified. Unverified, the stored login stays, so a missing identity
    ///    never adopts a login the account guard could not place.
    ///
    /// No path orders two live logins of one account without this rule (the
    /// CLI's store is on one side of every comparison), so no access-token
    /// expiry fallback remains.
    nonisolated static func cliLoginReplaces(
        _ stored: String?,
        with cliLogin: String,
        account: AccountMatch,
        cliLoginConsumed: Bool = false,
        storedLoginDead: Bool = false,
        now: Date
    ) -> Bool {
        if isDeadMarker(cliLogin) || isPartial(cliLogin) || cliLoginConsumed { return false }
        guard let stored else { return true }
        if isSamePair(cliLogin, stored) || isLapsed(cliLogin, now: now) { return false }
        if hasRefreshToken(stored), !hasRefreshToken(cliLogin) { return false }
        if storedLoginDead || isDeadMarker(stored) || isLapsed(stored, now: now) { return true }
        return account == .verified
    }

    /// Two copies carrying one token pair are one login, whatever else their
    /// JSON says (the CLI may rewrite its item with other fields).
    nonisolated static func isSamePair(_ a: String, _ b: String) -> Bool {
        guard let left = oauth(a), let right = oauth(b) else { return a == b }
        return left["accessToken"] as? String == right["accessToken"] as? String
            && left["refreshToken"] as? String == right["refreshToken"] as? String
    }

    /// A log-safe description of a login: its expiries, never a token.
    nonisolated static func summary(_ json: String?) -> String {
        guard let json else { return "no login" }
        if isDeadMarker(json) { return "the CLI's login-expired marker" }
        let expiry = accessExpiry(json).map { "\($0)" } ?? "unknown"
        let deadline = deadline(json).map { ", deadline \($0)" } ?? ""
        return "access token expires \(expiry)\(deadline)"
    }

    /// The refresh token of a login, from valid JSON or — for a Keychain item
    /// the `security` tool truncated — by pattern. Never logged.
    nonisolated static func refreshToken(_ raw: String) -> String? {
        if let token = oauth(raw)?["refreshToken"] as? String { return token }
        let pattern = "\"refreshToken\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw) else { return nil }
        return String(raw[range])
    }

    /// A one-way fingerprint of a refresh token, for comparing two copies in
    /// memory without holding or logging the token itself.
    nonisolated static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// When the widget may redeem a Claude refresh token.
///
/// Redeeming a Claude refresh token revokes the access token issued with it at
/// once (2026-10-08 21:50:22 and 10-09 05:22:40: nine sessions failed within
/// three seconds of each redemption). So the widget NEVER redeems a login the
/// CLI holds or is being handed — not even in its last minutes and not even
/// with the result written back: the CLI process can be redeeming the same
/// token at that moment, and no lock the widget holds can see it. The CLI
/// refreshes its own login and the widget adopts the rotated pair (the login
/// the CLI holds wins, `ClaudeLoginLifetime.cliLoginReplaces`). A hand-off
/// renews BEFORE it applies.
enum ClaudeRefreshPolicy {
    /// A login is renewed before it is handed to the CLI unless its access
    /// token has at least this long left — the same window the candidate
    /// preflight validates with. A login handed over therefore has an hour
    /// left, and from then on only the CLI renews it.
    nonisolated static let handoffFreshness: TimeInterval = 3600

    /// A background login (one the CLI does not hold) is healed when its access
    /// token has less than this left — the sweep's default.
    nonisolated static let healWindow: TimeInterval = 120

    enum Role {
        /// Sweeps and the preflight: skip a redemption already in flight.
        case maintenance
        /// The activation renewing the login it is about to apply: wait for a
        /// redemption in flight and apply its result.
        case handoff
    }

    enum Decision: Equatable {
        /// Fresh enough, no refresh token, or a login already flagged dead.
        case notNeeded
        /// Redeem; the result goes to the profile store only.
        case redeem
        /// The CLI holds this login, owns it, or is being handed it: a
        /// redemption would revoke the access token its sessions use.
        case refuseHandedOff
    }

    /// - Parameters:
    ///   - cliHoldsThisLogin: whether the CLI's store holds THIS refresh token
    ///     right now (`nil`: the store could not be read). The invariant itself
    ///     — it covers a stale pointer, a profile that shares the owner's
    ///     login, and ownership that moved after any other check.
    ///   - ownsCLILogin: the provider pointer names this profile.
    nonisolated static func decide(
        timeLeft: TimeInterval,
        freshFor: TimeInterval,
        canRedeem: Bool,
        cliHoldsThisLogin: Bool?,
        ownsCLILogin: Bool,
        handoffInFlight: Bool,
        role: Role
    ) -> Decision {
        guard canRedeem, timeLeft < freshFor else { return .notNeeded }
        // Unknown is refused: a store that cannot be read cannot prove the
        // token is not the CLI's.
        guard cliHoldsThisLogin == false else { return .refuseHandedOff }
        if ownsCLILogin { return .refuseHandedOff }
        if handoffInFlight, case .maintenance = role { return .refuseHandedOff }
        return .redeem
    }
}