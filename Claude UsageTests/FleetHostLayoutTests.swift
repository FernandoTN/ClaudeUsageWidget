import XCTest
@testable import Claude_Usage

/// The fleet item's host layout: every provider strip side by side in the
/// intended bar order, the hosted ⇄ at the right end, gaps split down the
/// middle so each x resolves to exactly one segment.
final class FleetHostLayoutTests: XCTestCase {

    private let widths: [Profile.ProviderKind: CGFloat] = [.claude: 96, .grok: 29, .codex: 54]

    func testThreeProvidersAndSelectorLayOutCodexGrokClaudeSelector() {
        let layout = StatusBarUIManager.hostLayout(widths: widths, selectorWidth: 24, gap: 6)
        XCTAssertEqual(layout.order, [.codex, .grok, .claude])
        XCTAssertEqual(layout.origins[.codex], 0)
        XCTAssertEqual(layout.origins[.grok], 60)
        XCTAssertEqual(layout.origins[.claude], 95)
        XCTAssertEqual(layout.selectorOrigin, 197)
        XCTAssertEqual(layout.totalWidth, 221)
    }

    func testRangesSplitTheGapsAndCoverTheWholeImage() {
        let layout = StatusBarUIManager.hostLayout(widths: widths, selectorWidth: 24, gap: 6)
        XCTAssertEqual(layout.ranges[.codex], 0..<57)
        XCTAssertEqual(layout.ranges[.grok], 57..<92)
        XCTAssertEqual(layout.ranges[.claude], 92..<194)
        XCTAssertEqual(layout.selectorRange, 194..<221)
    }

    func testSingleProviderWithoutSelectorIsTheStripItself() {
        let layout = StatusBarUIManager.hostLayout(widths: [.claude: 96], selectorWidth: nil)
        XCTAssertEqual(layout.order, [.claude])
        XCTAssertEqual(layout.origins[.claude], 0)
        XCTAssertEqual(layout.ranges[.claude], 0..<96)
        XCTAssertEqual(layout.totalWidth, 96)
        XCTAssertNil(layout.selectorOrigin)
        XCTAssertNil(layout.selectorRange)
    }

    func testAbsentProvidersAreSkippedAndWidthsRoundToWholePoints() {
        let layout = StatusBarUIManager.hostLayout(widths: [.claude: 95.6, .codex: 54.2], selectorWidth: nil, gap: 6)
        XCTAssertEqual(layout.order, [.codex, .claude])
        XCTAssertEqual(layout.origins[.codex], 0)
        XCTAssertEqual(layout.origins[.claude], 60)
        XCTAssertEqual(layout.totalWidth, 156)
        XCTAssertNil(layout.origins[.grok])
    }

    func testSelectorAloneLaysOutAtZero() {
        let layout = StatusBarUIManager.hostLayout(widths: [:], selectorWidth: 24)
        XCTAssertTrue(layout.order.isEmpty)
        XCTAssertEqual(layout.selectorOrigin, 0)
        XCTAssertEqual(layout.selectorRange, 0..<24)
        XCTAssertEqual(layout.totalWidth, 24)
    }

    func testNothingToHostIsEmpty() {
        let layout = StatusBarUIManager.hostLayout(widths: [:], selectorWidth: nil)
        XCTAssertEqual(layout, StatusBarUIManager.HostLayout())
    }
}
