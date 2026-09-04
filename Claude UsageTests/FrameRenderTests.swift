//
//  FrameRenderTests.swift
//  Claude UsageTests
//
//  The fixture half of the frame harness for the owner's pixel pass: every
//  state of the redesign's surfaces rendered to PNG at the screen's scale,
//  in light AND dark, without launching the app (the running app is the
//  owner's). Opt-in: `TEST_RUNNER_CUW_RENDER_FRAMES=<dir>` on xcodebuild
//  test; otherwise the test only asserts that the views host. Files:
//  `<surface>-<state>-<light|dark>@2x.png` plus `index.md`. The live half
//  (bar composites as painted, the popover for the real roster) is the
//  DEBUG app's `CUW_RENDER_FRAMES` (MenuBarManager).
//

import AppKit
import SwiftUI
import XCTest
@testable import Claude_Usage

@MainActor
final class FrameRenderTests: XCTestCase {
    private let now = Date()
    private let thresholds = ReadinessThresholds(session: 95, weekly: 99)
    private var index: [String] = []
    private var outputDir: URL?

    // MARK: Fixtures

    private func usage(session: Double = 0, weekly: Double = 0, fable: Double? = nil, sessionWindow: Bool = true,
                       age: TimeInterval = 28, provenance: MeasurementProvenance? = nil) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.sessionResetTime = now.addingTimeInterval(Constants.sessionWindow - 3600)
        u.weeklyPercentage = weekly
        u.weeklyResetTime = now.addingTimeInterval(2 * 86400 + 3600)
        u.fableWeeklyPercentage = fable
        u.fableWeeklyResetTime = fable == nil ? nil : now.addingTimeInterval(2 * 86400 + 3600)
        u.hasSessionWindow = sessionWindow ? nil : false
        u.lastUpdated = now.addingTimeInterval(-age)
        u.provenance = provenance
        return u
    }

    private func claude(_ name: String, _ u: ClaudeUsage?, autoSwitch: Bool = true, account: String? = nil) -> Profile {
        var p = Profile(name: name, claudeSessionKey: "sk-ant-sid01-test", organizationId: "org",
                        claudeUsage: u, includeInAutoSwitch: autoSwitch)
        p.claudeAccountUUID = account
        return p
    }

    private func codex(_ name: String, _ u: ClaudeUsage?) -> Profile {
        Profile(name: name, codexCredentialsJSON: "{\"tokens\":{\"access_token\":\"x\"}}",
                codexEmail: "\(name)@example.com", claudeUsage: u)
    }

    /// Every roster state the dashboard renders: owner, next, queued, dead,
    /// suspected, weekly-maxed, duplicate, CLI-cache, header-rescue,
    /// unmeasured, auto-switch off; Codex with no candidate; single Grok.
    private func snapshot(degraded: Bool = false, hidden: Set<Profile.ProviderKind> = []) -> DashboardSnapshot {
        var suspected = usage(session: 67, weekly: 67, fable: 100, age: 780)
        suspected.rateLimitedUntil = now.addingTimeInterval(300)
        suspected.rateLimitedInferred = true
        suspected.projectedSessionPercentage = 81
        let owner = claude("dRir(Fenrir)", usage(session: 78, weekly: 16, fable: 16), account: "acct-1")
        let twin = claude("Google", usage(session: 78, weekly: 16, fable: 16, age: 120), autoSwitch: false, account: "acct-1")
        let next = claude("dJormun", usage(weekly: 16, fable: 22))
        let queued = claude("jskxkxjssh", usage(weekly: 23, fable: 28, age: 3 * 3600, provenance: .cliCache))
        let dead = claude("Ai", usage(weekly: 100, fable: 91))
        let profiles = [
            claude("Memori", usage(weekly: 70, fable: 99)),
            claude("Stanford", usage(session: 100, weekly: 59, fable: 82)),
            claude("Commits", suspected),
            claude("BBR", usage(weekly: 73, fable: 99, age: 400, provenance: .headerRescue)),
            claude("xFenrir(dev)", nil),
            dead, queued, next, owner, twin,
            codex("Cod", usage(weekly: 60, sessionWindow: false)),
            codex("Dex", usage(weekly: 95, sessionWindow: false)),
            codex("xFernando(dev)", usage(weekly: 1, sessionWindow: false)),
            Profile(name: "Grok", grokCredentialsJSON: "{}", grokEmail: "g@example.com",
                    claudeUsage: usage(weekly: 19, sessionWindow: false)),
        ]
        let byName = Dictionary(uniqueKeysWithValues: profiles.map { ($0.name, $0) })
        let deadIds: Set<UUID> = [dead.id, byName["Cod"]!.id, byName["Dex"]!.id]
        return DashboardSnapshot.build(DashboardSnapshot.Inputs(
            profiles: profiles,
            activeIds: [owner.id, byName["xFernando(dev)"]!.id, byName["Grok"]!.id],
            focusedId: next.id,
            context: FleetSummaryContext(
                thresholds: thresholds,
                isLoginDead: { deadIds.contains($0.id) },
                isExcluded: { !$0.isAutoSwitchEnabled },
                nextCandidates: [.claude: PredictedCandidate(id: next.id, label: "dJo", queued: false, queueHeadBlocked: false)],
                preflightVerdicts: [next.id: PreflightVerdict(isLive: true, at: now.addingTimeInterval(-720), kind: .probed)],
                preferencesDegraded: degraded, isSwitching: false, now: now
            ),
            queue: [queued.id],
            history: [SwitchEvent(at: now.addingTimeInterval(-40 * 60), from: "BBR", to: "dRir(Fenrir)", trigger: .auto,
                                  reason: "session 96 % / weekly 73 % crossed threshold")],
            hiddenProviders: hidden,
            duplicateGroups: [[twin.id, owner.id]],
            manuallyPinned: [owner.id],
            needsRelogin: [dead.id]
        ))
    }

    private func fleet(members: Int, ready: Int, dead: Int, next: NextCandidate?, keyed: Double,
                       stale: Bool = false) -> ProviderSummary {
        let ids = (0..<members).map { _ in UUID() }
        var readiness: [UUID: AccountReadiness] = [:]
        for (i, id) in ids.enumerated() {
            readiness[id] = i < ready ? .ready : (i < ready + dead ? .dead : .exhausted)
        }
        return ProviderSummary.build(
            provider: .claude, orderedMembers: ids, activeId: ids[0], readiness: readiness,
            stale: stale ? Set(ids) : [], keyedPercentage: keyed, next: next,
            preferencesDegraded: false, activeLastMeasured: now.addingTimeInterval(stale ? -900 : -20), now: now
        )
    }

    // MARK: Writing

    private func write<V: View>(_ view: V, surface: String, state: String, size: NSSize, note: String) {
        guard let dir = outputDir else { return }
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            let name = "\(surface)-\(state)-\(mode)@2x.png"
            if let png = rep.representation(using: .png, properties: [:]),
               (try? png.write(to: dir.appendingPathComponent(name))) != nil {
                index.append("- `\(name)` — \(note)")
            }
        }
    }

    /// Bar images are white-on-transparent (the bar is always painted dark);
    /// they go onto a menu-bar grey so the PNG shows what the bar shows.
    private func write(_ image: NSImage, surface: String, state: String, note: String) {
        guard let dir = outputDir else { return }
        let scale: CGFloat = 2
        let size = image.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        let name = "\(surface)-\(state)-dark@2x.png"
        if let png = rep.representation(using: .png, properties: [:]),
           (try? png.write(to: dir.appendingPathComponent(name))) != nil {
            index.append("- `\(name)` — \(note)")
        }
    }

    // MARK: The pass

    func testRendersEveryStateOfTheRedesignSurfaces() throws {
        if let dir = ProcessInfo.processInfo.environment["CUW_RENDER_FRAMES"], !dir.isEmpty {
            outputDir = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: outputDir!, withIntermediateDirectories: true)
        }
        let noActions = DashboardActions(refresh: {}, openSettings: { _ in }, makeActive: { _ in .activated },
                                         queueNext: { _ in }, removeFromQueue: { _ in })
        let width = DashboardSurface.dashboardSize.width
        let tall = NSSize(width: width, height: 1500)

        // Dashboard: default, degraded banner, overflow banner, single-account detail.
        let snap = snapshot()
        let host = NSHostingView(rootView: DashboardView(store: DashboardStore(snapshot: snap, clickedProvider: .claude), actions: noActions, height: 1500))
        host.frame = NSRect(origin: .zero, size: tall)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, width)
        write(DashboardView(store: DashboardStore(snapshot: snap, clickedProvider: .claude), actions: noActions, height: 1500),
              surface: "dashboard", state: "fleet", size: tall,
              note: "fleet: Claude (viewing dJormun, owner pinned, duplicate Google, next, queued, dead + re-login, suspected, CLI cache, header rescue, unmeasured, auto-switch off), Codex (nowhere to switch), Grok (single)")
        write(DashboardView(store: DashboardStore(snapshot: snapshot(degraded: true), clickedProvider: .claude), actions: noActions, height: 600),
              surface: "dashboard", state: "degraded", size: NSSize(width: width, height: 600), note: "preferences-degraded banner outranking the rest")
        write(DashboardView(store: DashboardStore(snapshot: snapshot(hidden: [.codex]), clickedProvider: .codex), actions: noActions, height: 600),
              surface: "dashboard", state: "overflow", size: NSSize(width: width, height: 600), note: "Codex hidden by the menu bar (banner), scrolled to Codex")
        // The Insights block in situ, expanded, from the stage-4a fixture
        // (the block's own frames are the UX-revamp harness's).
        var withInsights = snap
        withInsights.insights = FleetInsights.fixture(now: now)
        let tallWithInsights = NSSize(width: width, height: 2400)
        write(DashboardView(store: DashboardStore(snapshot: withInsights, clickedProvider: .claude), actions: noActions,
                            height: tallWithInsights.height, insightsExpanded: true),
              surface: "dashboard", state: "insights-embedded", size: tallWithInsights,
              note: "fleet with the INSIGHTS block expanded under the last section (fixture insights)")

        // The classic popover's Make-active row: offer, confirmation, dead confirmation, outcome.
        let rowSize = NSSize(width: DashboardSurface.size(for: .classic).width - 20, height: 140)
        let ownerHeadline = "78 % session · resets in 2h 59m"
        let steps: [(String, MakeActiveRow, String)] = [
            ("offer", MakeActiveRow(name: "dJormun", provider: .claude, ownerName: "dRir(Fenrir)", ownerHeadline: ownerHeadline,
                                    headline: "0 % session · resets in 4h", loginDead: false, isPending: false, note: nil,
                                    onBegin: {}, onConfirm: {}, onCancel: {}), "the offer on a viewed non-owner, owner named"),
            ("confirm", MakeActiveRow(name: "dJormun", provider: .claude, ownerName: "dRir(Fenrir)", ownerHeadline: ownerHeadline,
                                      headline: "0 % session · resets in 4h", loginDead: false, isPending: true, note: nil,
                                      onBegin: {}, onConfirm: {}, onCancel: {}), "confirmation: from / to lines with headroom, cost"),
            ("confirm-dead", MakeActiveRow(name: "Ai", provider: .claude, ownerName: "dRir(Fenrir)", ownerHeadline: ownerHeadline,
                                           headline: "0 % session", loginDead: true, isPending: true, note: nil,
                                           onBegin: {}, onConfirm: {}, onCancel: {}), "confirmation on a dead login: Log in first disabled, Cancel default"),
            ("outcome", MakeActiveRow(name: "dJormun", provider: .codex, ownerName: nil, loginDead: false, isPending: false,
                                      note: DashboardFormatting.outcome(.activated, name: "dJormun", provider: .codex), succeeded: true,
                                      onBegin: {}, onConfirm: {}, onCancel: {}), "state after a successful switch — no action label"),
            ("refused", MakeActiveRow(name: "Ai", provider: .claude, ownerName: "dRir(Fenrir)", loginDead: true, isPending: false,
                                      note: DashboardFormatting.outcome(.credentialsRefused, name: "Ai", provider: .claude),
                                      onBegin: {}, onConfirm: {}, onCancel: {}), "after a refused switch — the offer stays"),
        ]
        for (state, row, note) in steps {
            write(row.padding(10), surface: "makeactive", state: state, size: rowSize, note: note)
        }

        // Fleet blocks (the bar's new element) for both fleet layouts.
        let renderer = MenuBarIconRenderer()
        let verified = NextCandidate(id: UUID(), label: "dJo", queued: false, queueHeadBlocked: false, readiness: .ready, verdict: .verified)
        let blockedQueue = NextCandidate(id: UUID(), label: "jsk", queued: true, queueHeadBlocked: true, readiness: .ready, verdict: .unverified)
        let blocks: [(String, ProviderSummary, MenuBarLayout, String)] = [
            ("dots-armed", fleet(members: 12, ready: 4, dead: 1, next: verified, keyed: 78), .fleetDots, "12 accounts, armed, → dJo ✓"),
            ("dots-queue-blocked", fleet(members: 12, ready: 4, dead: 1, next: blockedQueue, keyed: 78), .fleetDots, "queue head blocked (red Q)"),
            ("dots-nobody", fleet(members: 6, ready: 0, dead: 2, next: nil, keyed: 91), .fleetDots, "nobody with headroom (→—)"),
            ("dots-overflow", fleet(members: 25, ready: 9, dead: 3, next: verified, keyed: 40), .fleetDots, "25 accounts: two dot rows + overflow +N"),
            ("dots-stale", fleet(members: 12, ready: 4, dead: 1, next: verified, keyed: 78, stale: true), .fleetDots, "every reading stale (dimmed)"),
            ("counts-armed", fleet(members: 12, ready: 4, dead: 1, next: verified, keyed: 78), .fleetCounts, "counts row, armed"),
            ("counts-nobody", fleet(members: 6, ready: 0, dead: 2, next: nil, keyed: 91), .fleetCounts, "counts row, nobody with headroom"),
        ]
        for (state, summary, layout, note) in blocks {
            let height = FleetBlockGeometry.blockHeight(activeHeight: 22, memberCount: summary.members.count, layout: layout)
            var block: NSImage?
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                block = renderer.createFleetBlock(summary: summary, layout: layout, height: height)
            }
            let image = try XCTUnwrap(block)
            XCTAssertGreaterThan(image.size.width, 0)
            write(image, surface: "fleet", state: state, note: note)
        }

        guard let dir = outputDir else { return }
        let text = (["# Frames — fixture half — \(now)", "", "Light and dark for every SwiftUI surface; bar elements on menu-bar grey.", ""] + index)
            .joined(separator: "\n")
        try text.write(to: dir.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }
}
