//
//  CodexUsageServiceTests.swift
//  Claude UsageTests
//
//  Tests for CodexUsageService's non-200 classification — specifically the 429
//  branch (audit H4). Before it existed, a throttled Codex account fell through
//  to a bare `.apiGenericError` with no `retryAfterSeconds`: MenuBarManager keys
//  BOTH the burst backoff and the account-throttle stamp off `.apiRateLimited`
//  plus that field, so the account got neither, was re-fetched every 30s sweep,
//  and the user was told to "re-sync your Codex account" for what was a rate
//  limit.
//
//  The response is stubbed as a constructed HTTPURLResponse rather than a live
//  endpoint — the classification is a pure function precisely so this is
//  possible without a URLProtocol double (the suite has none).
//
//  It also covers the DEAD-LOGIN LIFECYCLE added after the 2026-09-03 incident
//  (audit C1/C2/H2/H8): one 4xx used to flag a profile forever — a 200 never
//  cleared the flag, the flag then blocked the refresh that would have healed
//  it, and the re-login notification was deduped for the life of the install,
//  so an account with a still-valid 10-day access token went dark silently.
//  Every decision below is a pure function or a state transition precisely so
//  it can be asserted without a network call.
//

import XCTest
@testable import Claude_Usage

final class CodexUsageServiceTests: XCTestCase {

    /// Fixed locale + timezone so the rendered retry clock is deterministic.
    private func fixedClock() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    // MARK: - 429

    func testThrottled429IsTypedRateLimitedAndCarriesRetryAfter() {
        // Given: the usage endpoint refuses with an account-scale Retry-After.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = fixedClock()

        // When
        let error = CodexUsageService.usageFetchError(
            for: response(429, headers: ["Retry-After": "2918"]),
            now: now,
            clockFormatter: clock
        )

        // Then: the taxonomy MenuBarManager's throttle stamp and burst backoff
        // both key on — 2918s is well over accountThrottleRetryAfterFloor, so
        // this is the shape that stamps the account as exhausted.
        XCTAssertEqual(error.code, .apiRateLimited)
        XCTAssertEqual(error.retryAfterSeconds, 2918)
        XCTAssertGreaterThanOrEqual(
            error.retryAfterSeconds ?? 0,
            MenuBarManager.accountThrottleRetryAfterFloor
        )

        // And: the user is told when the app comes back, not to fix a login
        // that is not broken.
        XCTAssertTrue(error.message.contains("rate limited, retrying at "), error.message)
        XCTAssertTrue(error.message.hasSuffix(clock.string(from: now.addingTimeInterval(2918))),
                      error.message)
        XCTAssertFalse(error.message.lowercased().contains("re-sync"), error.message)
        XCTAssertFalse((error.recoverySuggestion ?? "").lowercased().contains("re-sync"))
    }

    /// The header goes through the shared `parseRetryAfter`, so the branch
    /// inherits its RFC 9110 coverage: an HTTP-date form is honored (it used to
    /// read as "no header"), an out-of-range value is clamped rather than
    /// blinding the tile for its full span, and a non-finite one is rejected
    /// before it can reach an `Int(_:)` conversion.
    func testRetryAfterFlowsThroughTheSharedParser() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        // HTTP-date form, exactly 5 minutes past `now` (1_800_000_000 GMT is
        // Fri, 15 Jan 2027 08:00:00). This shape used to read as "no header".
        let dateForm = CodexUsageService.usageFetchError(
            for: response(429, headers: ["Retry-After": "Fri, 15 Jan 2027 08:05:00 GMT"]),
            now: now
        )
        XCTAssertEqual(dateForm.code, .apiRateLimited)
        XCTAssertEqual(dateForm.retryAfterSeconds, 300,
                       "an HTTP-date Retry-After must still reach the throttle stamp")

        // Clamped, not honored literally.
        let huge = CodexUsageService.usageFetchError(
            for: response(429, headers: ["Retry-After": "999999999"]), now: now
        )
        XCTAssertEqual(huge.retryAfterSeconds, retryAfterMaximum)

        // Non-finite is rejected outright — never an unguarded Int conversion.
        let bogus = CodexUsageService.usageFetchError(
            for: response(429, headers: ["Retry-After": "1e400"]), now: now
        )
        XCTAssertNil(bogus.retryAfterSeconds)

