//
//  GroupExposureTests.swift
//  Claude UsageTests
//
//  Stage C0: is a provider's composite status item visible on the menu bar?
//  The verdict is pure over one observation (screen-point hit tests first,
//  frame-shape rules second, absent windows unknown); the tracker applies
//  hysteresis so a single odd sample cannot flip the confirmed state.
//

import XCTest
@testable import Claude_Usage

final class GroupExposureTests: XCTestCase {
    /// A 16" display: 1728 × 1117 points, menu bar at the top.
    private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)

    private func observation(frame: CGRect?, length: CGFloat = 89, hits: [Bool] = [true, true, true],
                             visible: Bool = true, occluded: Bool = false, screen: CGRect? = nil) -> GroupExposure.Observation {
        GroupExposure.Observation(frame: frame, screenFrame: screen ?? self.screen, isVisible: visible,
                                  occluded: occluded, length: length, hits: hits)
    }

    private var onBar: CGRect { CGRect(x: 1200, y: 1117 - 37, width: 89, height: 37) }

    func testAHitOnItsOwnWindowIsProofOfExposureWhateverTheFrameSays() {
        XCTAssertEqual(GroupExposure.verdict(observation(frame: onBar)), .exposed)
        // Even a stub frame with one positive probe is exposed: pixels are on screen.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: CGRect(x: 1701, y: 1080, width: 27, height: 37),
                                                         hits: [false, true, false])), .exposed)
    }

    func testAbsentWindowOrScreenIsUnknownNeverHidden() {
        XCTAssertEqual(GroupExposure.verdict(observation(frame: nil, hits: [])), .unknown)
        XCTAssertEqual(GroupExposure.verdict(GroupExposure.Observation(frame: onBar, screenFrame: nil, isVisible: true,
                                                                       occluded: false, length: 89, hits: [])), .unknown)
        XCTAssertEqual(GroupExposure.verdict(observation(frame: onBar, hits: [])), .unknown,
                       "a plausible frame with no probe run is not evidence either way")
    }

    func testParkedStubAndOffEdgeFramesAreHidden() {
        let misses = [false, false, false]
        // Never laid out (lab census: h = 0).
        XCTAssertEqual(GroupExposure.verdict(observation(frame: CGRect(x: 1200, y: 1080, width: 89, height: 0), hits: misses)), .hidden)
        // Parked below the bar (lab census: y = -33).
        XCTAssertEqual(GroupExposure.verdict(observation(frame: CGRect(x: 1200, y: -33, width: 89, height: 37), hits: misses)), .hidden)
        // Past the right edge.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: CGRect(x: 1700, y: 1080, width: 89, height: 37), hits: misses)), .hidden)
        // A 27 pt stub for an 89 pt item — the legacy parking signature.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: CGRect(x: 1701, y: 1080, width: 27, height: 37), hits: misses)), .hidden)
        // Plausible frame, all probes resolve elsewhere: covered / hidden.
        XCTAssertEqual(GroupExposure.verdict(observation(frame: onBar, hits: misses)), .hidden)
        XCTAssertEqual(GroupExposure.verdict(observation(frame: onBar, hits: misses, visible: false)), .hidden)
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
