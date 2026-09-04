//
//  DashboardViewTests.swift
//  Claude UsageTests
//
//  The dashboard's pure helpers: the strings every number is labelled with
//  (provenance + age), the state chips, the next-candidate line, the switch
//  outcome notes, and the per-surface popover size.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class DashboardViewTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAgeAndDurationRoundToTheUnitPeopleRead() {
        XCTAssertEqual(DashboardFormatting.age(now.addingTimeInterval(-28), now: now), "28 s ago")
        XCTAssertEqual(DashboardFormatting.age(now.addingTimeInterval(-12 * 60), now: now), "12 m ago")
        XCTAssertEqual(DashboardFormatting.age(now.addingTimeInterval(-(3 * 3600 + 5 * 60)), now: now), "3 h 5 m ago")
        XCTAssertEqual(DashboardFormatting.age(now.addingTimeInterval(-2 * 3600), now: now), "2 h ago")
        XCTAssertEqual(DashboardFormatting.age(now.addingTimeInterval(-3 * 86400), now: now), "3 d ago")
        XCTAssertEqual(DashboardFormatting.age(now.addingTimeInterval(60), now: now), "0 s ago", "a future stamp never reads negative")
        XCTAssertEqual(DashboardFormatting.duration(40 * 60), "40 min")
        XCTAssertEqual(DashboardFormatting.duration(2 * 3600 + 10 * 60), "2 h 10 m")
        XCTAssertEqual(DashboardFormatting.duration(20), "under a minute")
    }

    func testProvenanceLabelsNameTheSourceAndFlagAttributedValues() {
        let own = UsageMeasurement(provenance: .ownEndpoint, measuredAt: now.addingTimeInterval(-28))
        XCTAssertEqual(DashboardFormatting.provenance(own, now: now), "measured 28 s ago")
        let header = UsageMeasurement(provenance: .headerRescue, measuredAt: now.addingTimeInterval(-120))
        XCTAssertEqual(DashboardFormatting.provenance(header, now: now), "via API headers · 2 m ago")
        XCTAssertTrue(header.isOwn)
        let cache = UsageMeasurement(provenance: .cliCache, measuredAt: now.addingTimeInterval(-300))
        XCTAssertEqual(DashboardFormatting.provenance(cache, now: now), "CLI cache · 5 m ago")
        XCTAssertFalse(cache.isOwn)
    }

    func testChipsSpellTheStateWithoutASyntheticHundred() {
        XCTAssertEqual(DashboardFormatting.chip(.ready, now: now), "ready")
        XCTAssertEqual(DashboardFormatting.chip(.fableMaxed, now: now), "Fable maxed")
        XCTAssertEqual(DashboardFormatting.chip(.suspected(lastMeasured: 74.4, at: now.addingTimeInterval(-600)), now: now),
                       "suspected · 74 % measured 10 m ago")
        XCTAssertEqual(DashboardFormatting.chip(.deadLogin, now: now), "dead login")
        XCTAssertEqual(DashboardFormatting.chip(.autoSwitchOff, now: now), "auto-switch off")
        XCTAssertTrue(DashboardFormatting.chip(.sessionExhausted(resetAt: now.addingTimeInterval(3600)), now: now)
                        .hasPrefix("session exhausted · "))
    }

    func testNextLineCarriesVerdictAgeQuotaAgeAndSource() {
        let id = UUID()
        let verified = NextCard(candidateId: id, name: "Cedar", source: .ranked, readiness: .ready,
                                verdict: .verified, verdictAt: now.addingTimeInterval(-720),
                                quotaMeasuredAt: now.addingTimeInterval(-180))
        XCTAssertEqual(DashboardFormatting.next(verified, now: now),
                       "ranked · ✓ verified 12 m ago · headroom measured 3 m ago")
        let blocked = NextCard(candidateId: id, name: "x", source: .rankedBehindBlockedQueueHead, readiness: .ready,
                               verdict: .unverified, verdictAt: nil, quotaMeasuredAt: nil)
        XCTAssertEqual(DashboardFormatting.next(blocked, now: now), "ranked, queue head blocked · not verified")
        let dead = NextCard(candidateId: id, name: "x", source: .queued, readiness: .dead,
                            verdict: .dead, verdictAt: now, quotaMeasuredAt: nil)
        XCTAssertEqual(DashboardFormatting.next(dead, now: now), "queued · × dead")
        XCTAssertEqual(
            DashboardFormatting.switchQuestion(provider: .claude, from: "Atlas", fromHeadline: "78 % session · resets in 2h 59m",
                                               to: "Cedar", toHeadline: "0 % session · resets in 4h"),
            "Switch the Claude login from Atlas (78 % session · resets in 2h 59m) to Cedar (0 % session · resets in 4h)?")
        XCTAssertEqual(DashboardFormatting.switchQuestion(provider: .codex, from: nil, fromHeadline: nil, to: "Kestrel", toHeadline: nil),
                       "Switch the Codex login to Kestrel?")
        XCTAssertEqual(DashboardFormatting.nobodyWithHeadroom(nil), "nobody with headroom")
    }

    func testSwitchOutcomeNotesNeverReadAsASilentNoOp() {
        XCTAssertEqual(DashboardFormatting.outcome(.activated, name: "Fjo", provider: .claude), "Active for Claude: Fjo ✓ · just now")
        XCTAssertTrue(DashboardFormatting.outcome(.credentialsRefused, name: "Echo", provider: .claude).contains("login is dead"))
        XCTAssertTrue(DashboardFormatting.outcome(.switchInFlight, name: "Echo", provider: .claude).contains("in progress"))
        XCTAssertEqual(DashboardFormatting.outcome(.alreadyActive, name: "Fjo", provider: .claude), "Fjo is already active.")
        XCTAssertTrue(DashboardFormatting.switchCost(.claude).contains("10–15 %"))
    }

    func testSurfaceSizesAreIndependent() {
        XCTAssertEqual(DashboardSurface.size(for: .classic), Constants.WindowSizes.popoverSize)
        XCTAssertEqual(DashboardSurface.size(for: .dashboard), DashboardSurface.dashboardSize)
        XCTAssertGreaterThan(DashboardSurface.dashboardSize.width, Constants.WindowSizes.popoverSize.width,
                             "two-line roster rows need the wider surface")
    }
}