        // A 429 with no usable header still types as rate-limited (the burst
        // backoff's exponential guess takes over) and still avoids "re-sync".
        let bare = CodexUsageService.usageFetchError(for: response(429), now: now)
        XCTAssertEqual(bare.code, .apiRateLimited)
        XCTAssertNil(bare.retryAfterSeconds)
        XCTAssertTrue(bare.message.contains("rate limited"), bare.message)
        XCTAssertFalse(bare.message.lowercased().contains("re-sync"), bare.message)
    }

    // MARK: - Everything else keeps its existing taxonomy

    func testNon429StatusesAreUnchanged() {
        for status in [401, 403] {
            let error = CodexUsageService.usageFetchError(for: response(status))
            XCTAssertEqual(error.code, .apiUnauthorized, "status \(status)")
            XCTAssertNil(error.retryAfterSeconds, "status \(status)")
        }

        let serverError = CodexUsageService.usageFetchError(for: response(500))
        XCTAssertEqual(serverError.code, .apiGenericError)
        XCTAssertNil(serverError.retryAfterSeconds)
        // A genuinely unexplained failure DOES still point at a re-sync.
        XCTAssertEqual(serverError.recoverySuggestion, "Please re-sync your Codex account in Settings")
    }

    // MARK: - Dead-login flag lifecycle (audit C1)

    /// A 200 from the usage endpoint is the app's only positive proof that a
    /// login works, so it must clear the flag AND re-arm the notification. It
    /// did neither: 'Cod' sat flagged-but-working, and its sibling went dark
    /// with no second notification.
    func testSuccessfulUsageFetchClearsTheDeadFlag() {
        let service = CodexUsageService.shared
        let profileId = UUID()
        defer { service.forgetProfile(profileId) }

        // Given: the profile was flagged dead by an earlier refresh refusal.
        service.markLoginDead(profileId)
        XCTAssertTrue(service.isLoginMarkedDead(profileId))
        XCTAssertFalse(service.hasRecentUsageSuccess(profileId, within: 300))

        // When: the account answers its own usage endpoint.
        service.recordUsageSuccess(for: profileId)

        // Then: the flag is gone, the measurement is stamped, and because the
        // notification dedup IS the flag, a later working→dead transition can
        // notify again.
        XCTAssertFalse(service.isLoginMarkedDead(profileId))
        XCTAssertTrue(service.hasRecentUsageSuccess(profileId, within: 300))
        XCTAssertFalse(service.hasRecentUsageSuccess(profileId, within: 0))
    }

    /// Only a definitive verdict on the REFRESH GRANT is terminal. A usage-
    /// endpoint 401 forces a refresh first and never flags on its own; a bare
    /// 400/403 from the token endpoint is a malformed request or an edge
    /// refusal and says nothing about the grant.
    func testOnlyADefinitiveGrantVerdictFlagsALoginDead() {
        let terminal = CodexUsageService.refreshFailureIsTerminal

        XCTAssertTrue(terminal(400, "invalid_grant"), "the revoked-refresh-token verdict")
        XCTAssertTrue(terminal(400, "invalid_client"))
        XCTAssertTrue(terminal(401, nil), "the auth server rejected the client outright")

        XCTAssertFalse(terminal(400, nil), "a 400 with no error code is not a grant verdict")
        XCTAssertFalse(terminal(403, nil), "403 is an edge/WAF shape, not a revoked grant")
        XCTAssertFalse(terminal(400, "invalid_request"))
        XCTAssertFalse(terminal(500, nil))
        XCTAssertFalse(terminal(-1, nil), "a transport failure is not a verdict")
    }

    // MARK: - Liveness gate (audit C2)

    /// The gate that decides whether a stored login may be written to
    /// ~/.codex/auth.json. Expiry alone cannot answer it: a Codex access token
    /// lives ~10 days, so a revoked login passes an expiry check for days and
    /// writing it bricks the codex CLI.
    func testApplyGateRefusesADeadFlaggedButUnexpiredLogin() {
        let decide = CodexUsageService.applyDecision

        // The live 2026-09-03 shape: flagged, JWT says valid until 09-11, and
        // the endpoint gave no fresh answer. Refuse — the CLI keeps working.
        XCTAssertFalse(decide(false, true, .unknown))
        // Measured 200 overrules a stale flag: one success is always enough.
        XCTAssertTrue(decide(false, true, .live))
        // A measured refusal refuses, flag or no flag.
        XCTAssertFalse(decide(false, false, .dead))
        XCTAssertFalse(decide(false, true, .dead))
        // No evidence and no flag: proceed, as before — an outage must not
        // block every switch.
        XCTAssertTrue(decide(false, false, .unknown))
        // Expired beats everything.
        XCTAssertFalse(decide(true, false, .live))
    }

    /// What a usage status says about the LOGIN. A 429 or 5xx is evidence about
    /// the endpoint, never about the token.
    func testLivenessVerdictClassification() {
        XCTAssertEqual(CodexUsageService.livenessVerdict(status: 200), .live)
        XCTAssertEqual(CodexUsageService.livenessVerdict(status: 401), .dead)
        XCTAssertEqual(CodexUsageService.livenessVerdict(status: 403), .dead)
        XCTAssertEqual(CodexUsageService.livenessVerdict(status: 429), .unknown)
        XCTAssertEqual(CodexUsageService.livenessVerdict(status: 500), .unknown)
    }

    // MARK: - 401 fetch backoff (audit H2)

    /// A 401 carries no Retry-After and nothing used to slow it down: one
    /// dead-flagged Codex profile drew 1,009 of them in nine hours. The
    /// schedule starts at 5 minutes and doubles to a 60-minute cap; a
    /// provider-active account stays at the first step because its number
    /// gates the auto-switch and a CLI-side login can revive it at any moment.
    func testAuthBackoffSchedule() {
        let interval = MenuBarManager.authBackoffInterval

        XCTAssertEqual(interval(1, false), 300)
        XCTAssertEqual(interval(2, false), 600)
        XCTAssertEqual(interval(3, false), 1200)
        XCTAssertEqual(interval(4, false), 2400)
        XCTAssertEqual(interval(5, false), 3600, "capped at 60 minutes")
        XCTAssertEqual(interval(12, false), 3600, "still capped")

        for streak in 1...6 {
            XCTAssertEqual(interval(streak, true), 300, "the active account retries every 5 min")
        }

        // Defensive: a zero/negative streak must not produce a sub-step wait.
        XCTAssertEqual(interval(0, false), 300)
    }

    // MARK: - Duplicate-account guard on Sync (audit H8)

    /// Syncing one Codex account into two profiles gives it two tiles for ONE
    /// quota, doubles its fetch load, and leaves roster order deciding who owns
    /// auth.json. The match must see a profile whose credentials are not
    /// hydrated yet — that is the window a duplicate slips through.
    func testDuplicateCodexAccountIsRefusedOnSync() {
        let target = Profile(name: "New")
        let hydrated = Profile(name: "Dex", codexAccountId: "acct-A")
        let other = Profile(name: "Cod", codexAccountId: "acct-B")
        let unhydrated = Profile(name: "Ghost", codexAccountId: "acct-C")
        let roster = [target, hydrated, other, unhydrated]
        let accountIdOf: (Profile) -> String? = { $0.codexAccountId }

        let holder = CodexUsageService.duplicateAccountHolder(
            accountId: "acct-A", target: target.id, profiles: roster, accountIdOf: accountIdOf
        )
        XCTAssertEqual(holder?.name, "Dex")

        // Pre-hydration: the persisted stamp is the only evidence there is.
        XCTAssertEqual(
            CodexUsageService.duplicateAccountHolder(
                accountId: "acct-C", target: target.id, profiles: roster, accountIdOf: accountIdOf
            )?.name,
            "Ghost"
        )

        // A re-sync of the SAME account into the SAME profile is not a duplicate.
        XCTAssertNil(CodexUsageService.duplicateAccountHolder(
            accountId: "acct-A", target: hydrated.id, profiles: roster, accountIdOf: accountIdOf
        ))
        // An account nobody holds syncs freely.
        XCTAssertNil(CodexUsageService.duplicateAccountHolder(
            accountId: "acct-Z", target: target.id, profiles: roster, accountIdOf: accountIdOf
        ))

        // The refusal names the other profile — a bare "already synced" leaves
        // the user hunting through 20 profiles for it.
        let message = CodexError.accountAlreadySynced(profileName: "Dex").errorDescription ?? ""
        XCTAssertTrue(message.contains("Dex"), message)
    }

    // MARK: - Sweep-end owner re-derivation (audit H4)

    /// `codex login` on the CLI side flips the real login while the app keeps
    /// watching the old owner. The re-derivation matches auth.json's account_id
    /// against the roster — and must match a profile whose credentials the
    /// background Keychain hydration has not filled in yet.
    func testOwnerReDerivationPicksTheAuthFileAccount() {
        let service = CodexUsageService.shared
        let hydrated = Profile(
            name: "Dex",
            codexCredentialsJSON: authJSON(accountId: "acct-A"),
            codexAccountId: "acct-A"
        )
        // Credentials not hydrated yet: only the non-secret stamp is present.
        let stampedOnly = Profile(name: "Cod", codexAccountId: "acct-B")
        let claudeOnly = Profile(name: "Memori")
        let roster = [claudeOnly, hydrated, stampedOnly]

        XCTAssertEqual(service.accountId(of: hydrated), "acct-A")
        XCTAssertEqual(service.accountId(of: stampedOnly), "acct-B",
                       "the stamp answers before Keychain hydration")
        XCTAssertNil(service.accountId(of: claudeOnly))

        XCTAssertEqual(
            CodexUsageService.profileMatchingAccount(
                "acct-B", in: roster, accountIdOf: { service.accountId(of: $0) }
            )?.name,
            "Cod"
        )
        XCTAssertEqual(
            CodexUsageService.profileMatchingAccount(
                "acct-A", in: roster, accountIdOf: { service.accountId(of: $0) }
            )?.name,
            "Dex"
        )
        // An account no profile holds leaves the pointer alone rather than
        // routing it to an arbitrary profile.
        XCTAssertNil(CodexUsageService.profileMatchingAccount(
            "acct-unknown", in: roster, accountIdOf: { service.accountId(of: $0) }
        ))
    }

    /// Minimal auth.json shape: a JWT access token carrying `exp`, plus the
    /// account id the adoption and duplicate checks key on.
    private func authJSON(accountId: String, expiresIn: TimeInterval = 10 * 24 * 3600) -> String {
        let claims = try! JSONSerialization.data(
            withJSONObject: ["exp": Date().addingTimeInterval(expiresIn).timeIntervalSince1970]
        )
        let payload = claims.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let root: [String: Any] = [
            "tokens": [
                "access_token": "header.\(payload).signature",
                "refresh_token": "rt-\(accountId)",
                "account_id": accountId
            ]
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: root), encoding: .utf8)!
    }
}
