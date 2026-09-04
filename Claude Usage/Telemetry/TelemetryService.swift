//
//  TelemetryService.swift
//  Claude Usage
//
//  The app-facing entry point of the token-consumption telemetry module
//  (docs/specs/token-telemetry.md). Owns ONE serial utility queue and ONE
//  timer on it — never the 30-second sweep, never a main-run-loop Timer — and
//  hands the queue immutable snapshots of what the main actor knows (the three
//  provider pointers). Nothing on the queue ever touches ProfileManager.
//
//  Stage 1a: opens the ledger, seeds and maintains the ownership log.
//  Stage 1b adds the indexer slices to the same tick.
//

import Combine
import Foundation
import os

/// Off-main logging for the telemetry queue: `LoggingService` is main-actor
/// isolated, and a hop per log line would defeat the point of the queue.
nonisolated let telemetryLog = Logger(subsystem: "com.claudeusagewidget.app", category: "telemetry")

extension Notification.Name {
    /// Posted on the main queue after a slice wrote events or a catch-up run
    /// ended, so an open window can reload. No payload.
    static let telemetryLedgerUpdated = Notification.Name("telemetryLedgerUpdated")
}

final class TelemetryService {
    static let shared = TelemetryService()

    /// `~/Library/Application Support/Claude Usage/telemetry/ledger.sqlite`.
    static var defaultLedgerURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? Constants.ClaudePaths.homeDirectory.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Claude Usage/telemetry/ledger.sqlite")
    }

    static let steadyInterval: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.claudeusagewidget.telemetry", qos: .utility)
    private let engine = TelemetryEngine()
    private var timer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {}

    /// Called once from `applicationDidFinishLaunching` after the profiles are
    /// loaded. Idempotent. Never runs under XCTest.
    func start(profileManager: ProfileManager = .shared,
               sharedData: SharedDataStore = .shared,
               ledgerURL: URL = TelemetryService.defaultLedgerURL,
               roots: TelemetrySourceRoots = .live()) {
        guard !started else { return }
        started = true

        publishSnapshot(from: profileManager)
        Publishers.MergeMany(
            profileManager.$profiles.map { _ in () }.eraseToAnyPublisher(),
            profileManager.$activeClaudeProfileId.map { _ in () }.eraseToAnyPublisher(),
            profileManager.$activeCodexProfileId.map { _ in () }.eraseToAnyPublisher(),
            profileManager.$activeGrokProfileId.map { _ in () }.eraseToAnyPublisher(),
            profileManager.$isSwitchingProfile.map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
        .sink { [weak self] _ in self?.publishSnapshot(from: profileManager) }
        .store(in: &cancellables)

        // The pointer-claim seam (#89): posted only when a pointer's value changes.
        NotificationCenter.default.addObserver(self, selector: #selector(ownerClaimed(_:)),
                                               name: .providerOwnerClaimed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ownerChangedExternally(_:)),
                                               name: .providerOwnerChangedExternally, object: nil)

        let ring = sharedData.loadSwitchHistory()
        let roster = Self.roster(from: profileManager.profiles)
        let engine = self.engine
        let queue = self.queue
        queue.async {
            engine.open(ledgerURL: ledgerURL, ring: ring, roster: roster, roots: roots)
            engine.tick(queue: queue)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.steadyInterval, repeating: Self.steadyInterval, leeway: .seconds(15))
        timer.setEventHandler { engine.tick(queue: queue) }
        timer.resume()
        self.timer = timer
        // The window observer must exist from launch: the entry points already
        // post, and a lazily created controller would drop the first click.
        TelemetryWindowController.shared.installObserver()
        LoggingService.shared.log("Telemetry: started (ledger \(ledgerURL.path))")
    }

    /// Runs a slice now (the window's "Refresh now"); catch-up continues on the
    /// queue while a bound is hit.
    func refreshNow() {
        let engine = self.engine
        let queue = self.queue
        queue.async { engine.tick(queue: queue) }
    }

    /// Pauses the file walk (ownership recording continues).
    func setPaused(_ paused: Bool) {
        let engine = self.engine
        queue.async { engine.paused = paused }
    }

    /// Builds a report on the telemetry queue and delivers it on the main queue
    /// with the indexer's status. `roster` is captured on the main actor.
    /// Writes the CSV on the engine queue; `completion` runs on main with nil
    /// on success or the error.
    func exportCSV(query: TelemetryQuery, roster: [ProfileSummary], scopeTitle: String, to url: URL,
                   completion: @escaping (Error?) -> Void) {
        let engine = self.engine
        queue.async {
            let failure: Error?
            do { try engine.exportCSV(query: query, roster: roster, scopeTitle: scopeTitle, to: url); failure = nil } catch { failure = error }
            DispatchQueue.main.async { completion(failure) }
        }
    }

    func loadReport(query: TelemetryQuery, roster: [ProfileSummary],
                    completion: @escaping (TelemetryReport?, IndexingStatus) -> Void) {
        let engine = self.engine
        queue.async {
            let report = engine.buildReport(query: query, roster: roster)
            let status = engine.indexingStatus()
            DispatchQueue.main.async { completion(report, status) }
        }
    }

    func meta(_ key: String, completion: @escaping (String?) -> Void) {
        let engine = self.engine
        queue.async {
            let value = engine.ledger?.meta(key)
            DispatchQueue.main.async { completion(value) }
        }
    }

    func setMeta(_ key: String, _ value: String) {
        let engine = self.engine
        queue.async { try? engine.ledger?.setMeta(key, value) }
    }

    // MARK: - Snapshots (main actor → queue)

    private func publishSnapshot(from profileManager: ProfileManager) {
        engine.snapshotBox.set(Self.snapshot(from: profileManager))
    }

    static func snapshot(from profileManager: ProfileManager, now: Date = Date()) -> OwnerSnapshot {
        var owners: [TelemetryProvider: OwnerIdentity] = [:]
        for kind in Profile.ProviderKind.allCases {
            guard let id = profileManager.providerOwnerId(for: kind),
                  let profile = profileManager.profiles.first(where: { $0.id == id }) else { continue }
            owners[TelemetryProvider(kind)] = OwnerIdentity(profileId: id, name: profile.name,
                                                            accountStamp: accountStamp(of: profile, for: kind))
        }
        return OwnerSnapshot(capturedAt: now, owners: owners, isSwitching: profileManager.isSwitchingProfile)
    }

    static func roster(from profiles: [Profile]) -> [ProfileSummary] {
        profiles.map { profile in
            let kind = profile.providerKind
            return ProfileSummary(id: profile.id, name: profile.name, provider: TelemetryProvider(kind),
                                  accountStamp: accountStamp(of: profile, for: kind),
                                  codexHomeSlug: profile.codexHomePath.map { URL(fileURLWithPath: $0).lastPathComponent })
        }
    }

    private static func accountStamp(of profile: Profile, for kind: Profile.ProviderKind) -> String? {
        switch kind {
        case .claude: return profile.claudeAccountUUID
        case .codex: return profile.codexAccountId
        case .grok: return profile.grokEmail
        }
    }

    // MARK: - Notifications

    @objc private func ownerClaimed(_ notification: Notification) {
        guard let providerName = notification.userInfo?["provider"] as? String,
              let provider = TelemetryProvider(name: providerName) else { return }
        let newOwner = notification.object as? UUID
        let previous = (notification.userInfo?["previousOwnerId"] as? String).flatMap(UUID.init(uuidString:))
        let stamp = notification.userInfo?["accountStamp"] as? String
        let cause = notification.userInfo?["cause"] as? String
        let name = newOwner.flatMap { id in ProfileManager.shared.profiles.first(where: { $0.id == id })?.name }
        let engine = self.engine
        let at = Date()
        queue.async {
            engine.recordClaim(provider: provider, newOwner: newOwner, previousOwner: previous,
                               accountStamp: stamp, name: name, cause: cause, at: at)
        }
    }

    @objc private func ownerChangedExternally(_ notification: Notification) {
        guard let newOwner = notification.object as? UUID,
              let providerName = notification.userInfo?["provider"] as? String,
              let provider = TelemetryProvider(name: providerName) else { return }
        let name = notification.userInfo?["ownerName"] as? String
        let engine = self.engine
        let at = Date()
        queue.async { engine.recordExternalChange(provider: provider, newOwner: newOwner, name: name, at: at) }
    }
}

