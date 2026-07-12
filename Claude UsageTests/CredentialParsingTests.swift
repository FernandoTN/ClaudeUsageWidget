//
//  CredentialParsingTests.swift
//  Claude UsageTests
//
//  Unit tests for the pure credential-parsing logic that has repeatedly caused
//  real incidents: token-expiry parsing (ms vs s epoch), Codex JWT expiry,
//  last_refresh timestamps with 6-digit fractional seconds, and the
//  dead-login / usable-credentials predicates.
//

import XCTest
@testable import Claude_Usage

// MARK: - Claude Code CLI credentials JSON

final class ClaudeCredentialParsingTests: XCTestCase {
    private let service = ClaudeCodeSyncService.shared

    private func credentialsJSON(
        accessToken: String = "sk-ant-oat01-testtoken",
        refreshToken: String? = "sk-ant-ort01-testrefresh",
        expiresAt: Any,
        subscriptionType: String = "max"
    ) -> String {
        var oauth: [String: Any] = [
            "accessToken": accessToken,
            "expiresAt": expiresAt,
            "subscriptionType": subscriptionType,
            "scopes": ["user:inference", "user:profile"]
        ]
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        return String(data: data, encoding: .utf8)!
    }

    // MARK: extractTokenExpiry

    func testExpiryParsedFromMilliseconds() {
        // The CLI stores expiresAt as INTEGER MILLISECONDS since epoch.
        let expiry = Date().addingTimeInterval(3600)
        let ms = expiry.timeIntervalSince1970 * 1000.0
        let json = credentialsJSON(expiresAt: Int(ms))

        let parsed = service.extractTokenExpiry(from: json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1.0)
    }

    func testExpiryParsedFromSeconds() {
        // Defensive: some tooling writes seconds. Values <= 1e12 are seconds.
        let expiry = Date().addingTimeInterval(3600)
        let json = credentialsJSON(expiresAt: expiry.timeIntervalSince1970)

        let parsed = service.extractTokenExpiry(from: json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, expiry.timeIntervalSince1970, accuracy: 1.0)
    }

    func testExpiryNilForMissingField() {
        let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "x"]])
        let json = String(data: data, encoding: .utf8)!
        XCTAssertNil(service.extractTokenExpiry(from: json))
    }

    func testExpiryNilForInvalidJSON() {
        XCTAssertNil(service.extractTokenExpiry(from: "{not json"))
        XCTAssertNil(service.extractTokenExpiry(from: ""))
    }

    // MARK: isTokenExpired

    func testFutureExpiryIsNotExpired() {
        let json = credentialsJSON(expiresAt: Int((Date().timeIntervalSince1970 + 3600) * 1000))
        XCTAssertFalse(service.isTokenExpired(json))
    }

    func testPastExpiryIsExpired() {
        let json = credentialsJSON(expiresAt: Int((Date().timeIntervalSince1970 - 3600) * 1000))
        XCTAssertTrue(service.isTokenExpired(json))
    }

    func testMissingExpiryAssumedValid() {
        // No expiry info = assume valid (documented behavior).
        let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "x"]])
        XCTAssertFalse(service.isTokenExpired(String(data: data, encoding: .utf8)!))
    }

    // MARK: extraction helpers

    func testAccessAndRefreshTokenExtraction() {
        let json = credentialsJSON(expiresAt: 1)
        XCTAssertEqual(service.extractAccessToken(from: json), "sk-ant-oat01-testtoken")
        XCTAssertEqual(service.extractRefreshToken(from: json), "sk-ant-ort01-testrefresh")
    }

    func testRefreshTokenNilWhenAbsent() {
        let json = credentialsJSON(refreshToken: nil, expiresAt: 1)
        XCTAssertNil(service.extractRefreshToken(from: json))
    }

    func testSubscriptionInfoExtraction() {
        let json = credentialsJSON(expiresAt: 1, subscriptionType: "free")
        let info = service.extractSubscriptionInfo(from: json)
        XCTAssertEqual(info?.type, "free")
        XCTAssertEqual(info?.scopes, ["user:inference", "user:profile"])
    }

    // MARK: dead-login gating predicates (Profile)

    func testExpiredTokenWithRefreshTokenIsStillUsable() {
        // An expired-but-refreshable login must NOT count as credential-less —
        // that was the "usage silently froze until manual resync" bug.
        let expired = credentialsJSON(expiresAt: Int((Date().timeIntervalSince1970 - 3600) * 1000))
        let profile = Profile(name: "t", cliCredentialsJSON: expired)
        XCTAssertFalse(profile.hasValidCLIOAuth)
        XCTAssertTrue(profile.hasUsableCLIOAuth)
        XCTAssertTrue(profile.hasUsageCredentials)
    }

    func testExpiredTokenWithoutRefreshTokenIsNotUsable() {
        let dead = credentialsJSON(refreshToken: nil, expiresAt: Int((Date().timeIntervalSince1970 - 3600) * 1000))
        let profile = Profile(name: "t", cliCredentialsJSON: dead)
        XCTAssertFalse(profile.hasValidCLIOAuth)
        XCTAssertFalse(profile.hasUsableCLIOAuth)
        XCTAssertFalse(profile.hasUsageCredentials)
    }

    func testValidTokenIsUsable() {
        let valid = credentialsJSON(expiresAt: Int((Date().timeIntervalSince1970 + 3600) * 1000))
        let profile = Profile(name: "t", cliCredentialsJSON: valid)
        XCTAssertTrue(profile.hasValidCLIOAuth)
        XCTAssertTrue(profile.hasUsableCLIOAuth)
    }
}

