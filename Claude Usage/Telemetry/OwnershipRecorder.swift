//
//  OwnershipRecorder.swift
//  Claude Usage
//
//  Writes the ownership log the per-account view is attributed from: who held
//  each provider's shared CLI login, from when, and on what evidence
//  (docs/specs/token-telemetry.md §2.4). Transcripts carry no account, and the
//  app's switch ring holds 30 name-only entries (24.7 hours on 2026-09-04), so
//  this log — started at the first deploy — is the only durable answer.
//
//  Evidence, strongest first: the pointer-claim seam's notification
//  (`exactClaim`), an adoption pass observing a CLI-side login
//  (`externalObservation`), the tick's owner snapshot differing from the last
//  record (`observedAtTick`), an hourly `heartbeat`, and a one-time strict seed
//  from the switch ring. The resolver (stage 2) attributes only inside
//  intervals the evidence brackets; the gap between the last sighting of A and
//  the first of B is unattributed, never "B, approximately".
//
//  Runs on TelemetryService's serial utility queue; the main actor hands it
//  immutable `OwnerSnapshot`s and never the ProfileManager itself.
//

import Foundation

/// The owner of one provider's login as the main actor last knew it.
nonisolated struct OwnerIdentity: Sendable, Equatable {
    var profileId: UUID
    var name: String
    var accountStamp: String?
}

/// Immutable picture of the three provider pointers, captured on the main
/// actor and read on the telemetry queue. A missing provider = no owner.
nonisolated struct OwnerSnapshot: Sendable, Equatable {
    var capturedAt: Date
    var owners: [TelemetryProvider: OwnerIdentity]
    /// A profile switch is in flight: the pointers are mid-transition, so the
    /// tick records nothing (contamination during a switch is a real incident).
    var isSwitching: Bool
}

/// The roster as names + provider + stamp — enough to seed from the ring.
nonisolated struct ProfileSummary: Sendable, Equatable {
    var id: UUID
    var name: String
    var provider: TelemetryProvider
    var accountStamp: String?
    /// Last path component of `Profile.codexHomePath` — an isolated Codex home
    /// whose rollouts attribute to this profile by path.
    var codexHomeSlug: String? = nil
}

nonisolated final class OwnershipRecorder: @unchecked Sendable {

    static let seedMetaKey = "ownershipSeeded_v1"
    /// Ring rows whose reason starts with this moved the FOCUS only — the CLI
    /// login never changed, so they are not ownership.
    static let focusOnlyReasonPrefix = "focus only"

    private let ledger: TelemetryLedger
    let heartbeatInterval: TimeInterval

    init(ledger: TelemetryLedger, heartbeatInterval: TimeInterval = 3_600) {
        self.ledger = ledger
        self.heartbeatInterval = heartbeatInterval
    }

    // MARK: - Tick

    /// Appends one record per provider whose owner changed since the last
    /// record, or a heartbeat where the owner is unchanged and the last record
    /// is older than `heartbeatInterval`. Returns what it appended.
    @discardableResult
    func record(snapshot: OwnerSnapshot) throws -> [OwnershipRecord] {
        guard !snapshot.isSwitching else { return [] }
        var appended: [OwnershipRecord] = []
        try ledger.transaction {
            for provider in TelemetryProvider.allCases {
                let last = try ledger.lastOwnership(provider: provider)
                let current = snapshot.owners[provider]
                if last?.profileId != current?.profileId || (last == nil && current != nil) {
                    guard last != nil || current != nil else { continue }
                    let record = OwnershipRecord(
                        at: snapshot.capturedAt, provider: provider, profileId: current?.profileId,
                        previousProfileId: last?.profileId, accountStamp: current?.accountStamp,
                        name: current?.name, basis: .observedAtTick, cause: nil)
                    try ledger.append(record)
                    appended.append(record)
                } else if let last, snapshot.capturedAt.timeIntervalSince(last.at) >= heartbeatInterval {
                    let record = OwnershipRecord(
                        at: snapshot.capturedAt, provider: provider, profileId: current?.profileId,
                        previousProfileId: last.profileId, accountStamp: current?.accountStamp ?? last.accountStamp,
                        name: current?.name ?? last.name, basis: .heartbeat, cause: nil)
                    try ledger.append(record)
                    appended.append(record)
                }
            }
        }
        return appended
    }

    // MARK: - Notifications

    /// The pointer-claim seam fired: exact time, exact ids.
    func recordClaim(provider: TelemetryProvider, newOwner: UUID?, previousOwner: UUID?,
                     accountStamp: String?, name: String?, cause: String?, at: Date) throws {
        try ledger.append(OwnershipRecord(
            at: at, provider: provider, profileId: newOwner, previousProfileId: previousOwner,
            accountStamp: accountStamp, name: name, basis: .exactClaim, cause: cause))
    }

    /// An adoption pass saw a CLI-side login land in a profile. This is when we
    /// NOTICED; the switch itself happened somewhere before.
    func recordExternalChange(provider: TelemetryProvider, newOwner: UUID, name: String?, at: Date) throws {
        let last = try ledger.lastOwnership(provider: provider)
        guard last?.profileId != newOwner else { return }
        try ledger.append(OwnershipRecord(
            at: at, provider: provider, profileId: newOwner, previousProfileId: last?.profileId,
            accountStamp: nil, name: name, basis: .externalObservation, cause: "adoption"))
    }

    // MARK: - Seed

    /// One-time import of the switch ring, gated by a meta key so a relaunch
    /// never re-seeds. Returns how many rows were written.
    @discardableResult
    func seedIfNeeded(ring: [SwitchEvent], roster: [ProfileSummary]) throws -> Int {
        guard ledger.meta(Self.seedMetaKey) == nil else { return 0 }
        let records = Self.seedRecords(ring: ring, roster: roster)
        try ledger.transaction {
            for record in records { try ledger.append(record) }
            try ledger.setMeta(Self.seedMetaKey, ISO8601DateFormatter().string(from: Date()))
        }
        return records.count
    }

    /// The strict rule (consult §8): a ring row becomes ownership only when
    /// its `to` name maps to exactly ONE profile in the whole roster (hence one
    /// provider), and it did not merely move the focus. Renamed, deleted,
    /// duplicated and cross-provider names stay unattributed.
    static func seedRecords(ring: [SwitchEvent], roster: [ProfileSummary]) -> [OwnershipRecord] {
        var byName: [String: [ProfileSummary]] = [:]
        for profile in roster { byName[profile.name, default: []].append(profile) }
        var records: [OwnershipRecord] = []
        for event in ring.sorted(by: { $0.at < $1.at }) {
            if let reason = event.reason,
               reason.lowercased().hasPrefix(focusOnlyReasonPrefix) { continue }
            guard let targets = byName[event.to], targets.count == 1, let target = targets.first else { continue }
            let previous = byName[event.from].flatMap { $0.count == 1 ? $0.first : nil }
            records.append(OwnershipRecord(
                at: event.at, provider: target.provider, profileId: target.id,
                previousProfileId: previous?.provider == target.provider ? previous?.id : nil,
                accountStamp: target.accountStamp, name: target.name,
                basis: .seededFromRing, cause: event.trigger.rawValue))
        }
        return records
    }
}
