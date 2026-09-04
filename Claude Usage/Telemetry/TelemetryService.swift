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

final class TelemetryService {
    static let shared = TelemetryService()

    /// `~/Library/Application Support/Claude Usage/telemetry/ledger.sqlite`.
    static var defaultLedgerURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? Constants.ClaudePaths.homeDirectory.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Claude Usage/telemetry/ledger.sqlite")
    }

    static let steadyInterval: TimeInterval = 300
    /// The pointer-claim seam's notification (fixes session, in flight).
    /// Referenced by name so this module compiles before that branch lands.
    static let providerOwnerClaimed = Notification.Name("providerOwnerClaimed")

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
               ledgerURL: URL = TelemetryService.defaultLedgerURL) {
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

        NotificationCenter.default.addObserver(self, selector: #selector(ownerClaimed(_:)),
                                               name: Self.providerOwnerClaimed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(ownerChangedExternally(_:)),
                                               name: .providerOwnerChangedExternally, object: nil)

        let ring = sharedData.loadSwitchHistory()
        let roster = Self.roster(from: profileManager.profiles)
        let engine = self.engine
        queue.async {
            engine.open(ledgerURL: ledgerURL, ring: ring, roster: roster)
            engine.tick()
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.steadyInterval, repeating: Self.steadyInterval, leeway: .seconds(15))
        timer.setEventHandler { engine.tick() }
        timer.resume()
        self.timer = timer
        LoggingService.shared.log("Telemetry: started (ledger \(ledgerURL.path))")
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
                                  accountStamp: accountStamp(of: profile, for: kind))
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

    func open(ledgerURL: URL, ring: [SwitchEvent], roster: [ProfileSummary]) {
        do {
            let ledger = try TelemetryLedger(url: ledgerURL)
            let recorder = OwnershipRecorder(ledger: ledger)
            let seeded = try recorder.seedIfNeeded(ring: ring, roster: roster)
            self.ledger = ledger
            self.recorder = recorder
            if seeded > 0 {
                telemetryLog.info("seeded \(seeded) ownership rows from the switch ring")
            }
        } catch {
            telemetryLog.error("ledger unavailable — \(String(describing: error))")
        }
    }

    func tick() {
        guard let recorder, let snapshot = snapshotBox.get() else { return }
        do {
            let appended = try recorder.record(snapshot: snapshot)
            if !appended.isEmpty {
                let summary = appended.map { "\($0.provider.rawValue)→\($0.name ?? "none")" }.joined(separator: ", ")
                telemetryLog.info("ownership +\(appended.count) (\(summary))")
            }
        } catch {
            telemetryLog.error("ownership write failed — \(String(describing: error))")
        }
    }

    func recordClaim(provider: TelemetryProvider, newOwner: UUID?, previousOwner: UUID?,
                     accountStamp: String?, name: String?, cause: String?, at: Date) {
        do {
            try recorder?.recordClaim(provider: provider, newOwner: newOwner, previousOwner: previousOwner,
                                      accountStamp: accountStamp, name: name, cause: cause, at: at)
        } catch {
            telemetryLog.error("claim write failed — \(String(describing: error))")
        }
    }

    func recordExternalChange(provider: TelemetryProvider, newOwner: UUID, name: String?, at: Date) {
        do {
            try recorder?.recordExternalChange(provider: provider, newOwner: newOwner, name: name, at: at)
        } catch {
            telemetryLog.error("external-change write failed — \(String(describing: error))")
        }
    }
}
