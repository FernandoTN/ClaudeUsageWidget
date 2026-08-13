//
//  BackgroundFetchSchedulingTests.swift
//  Claude UsageTests
//
//  Tests for MenuBarManager.selectBackgroundFetchIds / isNearLimit — the sweep
//  scheduler that decides which background Claude profiles get the per-sweep
//  oauth/usage budget. It replaced a blind round-robin cursor under which a
//  dead login burned a rotation slot every cycle and an account cached at 70%
//  session waited behind idle accounts ('Memori' sat 33 min stale while its
//  real session usage hit 100% — 2026-08-11 incident). The scheduler must:
//  spend the budget only on fetchable profiles, sample near-limit accounts
//  more often, and never starve anyone.
//

import XCTest
@testable import Claude_Usage

final class BackgroundFetchSchedulingTests: XCTestCase {

    // Anchored to the real clock: ClaudeUsage.effectiveSessionPercentage compares
    // sessionResetTime against Date() internally, not against an injected now.
    private let now = Date()

    private func usage(
        session: Double = 0,
        sessionResetIn: TimeInterval = 3600,
        weekly: Double = 0,
        fable: Double? = nil,
        rateLimitedUntil: Date? = nil,
        rateLimitedInferred: Bool? = nil
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: Int(session * 1000),
            sessionLimit: 100_000,
            sessionPercentage: session,
            sessionResetTime: now.addingTimeInterval(sessionResetIn),
            rateLimitedUntil: rateLimitedUntil,
            rateLimitedInferred: rateLimitedInferred,
            weeklyTokensUsed: Int(weekly * 10_000),
            weeklyLimit: 1_000_000,
            weeklyPercentage: weekly,
            weeklyResetTime: now.addingTimeInterval(86_400),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            fableWeeklyPercentage: fable,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            overageBalance: nil,
            overageBalanceCurrency: nil,
            lastUpdated: now,
            userTimezone: .current
        )
    }

    private func candidate(
        _ id: UUID = UUID(),
        attemptedAgo: TimeInterval?,
        hot: Bool = false,
        eligible: Bool = true
    ) -> MenuBarManager.BackgroundFetchCandidate {
        MenuBarManager.BackgroundFetchCandidate(
            id: id,
            lastAttempt: attemptedAgo.map { now.addingTimeInterval(-$0) },
            isHot: hot,
            isEligible: eligible
        )
    }

    // MARK: - Selection

    func testPicksStalestEligibleCandidate() {
        let stale = UUID(), fresh = UUID()
        let picked = MenuBarManager.selectBackgroundFetchIds(
            candidates: [
                candidate(fresh, attemptedAgo: 30),
                candidate(stale, attemptedAgo: 300),
            ],
            budget: 1, now: now
        )
        XCTAssertEqual(picked, [stale])
    }

    func testIneligibleCandidateNeverPickedEvenWhenStalest() {
        // The old cursor's core defect: a dead login was the stalest profile
        // every cycle and consumed the slot every cycle.
        let dead = UUID(), live = UUID()
        let picked = MenuBarManager.selectBackgroundFetchIds(
            candidates: [
                candidate(dead, attemptedAgo: 100_000, eligible: false),
                candidate(live, attemptedAgo: 60),
            ],
            budget: 1, now: now
        )
        XCTAssertEqual(picked, [live])
    }

    func testNeverAttemptedCandidateWinsFirst() {
        let neverFetched = UUID(), old = UUID()
        let picked = MenuBarManager.selectBackgroundFetchIds(
            candidates: [
                candidate(old, attemptedAgo: 100_000, hot: true),
                candidate(neverFetched, attemptedAgo: nil),
            ],
            budget: 1, now: now
        )
        XCTAssertEqual(picked, [neverFetched])
    }

    func testHotCandidateOutranksColderButStalerOne() {
        // Hot weight 3: a hot account attempted 2 min ago must beat a cold one
        // attempted 5 min ago (360 effective vs 300), but not one attempted
        // 7 min ago (360 vs 420) — hotness accelerates sampling, it does not
        // monopolize the budget.
        let hot = UUID(), cold5 = UUID(), cold7 = UUID()
        XCTAssertEqual(
            MenuBarManager.selectBackgroundFetchIds(
                candidates: [candidate(cold5, attemptedAgo: 300), candidate(hot, attemptedAgo: 120, hot: true)],
                budget: 1, now: now
            ),
            [hot]
        )
        XCTAssertEqual(
            MenuBarManager.selectBackgroundFetchIds(
                candidates: [candidate(cold7, attemptedAgo: 420), candidate(hot, attemptedAgo: 120, hot: true)],
                budget: 1, now: now
            ),
            [cold7]
        )
    }

    func testBudgetBoundsSelectionCount() {
        let candidates = (0..<5).map { candidate(attemptedAgo: Double($0 + 1) * 60) }
        XCTAssertEqual(
            MenuBarManager.selectBackgroundFetchIds(candidates: candidates, budget: 2, now: now).count, 2
        )
        XCTAssertTrue(
            MenuBarManager.selectBackgroundFetchIds(candidates: candidates, budget: 0, now: now).isEmpty
        )
        XCTAssertEqual(
            MenuBarManager.selectBackgroundFetchIds(candidates: candidates, budget: 10, now: now).count, 5
        )
    }

    func testAllIneligibleYieldsEmptySelection() {
        let candidates = [
            candidate(attemptedAgo: 600, eligible: false),
            candidate(attemptedAgo: nil, eligible: false),
        ]
        XCTAssertTrue(
            MenuBarManager.selectBackgroundFetchIds(candidates: candidates, budget: 2, now: now).isEmpty
        )
    }

    func testUnpickedCandidateEventuallyBeatsHotOnes_noStarvation() {
        // Steady state: the hot account is re-attempted each sweep (fresh
        // stamp), the cold one is not. Its age keeps growing, so within a
        // bounded number of sweeps it must win a slot: with hot weight 3 and a
        // hot account re-stamped 30s ago each sweep (effective score 90), the
        // cold account's age crosses 90 strictly on sweep 4 (30→60→90 tie→120).
        let hot = UUID(), cold = UUID()
        var coldAge: TimeInterval = 30
        var sweepsUntilColdWins = 0
        for _ in 0..<20 {
            sweepsUntilColdWins += 1
            let picked = MenuBarManager.selectBackgroundFetchIds(
                candidates: [
                    candidate(hot, attemptedAgo: 30, hot: true),   // just sampled, stays hot
                    candidate(cold, attemptedAgo: coldAge),
                ],
                budget: 1, now: now
            )
            if picked == [cold] { break }
            coldAge += 30
        }
        XCTAssertLessThanOrEqual(sweepsUntilColdWins, 4, "cold account starved behind a hot one")
    }

    // MARK: - Inferred account throttle (429 with useless Retry-After)

    func testInferredThrottleNeedsStreakAndFreshOtherAccountSuccess() {
        let victim = UUID(), other = UUID()

        // Happy path: streak at the floor + a different account succeeded
        // seconds ago (the IP is provably fine) → account-level refusal.
        XCTAssertTrue(MenuBarManager.shouldInferAccountThrottle(
            streak: MenuBarManager.inferredThrottleMinStreak,
            profileId: victim,
            isActiveAccount: false,
            cachedUsage: nil,
            lastClaudeSuccess: (other, now.addingTimeInterval(-10)),
            now: now
        ))

        // One 429 alone is burst noise — never infer off a single sample.
        XCTAssertFalse(MenuBarManager.shouldInferAccountThrottle(
            streak: MenuBarManager.inferredThrottleMinStreak - 1,
            profileId: victim,
            isActiveAccount: false,
            cachedUsage: nil,
            lastClaudeSuccess: (other, now.addingTimeInterval(-10)),
            now: now
        ))

        // No success evidence at all (e.g. total per-IP throttle storm hits
        // every profile): stay with the plain backoff.
        XCTAssertFalse(MenuBarManager.shouldInferAccountThrottle(
            streak: 5, profileId: victim, isActiveAccount: false, cachedUsage: nil,
            lastClaudeSuccess: nil, now: now
        ))

        // The only recent success is the SAME profile — proves nothing about
        // the current refusal.
        XCTAssertFalse(MenuBarManager.shouldInferAccountThrottle(
            streak: 5,
            profileId: victim,
            isActiveAccount: false,
            cachedUsage: nil,
            lastClaudeSuccess: (victim, now.addingTimeInterval(-10)),
            now: now
        ))

        // Stale control evidence — the IP's health at 429 time is unknown.
        XCTAssertFalse(MenuBarManager.shouldInferAccountThrottle(
            streak: 5,
            profileId: victim,
            isActiveAccount: false,
            cachedUsage: nil,
            lastClaudeSuccess: (other, now.addingTimeInterval(-MenuBarManager.inferredThrottleControlWindow - 1)),
            now: now
        ))
    }

    // MARK: - Inference precision gates (consult round, 2026-08-12)

    func testActiveAccountNeedsLongerStreak() {
        let victim = UUID(), other = UUID()
        let success: (UUID, Date) = (other, now.addingTimeInterval(-10))
        // Streak 2 suffices for a background profile but NOT the active one —
        // it fetches every sweep and collides with the per-IP cap first.
        XCTAssertTrue(MenuBarManager.shouldInferAccountThrottle(
            streak: 2, profileId: victim, isActiveAccount: false, cachedUsage: nil,
            lastClaudeSuccess: success, now: now
        ))
        XCTAssertFalse(MenuBarManager.shouldInferAccountThrottle(
            streak: 2, profileId: victim, isActiveAccount: true, cachedUsage: nil,
            lastClaudeSuccess: success, now: now
        ))
        XCTAssertTrue(MenuBarManager.shouldInferAccountThrottle(
            streak: 3, profileId: victim, isActiveAccount: true, cachedUsage: nil,
            lastClaudeSuccess: success, now: now
        ))
    }

    func testFreshLowCacheBlocksInference() {
        // A 5h window does not jump 45pp in one backoff interval: a FRESH
        // cache far below every limit means the 429s are IP noise ('BBR'
        // false positive — cached 8-55%, stamped exhausted, fleet switched).
        let victim = UUID(), other = UUID()
        let success: (UUID, Date) = (other, now.addingTimeInterval(-10))
        XCTAssertFalse(MenuBarManager.shouldInferAccountThrottle(
            streak: 5, profileId: victim, isActiveAccount: false,
            cachedUsage: usage(session: 55),
            lastClaudeSuccess: success, now: now
        ))
        // Fresh cache already near the limit — exhaustion plausible.
        XCTAssertTrue(MenuBarManager.shouldInferAccountThrottle(
            streak: 5, profileId: victim, isActiveAccount: false,
            cachedUsage: usage(session: MenuBarManager.inferredThrottleFreshCacheFloor),
            lastClaudeSuccess: success, now: now
        ))
        // Weekly near its cap counts too (weekly exhaustion also 429s).
        XCTAssertTrue(MenuBarManager.shouldInferAccountThrottle(
            streak: 5, profileId: victim, isActiveAccount: false,
            cachedUsage: usage(session: 10, weekly: 95),
            lastClaudeSuccess: success, now: now
        ))
    }

    func testStaleCacheDoesNotBlockInference() {
        // The frozen-74% case: data minutes-to-hours old proves nothing about
        // the account's current state and must not veto the suspicion.
        let victim = UUID(), other = UUID()
        var stale = usage(session: 40)
        stale.lastUpdated = now.addingTimeInterval(-MenuBarManager.inferredThrottleStaleCacheAge - 60)
        XCTAssertTrue(MenuBarManager.shouldInferAccountThrottle(
            streak: 2, profileId: victim, isActiveAccount: false,
            cachedUsage: stale,
            lastClaudeSuccess: (other, now.addingTimeInterval(-10)), now: now
        ))
    }

    // MARK: - Suspected display seam

    func testSuspectedStampDisplaysMeasuredValueNotSyntheticHundred() {
        let stamped = usage(
            session: 59, rateLimitedUntil: now.addingTimeInterval(300), rateLimitedInferred: true
        )
        // Decision seams still read exhaustion (candidate gating, scheduler heat)…
        XCTAssertEqual(stamped.effectiveSessionPercentage, 100)
        XCTAssertTrue(stamped.isSuspectedRateLimited)
        // …but the DISPLAY shows the last measured number ("100% then reverts
        // to 59%" flapping was the owner-reported bug — the tile must never
        // paint an unverified 100).
        XCTAssertEqual(stamped.displaySessionPercentage, 59)

        // Server-affirmed stamps display 100 — the server said the account is out.
        let affirmed = usage(session: 59, rateLimitedUntil: now.addingTimeInterval(300))
        XCTAssertFalse(affirmed.isSuspectedRateLimited)
        XCTAssertEqual(affirmed.displaySessionPercentage, 100)

        // Expired inferred stamp: back to plain measured display.
        let expired = usage(
            session: 59, rateLimitedUntil: now.addingTimeInterval(-1), rateLimitedInferred: true
        )
        XCTAssertFalse(expired.isSuspectedRateLimited)
        XCTAssertEqual(expired.displaySessionPercentage, 59)
    }

    // MARK: - Queue peek/consume semantics

    private func queueProfile(_ name: String, session: Double = 0) -> Profile {
        var p = Profile(id: UUID(), name: name)
        p.claudeUsage = usage(session: session)
        return p
    }

    func testQueuedTargetSurvivesIneligibleWalks() {
        // The consume-on-try bug: a queued target that looked headroom-less
        // (e.g. wearing a FALSE inferred 100%) was eaten without ever being
        // activated. Ineligible-now entries must stay queued.
        let queued = queueProfile("Queued")
        let (target, cleaned) = MenuBarManager.selectQueuedSwitchTarget(
            queue: [queued.id],
            profiles: [queued],
            provider: queued.providerKind,
            excluding: [],
            isEligible: { _ in false }
        )
        XCTAssertNil(target)
        XCTAssertEqual(cleaned, [queued.id], "ineligible queued entry must stay queued")
    }

    func testQueuedTargetSelectedButNotConsumedBySelection() {
        let queued = queueProfile("Queued")
        let (target, cleaned) = MenuBarManager.selectQueuedSwitchTarget(
            queue: [queued.id],
            profiles: [queued],
            provider: queued.providerKind,
            excluding: [],
            isEligible: { _ in true }
        )
        XCTAssertEqual(target?.id, queued.id)
        XCTAssertEqual(cleaned, [queued.id], "selection must not consume — only successful activation does")
    }

    func testDeletedProfileDroppedExcludedSkippedButKept() {
        let deleted = UUID()
        let excludedProfile = queueProfile("Excluded")
        let next = queueProfile("Next")
        let (target, cleaned) = MenuBarManager.selectQueuedSwitchTarget(
            queue: [deleted, excludedProfile.id, next.id],
            profiles: [excludedProfile, next],
            provider: next.providerKind,
            excluding: [excludedProfile.id],
            isEligible: { _ in true }
        )
        XCTAssertEqual(target?.id, next.id)
        XCTAssertEqual(cleaned, [excludedProfile.id, next.id],
                       "deleted id dropped; excluded-this-walk entry kept for later")
    }

    // MARK: - Inferred stamps never displace the active account

    func testInferredStampIsStrippedFromSwitchTriggerButHeaderStampIsNot() {
        let stampedUntil = now.addingTimeInterval(300)

        // Inferred stamp over LOW real numbers: the trigger sees the real 40%
        // and must not fire (a switch costs every session its prompt cache).
        let inferredLow = MenuBarManager.autoSwitchTriggerUsage(
            usage(session: 40, rateLimitedUntil: stampedUntil, rateLimitedInferred: true)
        )
        XCTAssertNil(inferredLow.rateLimitedUntil)
        XCTAssertFalse(MenuBarManager.isQuotaExhausted(
            inferredLow, sessionThreshold: 95, weeklyThreshold: 99, now: now
        ))

        // Inferred stamp over a MEASURED over-threshold number: the real
        // percentage still fires the trigger on its own.
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(
            MenuBarManager.autoSwitchTriggerUsage(
                usage(session: 96, rateLimitedUntil: stampedUntil, rateLimitedInferred: true)
            ),
            sessionThreshold: 95, weeklyThreshold: 99, now: now
        ))

        // Header-based (server-affirmed) stamp passes through untouched and
        // keeps firing the trigger.
        let headerStamped = MenuBarManager.autoSwitchTriggerUsage(
            usage(session: 40, rateLimitedUntil: stampedUntil)
        )
        XCTAssertEqual(headerStamped.rateLimitedUntil, stampedUntil)
        XCTAssertTrue(MenuBarManager.isQuotaExhausted(
            headerStamped, sessionThreshold: 95, weeklyThreshold: 99, now: now
        ))
    }

    func testRateLimitedInferredDecodesFromLegacyCacheAndRoundTrips() {
        // Cached usage JSON written before the field existed must decode (nil).
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var legacy = try! JSONSerialization.jsonObject(
            with: try! encoder.encode(usage(session: 50))
        ) as! [String: Any]
        legacy.removeValue(forKey: "rateLimitedInferred")
        let decoded = try! decoder.decode(
            ClaudeUsage.self,
            from: try! JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertNil(decoded.rateLimitedInferred)

        // And the flag survives a persist/load cycle when set.
        let roundTripped = try! decoder.decode(
            ClaudeUsage.self,
            from: try! encoder.encode(usage(
                session: 50, rateLimitedUntil: now.addingTimeInterval(300), rateLimitedInferred: true
            ))
        )
        XCTAssertEqual(roundTripped.rateLimitedInferred, true)
    }

    // MARK: - Manual popover refresh target

    func testManualRefreshTargetsViewedProfileElseActive() {
        var viewed = Profile(id: UUID(), name: "Viewed")
        viewed.claudeUsage = usage()
        var active = Profile(id: UUID(), name: "Active")
        active.claudeUsage = usage()

        // Viewed profile exists → it is the target, even with an active set.
        XCTAssertEqual(
            MenuBarManager.resolveManualRefreshTarget(
                viewedId: viewed.id, profiles: [viewed, active], activeProfile: active
            )?.name,
            "Viewed"
        )
        // Viewed id points at a deleted profile → fall back to active, not no-op.
        XCTAssertEqual(
            MenuBarManager.resolveManualRefreshTarget(
                viewedId: UUID(), profiles: [active], activeProfile: active
            )?.name,
            "Active"
        )
        // Nothing viewed → active.
        XCTAssertEqual(
            MenuBarManager.resolveManualRefreshTarget(
                viewedId: nil, profiles: [viewed, active], activeProfile: active
            )?.name,
            "Active"
        )
        XCTAssertNil(
            MenuBarManager.resolveManualRefreshTarget(viewedId: nil, profiles: [], activeProfile: nil)
        )
    }

    // MARK: - Hot classification

    func testNearLimitBySessionThreshold() {
        XCTAssertTrue(MenuBarManager.isNearLimit(usage(session: MenuBarManager.hotSessionThreshold)))
        XCTAssertTrue(MenuBarManager.isNearLimit(usage(session: 95)))
        XCTAssertFalse(MenuBarManager.isNearLimit(usage(session: MenuBarManager.hotSessionThreshold - 0.1)))
        XCTAssertFalse(MenuBarManager.isNearLimit(nil))
    }

    func testNearLimitByWeeklyAndFableThresholds() {
        XCTAssertTrue(MenuBarManager.isNearLimit(usage(weekly: MenuBarManager.hotWeeklyThreshold)))
        XCTAssertFalse(MenuBarManager.isNearLimit(usage(weekly: MenuBarManager.hotWeeklyThreshold - 0.1)))
        // Fable weekly is its own scoped limit and must count on its own.
        XCTAssertTrue(MenuBarManager.isNearLimit(usage(weekly: 10, fable: MenuBarManager.hotWeeklyThreshold)))
    }

    func testExpiredSessionWindowIsNotHot() {
        // An account whose 5h window lapsed reads effective 0% regardless of the
        // stale raw percentage — it is idle, not hot.
        XCTAssertFalse(MenuBarManager.isNearLimit(usage(session: 90, sessionResetIn: -60)))
    }

    func testThrottleStampedAccountReadsHot() {
        // rateLimitedUntil forces effectiveSessionPercentage to 100 — such an
        // account is ineligible for fetching anyway, but the classifier must
        // stay consistent with the shared effective-percentage seam.
        XCTAssertTrue(MenuBarManager.isNearLimit(
            usage(session: 10, rateLimitedUntil: now.addingTimeInterval(600))
        ))
    }
}
