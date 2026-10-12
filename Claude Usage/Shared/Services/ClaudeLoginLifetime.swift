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

    /// Whether the login is COMPLETE: an access token, a refresh token and an
    /// access-token expiry, checked structurally. Anything less — the access
    /// token the store read rebuilds from a truncated Keychain payload, or an
    /// access token and expiry without a refresh token — can serve requests
    /// until its token dies and never renew, so no adoption, sync or apply
    /// takes it, from any source.
    nonisolated static func isComplete(_ json: String) -> Bool {
        guard let oauth = oauth(json) else { return false }
        return !(oauth["accessToken"] as? String ?? "").isEmpty
            && !(oauth["refreshToken"] as? String ?? "").isEmpty
            && epochDate(oauth["expiresAt"]) != nil
    }

    /// A short tag for a login, derived one-way from its refresh token with a
    /// domain prefix. It is persisted (the store's refused-grant, account and
    /// redemption records), so it is never the in-memory `fingerprint` and
    /// never the token. Nil without a refresh token.
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

    /// What one login's OWN access token proves (#186 v3). Evidence comes only
    /// from that token, through a FRESH identity read that bypasses the
    /// identity cache, plus three store-owned facts about the exact credential
    /// (`ProfileStore`): the token endpoint refused its grant, this app sent
    /// its grant (the redemption record), and the account a fresh read
    /// reported while it was live.
    enum LoginEvidence: Equatable {
        /// A fresh read answered 2xx: live, and this account.
        case live(account: String)
        /// The token endpoint refused its refresh grant, this app sent its
        /// grant (pending or consumed: the predecessor's access token can keep
        /// answering for a while, so its read proves nothing), or its own
        /// UNEXPIRED access token was refused (401/403): dead. `account` is the
        /// credential's recorded account, when one was recorded.
        case dead(account: String?)
        /// Nothing proves it live or dead: its access token has expired (which
        /// proves nothing either way), or the read got no answer (transport
        /// error, 5xx). `account` as for `.dead`.
        case unknown(account: String?)

        var account: String? {
            switch self {
            case .live(let account): return account
            case .dead(let account), .unknown(let account): return account
            }
        }
    }

    /// The evidence one read produced. `identifiedAccount` is the account a
    /// fresh 2xx reported and `rejectedStatus` the status that refused it (both
    /// nil when no read was made, which is always so for an expired token).
    /// A refused or redeemed grant overrides any "alive" answer but never the
    /// account fact (`recordedAccount`); the account record never establishes
    /// liveness.
    nonisolated static func evidence(
        identifiedAccount: String?,
        rejectedStatus: Int?,
        accessExpiry: Date?,
        grantRefused: Bool,
        grantRedeemed: Bool = false,
        recordedAccount: String?,
        now: Date
    ) -> LoginEvidence {
        let known = recordedAccount ?? identifiedAccount
        if grantRefused || grantRedeemed { return .dead(account: known) }
        let unexpired = accessExpiry.map { $0 > now } ?? false
        if unexpired, let identifiedAccount { return .live(account: identifiedAccount) }
        if unexpired, let status = rejectedStatus, status == 401 || status == 403 { return .dead(account: recordedAccount) }
        return .unknown(account: recordedAccount)
    }

    /// Whether the login the CLI's store holds replaces a profile's stored one.
    ///
    /// Among logins of the SAME account that are proven live, the login the
    /// CLI holds wins. Recency never decides: no access-expiry or deadline
    /// ordering at all. The widget never redeems a login the CLI holds
    /// (`ClaudeRefreshPolicy`), so the CLI's copy is the CLI's own renewal or
    /// a `/login`; and a non-owner profile can legitimately hold an
    /// independent second chain of the CLI's account that the widget heals
    /// later, which recency would rank first.
    ///
    /// The deadline never ranks two live logins either. Three `/login`s into
    /// one account within seven minutes (2026-10-12) recorded deadlines out of
    /// login order. It only drops a lapsed login.
    ///
    /// 1. The CLI's login must be complete (`isComplete`), not the dead
    ///    marker, not lapsed, and PROVEN LIVE by its own fresh read.
    /// 2. The stored side needs its own evidence: live as account A, or dead,
    ///    or unknown liveness with a recorded account. Its account must be the
    ///    CLI login's (a different one is contamination: refused). A dead
    ///    login with no recorded account is replaced unless the profile's stamp
    ///    names another account (weak evidence may refuse, never grant).
    ///    Unknown with no recorded account: the stored login stays; explicit
    ///    Sync is the user's path. So does an empty profile.
    nonisolated static func cliLoginReplaces(
        _ stored: String?,
        with cliLogin: String,
        cli: LoginEvidence,
        stored storedEvidence: LoginEvidence,
        storedStamp: String?,
        now: Date
    ) -> Bool {
        guard isComplete(cliLogin), !isDeadMarker(cliLogin), !isLapsed(cliLogin, now: now),
              case .live(let account) = cli else { return false }
        guard let stored, !isSamePair(cliLogin, stored) else { return false }
        switch storedEvidence {
        case .live(let storedAccount):
            return storedAccount == account
        case .unknown(let recorded):
            return recorded == account
        case .dead(let recorded):
            if let recorded { return recorded == account }
            return storedStamp.map { $0.isEmpty || $0 == account } ?? true
        }
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

    /// What a refresh grant that brought back no successor did to its
    /// credential, for the redemption record
    /// (`ProfileStore.markClaudeRedemptionPending`, written before the send).
    enum GrantOutcome: Equatable {
        /// The token endpoint refused the grant (400/401/403). The refusal is
        /// recorded; the pending mark stays (the credential is dead either way).
        case refused
        /// The grant certainly never left this Mac, or the endpoint answered
        /// without processing it (429): the credential is untouched, and its
        /// pending mark is taken back.
        case notProcessed
        /// Anything else — a timeout, a dropped connection, a 5xx, an answer
        /// that could not be read: it may have been consumed, so the pending
        /// mark stays.
        case ambiguous
    }

    static func grantOutcome(of error: Error) -> GrantOutcome {
        if case ClaudeCodeError.tokenRefreshFailed(let status) = error {
            switch status {
            case 400, 401, 403: return .refused
            case 429: return .notProcessed
            default: return .ambiguous
            }
        }
        if let transport = error as? URLError, notSentCodes.contains(transport.code) { return .notProcessed }
        return .ambiguous
    }

    /// Transport failures that happen before a request's body leaves this Mac:
    /// no connection, no name, no connection to the host, a TLS handshake
    /// that failed, a request that could not be built.
    nonisolated private static let notSentCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
        .internationalRoamingOff, .dataNotAllowed, .callIsActive, .secureConnectionFailed,
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
        .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL,
    ]
}