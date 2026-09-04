//
//  DashboardPreviewRenderTests.swift
//  Claude UsageTests
//
//  Renders the fleet dashboard for a realistic roster to a PNG so its layout
//  can be inspected frame by frame WITHOUT launching the app (the running
//  app is the owner's). Opt-in: set CUW_DASHBOARD_PREVIEW to an output path;
//  otherwise the test only asserts that the view hosts and lays out.
//

import AppKit
import SwiftUI
import XCTest
@testable import Claude_Usage

@MainActor
final class DashboardPreviewRenderTests: XCTestCase {
    private let now = Date()
    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)

    private func usage(session: Double = 0, weekly: Double = 0, fable: Double? = nil,
                       sessionWindow: Bool = true, age: TimeInterval = 28,
                       provenance: MeasurementProvenance? = nil, sessionElapsed: TimeInterval = 3600) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = now.addingTimeInterval(Constants.sessionWindow - sessionElapsed)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = now.addingTimeInterval(2 * 86400 + 3600)
        u.fableWeeklyPercentage = fable
        u.fableWeeklyResetTime = fable == nil ? nil : now.addingTimeInterval(2 * 86400 + 3600)
        u.hasSessionWindow = sessionWindow ? nil : false
        u.lastUpdated = now.addingTimeInterval(-age)
        u.provenance = provenance
        return u
    }

    private func claude(_ name: String, _ u: ClaudeUsage?, autoSwitch: Bool = true) -> Profile {
        Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org",
                claudeUsage: u, includeInAutoSwitch: autoSwitch)
    }

    private func codex(_ name: String, _ u: ClaudeUsage?) -> Profile {
        Profile(name: name, codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
                codexEmail: "\(name)@example.com", claudeUsage: u)
    }

    /// The owner's live shape on 2026-09-03, anonymised to the same labels.
    private func fixture() -> DashboardSnapshot {
        var suspected = usage(session: 67, weekly: 67, fable: 100, age: 780)
        suspected.rateLimitedUntil = now.addingTimeInterval(300)
        suspected.rateLimitedInferred = true
        suspected.projectedSessionPercentage = 81
        let rir = claude("dRir(Fenrir)", usage(session: 78, weekly: 16, fable: 16, sessionElapsed: 2 * 3600))
        let google = claude("Google", usage(session: 78, weekly: 16, fable: 16, age: 120), autoSwitch: false)
        let profiles = [
            claude("Memori", usage(weekly: 70, fable: 99)),
            claude("Stanford", usage(session: 100, weekly: 59, fable: 82, sessionElapsed: 1.8 * 3600)),
            claude("2010", usage(weekly: 39, fable: 53)),
            claude("Commits", suspected),
            claude("BBR", usage(weekly: 73, fable: 99, age: 400, provenance: .headerRescue)),
            claude("Ai", usage(weekly: 100, fable: 91)),
            claude("jskxkxjssh", usage(weekly: 23, fable: 28, age: 3 * 3600, provenance: .cliCache)),
            claude("dJormun", usage(weekly: 16, fable: 22)),
            claude("xFenrir(dev)", nil),
            rir, google,
            codex("Cod", usage(weekly: 60, sessionWindow: false)),
            codex("Dex", usage(weekly: 95, sessionWindow: false)),
            codex("xFernando(dev)", usage(weekly: 1, sessionWindow: false)),
            Profile(name: "Grok", grokCredentialsJSON: "{}", grokEmail: "g@example.com",
                    claudeUsage: usage(weekly: 19, sessionWindow: false)),
        ]
        let byName = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0) })
        let dead: Set<UUID> = [byName["Ai"]!.id, byName["Cod"]!.id, byName["Dex"]!.id]
        let jormun = byName["dJormun"]!
        let inputs = DashboardSnapshot.Inputs(
            profiles: profiles,
            activeIds: [rir.id, byName["xFernando(dev)"]!.id, byName["Grok"]!.id],
            focusedId: rir.id,
            context: FleetSummaryContext(
                thresholds: thresholds,
                isLoginDead: { dead.contains($0.id) },
                isExcluded: { !$0.isAutoSwitchEnabled },
                nextCandidates: [.claude: PredictedCandidate(id: jormun.id, label: "dJo", queued: false, queueHeadBlocked: false)],
                preflightVerdicts: [jormun.id: PreflightVerdict(isLive: true, at: now.addingTimeInterval(-720), kind: .probed)],
                preferencesDegraded: false, isSwitching: false, now: now
            ),
            queue: [byName["jskxkxjssh"]!.id],
            history: [
                SwitchEvent(at: now.addingTimeInterval(-6 * 3600), from: "Outlook", to: "BBR", trigger: .queued, reason: nil),
                SwitchEvent(at: now.addingTimeInterval(-40 * 60), from: "BBR", to: "dRir(Fenrir)", trigger: .auto, reason: "session 96 % / weekly 73 % crossed threshold"),
            ],
            duplicateGroups: [[google.id, rir.id]]
        )
        return DashboardSnapshot.build(inputs)
    }

    func testDashboardHostsAndRendersTheLiveShapedRoster() throws {
        let store = DashboardStore(snapshot: fixture(), clickedProvider: .claude)
        let actions = DashboardActions(refresh: {}, openSettings: { _ in },
                                       makeActive: { _ in .activated }, queueNext: { _ in }, removeFromQueue: { _ in })
        // A taller render shows the whole scroll content (Codex / Grok
        // sections, recent switches) for inspection.
        let height = ProcessInfo.processInfo.environment["CUW_DASHBOARD_PREVIEW_HEIGHT"].flatMap(Double.init)
            ?? DashboardSurface.dashboardSize.height
        let host = NSHostingView(rootView: DashboardView(store: store, actions: actions, height: height))
        host.frame = NSRect(x: 0, y: 0, width: DashboardSurface.dashboardSize.width, height: height)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, DashboardSurface.dashboardSize.width)

        guard let path = ProcessInfo.processInfo.environment["CUW_DASHBOARD_PREVIEW"], !path.isEmpty else { return }
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        _ = scale
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
