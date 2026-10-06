//
//  FleetDotMemoryTests.swift
//  Claude UsageTests
//
//  Owner round 2026-09-04, B3: a fleet dot changes colour only on
//  server-affirmed evidence — a new measurement, a login dying or reviving,
//  a server-affirmed limit stamp, a window reset, an exclusion — never on the
//  mere passage of time, and an inferred throttle has to persist before it
//  turns a dot purple. Every adoption carries a reason for the log.
//

import XCTest
@testable import Claude_Usage

final class FleetDotMemoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let id = UUID()

    private func usage(session: Double, measuredAgo: TimeInterval = 10, inferred: Bool? = nil,
                       stampFor: TimeInterval? = nil, sessionResetIn: TimeInterval = 3600) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = now.addingTimeInterval(sessionResetIn)
        u.weeklyResetTime = now.addingTimeInterval(3 * 86400)
        u.lastUpdated = now.addingTimeInterval(-measuredAgo)
        if let stampFor { u.rateLimitedUntil = now.addingTimeInterval(stampFor) }
        u.rateLimitedInferred = inferred
        return u
    }

    func testFirstPaintAdoptsAndANewMeasurementIsAffirmed() {
        var memory = FleetDotMemory()
        let first = memory.adopt(id: id, candidate: .ready, usage: usage(session: 10), isLoginDead: false, isExcluded: false, now: now)
        XCTAssertEqual(first.readiness, .ready)
        XCTAssertEqual(first.change?.reason, "first paint")
        // Same measurement, different classification (nothing new arrived): held.
        let held = memory.adopt(id: id, candidate: .readyUnderHalf, usage: usage(session: 10), isLoginDead: false, isExcluded: false, now: now.addingTimeInterval(30))
        XCTAssertEqual(held.readiness, .ready)
        XCTAssertNil(held.change)
        // A new measurement: adopted, with its provenance in the reason.
        let measured = memory.adopt(id: id, candidate: .readyUnderHalf, usage: usage(session: 85, measuredAgo: 0), isLoginDead: false, isExcluded: false, now: now.addingTimeInterval(60))
        XCTAssertEqual(measured.readiness, .readyUnderHalf)
        XCTAssertEqual(measured.change?.from, .ready)
        XCTAssertEqual(measured.change?.reason, "new measurement (own endpoint)")
    }

    /// The third shade moves exactly like the other two: a shade-only change
    /// between greens waits for a new measurement, and an orange of any
    /// shade clears on its session window's reset.
    func testEveryShadeMoveWaitsForEvidence() {
        var memory = FleetDotMemory()
        let first = usage(session: 10, measuredAgo: 60)
        _ = memory.adopt(id: id, candidate: .readyUnderHalf, usage: first, isLoginDead: false, isExcluded: false, now: now)
        let held = memory.adopt(id: id, candidate: .readyUnderQuarter, usage: first, isLoginDead: false, isExcluded: false, now: now.addingTimeInterval(30))
        XCTAssertEqual(held.readiness, .readyUnderHalf, "no new reading: the shade holds")
        XCTAssertNil(held.change)
        let measured = memory.adopt(id: id, candidate: .readyUnderQuarter, usage: usage(session: 10, measuredAgo: 0),
                                    isLoginDead: false, isExcluded: false, now: now.addingTimeInterval(60))
        XCTAssertEqual(measured.readiness, .readyUnderQuarter)
        XCTAssertEqual(measured.change?.from, .readyUnderHalf)

        var orange = FleetDotMemory()
        let hit = usage(session: 96, measuredAgo: 60, sessionResetIn: 30)
        _ = orange.adopt(id: id, candidate: .sessionHitUnderQuarter, usage: hit, isLoginDead: false, isExcluded: false, now: now)
        let reset = orange.adopt(id: id, candidate: .readyUnderQuarter, usage: hit, isLoginDead: false, isExcluded: false, now: now.addingTimeInterval(60))
        XCTAssertEqual(reset.readiness, .readyUnderQuarter, "the dullest orange is a session hit like the others")
        XCTAssertEqual(reset.change?.reason, "session window reset")
    }

    func testLoginDeathAndRevivalAreAffirmedImmediately() {
        var memory = FleetDotMemory()
        _ = memory.adopt(id: id, candidate: .ready, usage: usage(session: 10), isLoginDead: false, isExcluded: false, now: now)
        let dead = memory.adopt(id: id, candidate: .dead, usage: usage(session: 10), isLoginDead: true, isExcluded: false, now: now.addingTimeInterval(5))
        XCTAssertEqual(dead.readiness, .dead)
        XCTAssertEqual(dead.change?.reason, "login dead")
        let revived = memory.adopt(id: id, candidate: .ready, usage: usage(session: 10), isLoginDead: false, isExcluded: false, now: now.addingTimeInterval(10))
        XCTAssertEqual(revived.readiness, .ready)
        XCTAssertEqual(revived.change?.reason, "login revived")
    }

    func testAnInferredThrottleHasToPersistBeforeTheDotTurnsPurple() {
        var memory = FleetDotMemory()
        _ = memory.adopt(id: id, candidate: .ready, usage: usage(session: 10), isLoginDead: false, isExcluded: false, now: now)
        let suspect = usage(session: 10, inferred: true, stampFor: 300)
        let early = memory.adopt(id: id, candidate: .suspected, usage: suspect, isLoginDead: false, isExcluded: false, now: now.addingTimeInterval(5))
        XCTAssertEqual(early.readiness, .ready, "a suspicion five seconds old does not repaint the dot")
        XCTAssertNil(early.change)
        let later = memory.adopt(id: id, candidate: .suspected, usage: suspect, isLoginDead: false, isExcluded: false, now: now.addingTimeInterval(5 + FleetDotMemory.suspectedDebounce))
        XCTAssertEqual(later.readiness, .suspected)
        XCTAssertTrue(later.change?.reason.hasPrefix("inferred throttle persisted") == true)
    }

    func testAServerAffirmedStampAndItsExpiryAreAffirmed() {
        var memory = FleetDotMemory()
        _ = memory.adopt(id: id, candidate: .ready, usage: usage(session: 10), isLoginDead: false, isExcluded: false, now: now)
        let stamped = memory.adopt(id: id, candidate: .sessionHit, usage: usage(session: 10, inferred: false, stampFor: 2918),
                                   isLoginDead: false, isExcluded: false, now: now.addingTimeInterval(5))
        XCTAssertEqual(stamped.readiness, .sessionHit)
        XCTAssertEqual(stamped.change?.reason, "server-affirmed limit stamp")
        let expired = memory.adopt(id: id, candidate: .ready, usage: usage(session: 10, inferred: false, stampFor: -1),
                                   isLoginDead: false, isExcluded: false, now: now.addingTimeInterval(3000))
        XCTAssertEqual(expired.readiness, .ready)
        XCTAssertEqual(expired.change?.reason, "limit stamp expired")
    }

    func testForgettingDropsAccountsNoLongerPainted() {
        var memory = FleetDotMemory()
        let other = UUID()
        _ = memory.adopt(id: id, candidate: .ready, usage: usage(session: 10), isLoginDead: false, isExcluded: false, now: now)
        _ = memory.adopt(id: other, candidate: .ready, usage: usage(session: 10), isLoginDead: false, isExcluded: false, now: now)
        memory.forget(except: [id])
        XCTAssertNotNil(memory.shown[id])
        XCTAssertNil(memory.shown[other])
    }
}
