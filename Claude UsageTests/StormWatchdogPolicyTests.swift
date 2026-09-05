//
//  StormWatchdogPolicyTests.swift
//  Claude UsageTests
//
//  The watchdog's decision core (threshold, strikes, episodes, gates, the
//  storm signature) against synthetic tick streams. No timer, no process:
//  `StormWatchdogPolicy` is a value fed one sample at a time.
//

import XCTest
@testable import Claude_Usage

final class StormWatchdogPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_789_000_000)

    private func sample(_ usage: Double, at minutes: Double, idle: Bool = true, windows: Int = 9, tracking: Int = 12) -> StormWatchdogPolicy.Sample {
        StormWatchdogPolicy.Sample(usage: usage, wall: 120, uiIdle: idle, windows: windows, trackingAreas: tracking,
                                   now: t0.addingTimeInterval(minutes * 60))
    }

    /// Feeds `usage` for `count` ticks starting at `minute`, returning the verdicts.
    private func run(_ policy: inout StormWatchdogPolicy, _ usage: Double, ticks: Int, from minute: Double, windows: Int = 9, tracking: Int = 12) -> [StormWatchdogPolicy.Verdict] {
        (0..<ticks).map { policy.observe(sample(usage, at: minute + Double($0) * 2, windows: windows, tracking: tracking)) }
    }

    func testSamplesBelowTheThresholdNeverStrike() {
        var policy = StormWatchdogPolicy(burnThreshold: 0.03)
        let verdicts = run(&policy, 0.029, ticks: 10, from: 0)
        XCTAssertTrue(verdicts.allSatisfy { $0 == .clean(episodeEnded: false) }, "the app's own steady state sits under the bar")
        XCTAssertEqual(policy.consecutiveHotSamples, 0)
        XCTAssertNil(policy.episodeStartedAt)
        XCTAssertEqual(policy.suppressedBurn, 0, "nothing banks below the threshold")
    }

    /// Three hot samples open the episode and try the one remediation; the
    /// fourth notifies with the MEASURED mean, not a synthetic value; a fifth
    /// inside the 6h backoff is gated; the backoff elapsing re-posts.
    func testThreeStrikesRemediateThenNotifyWithTheMeasuredValueAndBackOffSixHours() throws {
        var policy = StormWatchdogPolicy(burnThreshold: 0.03)
        let verdicts = run(&policy, 0.08, ticks: 4, from: 0)
        XCTAssertEqual(Array(verdicts.prefix(3)), [.hot(streak: 1), .hot(streak: 2), .remediate])
        guard case .notify(let notice) = verdicts[3] else { return XCTFail("the sample after remediation alarms: \(verdicts[3])") }
        XCTAssertTrue(notice.isFirstForEpisode)
        XCTAssertEqual(notice.gate, "first-of-episode, 45-min floor clear")
        XCTAssertEqual(notice.measuredUsage, 0.08, accuracy: 0.0001, "the mean over the hot run")
        XCTAssertEqual(notice.measuredOver, 4 * 120, "four hot samples of two minutes")
        XCTAssertFalse(notice.signature.detected, "the window population did not move")
        XCTAssertEqual(policy.suppressedBurn, 0, "a post drains the bank")

        XCTAssertEqual(policy.observe(sample(0.08, at: 8)), .gated("6h intra-episode re-post backoff (2 min since the last post)"))
        guard case .notify(let repost) = policy.observe(sample(0.09, at: 6 + 6 * 60)) else { return XCTFail("6h elapsed re-posts") }
        XCTAssertFalse(repost.isFirstForEpisode)
        XCTAssertEqual(repost.gate, "6h intra-episode re-post backoff elapsed")
        XCTAssertEqual(repost.episodeAge, (366 + 2) * 60, accuracy: 1,
                       "the episode is backdated to the start of its first hot sample's interval (three intervals before it opened)")
    }

    /// Quit advice is reserved for the storm signature: windows or tracking
    /// areas that GREW during the episode. A steady population is named as
    /// such, and the body leads with the measured number either way.
    func testAlarmPrescribesQuittingOnlyBehindTheWindowGrowthSignature() throws {
        var steady = StormWatchdogPolicy(burnThreshold: 0.03)
        let verdicts = run(&steady, 0.05, ticks: 4, from: 0, windows: 9, tracking: 12)
        guard case .notify(let calm) = verdicts[3] else { return XCTFail("expected a notice") }
        let calmBody = StormWatchdogPolicy.alarmBody(for: calm, threshold: 0.03)
        XCTAssertTrue(calmBody.hasPrefix("The widget averaged 5.0% of a core over the last 8 min while idle (alarm threshold 3.0%)."), calmBody)
        XCTAssertTrue(calmBody.contains("No WindowServer storm signature"), calmBody)
        XCTAssertFalse(calmBody.contains("Quit"), "no quit advice without the signature")

        var storm = StormWatchdogPolicy(burnThreshold: 0.03)
        _ = run(&storm, 0.10, ticks: 3, from: 0, windows: 9, tracking: 12)
        guard case .notify(let grown) = storm.observe(sample(0.10, at: 6, windows: 11, tracking: 12)) else { return XCTFail("expected a notice") }
        XCTAssertEqual(grown.signature, StormWatchdogPolicy.Signature(windowsAtOpen: 9, windowsNow: 11, trackingAreasAtOpen: 12, trackingAreasNow: 12))
        XCTAssertTrue(grown.signature.detected)
        let stormBody = StormWatchdogPolicy.alarmBody(for: grown, threshold: 0.03)
        XCTAssertTrue(stormBody.contains("9 → 11 windows"), stormBody)
        XCTAssertTrue(stormBody.contains("Quit the widget, wait ~2 minutes, then relaunch"), stormBody)

        var churn = StormWatchdogPolicy(burnThreshold: 0.03)
        _ = run(&churn, 0.10, ticks: 3, from: 0, windows: 9, tracking: 12)
        guard case .notify(let leaked) = churn.observe(sample(0.10, at: 6, windows: 9, tracking: 40)) else { return XCTFail("expected a notice") }
        XCTAssertTrue(leaked.signature.detected, "tracking-area churn alone is the signature too")
    }

    /// Three clean samples close the episode and re-arm remediation and the
    /// notification; the next episode inside the 45-min floor is held until
    /// its banked burn reaches the 20-min override. Hot samples with the UI
    /// open pause instead of striking.
    func testCleanSamplesCloseTheEpisodeAndTheNextOneWaitsForFloorOrBankedBurn() throws {
        var policy = StormWatchdogPolicy(burnThreshold: 0.03)
        let first = run(&policy, 0.08, ticks: 4, from: 0)
        guard case .notify = first[3] else { return XCTFail("first episode notifies") }

        let clean = run(&policy, 0.01, ticks: 3, from: 8)
        XCTAssertEqual(clean, [.clean(episodeEnded: false), .clean(episodeEnded: false), .clean(episodeEnded: true)])
        XCTAssertNil(policy.episodeStartedAt)

        XCTAssertEqual(policy.observe(sample(0.08, at: 14, idle: false)), .pausedHot(paused: 1), "UI open: paused, not a strike")
        let second = run(&policy, 0.08, ticks: 4, from: 16)
        XCTAssertEqual(second[2], .remediate, "the episode's remediation is re-armed")
        guard case .gated(let reason) = second[3] else { return XCTFail("inside the 45-min floor with 8 min banked: held, got \(second[3])") }
        XCTAssertTrue(reason.hasPrefix("first-of-episode floor"), reason)

        // Six more hot samples bank the remaining 12 minutes → the override opens the gate.
        let banked = run(&policy, 0.08, ticks: 6, from: 24)
        guard case .notify(let notice) = banked.last else { return XCTFail("the cumulative override fires: \(String(describing: banked.last))") }
        XCTAssertTrue(notice.isFirstForEpisode)
        XCTAssertTrue(notice.gate.hasPrefix("first-of-episode, cumulative override"), notice.gate)
    }
}
