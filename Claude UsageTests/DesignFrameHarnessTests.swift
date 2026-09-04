//
//  DesignFrameHarnessTests.swift
//  Claude UsageTests
//
//  Renders the design-pass frames inside the test host — which never sets up
//  the menu bar — so a review needs no second instance of the app:
//
//      TEST_RUNNER_CUW_RENDER_FRAMES=/tmp/cuw-frames xcodebuild test \
//          -scheme "Claude Usage" -destination 'platform=macOS' \
//          -only-testing:"Claude UsageTests/DesignFrameHarnessTests"
//
//  Without the variable the test only checks that the fixture roster builds.
//

import XCTest
@testable import Claude_Usage

@MainActor
final class DesignFrameHarnessTests: XCTestCase {
    func testFixtureCoversEveryStateAndRendersWhenRequested() throws {
        #if DEBUG
        let selections = DesignFrameHarness.Fixture.selections(degraded: false, now: Date())
        let claude = selections.first { $0.provider == .claude }!
        let states = Set(claude.candidates.map(\.readiness)) .union([claude.owner?.readiness ?? .unknown])
        XCTAssertTrue(states.isSuperset(of: [.ready, .exhausted, .dead, .suspected, .unknown, .excluded]),
                      "the fixture must exercise every readiness state: \(states)")
        XCTAssertTrue(claude.candidates.contains { if case .duplicateOfOwner = $0.status { return true }; return false })
        XCTAssertNotNil(selections.first { $0.provider == .codex }?.owner?.resetCreditsAvailable)

        if let dir = ProcessInfo.processInfo.environment["CUW_RENDER_FRAMES"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            DesignFrameHarness.renderAll(to: url)
            let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            XCTAssertTrue(files.contains("index.md"))
            XCTAssertTrue(files.contains("selector-menu-healthy-dark@2x.png"), files.joined(separator: ", "))
            XCTAssertTrue(files.contains("accounts-overview-suspected-light@2x.png"))
        }
        #endif
    }
}
