//
//  CodexResetCreditsTests.swift
//  Claude UsageTests
//
//  Codex "usage limit resets" (rate limit reset credits). Every decision below
//  is a pure function or a decode against stubbed bytes — the suite has no
//  URLProtocol double, and two of these endpoints must never be called from a
//  test at all: the detail endpoint rate-limits per IP (five back-to-back
//  account probes produced two 200s and three 429s, 2026-09-03), and the
//  consume endpoint SPENDS a scarce, non-refundable credit.
//
//  The load-bearing invariant across the file: a count the payload did not
//  state is UNKNOWN, never zero. A zero-credit account returns
//  `"rate_limit_reset_credits": null`, so surfacing a measured "0" would be a
//  claim the wire does not support — and a 429 says nothing about the balance
//  either.
//

import XCTest
@testable import Claude_Usage

final class CodexResetCreditsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CodexResetCreditsState.shared.reset()
    }

    override func tearDown() {
        CodexResetCreditsState.shared.reset()
        super.tearDown()
    }

    private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: CodexUsageService.resetCreditsDetailEndpoint)!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private func usagePayload(resetCredits: String) -> Data {
        """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 42, "reset_at": 1800000000, "limit_window_seconds": 604800 },
            "secondary_window": null
          },
          "rate_limit_reset_credits": \(resetCredits)
        }
        """.data(using: .utf8)!
    }

    // MARK: - Count, from the usage payload the sweep already fetches

    /// `null` is what a ZERO-credit account returns (verified live on all five
    /// local Codex homes), so it must read as unknown — not as a measured zero,
    /// which would put a "0 resets" badge on every account in the fleet.
    func testUsagePayloadCountIsUnknownWhenNullAndReadWhenPresent() throws {
        let service = CodexUsageService.shared

        let nullCredits = try service.parseUsageResponse(usagePayload(resetCredits: "null"))
        XCTAssertNil(nullCredits.codexResetCreditsAvailable, "null must be UNKNOWN, never a measured 0")
        XCTAssertNil(nullCredits.codexResetCreditsMeasuredAt,
                     "no stamp without a value — a stamp on nil claims a measurement that did not happen")

        // Absent key: same answer.
        let absent = """
        {"rate_limit": {"primary_window": {"used_percent": 1, "reset_at": 1800000000}}}
        """.data(using: .utf8)!
        XCTAssertNil(try service.parseUsageResponse(absent).codexResetCreditsAvailable)

        let two = try service.parseUsageResponse(usagePayload(resetCredits: #"{"available_count": 2}"#))
        XCTAssertEqual(two.codexResetCreditsAvailable, 2)
        XCTAssertNotNil(two.codexResetCreditsMeasuredAt)
        XCTAssertEqual(two.weeklyPercentage, 42, "the reset-credit read must not disturb the usage parse")

        // A stated zero IS a measurement, unlike null.
        XCTAssertEqual(
            try service.parseUsageResponse(usagePayload(resetCredits: #"{"available_count": 0}"#))
                .codexResetCreditsAvailable,
            0
        )
        // Nonsense shapes fall back to unknown rather than to a number.
        XCTAssertNil(CodexUsageService.resetCreditCount(inUsagePayload: ["rate_limit_reset_credits": 3]))
        XCTAssertNil(CodexUsageService.resetCreditCount(
            inUsagePayload: ["rate_limit_reset_credits": ["available_count": -1]]
        ))
    }

    // MARK: - Detail payload

    /// The canonical shape from the CLI's own fixture, plus the two things the
    /// wire actually does that a naive decode breaks on: `expires_at: null`
    /// (means NEVER expires, not "unknown") and top-level keys this build has
    /// never heard of.
    func testCreditDetailDecodesNullExpiryAndToleratesUnknownKeys() throws {
        let json = """
        {
          "available_count": 3,
          "history_enabled": false,
          "immediate_reset_purchase_eligible": false,
          "total_earned_count": 7,
          "some_future_field": {"nested": [1, 2, 3]},
          "credits": [
            {
              "id": "credit-1",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-06-17T00:00:00Z",
              "expires_at": "2026-07-17T00:00:00Z",
              "redeem_started_at": null,
              "profile_user_id": "@friend",
              "title": "Full reset (Weekly + 5 hr)",
              "description": "Ready to redeem"
            },
            {
              "id": "credit-2",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-06-18T00:00:00.500Z",
              "expires_at": null,
              "title": null,
              "description": null
            },
            {
              "id": "credit-3",
              "reset_type": "codex_rate_limits",
              "status": "redeemed",
              "granted_at": "2026-05-01T00:00:00Z",
              "expires_at": "2026-06-01T00:00:00Z"
            }
          ]
        }
        """.data(using: .utf8)!

        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let credits = try CodexResetCredits.decode(json, fetchedAt: stamp)

        XCTAssertEqual(credits.availableCount, 3)
        XCTAssertEqual(credits.totalEarnedCount, 7)
        XCTAssertEqual(credits.immediateResetPurchaseEligible, false)
        XCTAssertEqual(credits.fetchedAt, stamp)
        XCTAssertEqual(credits.credits.count, 3)

        let first = credits.credits[0]
        XCTAssertEqual(first.title, "Full reset (Weekly + 5 hr)")
        XCTAssertEqual(first.expiresAt, ISO8601DateFormatter().date(from: "2026-07-17T00:00:00Z"))
        XCTAssertTrue(first.isAvailable)

        XCTAssertNil(credits.credits[1].expiresAt, "null expires_at means never expires")
        XCTAssertNotNil(credits.credits[1].grantedAt, "fractional seconds must still parse")
        XCTAssertFalse(credits.credits[2].isAvailable, "a redeemed credit is not offerable")

        // Available only, soonest expiry first, never-expiring last.
        XCTAssertEqual(credits.availableCreditsByExpiry.map(\.id), ["credit-1", "credit-2"])

        // The count is authoritative even when the backend caps the list.
        let capped = try CodexResetCredits.decode(
            #"{"available_count": 9, "credits": []}"#.data(using: .utf8)!
        )
        XCTAssertEqual(capped.availableCount, 9)
        XCTAssertTrue(capped.credits.isEmpty)
    }

    // MARK: - Cache + per-IP spacing

    /// The detail endpoint is the one that 429s across accounts, so the cache
    /// and the process-wide gap are load-bearing, and `force` has to be able to
    /// defeat the cache when the user explicitly asks for fresh data.
    func testDetailCacheIsHonoredUntilTTLAndBypassedByForce() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(CodexUsageService.resetCreditsCacheIsFresh(
            fetchedAt: fetched, now: fetched.addingTimeInterval(599)
        ))
        XCTAssertFalse(CodexUsageService.resetCreditsCacheIsFresh(
            fetchedAt: fetched, now: fetched.addingTimeInterval(601)
        ), "past the TTL the cache is stale")
        XCTAssertFalse(CodexUsageService.resetCreditsCacheIsFresh(
            fetchedAt: fetched, now: fetched.addingTimeInterval(10), force: true
        ), "force must defeat a still-fresh cache")
        XCTAssertFalse(CodexUsageService.resetCreditsCacheIsFresh(
            fetchedAt: fetched, now: fetched.addingTimeInterval(-30)
        ), "a stamp in the future is not evidence of freshness")

        // Spacing is process-wide: the limit is per IP, so a different profile
        // still has to wait.
        XCTAssertEqual(CodexUsageService.resetCreditsSpacingDelay(lastFetchAt: nil, now: fetched), 0)
        XCTAssertEqual(
            CodexUsageService.resetCreditsSpacingDelay(
                lastFetchAt: fetched, now: fetched.addingTimeInterval(1)
            ),
            4,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CodexUsageService.resetCreditsSpacingDelay(
                lastFetchAt: fetched, now: fetched.addingTimeInterval(9)
            ),
            0
        )
    }

    /// A refused read is not a zero balance. The typed error is what keeps the
    /// UI saying "unknown" instead of hiding an account's remaining resets.
    func testThrottledDetailFetchIsUnavailableNotZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let throttled = CodexUsageService.resetCreditsError(
            for: response(429, headers: ["Retry-After": "120"]), now: now
        )
        XCTAssertEqual(throttled, .resetCreditsUnavailable(retryAfter: 120))

        // No usable header still means unavailable, not zero.
        XCTAssertEqual(
            CodexUsageService.resetCreditsError(for: response(429), now: now),
            .resetCreditsUnavailable(retryAfter: nil)
        )
        // Everything else keeps its status so the caller can tell them apart.
        XCTAssertEqual(CodexUsageService.resetCreditsError(for: response(503), now: now),
                       .requestFailed(status: 503))

        let description = CodexResetCreditsError.resetCreditsUnavailable(retryAfter: 120)
            .errorDescription ?? ""
        XCTAssertTrue(description.contains("unknown, not zero"), description)
    }

    // MARK: - Activation gate

    /// The consume call spends a scarce, non-refundable credit, so it is
    /// refused on anything short of a fresh MEASUREMENT that the account is at
    /// its limit — a projection or a suspicion is not enough.
    func testActivationRefusesWithoutFreshAtLimitEvidence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let notAtLimit = CodexResetActivationEvidence(
            measuredAtLimit: false, measuredAt: now, source: "wham/usage"
        )
        XCTAssertEqual(
            CodexUsageService.activationRefusal(notAtLimit, now: now),
            .notMeasuredAtLimit(source: "wham/usage")
        )

        let stale = CodexResetActivationEvidence(
            measuredAtLimit: true, measuredAt: now.addingTimeInterval(-301), source: "wham/usage"
        )
        guard case .staleEvidence = CodexUsageService.activationRefusal(stale, now: now) else {
            return XCTFail("a measurement older than 5 minutes must not justify spending a credit")
        }

        // A stamp far in the future would otherwise never age out of the window.
        let skewed = CodexResetActivationEvidence(
            measuredAtLimit: true, measuredAt: now.addingTimeInterval(120), source: "wham/usage"
        )
        guard case .staleEvidence = CodexUsageService.activationRefusal(skewed, now: now) else {
            return XCTFail("future-stamped evidence must be refused, not trusted forever")
        }

        let fresh = CodexResetActivationEvidence(
            measuredAtLimit: true, measuredAt: now.addingTimeInterval(-60), source: "wham/usage"
        )
        XCTAssertNil(CodexUsageService.activationRefusal(fresh, now: now))
    }

    /// Idempotency: a retry inside the same reset window must re-send the SAME
    /// `redeem_request_id`, or the second attempt spends a second credit. The
    /// window key is quantized to the minute because the API reports the same
    /// boundary with ±1s jitter — an unquantized key mints a new id per sweep
    /// and defeats the whole mechanism.
    func testRedeemRequestIdIsStableWithinAWindowAndFreshAcrossWindows() {
        let service = CodexUsageService.shared
        let profile = UUID()
        let other = UUID()

        let session = Date(timeIntervalSince1970: 1_800_000_000)
        let weekly = Date(timeIntervalSince1970: 1_800_600_000)
        let key = CodexUsageService.resetWindowKey(sessionReset: session, weeklyReset: weekly)
        let jittered = CodexUsageService.resetWindowKey(
            sessionReset: session.addingTimeInterval(1), weeklyReset: weekly.addingTimeInterval(-1)
        )
        XCTAssertEqual(key, jittered, "±1s of boundary jitter is the same window")

        let first = service.redeemRequestId(for: profile, windowKey: key)
        XCTAssertEqual(service.redeemRequestId(for: profile, windowKey: key), first,
                       "a retry in the same window must reuse the id")
        XCTAssertNotNil(UUID(uuidString: first), "the id is a UUID, as the endpoint expects")

        let nextWindow = CodexUsageService.resetWindowKey(
            sessionReset: session.addingTimeInterval(3600), weeklyReset: weekly
        )
        XCTAssertNotEqual(service.redeemRequestId(for: profile, windowKey: nextWindow), first)
        XCTAssertNotEqual(service.redeemRequestId(for: other, windowKey: key), first,
                          "ids are per profile as well as per window")

        // An account with no cached usage still produces a stable key.
        XCTAssertEqual(CodexUsageService.resetWindowKey(for: nil), "s-/w-")
    }

    // MARK: - Consume response + request shape

    /// All four documented codes mean different things to the user — most
    /// importantly `nothing_to_reset`, where the credit was NOT spent and
    /// retrying later is the right advice.
    func testConsumeCodeMappingCoversAllFourOutcomes() {
        func outcome(_ body: String) -> CodexResetActivationOutcome {
            CodexUsageService.activationOutcome(fromConsumePayload: body.data(using: .utf8)!)
        }

        XCTAssertEqual(
            outcome(#"{"code": "reset", "credit": {"id": "credit-1"}, "windows_reset": 2}"#),
            .reset(windowsReset: 2)
        )
        XCTAssertEqual(outcome(#"{"code": "nothing_to_reset"}"#), .nothingToReset)
        XCTAssertEqual(outcome(#"{"code": "no_credit"}"#), .noCredit)
        XCTAssertEqual(outcome(#"{"code": "already_redeemed"}"#), .alreadyRedeemed)
        XCTAssertEqual(outcome(#"{"code": "reset_queued"}"#), .unknown(code: "reset_queued"))

        // An unreadable body is never optimistically reported as a reset.
        XCTAssertEqual(outcome("not json at all"), .unknown(code: "unreadable"))

        // A list, if the backend ever sends one, is counted rather than refused.
        XCTAssertEqual(
            outcome(#"{"code": "reset", "windows_reset": ["primary", "secondary"]}"#),
            .reset(windowsReset: 2)
        )
        // A reset with no count is still a reset — 0 reads as "count unknown",
        // never as a claim about a number the payload did not carry.
        XCTAssertEqual(outcome(#"{"code": "reset"}"#), .reset(windowsReset: 0))
        XCTAssertEqual(outcome(#"{"code": "reset"}"#).logLabel, "reset (0 window(s))")
    }

    /// `x-openai-codex-luna-reserve` opts a client into Luna Reserve and lets
    /// the backend record experiment exposure. This app is a passive reader and
    /// must never send it — on either endpoint.
    func testConsumeRequestCarriesAuthButNeverTheLunaHeader() {
        let request = CodexUsageService.resetCreditsRequest(
            url: URL(string: CodexUsageService.resetCreditsConsumeEndpoint)!,
            accessToken: "access-token-value",
            accountId: "acct-A",
            method: "POST",
            body: try! JSONSerialization.data(withJSONObject: CodexUsageService.consumeRequestBody(
                redeemRequestId: "11111111-2222-3333-4444-555555555555", creditId: nil
            )),
            timeout: 10
        )

        let headers = request.allHTTPHeaderFields ?? [:]
        XCTAssertTrue(
            headers.keys.allSatisfy { !$0.lowercased().contains("luna") },
            "no Luna Reserve opt-in may ride on a passive read: \(headers.keys.sorted())"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(headers["Authorization"], "Bearer access-token-value")
        XCTAssertEqual(headers["ChatGPT-Account-Id"], "acct-A")
        XCTAssertEqual(headers["Content-Type"], "application/json")
        XCTAssertEqual(request.url?.absoluteString,
                       "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")

        // credit_id is OMITTED when nil (the CLI's skip_serializing_if), never
        // sent as null — an absent key is what tells the backend to pick.
        let sentBody = try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(sentBody["redeem_request_id"] as? String, "11111111-2222-3333-4444-555555555555")
        XCTAssertNil(sentBody["credit_id"])
        XCTAssertEqual(
            CodexUsageService.consumeRequestBody(redeemRequestId: "req", creditId: "credit-1")["credit_id"],
            "credit-1"
        )

        // The detail read is a GET with no body and no Content-Type.
        let detail = CodexUsageService.resetCreditsRequest(
            url: URL(string: CodexUsageService.resetCreditsDetailEndpoint)!,
            accessToken: "access-token-value",
            accountId: "acct-A",
            method: "GET",
            body: nil,
            timeout: 5
        )
        XCTAssertEqual(detail.httpMethod, "GET")
        XCTAssertNil(detail.httpBody)
        XCTAssertTrue((detail.allHTTPHeaderFields ?? [:]).keys.allSatisfy { !$0.lowercased().contains("luna") })
    }

    // MARK: - ChatGPT-auth precondition

    /// Reset credits exist only for ChatGPT-auth accounts — the CLI's own
    /// client answers "api key auth is not supported" — so an API-key login is
    /// refused locally rather than spending a request that cannot succeed.
    func testAPIKeyOnlyLoginIsRecognizedAndChatGPTLoginIsNot() {
        XCTAssertTrue(CodexUsageService.usesAPIKeyAuth(
            credentialsJSON: #"{"OPENAI_API_KEY": "sk-placeholder", "tokens": null}"#
        ))
        XCTAssertFalse(CodexUsageService.usesAPIKeyAuth(
            credentialsJSON: #"{"OPENAI_API_KEY": null, "tokens": {"access_token": "h.p.s", "account_id": "acct-A"}}"#
        ))
        // A ChatGPT login WINS when both are present: the feature works there,
        // and refusing on the mere presence of a key would disable it wrongly.
        XCTAssertFalse(CodexUsageService.usesAPIKeyAuth(
            credentialsJSON: #"{"OPENAI_API_KEY": "sk-placeholder", "tokens": {"access_token": "h.p.s"}}"#
        ))
        // Neither, or unreadable, is not an API-key verdict — the existing
        // no-credentials error covers that case and says something truer.
        XCTAssertFalse(CodexUsageService.usesAPIKeyAuth(credentialsJSON: #"{"tokens": {}}"#))
        XCTAssertFalse(CodexUsageService.usesAPIKeyAuth(credentialsJSON: "not json"))

        let message = CodexResetCreditsError.unsupportedForAPIKeyAuth.errorDescription ?? ""
        XCTAssertTrue(message.contains("ChatGPT login"), message)
    }
}
