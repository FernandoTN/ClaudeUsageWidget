import XCTest
@testable import Claude_Usage

final class ClaudeUsageTests: XCTestCase {

    // MARK: - Status Level Tests (Deprecated Property - uses remaining-based thresholds)

    func testStatusLevelSafe() {
        // statusLevel uses remaining-based thresholds: safe when remaining >= 20%
        let usage = createUsage(sessionPercentage: 0)  // 100% remaining
        XCTAssertEqual(usage.statusLevel, .safe)

        let usage25 = createUsage(sessionPercentage: 25)  // 75% remaining
        XCTAssertEqual(usage25.statusLevel, .safe)

        let usage80 = createUsage(sessionPercentage: 80)  // 20% remaining (exact boundary)
        XCTAssertEqual(usage80.statusLevel, .safe)
    }

    func testStatusLevelModerate() {
        // statusLevel uses remaining-based thresholds: moderate when 10% <= remaining < 20%
        let usage81 = createUsage(sessionPercentage: 81)  // 19% remaining
        XCTAssertEqual(usage81.statusLevel, .moderate)

        let usage85 = createUsage(sessionPercentage: 85)  // 15% remaining
        XCTAssertEqual(usage85.statusLevel, .moderate)

        let usage90 = createUsage(sessionPercentage: 90)  // 10% remaining (exact boundary)
        XCTAssertEqual(usage90.statusLevel, .moderate)
    }

    func testStatusLevelCritical() {
        // statusLevel uses remaining-based thresholds: critical when remaining < 10%
        let usage91 = createUsage(sessionPercentage: 91)  // 9% remaining
        XCTAssertEqual(usage91.statusLevel, .critical)

        let usage95 = createUsage(sessionPercentage: 95)  // 5% remaining
        XCTAssertEqual(usage95.statusLevel, .critical)

        let usage100 = createUsage(sessionPercentage: 100)  // 0% remaining
        XCTAssertEqual(usage100.statusLevel, .critical)
    }

    // MARK: - Empty Usage Tests

    func testEmptyUsage() {
        let empty = ClaudeUsage.empty

        XCTAssertEqual(empty.sessionTokensUsed, 0)
        XCTAssertEqual(empty.sessionPercentage, 0)
        XCTAssertEqual(empty.weeklyTokensUsed, 0)
        XCTAssertEqual(empty.weeklyPercentage, 0)
        XCTAssertEqual(empty.statusLevel, .safe)
        XCTAssertNil(empty.costUsed)
        XCTAssertNil(empty.costLimit)
    }

    // MARK: - Codable Tests

    func testEncodeDecode() throws {
        let original = createUsage(sessionPercentage: 45.5)

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ClaudeUsage.self, from: data)

