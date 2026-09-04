//
//  DashboardSelectionTests.swift
//  Claude UsageTests
//
//  B2.1: the dashboard reads the SAME `ProviderActiveSelection` the ⇄
//  selector menu reads (docs/specs/ux-revamp.md R3/D6) — built once inside
//  `DashboardSnapshot.build`, never a second classification — and speaks the
//  Viewing / Active-for vocabulary in its section captions.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class DashboardSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)

    private func usage(session: Double = 0, weekly: Double = 0) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = now.addingTimeInterval(3600)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = now.addingTimeInterval(3 * 86400)
        u.lastUpdated = now.addingTimeInterval(-10)
        return u
    }

    private func claude(_ name: String, _ u: ClaudeUsage?, autoSwitch: Bool = true, account: String? = nil) -> Profile {
        var p = Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org",
                        claudeUsage: u, isSelectedForDisplay: true, includeInAutoSwitch: autoSwitch)
        p.claudeAccountUUID = account
        return p
    }

    private func inputs(_ profiles: [Profile], active: Set<UUID>, focused: UUID? = nil,
                        dead: Set<UUID> = [], next: [Profile.ProviderKind: PredictedCandidate] = [:],
                        queue: [UUID] = [], duplicates: [[UUID]] = [], pinned: Set<UUID> = [],
                        relogin: Set<UUID> = []) -> DashboardSnapshot.Inputs {
        DashboardSnapshot.Inputs(
            profiles: profiles, activeIds: active, focusedId: focused,
            context: FleetSummaryContext(
                thresholds: thresholds,
                isLoginDead: { dead.contains($0.id) },
                isExcluded: { !$0.isAutoSwitchEnabled },
                nextCandidates: next, preflightVerdicts: [:],
                preferencesDegraded: false, isSwitching: false, now: now
            ),
            queue: queue, history: [], duplicateGroups: duplicates,
            manuallyPinned: pinned, needsRelogin: relogin
        )
    }

    func testEverySectionCarriesTheSelectorsSelectionWithOwnerAndViewing() {
        let owner = claude("Owner", usage(session: 40))
        let viewed = claude("Viewed", usage(session: 10))
        let snap = DashboardSnapshot.build(inputs([owner, viewed], active: [owner.id], focused: viewed.id, pinned: [owner.id]))
        let selection = try! XCTUnwrap(snap.sections[0].selection)
        XCTAssertEqual(selection.owner?.id, owner.id)
        XCTAssertEqual(selection.viewing, viewed.id)
        XCTAssertTrue(selection.owner?.isManuallyPinned == true)
        XCTAssertEqual(selection.candidates.map(\.id), [viewed.id])
        XCTAssertEqual(selection.counts.profiles, 2)
    }

    func testRosterRowsCarryTheCandidateStatusNextMarkAndReloginFlag() {
        let owner = claude("Owner", usage(session: 40), account: "acct-1")
        let twin = claude("Twin", usage(session: 40), account: "acct-1")
        let dead = claude("Dead", usage(session: 5))
        let off = claude("Off", usage(session: 5), autoSwitch: false)
        let next = claude("Next", usage(session: 5))
        let snap = DashboardSnapshot.build(inputs(
            [owner, twin, dead, off, next], active: [owner.id], dead: [dead.id],
            next: [.claude: PredictedCandidate(id: next.id, label: "Next", queued: false, queueHeadBlocked: false)],
            duplicates: [[owner.id, twin.id]], relogin: [dead.id]
        ))
        let rows = Dictionary(uniqueKeysWithValues: snap.sections[0].roster.map { ($0.id, $0) })
        XCTAssertEqual(rows[twin.id]?.candidateStatus, .duplicateOfOwner(ownerName: "Owner"))
        XCTAssertEqual(rows[dead.id]?.candidateStatus, .blocked(.dead))
        XCTAssertTrue(rows[dead.id]?.needsRelogin == true)
        XCTAssertEqual(rows[off.id]?.candidateStatus, .excluded(.autoSwitchOff))
        XCTAssertEqual(rows[next.id]?.candidateStatus, .eligible)
        XCTAssertTrue(rows[next.id]?.isNext == true)
        XCTAssertFalse(rows[owner.id] != nil, "the owner is the active card, never a roster row")
    }

    func testSectionCaptionSpeaksTheViewingVocabulary() {
        let owner = claude("dRir", usage(session: 40))
        let viewed = claude("dJormun", usage(session: 10))
        // Viewing another account of the provider.
        var snap = DashboardSnapshot.build(inputs([owner, viewed], active: [owner.id], focused: viewed.id))
        XCTAssertEqual(DashboardFormatting.sectionCaption(snap.sections[0]),
                       "Viewing dJormun · Active for Claude: dRir")
        // Viewing the owner itself, pinned by the user.
        snap = DashboardSnapshot.build(inputs([owner, viewed], active: [owner.id], focused: owner.id, pinned: [owner.id]))
        XCTAssertEqual(DashboardFormatting.sectionCaption(snap.sections[0]),
                       "Viewing dRir · Active for Claude: dRir · pinned")
        // No owner at all.
        snap = DashboardSnapshot.build(inputs([owner, viewed], active: [], focused: nil))
        XCTAssertEqual(DashboardFormatting.sectionCaption(snap.sections[0]), "No active Claude login")
        // Owner, focus on another provider.
        snap = DashboardSnapshot.build(inputs([owner, viewed], active: [owner.id], focused: nil))
        XCTAssertEqual(DashboardFormatting.sectionCaption(snap.sections[0]), "Active for Claude: dRir")
    }

    func testRosterHeaderCountsComeFromTheSharedFleetCounts() {
        let owner = claude("Owner", usage(session: 40))
        let ready = claude("Ready", usage(session: 5))
        let maxed = claude("Maxed", usage(session: 5, weekly: 100))
        let snap = DashboardSnapshot.build(inputs([owner, ready, maxed], active: [owner.id]))
        let counts = try! XCTUnwrap(snap.sections[0].selection?.counts)
        XCTAssertEqual(counts.profiles, 3)
        XCTAssertEqual(counts.autoSwitchEligible, 2, "owner and Ready have headroom; Maxed is exhausted")
        XCTAssertEqual(DashboardFormatting.rosterHeader(snap.sections[0]),
                       "ROSTER · 2 · soonest weekly reset first · 2 eligible now")
    }
}