/// A lock-protected mailbox: the main actor writes the latest snapshot, the
/// telemetry queue reads it. Keeps the queue from ever needing the main actor.
nonisolated final class OwnerSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OwnerSnapshot?

    func set(_ snapshot: OwnerSnapshot) {
        lock.lock(); defer { lock.unlock() }
        value = snapshot
    }

    func get() -> OwnerSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Everything that runs on the telemetry queue. `nonisolated` is load-bearing:
/// an implicitly main-actor class here would hop every tick back to the UI
/// thread.
nonisolated final class TelemetryEngine: @unchecked Sendable {
    let snapshotBox = OwnerSnapshotBox()
    private(set) var ledger: TelemetryLedger?
    private(set) var recorder: OwnershipRecorder?
    private(set) var indexer: TelemetryIndexer?
    /// Catch-up: while a slice hits a bound, the next one is queued this soon
    /// instead of waiting for the steady timer (the first 27 GB would take
    /// hours at 200 files per five minutes).
    static let catchUpDelay: TimeInterval = 0.25
    private var catchUpQueued = false

    /// Set from the window's "Pause indexing"; ownership keeps recording.
    var paused = false

    private(set) var ledgerURL: URL?

    func open(ledgerURL: URL, ring: [SwitchEvent], roster: [ProfileSummary], roots: TelemetrySourceRoots) {
        self.ledgerURL = ledgerURL
        do {
            let ledger = try TelemetryLedger(url: ledgerURL)
            let recorder = OwnershipRecorder(ledger: ledger)
            let seeded = try recorder.seedIfNeeded(ring: ring, roster: roster)
            if ledger.meta("firstIndexedAt") == nil {
                try ledger.setMeta("firstIndexedAt", String(Date().timeIntervalSince1970))
            }
            self.ledger = ledger
            self.recorder = recorder
            self.indexer = TelemetryIndexer(ledger: ledger, roots: roots)
            if seeded > 0 {
                telemetryLog.info("seeded \(seeded) ownership rows from the switch ring")
            }
        } catch {
            telemetryLog.error("ledger unavailable — \(String(describing: error))")
        }
    }

    /// The report for one query, built entirely on the telemetry queue.
    struct LedgerUnavailable: Error {}

    /// Everything a report — or its CSV — needs, read from the ledger in one
    /// pass. The query comes back with `earliestIndexed` filled for "All".
    func reportInput(query: TelemetryQuery, roster: [ProfileSummary]) throws -> (TelemetryQuery, TelemetryReportBuilder.Input) {
        guard let ledger else { throw LedgerUnavailable() }
        var query = query
        if query.window == .allIndexed, query.earliestIndexed == nil {
            query.earliestIndexed = try ledger.eventTimeSpan()?.from
        }
        let range = query.range()
        let aggregates = try ledger.aggregateMinutes(from: range.start, to: range.end)
        let previous = try ledger.aggregateMinutes(from: range.previousStart, to: range.previousEnd)
        let ownership = try ledger.ownership()
        let markers = try ledger.markers(from: range.start, to: range.end)
        let health = try TelemetryProvider.allCases.map { try ledger.health(provider: $0) }
        let codexSessions: Int?
        switch query.scope {
        case .fleet, .provider(.codex), .unattributed(.codex):
            codexSessions = try ledger.distinctSessions(provider: .codex, from: range.start, to: range.end)
        default:
            codexSessions = nil
        }
        let firstIndexed = ledger.meta("firstIndexedAt").flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let input = TelemetryReportBuilder.Input(aggregates: aggregates, previousAggregates: previous, ownership: ownership,
                                                 roster: roster, health: health, codexSessions: codexSessions,
                                                 prices: .shipped, firstIndexedAt: firstIndexed, markers: markers)
        return (query, input)
    }

    func buildReport(query: TelemetryQuery, roster: [ProfileSummary]) -> TelemetryReport? {
        guard ledger != nil else { return nil }
        do {
            let (query, input) = try reportInput(query: query, roster: roster)
            return TelemetryReportBuilder.build(query: query, input: input)
        } catch {
            telemetryLog.error("report failed — \(String(describing: error))")
            return nil
        }
    }

    /// The CSV for `query`, written atomically to `url`. Same input as the
    /// report, so the file and the window agree to the row.
    func exportCSV(query: TelemetryQuery, roster: [ProfileSummary], scopeTitle: String, to url: URL) throws {
        let (query, input) = try reportInput(query: query, roster: roster)
        let csv = TelemetryExport.csv(query: query, input: input, scopeTitle: scopeTitle)
        try csv.data(using: .utf8)?.write(to: url, options: .atomic)
        telemetryLog.info("exported CSV: \(url.lastPathComponent, privacy: .public), \(csv.utf8.count) bytes")
    }

    func indexingStatus() -> IndexingStatus {
        guard let ledger else { return IndexingStatus(ledgerPath: ledgerURL?.path) }
        var status = IndexingStatus(ledgerAvailable: true, isCatchingUp: catchingUp, isPaused: paused, ledgerPath: ledger.url.path)
        for provider in TelemetryProvider.allCases {
            guard let health = try? ledger.health(provider: provider) else { continue }
            status.filesSeen += health.filesSeen
            status.backlogFiles += health.backlogFiles
            status.backlogBytes += health.backlogBytes
            if let through = health.dataThrough { status.dataThrough[provider] = through }
            if let scanned = health.scannedAt, status.scannedAt.map({ scanned > $0 }) ?? true { status.scannedAt = scanned }
        }
        status.eventCount = (try? ledger.eventCount()) ?? 0
        status.storageBytes = ledger.storageBytes()
        return status
    }

    func tick(queue: DispatchQueue) {
        catchUpQueued = false
        if let recorder, let snapshot = snapshotBox.get() {
            do {
                let appended = try recorder.record(snapshot: snapshot)
                if !appended.isEmpty {
                    let summary = appended.map { "\($0.provider.rawValue)→\($0.name ?? "none")" }.joined(separator: ", ")
                    telemetryLog.info("ownership +\(appended.count) (\(summary, privacy: .public))")
                }
            } catch {
                telemetryLog.error("ownership write failed — \(String(describing: error))")
            }
        }
        guard let indexer, !paused else { return }
        let report = indexer.runSlice()
        if report.filesScanned > 0 {
            telemetryLog.info("slice: \(report.filesScanned) files, \(report.bytesRead) B, +\(report.eventsUpserted) events, backlog \(report.backlogFiles) files / \(report.backlogBytes) B, \(String(format: "%.2f", report.duration), privacy: .public) s")
        }
        if report.eventsUpserted > 0 || (catchingUp && !report.hitBound) {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .telemetryLedgerUpdated, object: nil) }
        }
        if report.hitBound, !catchUpQueued {
            catchUpQueued = true
            catchingUp = true
            queue.asyncAfter(deadline: .now() + Self.catchUpDelay) { [weak self] in
                guard let self else { return }
                self.tick(queue: queue)
            }
        } else if !report.hitBound {
            // A run ended (a bounded catch-up or a plain tick that wrote): fold
            // the WAL back into the main file rather than let it sit at the cap.
            if catchingUp {
                catchingUp = false
                telemetryLog.info("catch-up complete; ledger \(self.ledger?.storageBytes() ?? 0) B on disk")
            }
            if report.filesScanned > 0 { ledger?.checkpoint() }
        }
    }
    private var catchingUp = false

    func recordClaim(provider: TelemetryProvider, newOwner: UUID?, previousOwner: UUID?,
                     accountStamp: String?, name: String?, cause: String?, at: Date) {
        do {
            try recorder?.recordClaim(provider: provider, newOwner: newOwner, previousOwner: previousOwner,
                                      accountStamp: accountStamp, name: name, cause: cause, at: at)
            telemetryLog.info("ownership claim \(provider.rawValue, privacy: .public) → \(name ?? "none", privacy: .public) (\(cause ?? "unknown", privacy: .public))")
        } catch {
            telemetryLog.error("claim write failed — \(String(describing: error))")
        }
    }

    func recordExternalChange(provider: TelemetryProvider, newOwner: UUID, name: String?, at: Date) {
        do {
            try recorder?.recordExternalChange(provider: provider, newOwner: newOwner, name: name, at: at)
            telemetryLog.info("ownership observed outside the app: \(provider.rawValue, privacy: .public) → \(name ?? "?", privacy: .public)")
        } catch {
            telemetryLog.error("external-change write failed — \(String(describing: error))")
        }
    }
}
