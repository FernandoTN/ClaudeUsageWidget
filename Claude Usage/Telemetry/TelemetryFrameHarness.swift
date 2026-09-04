//
//  TelemetryFrameHarness.swift
//  Claude Usage
//
//  DEBUG-only: renders the token-usage window's states from fixture data to
//  `telemetry-<state>-<light|dark>@2x.png` plus a section in the shared
//  `index.md`, so the pixel pass can review a menu-bar agent's window without
//  screenshots. Honoured when `CUW_RENDER_FRAMES=<dir>` is set on a Debug
//  build (also runnable from the test target); never compiled into Release.
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum TelemetryFrameHarness {
    static let size = CGSize(width: 1040, height: 680)

    static func runIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["CUW_RENDER_FRAMES"], !dir.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { renderAll(to: URL(fileURLWithPath: dir)) }
    }

    /// Every state the design pass names (spec §3.2 "States").
    static func renderAll(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var index: [String] = []
        let now = Fixture.now
        let input = Fixture.input(now: now)
        let status = Fixture.status(now: now)
        let sections = TelemetryWindowModel.sidebar(fleet: report(.fleet, .days7, input: input, now: now), profiles: Fixture.sidebarProfiles)

        func frame(_ name: String, scope: TelemetryScope, window: TelemetryWindow = .days7, metric: TelemetryMetric = .inputClass,
                   report: TelemetryReport?, status: IndexingStatus = status, paused: Bool = false, title: String? = nil) {
            let view = TelemetryFrameView(
                sections: sections, selection: .constant(scope), report: report, status: status, isLoading: false, isPaused: paused,
                // (bindings are constant: the harness renders one state per frame)
                scopeTitle: title ?? scopeTitle(scope), window: .constant(window), metric: .constant(metric),
                owners: Set(Fixture.sidebarProfiles.filter(\.isOwner).map(\.id)), actions: TelemetryActions())
            emit(view, name: "telemetry-\(name)", to: dir, index: &index)
        }

        frame("fleet-7d", scope: .fleet, report: report(.fleet, .days7, input: input, now: now))
        frame("fleet-30d", scope: .fleet, window: .days30, report: report(.fleet, .days30, input: Fixture.input(now: now, days: 30), now: now))
        frame("codex-30d-outlier", scope: .provider(.codex), window: .days30, report: report(.provider(.codex), .days30, input: Fixture.inputWithOutlier(now: now), now: now))
        frame("fleet-today", scope: .fleet, window: .today, report: report(.fleet, .today, input: input, now: now))
        frame("fleet-by-kind", scope: .fleet, metric: .inputByKind, report: report(.fleet, .days7, metric: .inputByKind, input: input, now: now))
        frame("fleet-cost", scope: .fleet, metric: .cost, report: report(.fleet, .days7, metric: .cost, input: input, now: now))
        frame("provider-claude", scope: .provider(.claude), report: report(.provider(.claude), .days7, input: input, now: now))
        frame("provider-codex", scope: .provider(.codex), report: report(.provider(.codex), .days7, input: input, now: now))
        frame("account-attributed", scope: .account(Fixture.dRir), report: report(.account(Fixture.dRir), .days7, input: input, now: now))
        frame("unattributed-codex", scope: .unattributed(.codex), report: report(.unattributed(.codex), .days7, input: input, now: now))
        frame("indexing", scope: .fleet, report: nil, status: Fixture.indexingStatus(now: now))
        frame("empty", scope: .account(Fixture.dLeo), report: report(.account(Fixture.dLeo), .days7, input: input, now: now))
        frame("paused", scope: .fleet, report: report(.fleet, .days7, input: input, now: now), status: Fixture.status(now: now, paused: true), paused: true)
        frame("degraded", scope: .fleet, report: nil, status: IndexingStatus())

        let indexURL = dir.appendingPathComponent("index.md")
        var existing = (try? String(contentsOf: indexURL, encoding: .utf8)) ?? ""
        if let range = existing.range(of: "\n## Token usage window") { existing = String(existing[..<range.lowerBound]) }
        let header = existing.isEmpty ? ["# Design frames", "", "Rendered by `CUW_RENDER_FRAMES` (Debug build) at 2x, light and dark.", ""].joined(separator: "\n") : existing
        let section = (["", "## Token usage window (telemetry)", "", "Fixture data: 7 days, three providers, dRir → dJormun switch two days ago at noon, a Codex outlier day in the 30-day set.", ""] + index).joined(separator: "\n")
        try? header.appending(section).write(to: indexURL, atomically: true, encoding: .utf8)
        LoggingService.shared.log("TelemetryFrameHarness: wrote \(index.count) frames to \(dir.path)")
    }

    static func report(_ scope: TelemetryScope, _ window: TelemetryWindow, metric: TelemetryMetric = .inputClass,
                       input: TelemetryReportBuilder.Input, now: Date) -> TelemetryReport {
        TelemetryReportBuilder.build(query: TelemetryQuery(scope: scope, window: window, metric: metric, now: now, calendar: Fixture.calendar), input: input)
    }

    private static func scopeTitle(_ scope: TelemetryScope) -> String {
        switch scope {
        case .fleet: return "Fleet"
        case .provider(let p): return TelemetryReportBuilder.providerLabel(p)
        case .account(let id): return Fixture.sidebarProfiles.first { $0.id == id }?.name ?? "Account"
        case .unattributed(let p): return "Unattributed · \(TelemetryReportBuilder.providerLabel(p))"
        }
    }

    private static func emit<V: View>(_ view: V, name: String, to dir: URL, index: inout [String]) {
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "light" : "dark"
            let file = "\(name)-\(suffix)@2x.png"
            let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
            renderer.scale = 2
            guard let cg = renderer.cgImage else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(file))
                index.append("- `\(file)`")
            }
        }
    }

    // MARK: - Fixture

    enum Fixture {
        static let calendar: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            return c
        }()
        static let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 16, minute: 4))!
        static let dRir = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        static let dJormun = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        static let dLeo = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        static let xFenrir = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        static let xLucifer = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        static let grok = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!

        static let roster: [ProfileSummary] = [
            ProfileSummary(id: dRir, name: "dRir", provider: .claude, accountStamp: "a"),
            ProfileSummary(id: dJormun, name: "dJormun", provider: .claude, accountStamp: "b"),
            ProfileSummary(id: dLeo, name: "dLeo", provider: .claude, accountStamp: "c"),
            ProfileSummary(id: xFenrir, name: "xFenrir(dev)", provider: .codex, accountStamp: "d", codexHomeSlug: "xfenrir-dev"),
            ProfileSummary(id: xLucifer, name: "xLucifer(dev)", provider: .codex, accountStamp: "e"),
            ProfileSummary(id: grok, name: "GROK", provider: .grok, accountStamp: "f"),
        ]

        static let sidebarProfiles: [TelemetrySidebarProfile] = [
            TelemetrySidebarProfile(id: dRir, name: "dRir", provider: .claude, isOwner: false),
            TelemetrySidebarProfile(id: dJormun, name: "dJormun", provider: .claude, isOwner: true),
            TelemetrySidebarProfile(id: dLeo, name: "dLeo", provider: .claude, isOwner: false),
            TelemetrySidebarProfile(id: xFenrir, name: "xFenrir(dev)", provider: .codex, isOwner: true),
            TelemetrySidebarProfile(id: xLucifer, name: "xLucifer(dev)", provider: .codex, isOwner: false),
            TelemetrySidebarProfile(id: grok, name: "GROK", provider: .grok, isOwner: true),
        ]

        static func day(_ offset: Int, _ hour: Int, now: Date) -> Date {
            calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!.addingTimeInterval(Double(hour) * 3_600)
        }

        static func aggregate(_ provider: TelemetryProvider, _ model: String, at: Date, input: Int, cacheRead: Int, cacheWrite: Int = 0,
                              output: Int, units: Int, source: String? = nil, sidechain: Bool = false, costNano: Int = 0) -> MinuteAggregate {
            var totals = TokenTotals()
            totals.units = units; totals.input = input; totals.cacheRead = cacheRead; totals.cacheWrite = cacheWrite
            totals.cacheWrite1h = cacheWrite; totals.output = output; totals.reasoning = output * 3 / 10
            totals.costNanoUSD = costNano; totals.sidechainUnits = sidechain ? units : 0
            return MinuteAggregate(provider: provider, model: model, source: source, sidechain: sidechain, minute: at, totals: totals)
        }

        /// Seven days shaped like the census (Claude ~11 B/day input-class, 97 %
        /// cache reads; Codex ~100 M; Grok ~30 M), a switch two days ago at noon.
        static func input(now: Date, days: Int = 7) -> TelemetryReportBuilder.Input {
            let ownership = [
                OwnershipRecord(at: day(days + 20, 0, now: now), provider: .claude, profileId: dRir, previousProfileId: nil, accountStamp: "a", name: "dRir", basis: .exactClaim, cause: "activate"),
                OwnershipRecord(at: day(2, 12, now: now), provider: .claude, profileId: dJormun, previousProfileId: dRir, accountStamp: "b", name: "dJormun", basis: .exactClaim, cause: "activate"),
                OwnershipRecord(at: day(days + 20, 0, now: now), provider: .codex, profileId: xLucifer, previousProfileId: nil, accountStamp: "e", name: "xLucifer(dev)", basis: .observedAtTick, cause: nil),
                OwnershipRecord(at: day(4, 9, now: now), provider: .codex, profileId: xFenrir, previousProfileId: xLucifer, accountStamp: "d", name: "xFenrir(dev)", basis: .observedAtTick, cause: nil),
            ]
            let claudeShape: [Double] = [0.58, 1.39, 1.43, 0.56, 1.26, 1.92, 1.08, 0.19]
            var aggregates: [MinuteAggregate] = []
            for offset in (0...(days - 1)).reversed() {
                let factor = claudeShape[(days - 1 - offset) % claudeShape.count]
                for hour in stride(from: 8, through: 20, by: 4) {
                    let scale = factor * (hour == 12 ? 1.4 : 1.0)
                    aggregates.append(aggregate(.claude, "claude-opus-5", at: day(offset, hour, now: now), input: Int(400 * scale), cacheRead: Int(2_400_000_000 * scale), cacheWrite: Int(80_000_000 * scale), output: Int(3_100_000 * scale), units: Int(3_900 * scale)))
                    aggregates.append(aggregate(.claude, "claude-fable-5", at: day(offset, hour + 1, now: now), input: Int(100 * scale), cacheRead: Int(480_000_000 * scale), cacheWrite: Int(20_000_000 * scale), output: Int(900_000 * scale), units: Int(700 * scale), sidechain: true))
                    aggregates.append(aggregate(.claude, "claude-sonnet-5", at: day(offset, hour + 2, now: now), input: Int(60 * scale), cacheRead: Int(120_000_000 * scale), output: Int(400_000 * scale), units: Int(600 * scale), sidechain: true))
                    aggregates.append(aggregate(.codex, "gpt-5.6-sol", at: day(offset, hour, now: now), input: Int(900_000 * scale), cacheRead: Int(24_000_000 * scale), output: Int(90_000 * scale), units: Int(600 * scale), source: offset % 3 == 0 ? "xfenrir-dev" : ".codex"))
                    aggregates.append(aggregate(.grok, "grok-4.6-build", at: day(offset, hour + 3, now: now), input: Int(1_600_000 * scale), cacheRead: Int(7_000_000 * scale), output: Int(160_000 * scale), units: Int(8 * scale), source: "ClaudeUsageWidget", costNano: Int(13_000_000_000 * scale)))
                }
            }
            aggregates = aggregates.filter { $0.minute <= now }
            let previous = aggregates.map { a in
                var copy = a; copy.minute = calendar.date(byAdding: .day, value: -days, to: a.minute)!
                copy.totals.input = a.totals.input * 2 / 3; copy.totals.cacheRead = a.totals.cacheRead * 2 / 3
                copy.totals.output = a.totals.output * 9 / 10; copy.totals.costNanoUSD = a.totals.costNanoUSD * 2 / 3
                return copy
            }
            return TelemetryReportBuilder.Input(
                aggregates: aggregates, previousAggregates: previous, ownership: ownership, roster: roster,
                health: [ProviderHealth(provider: .claude, scannedAt: now.addingTimeInterval(-12), dataThrough: now.addingTimeInterval(-40), filesSeen: 12_565),
                         ProviderHealth(provider: .codex, scannedAt: now.addingTimeInterval(-12), dataThrough: now.addingTimeInterval(-400), filesSeen: 1_243),
                         ProviderHealth(provider: .grok, scannedAt: now.addingTimeInterval(-12), dataThrough: now.addingTimeInterval(-3_000), filesSeen: 1_542)],
                codexSessions: 148, firstIndexedAt: day(1, 0, now: now))
        }

        static func inputWithOutlier(now: Date) -> TelemetryReportBuilder.Input {
            var input = self.input(now: now, days: 30)
            input.aggregates.append(aggregate(.codex, "gpt-5.6-sol", at: day(17, 11, now: now), input: 2_000_000_000, cacheRead: 33_000_000_000, output: 40_000_000, units: 159_000, source: ".codex"))
            return input
        }

        static func status(now: Date, paused: Bool = false) -> IndexingStatus {
            IndexingStatus(ledgerAvailable: true, isCatchingUp: false, isPaused: paused, filesSeen: 15_350, backlogFiles: 0, backlogBytes: 0,
                           eventCount: 1_261_884, storageBytes: 302_000_000, scannedAt: now.addingTimeInterval(-12),
                           dataThrough: [.claude: now.addingTimeInterval(-40), .codex: now.addingTimeInterval(-400), .grok: now.addingTimeInterval(-3_000)])
        }

        static func indexingStatus(now: Date) -> IndexingStatus {
            IndexingStatus(ledgerAvailable: true, isCatchingUp: true, isPaused: false, filesSeen: 15_350, backlogFiles: 9_056, backlogBytes: 16_400_000_000,
                           eventCount: 412_000, storageBytes: 98_000_000, scannedAt: now.addingTimeInterval(-1), dataThrough: [.claude: now.addingTimeInterval(-3_600)])
        }
    }
}
#endif
