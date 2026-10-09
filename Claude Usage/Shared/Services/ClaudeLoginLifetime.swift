//
//  ClaudeLoginLifetime.swift
//  Claude Usage
//
//  What a stored Claude Code login says about its own lifetime, and when the
//  widget may redeem its refresh token. Pure and nonisolated: the candidate
//  filters run it on every paint, and the CLI-store reads run off the main
//  actor. Nothing here reads or logs a token value.
//

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

    /// Whether `candidate` is a NEWER login than `current`, so replacing
    /// `current` with it loses nothing. In order:
    ///
    /// 1. The CLI's dead marker is never newer than anything, and anything
    ///    else is newer than it — it marks a pair as consumed, it is not one.
    /// 2. A login past its server deadline loses to one that is not, whatever
    ///    their access tokens say: a fresh `/login` can carry an earlier
    ///    access-token expiry than an old pair refreshed minutes later, and
    ///    only the fresh one can still be renewed.
    /// 3. Otherwise the later access-token expiry wins, strictly; a tie is
    ///    not newer. Every refresh issues a pair with a fixed lifetime, so
    ///    within one account the expiry orders pairs by when they were issued,
    ///    and an older pair of the same login is a consumed one.
    nonisolated static func isNewer(_ candidate: String, than current: String, now: Date) -> Bool {
        if isDeadMarker(candidate) { return false }
        if isDeadMarker(current) { return true }
        let candidateLapsed = deadline(candidate).map { $0 <= now } ?? false
        let currentLapsed = deadline(current).map { $0 <= now } ?? false
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
}

/// When the widget may redeem a Claude refresh token.
///
/// Redeeming a Claude refresh token revokes the access token issued with it at
/// once (2026-10-08 21:50:22 and 10-09 05:22:40: nine sessions failed within
/// three seconds of each redemption). So a login the CLI holds, or is about to
/// be handed, must not be rotated by anyone but the step that writes the
/// rotated pair to the CLI — and a hand-off renews BEFORE it applies.
enum ClaudeRefreshPolicy {
    /// A login is renewed before it is handed to the CLI unless its access
    /// token has at least this long left — the same window the candidate
    /// preflight validates with. A login handed over therefore has an hour
    /// left, so nothing (the CLI's own 5-minute refresh lead, the sweep's
    /// 2-minute heal, a late preflight) has any reason to redeem it right after
    /// the switch.
    nonisolated static let handoffFreshness: TimeInterval = 3600

    /// The only window in which the widget redeems a login the CLI holds: the
    /// last two minutes, inside the CLI's own five-minute refresh lead. A
    /// running CLI has always refreshed first by then (the sweep adopts its
    /// result); the widget steps in only for an idle CLI whose access token is
    /// lapsing anyway, and writes the rotated pair to the CLI in the same step.
    nonisolated static let ownerRefreshHorizon: TimeInterval = 120

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
        /// Redeem; the profile owns the CLI login, so the result is written to
        /// the CLI in the same step.
        case redeemAndHandToCLI
        /// The CLI holds this login (or is being handed it): a redemption here
        /// would revoke the access token its sessions are using.
        case refuseHandedOff
    }

    nonisolated static func decide(
        timeLeft: TimeInterval,
        freshFor: TimeInterval,
        canRedeem: Bool,
        ownsCLILogin: Bool,
        handoffInFlight: Bool,
        role: Role,
        syncToSystem: Bool
    ) -> Decision {
        guard canRedeem, timeLeft < freshFor else { return .notNeeded }
        if ownsCLILogin {
            return syncToSystem && timeLeft < ownerRefreshHorizon ? .redeemAndHandToCLI : .refuseHandedOff
        }
        if handoffInFlight, case .maintenance = role { return .refuseHandedOff }
        // A login the CLI does not hold is never written to it from here —
        // that would be an account switch nobody asked for.
        return .redeem
    }
}
