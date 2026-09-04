//
//  TelemetryWindowModel.swift
//  Claude Usage
//
//  The window's one state model (spec §3.2): a scope (the sidebar selection
//  IS the deep link), a time window, a metric, the current report and the
//  indexer's status. Loads run on the telemetry queue and land here on the
//  main actor; the sidebar is derived from the Fleet report of the same
//  window so its totals agree with the pane. Selecting a row is a SCOPE —
//  it never calls `viewProfile` or activates anything.
//

import AppKit
import Combine
import Foundation

nonisolated struct IndexingStatus: Sendable, Equatable {
    var ledgerAvailable = false
    var isCatchingUp = false
    var isPaused = false
    var filesSeen = 0
    var backlogFiles = 0
    var backlogBytes: Int64 = 0
    var eventCount = 0
    var storageBytes: Int64 = 0
    var scannedAt: Date?
    var dataThrough: [TelemetryProvider: Date] = [:]

    /// 0…1 while catching up, from files done over files known.
    var progress: Double {
        guard filesSeen > 0 else { return 0 }
        return max(0, min(1, Double(filesSeen - backlogFiles) / Double(filesSeen)))
    }
}

struct TelemetrySidebarRow: Identifiable, Equatable {
    var id: String
    var scope: TelemetryScope
    var title: String
    var provider: TelemetryProvider?
    /// The cyan Cl/Cx/Gk mark — the bar's convention for the current owner only.
    var isOwner: Bool
    /// nil until the ownership log covers the window ("—" in the sidebar).
    var total: Int?
    var indent: Bool
}

struct TelemetrySidebarSection: Identifiable, Equatable {
    var id: String
    var title: String
    var count: Int?
    var rows: [TelemetrySidebarRow]
}

struct TelemetrySidebarProfile: Equatable {
    var id: UUID
    var name: String
    var provider: TelemetryProvider
    var isOwner: Bool
}

final class TelemetryWindowModel: ObservableObject {
    @Published var scope: TelemetryScope = .fleet { didSet { if scope != oldValue { reload() } } }
    @Published var window: TelemetryWindow = .days7 { didSet { if window != oldValue { reload() } } }
    @Published var metric: TelemetryMetric = .inputClass { didSet { if metric != oldValue { reload() } } }
    @Published private(set) var report: TelemetryReport?
    @Published private(set) var fleetReport: TelemetryReport?
    @Published private(set) var status = IndexingStatus()
    @Published private(set) var sidebar: [TelemetrySidebarSection] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isPaused = false
    @Published private(set) var lastLoaded: Date?

    private let service: TelemetryService
    private let profileManager: ProfileManager
    private var observers: [NSObjectProtocol] = []
    private var reloadScheduled = false
    private var generation = 0
    /// Reloads only run while the window is on screen; a closed window that
    /// kept re-querying the ledger every slice would be the orphan-window
    /// pattern the Settings window once had.
    private var isVisible = false

    func setVisible(_ visible: Bool) {
        isVisible = visible
    }