// MARK: - Codex auth.json

final class CodexCredentialParsingTests: XCTestCase {
    private let service = CodexUsageService.shared

    /// Builds an unsigned JWT whose payload carries the given claims (the app only
    /// decodes the payload segment; it never verifies signatures).
    private func jwt(claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims)
        let base64url = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(base64url).sig"  // "e30" = base64url("{}")
    }

    private func authJSON(
        exp: TimeInterval,
        accountId: String = "acct-123",
        email: String? = "test@example.com",
        refreshToken: String? = "rt-1",
        lastRefresh: String? = nil
    ) -> String {
        var tokens: [String: Any] = [
            "access_token": jwt(claims: ["exp": exp]),
            "account_id": accountId
        ]
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        if let email { tokens["id_token"] = jwt(claims: ["email": email]) }
        var root: [String: Any] = ["tokens": tokens, "OPENAI_API_KEY": NSNull()]
        if let lastRefresh { root["last_refresh"] = lastRefresh }
        let data = try! JSONSerialization.data(withJSONObject: root)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: JWT expiry

    func testExpiryDecodedFromJWTExpClaim() {
        let exp = Date().addingTimeInterval(7200).timeIntervalSince1970
        let json = authJSON(exp: exp)
        let parsed = service.extractTokenExpiry(from: json)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, exp, accuracy: 1.0)
    }

    func testIsTokenExpired() {
        XCTAssertTrue(service.isTokenExpired(authJSON(exp: Date().timeIntervalSince1970 - 60)))
        XCTAssertFalse(service.isTokenExpired(authJSON(exp: Date().timeIntervalSince1970 + 3600)))
    }

    func testExpiryNilForNonJWTAccessToken() {
        let data = try! JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "opaque-token"]])
        XCTAssertNil(service.extractTokenExpiry(from: String(data: data, encoding: .utf8)!))
        // ...and no expiry info means "assume valid".
        XCTAssertFalse(service.isTokenExpired(String(data: data, encoding: .utf8)!))
    }

    // MARK: metadata extraction

    func testAccountIdAndEmailExtraction() {
        let json = authJSON(exp: 1, accountId: "acct-xyz", email: "who@example.com")
        XCTAssertEqual(service.extractAccountId(from: json), "acct-xyz")
        XCTAssertEqual(service.extractEmail(from: json), "who@example.com")
        XCTAssertEqual(service.extractRefreshToken(from: json), "rt-1")
    }

    // MARK: last_refresh parsing

    func testLastRefreshWithSixDigitFractionalSeconds() {
        // The codex CLI writes 6-digit fractional seconds; ISO8601DateFormatter's
        // .withFractionalSeconds accepts exactly 3 — the service must normalize.
        // (Unparsed stamps → .distantPast → refresh-token rotations never adopted.)
        let json = authJSON(exp: 1, lastRefresh: "2026-07-05T17:52:21.319149Z")
        let parsed = service.extractLastRefresh(from: json)
        XCTAssertNotNil(parsed)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: parsed!)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 7, 5, 17, 52, 21])
    }

    func testLastRefreshWithThreeDigitFraction() {
        let json = authJSON(exp: 1, lastRefresh: "2026-07-05T17:52:21.319Z")
        XCTAssertNotNil(service.extractLastRefresh(from: json))
    }

    func testLastRefreshWithSingleDigitFraction() {
        let json = authJSON(exp: 1, lastRefresh: "2026-07-05T17:52:21.3Z")
        XCTAssertNotNil(service.extractLastRefresh(from: json))
    }

    func testLastRefreshWithoutFraction() {
        let json = authJSON(exp: 1, lastRefresh: "2026-07-05T17:52:21Z")
        XCTAssertNotNil(service.extractLastRefresh(from: json))
    }

    func testLastRefreshOrderingSurvivesPrecisionDifference() {
        // A rotation adoption compares stamps from different writers (CLI: 6-digit,
        // this app: no fraction) — ordering must still be correct.
        let earlier = service.extractLastRefresh(from: authJSON(exp: 1, lastRefresh: "2026-07-05T17:52:21.999999Z"))!
        let later = service.extractLastRefresh(from: authJSON(exp: 1, lastRefresh: "2026-07-05T17:52:22Z"))!
        XCTAssertLessThan(earlier, later)
    }

    func testLastRefreshNilWhenAbsent() {
        XCTAssertNil(service.extractLastRefresh(from: authJSON(exp: 1)))
    }
}

