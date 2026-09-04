//
//  TelemetryEvent.swift
//  Claude Usage
//
//  The value types of the token-consumption ledger (docs/specs/token-telemetry.md
//  §2). Everything here is `nonisolated` on purpose: the ledger, the readers and
//  the recorder run on a serial utility queue, and under
//  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` an unannotated type would drag
//  that work back onto the UI thread (the LocalLimitSignalService lesson).
//
//  Consumption, never quota: these records say how many tokens the CLIs sent
//  and received; nothing here is a percentage of a limit.
//

import Foundation

nonisolated enum TelemetryProvider: String, Codable, Sendable, CaseIterable {
    case claude, codex, grok

    init(_ kind: Profile.ProviderKind) {
        switch kind {
        case .claude: self = .claude
        case .codex: self = .codex
        case .grok: self = .grok
        }
    }

    /// Accepts the `String(describing:)` form the app's notifications carry
    /// ("claude" / "codex" / "grok") as well as the raw value.
    init?(name: String) {
        self.init(rawValue: name.lowercased())
    }
}

/// One deduplicated unit of consumption: a Claude API message (all its block
/// records collapsed), a Codex delta between two distinct cumulative
/// snapshots, or a Grok completed turn for one model. Immutable facts about a
/// source line — ownership is joined at query time, never stored here.
nonisolated struct TelemetryEvent: Codable, Sendable, Equatable {
    /// Globally unique: Claude `message.id`; Codex `<fileId>#<snapshot seq>`;
    /// Grok `_meta.eventId`. The ledger upserts on it, so a replay of the same
    /// bytes (shrink, move, crash) never double counts.
    var unitId: String
    var provider: TelemetryProvider
    var at: Date
    var model: String
    /// Uncached input tokens (Claude's `input_tokens` is already uncached; the
    /// other two providers report cached as a subset and are subtracted).
    var input: Int
    var cacheRead: Int
    var cacheWrite: Int
    /// The 1-hour-tier part of `cacheWrite` when the source splits it (Claude).
    var cacheWrite1h: Int
    var output: Int
    /// Thinking / reasoning tokens — a subset of `output`, never added to it.
    var reasoning: Int
    /// The Grok CLI's own list-price figure in nano-USD; nil for the others.
    var reportedCostNanoUSD: Int?
    var session: String
    var sidechain: Bool
    /// Claude: project slug / entrypoint; Codex: originator; Grok: cwd.
    var source: String?
    var fileId: String
    var sourceOffset: Int
    var parserVersion: Int
    /// A Claude message whose final block has not been seen yet; the next tick
    /// upserts the finished snapshot over it.
    var inFlight: Bool

    var inputClass: Int { input + cacheRead + cacheWrite }
}

/// A recorded non-consumption fact that explains a dip: a Claude transcript
/// death on the rate limit, or a server `quotaLimits` rejection.
nonisolated struct TelemetryMarker: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case rateLimit, quotaRejected
    }

    var markerId: String
    var provider: TelemetryProvider
    var kind: Kind
    var at: Date
    var session: String
    var detail: String?
}

/// Who owned a provider's shared CLI login from `at` onwards, and how we know.
nonisolated struct OwnershipRecord: Codable, Sendable, Equatable {
    enum Basis: String, Codable, Sendable {
        /// Posted by the pointer-claim seam the moment a pointer changed.
        case exactClaim
        /// An adoption pass observed a CLI-side login — the observation time,
        /// not the switch time.
        case externalObservation
        /// The tick's owner snapshot differed from the last recorded owner.
        case observedAtTick
        /// Unchanged owner, re-asserted so downtime gaps stay bounded.
        case heartbeat
        /// Seeded once from the 30-entry switch ring, only where the name
        /// mapped to exactly one profile of exactly one provider.
        case seededFromRing
    }

    var seq: Int64?
    var at: Date
    var provider: TelemetryProvider
    /// nil = no owner (the pointer was cleared or nobody holds the login).
    var profileId: UUID?
    var previousProfileId: UUID?
    var accountStamp: String?
    var name: String?
    var basis: Basis
    var cause: String?
}

/// Per-source-file resume state. `state` carries what a reader needs across
/// ticks (the Codex component vector and current model; Claude in-flight ids).
nonisolated struct TelemetryCursor: Codable, Sendable, Equatable {
    var fileId: String
    var path: String
    var inode: UInt64
    var size: Int64
    var mtime: Date
    var offset: Int64
    var state: Data?
}

/// What the indexer knows about a provider's source health; shown by the
/// window beside that provider's `dataThrough`, never as zero consumption.
nonisolated struct ProviderHealth: Codable, Sendable, Equatable {
    var provider: TelemetryProvider
    var scannedAt: Date?
    var dataThrough: Date?
    var filesSeen: Int = 0
    var filesUnreadable: Int = 0
    var linesMalformed: Int = 0
    var unknownShapes: Int = 0
    var backlogFiles: Int = 0
    var backlogBytes: Int64 = 0
}