    init(service: TelemetryService = .shared, profileManager: ProfileManager = .shared) {
        self.service = service
        self.profileManager = profileManager
        observers.append(NotificationCenter.default.addObserver(forName: .telemetryLedgerUpdated, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload(after: 2) }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: - Intents

    func select(_ scope: TelemetryScope) { self.scope = scope }

    func refreshNow() {
        service.refreshNow()
        scheduleReload(after: 1.5)
    }

    func togglePaused() {
        isPaused.toggle()
        service.setPaused(isPaused)
        scheduleReload(after: 0.5)
    }

    /// The KPI row as text, for the clipboard.
    func copyNumbers() {
        guard let report else { return }
        var lines = ["\(scopeTitle) · \(window.title) · consumption read from local CLI logs, not quota"]
        lines.append("Input-class tokens: \(TelemetryFormatting.compact(report.totals.inputClass)) (\(TelemetryFormatting.percent(cacheReadShare(report))) cache reads)")
        lines.append("Output tokens: \(TelemetryFormatting.compact(report.totals.output)) (\(TelemetryFormatting.percent(thinkingShare(report))) thinking)")
        lines.append("API list-price equivalent, not billed: \(TelemetryFormatting.usd(nanoUSD: report.totals.costNanoUSD)) (rates as of \(TelemetryFormatting.mediumDate(report.priceTable.asOf)))")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Loading

    func reload() { scheduleReload(after: 0) }

    private func scheduleReload(after delay: TimeInterval) {
        guard isVisible, !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.reloadScheduled = false
            self?.performReload()
        }
    }

    private func performReload() {
        generation += 1
        let thisGeneration = generation
        isLoading = true
        let roster = TelemetryService.roster(from: profileManager.profiles)
        let owners = profileManager.activeAccountIds(among: profileManager.profiles)
        let sidebarProfiles = profileManager.profiles.map {
            TelemetrySidebarProfile(id: $0.id, name: $0.name, provider: TelemetryProvider($0.providerKind), isOwner: owners.contains($0.id))
        }
        let fleetQuery = TelemetryQuery(scope: .fleet, window: window, metric: metric, now: Date(), calendar: .current)
        let scopedQuery = TelemetryQuery(scope: scope, window: window, metric: metric, now: fleetQuery.now, calendar: .current)
        service.loadReport(query: fleetQuery, roster: roster) { [weak self] fleet, status in
            guard let self, thisGeneration == self.generation else { return }
            self.fleetReport = fleet
            self.status = status
            self.sidebar = Self.sidebar(fleet: fleet, profiles: sidebarProfiles)
            if self.scope == .fleet {
                self.report = fleet
                self.isLoading = false
                self.lastLoaded = Date()
            } else {
                self.service.loadReport(query: scopedQuery, roster: roster) { [weak self] scoped, status in
                    guard let self, thisGeneration == self.generation else { return }
                    self.report = scoped
                    self.status = status
                    self.isLoading = false
                    self.lastLoaded = Date()
                }
            }
        }
    }

    // MARK: - Derived

    var scopeTitle: String {
        switch scope {
        case .fleet: return "telemetry.fleet".localized
        case .provider(let p): return TelemetryReportBuilder.providerLabel(p)
        case .account(let id): return profileManager.profiles.first { $0.id == id }?.name ?? "Account"
        case .unattributed(let p): return "\("telemetry.unattributed".localized) · \(TelemetryReportBuilder.providerLabel(p))"
        }
    }

    func cacheReadShare(_ report: TelemetryReport) -> Double {
        report.totals.inputClass > 0 ? Double(report.totals.cacheRead) / Double(report.totals.inputClass) : 0
    }

    func thinkingShare(_ report: TelemetryReport) -> Double {
        report.totals.output > 0 ? Double(report.totals.reasoning) / Double(report.totals.output) : 0
    }

    /// Fleet first; then each provider with its accounts sorted by activity in
    /// the window (owner mark, compact total only where attribution covers
    /// the window) and an Unattributed row when it is non-zero.
    static func sidebar(fleet: TelemetryReport?, profiles: [TelemetrySidebarProfile]) -> [TelemetrySidebarSection] {
        let totalsByAccount: [String: TelemetryRow] = Dictionary(
            (fleet?.accounts ?? []).map { ($0.key.id, $0) }, uniquingKeysWith: { first, _ in first })
        var sections = [TelemetrySidebarSection(
            id: "fleet", title: "telemetry.fleet".localized, count: nil,
            rows: [TelemetrySidebarRow(id: "fleet", scope: .fleet, title: "telemetry.fleet".localized, provider: nil,
                                       isOwner: false, total: fleet?.totals.inputClass, indent: false)])]
        for provider in TelemetryProvider.allCases {
            let members = profiles.filter { $0.provider == provider }
            guard !members.isEmpty else { continue }
            let providerTotal = fleet?.buckets.reduce(0) { sum, bucket in
                sum + (bucket.series[TelemetryReportBuilder.providerKey(provider)]?.inputClass ?? 0)
            }
            var rows = [TelemetrySidebarRow(id: "provider:\(provider.rawValue)", scope: .provider(provider),
                                            title: TelemetryReportBuilder.providerLabel(provider), provider: provider,
                                            isOwner: false, total: providerTotal, indent: false)]
            let accountRows = members.map { member -> TelemetrySidebarRow in
                let row = totalsByAccount[member.id.uuidString]
                return TelemetrySidebarRow(id: member.id.uuidString, scope: .account(member.id), title: member.name,
                                           provider: provider, isOwner: member.isOwner, total: row?.totals.inputClass, indent: true)
            }.sorted { ($0.total ?? -1, $0.title) > ($1.total ?? -1, $1.title) }
            rows += accountRows
            if let unattributed = totalsByAccount["unattributed:\(provider.rawValue)"], unattributed.totals.inputClass > 0 {
                rows.append(TelemetrySidebarRow(id: "unattributed:\(provider.rawValue)", scope: .unattributed(provider),
                                                title: "telemetry.unattributed".localized, provider: provider, isOwner: false,
                                                total: unattributed.totals.inputClass, indent: true))
            }
            sections.append(TelemetrySidebarSection(id: provider.rawValue, title: TelemetryReportBuilder.providerLabel(provider).uppercased(),
                                                    count: members.count, rows: rows))
        }
        return sections
    }

    /// `.telemetryWindowRequested`: object = profile UUID (an account scope),
    /// userInfo["provider"] as `Profile.ProviderKind` or its String name
    /// (a provider scope when no profile); neither → Fleet.
    static func scope(from notification: Notification) -> TelemetryScope {
        if let id = notification.object as? UUID { return .account(id) }
        if let kind = notification.userInfo?["provider"] as? Profile.ProviderKind { return .provider(TelemetryProvider(kind)) }
        if let name = notification.userInfo?["provider"] as? String, let provider = TelemetryProvider(name: name) {
            return .provider(provider)
        }
        return .fleet
    }
}
