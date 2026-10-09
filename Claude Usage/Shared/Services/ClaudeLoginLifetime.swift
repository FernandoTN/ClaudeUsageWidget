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

    // MARK: - Deadline (cause A)

    /// True when the login's server deadline has passed or falls within
    /// `deadlineMargin`. A credential without the field is never blocked.
    nonisolated static func deadlineBlocksSwitch(_ json: String?, now: Date) -> Bool {
        guard let json, let deadline = deadline(json) else { return false }
        return deadline <= now.addingTimeInterval(deadlineMargin)
    }

    // MARK: - Ordering (newest login wins)

    /// Two deadlines this close belong to ONE login. The deadline is fixed at
    /// `/login` and refreshes do not move it (2026-10-02 research, cause A), but
    /// it is computed on the local clock from a relative `*_expires_in`, so two
    /// copies of one login can disagree by the latency of the call that
    /// recorded them. Two distinct `/login`s are never this close in practice.
    nonisolated static let sameLoginDeadlineTolerance: TimeInterval = 60

    /// Whether `candidate` is a NEWER login than `current`, so replacing
    /// `current` with it loses nothing. In order:
    ///
    /// 1. The CLI's dead marker is never newer than anything, and anything
    ///    else is newer than it — it marks a pair as consumed, it is not one.
    /// 2. Two DIFFERENT logins (both carry a deadline, more than
    ///    `sameLoginDeadlineTolerance` apart): the later deadline wins. Each
    ///    `/login` gets a fresh deadline and refreshes never extend it, so the
    ///    later deadline is the later `/login` — the one that renews longest,
    ///    even when an older login's pair was refreshed after it and carries a
    ///    later access-token expiry.
    /// 3. One login, or a deadline missing on either side: a login past its
    ///    deadline loses to one that is not; otherwise the later access-token
    ///    expiry wins, strictly, and a tie is not newer. Every refresh issues a
    ///    pair with a fixed lifetime, so within one login the expiry orders
    ///    pairs by when they were issued, and the older pair is a consumed one.
    nonisolated static func isNewer(_ candidate: String, than current: String, now: Date) -> Bool {
        if isDeadMarker(candidate) { return false }
        if isDeadMarker(current) { return true }
        let candidateDeadline = deadline(candidate)
        let currentDeadline = deadline(current)
        if let candidateDeadline, let currentDeadline,
           abs(candidateDeadline.timeIntervalSince(currentDeadline)) > sameLoginDeadlineTolerance {
            return candidateDeadline > currentDeadline
        }
        let candidateLapsed = candidateDeadline.map { $0 <= now } ?? false
        let currentLapsed = currentDeadline.map { $0 <= now } ?? false
        if candidateLapsed != currentLapsed { return !candidateLapsed }
        return (accessExpiry(candidate) ?? .distantPast) > (accessExpiry(current) ?? .distantPast)
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
/// refreshes its own login and the widget adopts the rotated pair (newest login
/// wins). A hand-off renews BEFORE it applies.
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