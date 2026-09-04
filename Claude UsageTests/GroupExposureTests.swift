//
//  GroupExposureTests.swift
//  Claude UsageTests
//
//  Stage C0: is a provider's composite status item visible on the menu bar?
//  The verdict is pure over one observation (the WindowServer's occlusion
//  answer, frame-shape rules, an advisory hit test and an advisory on-screen
//  list whose misses prove nothing, absent windows unknown); the tracker applies
//  hysteresis so a single odd sample cannot flip the confirmed state.
//

import XCTest
@testable import Claude_Usage

final class GroupExposureTests: XCTestCase {
    /// A 16" display: 1728 × 1117 points, menu bar at the top.
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    private func observation(frame: CGRect?, length: CGFloat = 89, hits: [Bool] = [false, false, false],
                             visible: Bool = true, occluded: Bool = false, onScreen: Bool? = true,
                             screen: CGRect? = nil) -> GroupExposure.Observation {
        GroupExposure.Observation(frame: frame, screenFrame: screen ?? self.screen, isVisible: visible,
                                  occluded: occluded, onScreen: onScreen, length: length, hits: hits)
    }

    private var onBar: CGRect { CGRect(x: 1200, y: 1117 - 37, width: 89, height: 37) }

    func testWindowServerEvidenceDecidesAndAHitTestMissProvesNothing() {
        // The field shape on macOS 27: real frame, visible, not occluded, every probe missed.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: onBar)), .exposed)
        XCTAssertEqual(GroupExposure.verdict(observation(frame: onBar, hits: [])), .exposed,
                       "no probe at all changes nothing when the WindowServer sees the window")
        // A hit on the item's own window is proof even for a stub frame.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: CGRect(x: 1701, y: 1080, width: 27, height: 37),
                                                         hits: [false, true, false], occluded: true)), .exposed)
        // The second field shape (build 96c9aa5): visible, not occluded, absent from the
        // on-screen list — status-item windows are hosted out of process on macOS 27.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: onBar, onScreen: false)), .exposed)
        // Fully occluded, no hit: not confirmed either way, whatever the list says.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: onBar, occluded: true)), .unknown)
        XCTAssertEqual(GroupExposure.verdict(observation(frame: onBar, occluded: true, onScreen: false)), .unknown)
        XCTAssertEqual(GroupExposure.verdict(observation(frame: onBar, occluded: true, onScreen: nil)), .unknown)
    }

    func testAbsentWindowScreenOrLayoutIsUnknownNeverHidden() {
        XCTAssertEqual(GroupExposure.verdict(observation(frame: nil, hits: [])), .unknown)
        XCTAssertEqual(GroupExposure.verdict(GroupExposure.Observation(frame: onBar, screenFrame: nil, isVisible: true,
                                                                       occluded: false, length: 89, hits: [])), .unknown)
        // The first paint after launch (field: x=0 w=461 h=0): not laid out yet.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: CGRect(x: 0, y: 0, width: 461, height: 0))), .unknown)
    }

    func testParkedStubAndOffEdgeFramesAreHidden() {
        // Parked below the bar (lab census: y = -33), even with the WindowServer bits looking healthy.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: CGRect(x: 1200, y: -33, width: 89, height: 37))), .hidden)
        // Past the right edge.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: CGRect(x: 1700, y: 1080, width: 89, height: 37))), .hidden)
        // A 27 pt stub for an 89 pt item — the legacy parking signature.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: CGRect(x: 1701, y: 1080, width: 27, height: 37))), .hidden)
        // AppKit itself says the window is not visible.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: onBar, visible: false)), .hidden)
    }

    func testTrackerConfirmsAfterTwoHiddenAndClearsAfterThreeExposed() {
        var tracker = GroupExposureTracker()
        XCTAssertEqual(tracker.record([.codex: .hidden, .claude: .exposed]), [])
        XCTAssertEqual(tracker.record([.codex: .hidden, .claude: .exposed]), [.codex])
        // One exposed sample does not clear it (menu tracking, display change).
        XCTAssertEqual(tracker.record([.codex: .exposed, .claude: .exposed]), [.codex])
        XCTAssertEqual(tracker.record([.codex: .exposed, .claude: .exposed]), [.codex])
        XCTAssertEqual(tracker.record([.codex: .exposed, .claude: .exposed]), [])
    }

    func testUnknownSamplesLeaveTheStateAloneAndVanishedItemsDropOut() {
        var tracker = GroupExposureTracker()
        tracker.record([.codex: .hidden])
        tracker.record([.codex: .hidden])
        XCTAssertEqual(tracker.record([.codex: .unknown]), [.codex], "unknown neither confirms nor clears")
        // One hidden after an unknown continues the streak semantics.
        XCTAssertEqual(tracker.record([.codex: .hidden]), [.codex])
        // The Codex item is gone (provider deselected): nothing to be hidden.
        XCTAssertEqual(tracker.record([.claude: .exposed]), [])
    }
}