        XCTAssertEqual(original, decoded)
    }

    // MARK: - Account-Level Throttle (rateLimitedUntil)

    func testActiveThrottleReportsFullSessionRegardlessOfCachedPercentage() {
        // The incident shape: cache frozen at 16% while the account is actually
        // exhausted and its usage endpoint 429s. The stamp must win everywhere
        // effectiveSessionPercentage is read.
        var usage = createUsage(sessionPercentage: 16)
        usage.rateLimitedUntil = Date().addingTimeInterval(2918)
        XCTAssertEqual(usage.effectiveSessionPercentage, 100)
        XCTAssertEqual(usage.remainingPercentage, 0)
    }

    func testActiveThrottleWinsOverRolledOverSessionWindow() {
        // Even if the cached session window has expired (normally 0%), a live
        // throttle means the account still cannot be used.
        var usage = createUsage(sessionPercentage: 16)
        usage.sessionResetTime = Date().addingTimeInterval(-60)
        usage.rateLimitedUntil = Date().addingTimeInterval(600)
        XCTAssertEqual(usage.effectiveSessionPercentage, 100)
    }

    func testExpiredThrottleStampRestoresNormalSemantics() {
        var usage = createUsage(sessionPercentage: 16)
        usage.rateLimitedUntil = Date().addingTimeInterval(-1)
        XCTAssertEqual(usage.effectiveSessionPercentage, 16)
    }

    func testDecodingLegacyJSONWithoutThrottleField() throws {
        // Cached usage persisted before the field existed must decode with a
        // nil stamp (same back-compat contract as the Fable fields).
        var legacy = createUsage(sessionPercentage: 45.5)
        legacy.rateLimitedUntil = nil
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("rateLimitedUntil"))
        let decoded = try JSONDecoder().decode(ClaudeUsage.self, from: data)
        XCTAssertNil(decoded.rateLimitedUntil)
    }

    // MARK: - Monotonic Windows (reconciledWithPrevious)

    // The live incident, 2026-09-04 13:06 PDT: 'dJormun' measured at
    // 56 / 70 / 89 (session / weekly / Fable) at 13:04–13:05, then oauth/usage
    // answered HTTP 200 parsing to 0 / 0 / 0 with every boundary still hours
    // away. The zeros were saved and became what the auto-switch read.
    func testHoldsEveryWindowThatDroppedBeforeItsBoundary() {
        let now = Date()
        let previous = monotonicUsage(session: 56, weekly: 70, fable: 89, opus: 40, sonnet: 12, now: now)
        let fresh = monotonicUsage(session: 0, weekly: 0, fable: 0, opus: 0, sonnet: 0, now: now)

        let (reconciled, suspectedLow) = fresh.reconciledWithPrevious(previous, now: now)

        XCTAssertEqual(suspectedLow, ["session", "weekly", "fable", "opus", "sonnet"])
        XCTAssertEqual(reconciled.sessionPercentage, 56)
        XCTAssertEqual(reconciled.weeklyPercentage, 70)
        XCTAssertEqual(reconciled.fableWeeklyPercentage, 89)
        XCTAssertEqual(reconciled.opusWeeklyPercentage, 40)
        XCTAssertEqual(reconciled.sonnetWeeklyPercentage, 12)
        XCTAssertEqual(reconciled.heldWindowNames, suspectedLow)
        // The held windows keep the boundary they were measured against, and
        // the reading's own timestamp is untouched.
        XCTAssertEqual(reconciled.sessionResetTime, previous.sessionResetTime)
        XCTAssertEqual(reconciled.lastUpdated, fresh.lastUpdated)
    }

    func testAcceptsDropOnceTheBoundaryHasPassed() {
        let now = Date()
        var previous = monotonicUsage(session: 56, weekly: 70, now: now)
        previous.sessionResetTime = now.addingTimeInterval(-60)
        var fresh = monotonicUsage(session: 0, weekly: 70, now: now)
        fresh.sessionResetTime = now.addingTimeInterval(5 * 3600)

        let (reconciled, suspectedLow) = fresh.reconciledWithPrevious(previous, now: now)

        XCTAssertTrue(suspectedLow.isEmpty)
        XCTAssertEqual(reconciled.sessionPercentage, 0)
        XCTAssertEqual(reconciled.sessionResetTime, fresh.sessionResetTime)
        XCTAssertNil(reconciled.heldWindows)
    }

    func testAcceptsDropWhenThePreviousResetStampIsUnknown() {
        // A sentinel stamp means the window's boundary was never reported, so
        // there is no evidence the window is still open — never hold on it.
        let now = Date()
        var previous = monotonicUsage(session: 56, weekly: 70, now: now)
        previous.sessionResetTime = ClaudeUsage.unknownResetSentinel
        let fresh = monotonicUsage(session: 0, weekly: 70, now: now)

        let (reconciled, suspectedLow) = fresh.reconciledWithPrevious(previous, now: now)

        XCTAssertTrue(suspectedLow.isEmpty)
        XCTAssertEqual(reconciled.sessionPercentage, 0)
    }

    func testAcceptsDropWhenThePreviousValueWasNotServerAffirmed() {
        // A CLI-cache value was never read with this account's credentials, so
        // it is not fit to override a fresh measurement.
        let now = Date()
        var previous = monotonicUsage(session: 56, weekly: 70, now: now)
        previous.provenance = .cliCache
        let fresh = monotonicUsage(session: 0, weekly: 0, now: now)

        let (reconciled, suspectedLow) = fresh.reconciledWithPrevious(previous, now: now)

        XCTAssertTrue(suspectedLow.isEmpty)
        XCTAssertEqual(reconciled.sessionPercentage, 0)
        XCTAssertEqual(reconciled.weeklyPercentage, 0)
    }

    func testAcceptsASmallDropWithinTolerance() {
        // 56 -> 53 is rounding/derivation noise, not a payload that lost the
        // account; 56 -> 50 is past the 5-point tolerance and is held.
        let now = Date()
        let previous = monotonicUsage(session: 56, weekly: 70, now: now)

        let (near, nearLow) = monotonicUsage(session: 53, weekly: 70, now: now)
            .reconciledWithPrevious(previous, now: now)
        XCTAssertTrue(nearLow.isEmpty)
        XCTAssertEqual(near.sessionPercentage, 53)

        let (far, farLow) = monotonicUsage(session: 50, weekly: 70, now: now)
            .reconciledWithPrevious(previous, now: now)
        XCTAssertEqual(farLow, ["session"])
        XCTAssertEqual(far.sessionPercentage, 56)
    }

    func testWindowsAreDecidedIndependentlyAndIncreasesAlwaysWin() {
        let now = Date()
        let previous = monotonicUsage(session: 56, weekly: 70, fable: 89, now: now)
        let fresh = monotonicUsage(session: 0, weekly: 75, fable: 91, now: now)

        let (reconciled, suspectedLow) = fresh.reconciledWithPrevious(previous, now: now)

        XCTAssertEqual(suspectedLow, ["session"])
        XCTAssertEqual(reconciled.sessionPercentage, 56)
        XCTAssertEqual(reconciled.weeklyPercentage, 75)
        XCTAssertEqual(reconciled.fableWeeklyPercentage, 91)
    }

    func testHeldWindowsSurviveACodableRoundTripAndLegacyRowsStillDecode() throws {
        let now = Date()
        let previous = monotonicUsage(session: 56, weekly: 70, now: now)
        let (held, _) = monotonicUsage(session: 0, weekly: 0, now: now)
            .reconciledWithPrevious(previous, now: now)
        let roundTripped = try JSONDecoder().decode(ClaudeUsage.self, from: JSONEncoder().encode(held))
        XCTAssertEqual(roundTripped.heldWindows, ["session", "weekly"])
        XCTAssertEqual(roundTripped, held)

        // A row persisted before the field existed carries no key at all.
        let legacy = monotonicUsage(session: 56, weekly: 70, now: now)
        let data = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(data: data, encoding: .utf8)!.contains("heldWindows"))
        XCTAssertNil(try JSONDecoder().decode(ClaudeUsage.self, from: data).heldWindows)
    }

    func testPercentagesRenderTheHeldLogLinesTwoHalves() {
        // The exact substrings the held-reading log line and incident carry:
        // "own endpoint said 0/0/0, holding 56/70/89".
        let now = Date()
        let previous = monotonicUsage(session: 56, weekly: 70, fable: 89, now: now)
        let fresh = monotonicUsage(session: 0, weekly: 0, fable: 0, now: now)
        let windows = fresh.reconciledWithPrevious(previous, now: now).suspectedLow

        XCTAssertEqual(fresh.percentages(for: windows), "0/0/0")
        XCTAssertEqual(previous.percentages(for: windows), "56/70/89")
        // A window this value does not report at all is not invented.
        XCTAssertEqual(monotonicUsage(session: 1, weekly: 1, now: now).percentages(for: ["fable"]), "-")
    }

    // MARK: - Helpers

    private func createUsage(sessionPercentage: Double) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: Int(sessionPercentage * 1000),
            sessionLimit: 100000,
            sessionPercentage: sessionPercentage,
            sessionResetTime: Date().addingTimeInterval(3600),
            weeklyTokensUsed: 500000,
            weeklyLimit: 1000000,
            weeklyPercentage: 50,
            weeklyResetTime: Date().addingTimeInterval(86400),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: Date(),
            userTimezone: .current
        )
    }
    /// A Claude reading with every window open well past `now` — the shape the
    /// monotonic guard reasons about.
    private func monotonicUsage(
        session: Double,
        weekly: Double,
        fable: Double? = nil,
        opus: Double = 0,
        sonnet: Double = 0,
        now: Date = Date()
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: session,
            sessionResetTime: now.addingTimeInterval(3 * 3600),
            weeklyTokensUsed: Int(weekly * 10_000),
            weeklyLimit: 1_000_000,
            weeklyPercentage: weekly,
            weeklyResetTime: now.addingTimeInterval(3 * 86_400),
            opusWeeklyTokensUsed: Int(opus * 10_000),
            opusWeeklyPercentage: opus,
            sonnetWeeklyTokensUsed: Int(sonnet * 10_000),
            sonnetWeeklyPercentage: sonnet,
            sonnetWeeklyResetTime: now.addingTimeInterval(3 * 86_400),
            fableWeeklyPercentage: fable,
            fableWeeklyResetTime: fable == nil ? nil : now.addingTimeInterval(4 * 86_400),
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: now,
            userTimezone: .current
        )
    }
}