// MARK: - Weekly reset projection (Profile.nextWeeklyReset)

final class WeeklyResetProjectionTests: XCTestCase {
    private func profile(name: String = "p", weeklyReset: Date?, weeklyPercentage: Double = 50) -> Profile {
        var usage: ClaudeUsage?
        if let weeklyReset {
            var u = ClaudeUsage.empty
            u.weeklyResetTime = weeklyReset
            u.weeklyPercentage = weeklyPercentage
            usage = u
        }
        return Profile(name: name, claudeUsage: usage)
    }

    func testFutureResetIsReturnedUnchanged() {
        let now = Date()
        let reset = now.addingTimeInterval(3 * 24 * 3600)
        XCTAssertEqual(profile(weeklyReset: reset).nextWeeklyReset(after: now), reset)
    }

    func testPastResetIsProjectedForwardOneWeek() {
        let now = Date()
        let reset = now.addingTimeInterval(-24 * 3600)  // rolled over yesterday
        let projected = profile(weeklyReset: reset).nextWeeklyReset(after: now)
        XCTAssertEqual(projected, reset.addingTimeInterval(7 * 24 * 3600))
        XCTAssertGreaterThan(projected, now)
    }

    func testWeeksOldResetIsProjectedToNextBoundary() {
        // Cached usage can be arbitrarily stale — project week by week.
        let now = Date()
        let reset = now.addingTimeInterval(-20 * 24 * 3600)  // ~3 weeks stale
        let projected = profile(weeklyReset: reset).nextWeeklyReset(after: now)
        XCTAssertGreaterThan(projected, now)
        XCTAssertLessThanOrEqual(projected.timeIntervalSince(now), 7 * 24 * 3600)
        // Same weekly phase as the original boundary
        let delta = projected.timeIntervalSince(reset).truncatingRemainder(dividingBy: 7 * 24 * 3600)
        XCTAssertEqual(delta, 0, accuracy: 0.001)
    }

    func testNoCachedUsageSortsLast() {
        XCTAssertEqual(profile(weeklyReset: nil).nextWeeklyReset(after: Date()), .distantFuture)
    }
}
