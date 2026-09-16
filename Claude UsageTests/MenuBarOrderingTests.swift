//
//  MenuBarOrderingTests.swift
//  Claude UsageTests
//
//  Tests for StatusBarUIManager.multiProfileCreationOrder — the weekly-reset
//  ranking that decides menu bar item order. Creation order maps right-to-left
//  on screen: index 0 is the RIGHTMOST item. Claude profiles are created first
//  (right side), Codex profiles last (far left). A ranking flip tears down and
//  rebuilds the whole status-item group (visible flicker), so stability under
//  API jitter is load-bearing behavior.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class MenuBarOrderingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A Claude-side profile (claude.ai session credentials).
    private func claudeProfile(_ name: String, weeklyReset: Date?, selected: Bool = true) -> Profile {
        var usage: ClaudeUsage?
        if let weeklyReset {
            var u = ClaudeUsage.empty
            u.weeklyResetTime = weeklyReset
            usage = u
        }
        return Profile(
            name: name,
            claudeSessionKey: "sk-ant-sid01-test",
            organizationId: "org-test",
            claudeUsage: usage,
            isSelectedForDisplay: selected
        )
    }

    /// A Codex-only profile (isCodexOnlyProfile == true).
    private func codexProfile(_ name: String, weeklyReset: Date?, selected: Bool = true) -> Profile {
        var usage: ClaudeUsage?
        if let weeklyReset {
            var u = ClaudeUsage.empty
            u.weeklyResetTime = weeklyReset
            usage = u
        }
        return Profile(
            name: name,
            codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
            codexEmail: "codex@example.com",
            claudeUsage: usage,
            isSelectedForDisplay: selected
        )
    }

    private func order(_ profiles: [Profile]) -> [String] {
        StatusBarUIManager.multiProfileCreationOrder(for: profiles, now: now).map(\.name)
    }

    // MARK: group split

    func testClaudeGroupIsCreatedBeforeCodexGroup() {
        // Creation order right-to-left: Claude items first (right), Codex last (far left).
        let profiles = [
            codexProfile("X-Codex", weeklyReset: now.addingTimeInterval(3600)),
            claudeProfile("A-Claude", weeklyReset: now.addingTimeInterval(7200))
        ]
        XCTAssertEqual(order(profiles), ["A-Claude", "X-Codex"])
    }

    // MARK: within-group ranking

    func testSoonestWeeklyResetRanksFirstWithinGroup() {
        let profiles = [
            claudeProfile("Late", weeklyReset: now.addingTimeInterval(5 * 24 * 3600)),
            claudeProfile("Soon", weeklyReset: now.addingTimeInterval(1 * 24 * 3600)),
            claudeProfile("Mid", weeklyReset: now.addingTimeInterval(3 * 24 * 3600))
        ]
        XCTAssertEqual(order(profiles), ["Soon", "Mid", "Late"])
    }

    func testProfileWithoutCachedUsageSortsLastInItsGroup() {
        let profiles = [
            claudeProfile("Unknown", weeklyReset: nil),
            claudeProfile("Known", weeklyReset: now.addingTimeInterval(24 * 3600))
        ]
        XCTAssertEqual(order(profiles), ["Known", "Unknown"])
    }

    func testUnselectedProfilesAreExcluded() {
        let profiles = [
            claudeProfile("Shown", weeklyReset: now.addingTimeInterval(3600)),
            claudeProfile("Hidden", weeklyReset: now.addingTimeInterval(60), selected: false)
        ]
        XCTAssertEqual(order(profiles), ["Shown"])
    }

    /// Accounts the owner hid ("Show in the menu bar" off) leave BOTH layouts:
    /// the every-account tiles, the fleet ranking (which otherwise keeps
    /// unselected accounts), the popover navigator's fallback and — once a
    /// provider has nothing shown — the provider's status item. The dashboard
    /// and the next-account hotkey still rank them (`includeHidden`).
    func testAccountsHiddenFromTheMenuBarLeaveEveryLayout() {
        var held = claudeProfile("Held", weeklyReset: now.addingTimeInterval(60))
        held.isShownOnMenuBar = false
        var heldCodex = codexProfile("Held-Codex", weeklyReset: now.addingTimeInterval(60))
        heldCodex.isShownOnMenuBar = false
        let shown = claudeProfile("Shown", weeklyReset: now.addingTimeInterval(3600))
        let quiet = claudeProfile("Quiet", weeklyReset: now.addingTimeInterval(7200), selected: false)
        let profiles = [held, shown, heldCodex, quiet]

        XCTAssertEqual(order(profiles), ["Shown"])
        XCTAssertEqual(
            StatusBarUIManager.multiProfileCreationOrder(for: profiles, now: now, includeUnselected: true).map(\.name),
            ["Shown", "Quiet"], "fleet layouts keep unselected accounts, never hidden ones")
        XCTAssertEqual(StatusBarUIManager.fleetPaintOrder(for: profiles, activeIds: [], now: now), [quiet.id, shown.id])
        XCTAssertEqual(
            StatusBarUIManager.onScreenGroupMembers(for: profiles, provider: .claude, now: now).map(\.name), ["Shown"])
        XCTAssertTrue(StatusBarUIManager.onScreenGroupMembers(for: profiles, provider: .codex, now: now).isEmpty)
        XCTAssertEqual(StatusBarUIManager.barProviders(profiles), [.claude],
                       "a provider whose every account is hidden has no status item")
        XCTAssertEqual(StatusBarUIManager.hiddenFromBarCount(profiles, provider: .claude, activeIds: []), 1)
        XCTAssertEqual(StatusBarUIManager.hiddenFromBarCount(profiles, provider: .codex, activeIds: []), 1)

        XCTAssertEqual(
            StatusBarUIManager.multiProfileCreationOrder(
                for: profiles, now: now, includeUnselected: true, includeHidden: true).map(\.name),
            ["Held", "Shown", "Quiet", "Held-Codex"], "the dashboard and the hotkey rank the whole provider")
    }

    /// The provider-active account is drawn even when hidden — a group
    /// without its active block is forbidden — but it does not keep a
    /// provider on the bar by itself: hiding every account removes the group.
    func testAHiddenActiveAccountStaysDrawnWhileItsProviderIsShown() {
        var owner = claudeProfile("Owner", weeklyReset: now.addingTimeInterval(60))
        owner.isShownOnMenuBar = false
        var other = claudeProfile("Other", weeklyReset: now.addingTimeInterval(3600))

        XCTAssertEqual(
            StatusBarUIManager.multiProfileCreationOrder(for: [owner, other], now: now, alwaysShown: [owner.id]).map(\.name),
            ["Owner", "Other"])
        XCTAssertEqual(order([owner, other]), ["Other"], "without the exception the owner is just a hidden account")
        XCTAssertTrue(StatusBarUIManager.isTileMember(owner, activeIds: [owner.id]))
        XCTAssertFalse(StatusBarUIManager.isTileMember(owner, activeIds: []))
        var deselectedOwner = owner
        deselectedOwner.isSelectedForDisplay = false
        XCTAssertFalse(StatusBarUIManager.isTileMember(deselectedOwner, activeIds: [owner.id]),
                       "the every-account layout still leaves a deselected owner out (unchanged)")
        XCTAssertEqual(StatusBarUIManager.hiddenFromBarCount([owner, other], provider: .claude, activeIds: [owner.id]), 0,
                       "a drawn owner is not reported as hidden")
        XCTAssertEqual(StatusBarUIManager.barProviders([owner, other]), [.claude])

        other.isShownOnMenuBar = false
        XCTAssertEqual(StatusBarUIManager.barProviders([owner, other]), [])
    }

    // MARK: jitter quantization

    func testSubMinuteJitterDoesNotFlipTheOrder() {
        // The usage API reports the same weekly boundary with ±1s jitter across
        // fetches. Two accounts sharing a boundary must keep a stable order
        // (name tiebreak) no matter which side of the second boundary each
        // fetch lands on — every flip is a full menu bar rebuild.
        let boundary = now.addingTimeInterval(24 * 3600)

        let sweep1 = [
            claudeProfile("Beta", weeklyReset: boundary.addingTimeInterval(-0.2)),
            claudeProfile("Alpha", weeklyReset: boundary.addingTimeInterval(0.1))
        ]
        let sweep2 = [
            claudeProfile("Beta", weeklyReset: boundary.addingTimeInterval(0.3)),
            claudeProfile("Alpha", weeklyReset: boundary.addingTimeInterval(-0.4))
        ]
        XCTAssertEqual(order(sweep1), ["Alpha", "Beta"])
        XCTAssertEqual(order(sweep2), ["Alpha", "Beta"])
    }

    func testJitterAcrossAMinuteBoundaryStillQuantizesTogether() {
        // 23:59:59.8 vs 00:00:00.1 — different minutes, but rounding to the
        // NEAREST minute maps both onto the same key.
        let minuteBoundary = Date(timeIntervalSinceReferenceDate:
            (now.addingTimeInterval(24 * 3600).timeIntervalSinceReferenceDate / 60).rounded() * 60)

        let sweep1 = [
            claudeProfile("Beta", weeklyReset: minuteBoundary.addingTimeInterval(-0.5)),
            claudeProfile("Alpha", weeklyReset: minuteBoundary.addingTimeInterval(0.5))
        ]
        XCTAssertEqual(order(sweep1), ["Alpha", "Beta"])
    }

    func testGenuinelyDifferentResetsAreNotMerged() {
        let profiles = [
            claudeProfile("Alpha", weeklyReset: now.addingTimeInterval(24 * 3600 + 300)),
            claudeProfile("Beta", weeklyReset: now.addingTimeInterval(24 * 3600))
        ]
        // 5 minutes apart: real difference, Beta (sooner) first despite name order.
        XCTAssertEqual(order(profiles), ["Beta", "Alpha"])
    }

    func testEqualUnknownResetsUseNameTiebreak() {
        let profiles = [
            claudeProfile("Zeta", weeklyReset: nil),
            claudeProfile("Alpha", weeklyReset: nil)
        ]
        XCTAssertEqual(order(profiles), ["Alpha", "Zeta"])
    }

    private func grokProfile(_ name: String, weeklyReset: Date?, selected: Bool = true) -> Profile {
        var usage: ClaudeUsage?
        if let weeklyReset {
            var u = ClaudeUsage.empty
            u.weeklyResetTime = weeklyReset
            usage = u
        }
        return Profile(
            name: name,
            grokCredentialsJSON: "{\"https://auth.x.ai::client\":{\"key\":\"jwt\"}}",
            grokEmail: "grok@example.com",
            claudeUsage: usage,
            isSelectedForDisplay: selected
        )
    }

    func testFullTwoProviderLayout() {
        let profiles = [
            codexProfile("Codex-Late", weeklyReset: now.addingTimeInterval(6 * 24 * 3600)),
            claudeProfile("Claude-Late", weeklyReset: now.addingTimeInterval(5 * 24 * 3600)),
            codexProfile("Codex-Soon", weeklyReset: now.addingTimeInterval(1 * 24 * 3600)),
            claudeProfile("Claude-Soon", weeklyReset: now.addingTimeInterval(2 * 24 * 3600))
        ]
        // Rightmost → leftmost: Claude group (soonest first), then Codex group.
        XCTAssertEqual(order(profiles), ["Claude-Soon", "Claude-Late", "Codex-Soon", "Codex-Late"])
    }

    func testThreeProviderLayoutKeepsGrokVisibleLeftOfClaude() {
        let profiles = [
            grokProfile("Grok", weeklyReset: now.addingTimeInterval(3 * 24 * 3600)),
            codexProfile("Codex", weeklyReset: now.addingTimeInterval(1 * 24 * 3600)),
            claudeProfile("Claude", weeklyReset: now.addingTimeInterval(2 * 24 * 3600))
        ]
        // Creation order maps right-to-left, and the leftmost item clips first
        // on a full bar: Claude rightmost, then Grok, then Codex at the
        // overflow edge — so a newly-added Grok tile stays visible.
        XCTAssertEqual(order(profiles), ["Claude", "Grok", "Codex"])
    }

    // MARK: - Stranded-tile layout check

    func testDescendingContiguousXPositionsMatchCreationOrder() {
        // Creation order maps right-to-left: strictly descending, tightly
        // packed x (~27pt tiles) is healthy.
        XCTAssertFalse(StatusBarUIManager.layoutDivergesFromCreationOrder([900, 873, 846, 819]))
        XCTAssertFalse(StatusBarUIManager.layoutDivergesFromCreationOrder([100]))
        XCTAssertFalse(StatusBarUIManager.layoutDivergesFromCreationOrder([]))
    }

    func testStrandedTileIsDetected() {
        // The incident shape: the LAST-created tile (expected leftmost) sitting
        // at the far right of the bar.
        XCTAssertTrue(StatusBarUIManager.layoutDivergesFromCreationOrder([900, 873, 846, 1650]))
        // Equal positions (overlapping/unresolved windows) also count as broken
        // rather than silently accepted — the caller filters unmeasurable cases.
        XCTAssertTrue(StatusBarUIManager.layoutDivergesFromCreationOrder([900, 900]))
    }

    func testSplitGroupIsDetected() {
        // Order intact but the group torn in two (other apps' icons in the
        // middle — a rejected pin's fallback placement): a >90pt adjacent gap.
        XCTAssertTrue(StatusBarUIManager.layoutDivergesFromCreationOrder([1509, 1482, 1321, 1294]))
    }

    // MARK: - Overflow-parked detection

    func testDistinctPositionsAreNotOverflowParked() {
        XCTAssertFalse(StatusBarUIManager.containsOverflowParkedTiles([1471, 1444, 1417, 1390]))
        XCTAssertFalse(StatusBarUIManager.containsOverflowParkedTiles([100]))
        XCTAssertFalse(StatusBarUIManager.containsOverflowParkedTiles([]))
    }

    func testDuplicatePositionsAreOverflowParked() {
        // Real snapshot 2026-07-25: four of twelve tiles hidden by menu-bar
        // overflow, all parked at the same x=1701 — an overflowing bar, not a
        // stranded layout. Healing must not fire (a rebuild can't make the
        // tiles fit, and retrying every rate-limit window flickers the whole
        // group forever).
        XCTAssertTrue(StatusBarUIManager.containsOverflowParkedTiles(
            [1471, 1444, 1701, 1390, 1701, 1701, 1309, 1282, 1255, 1228, 1201, 1701]
        ))
    }

    // MARK: - Overflow-parked profile-id derivation

    func testOverflowParkedProfileIdsMatchesDuplicatedPositions() {
        // Given four tiles where the 2nd and 4th share the off-edge parking x
        let ids = (0..<4).map { _ in UUID() }
        let parked = StatusBarUIManager.overflowParkedProfileIds(
            order: ids,
            xPositions: [1471, 1701, 1390, 1701]
        )
        // Then exactly the duplicated-x tiles are parked
        XCTAssertEqual(parked, Set([ids[1], ids[3]]))
    }

    func testOverflowParkedProfileIdsEmptyForDistinctPositionsAndMismatchedInput() {
        let ids = (0..<3).map { _ in UUID() }
        // Distinct positions: nothing parked
        XCTAssertTrue(StatusBarUIManager.overflowParkedProfileIds(
            order: ids, xPositions: [100, 200, 300]
        ).isEmpty)
        // Count mismatch: fail safe to empty (never skip renders on bad input)
        XCTAssertTrue(StatusBarUIManager.overflowParkedProfileIds(
            order: ids, xPositions: [100, 100]
        ).isEmpty)
    }

}
