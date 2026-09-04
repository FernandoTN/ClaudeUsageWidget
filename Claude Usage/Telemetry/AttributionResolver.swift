//
//  AttributionResolver.swift
//  Claude Usage
//
//  Who consumed a unit (spec §2.4). The logs carry no account, so the answer
//  comes from the ownership log by TIME — and only where the evidence
//  brackets the moment: an exact pointer claim (or the strict ring seed)
//  attributes its whole interval; an observation-only owner (tick diff,
//  external adoption, heartbeat) attributes only until the next sighting of
//  the SAME owner or an exact claim of the next; the gap between the last
//  sighting of A and the first observation of B is unattributed — never "B,
//  approximately". Isolated Codex homes attribute by path; a single Grok
//  account attributes trivially. Resolved at query time, never stored.
//

import Foundation

nonisolated enum Attribution: Sendable, Equatable, Hashable {
    enum Basis: String, Sendable {
        /// Inside an interval opened by an exact claim or the ring seed, or an
        /// observed owner confirmed by its next sighting.
        case timeline
        /// An isolated Codex home named by `Profile.codexHomePath`.
        case byPath
        /// The provider has exactly one account.
        case soleAccount
    }

    enum Reason: String, Sendable {
        /// Before the first ownership record for the provider.
        case beforeLog
        /// Between the last sighting of one owner and the first of another.
        case gap
        /// The pointer was cleared / nobody held the login.
        case noOwner
    }

    case profile(UUID, basis: Basis)
    case unattributed(Reason)

    var profileId: UUID? {
        if case .profile(let id, _) = self { return id }
        return nil
    }
}

nonisolated struct AttributionResolver: Sendable {
    /// How long an observation-only owner stays credible after its last
    /// sighting when nothing follows (the app was down): two heartbeats.
    static let trailingTrust: TimeInterval = 2 * 3_600

    private let byProvider: [TelemetryProvider: [OwnershipRecord]]
    private let codexSlugToProfile: [String: UUID]
    private let soleGrokProfile: UUID?
    let roster: [UUID: ProfileSummary]

    init(ownership: [OwnershipRecord], roster: [ProfileSummary]) {
        var grouped: [TelemetryProvider: [OwnershipRecord]] = [:]
        for record in ownership { grouped[record.provider, default: []].append(record) }
        for provider in grouped.keys { grouped[provider]?.sort { ($0.at, $0.seq ?? 0) < ($1.at, $1.seq ?? 0) } }
        byProvider = grouped
        var slugs: [String: UUID] = [:]
        for profile in roster where profile.provider == .codex {
            if let slug = profile.codexHomeSlug, !slug.isEmpty, slug != ".codex" { slugs[slug] = profile.id }
        }
        codexSlugToProfile = slugs
        let grok = roster.filter { $0.provider == .grok }
        soleGrokProfile = grok.count == 1 ? grok[0].id : nil
        self.roster = Dictionary(roster.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `source` is the unit's origin string: for Codex the home directory's
    /// last path component (an isolated home's slug, or ".codex").
    func attribute(provider: TelemetryProvider, at: Date, source: String?) -> Attribution {
        if provider == .codex, let source, let profile = codexSlugToProfile[source] {
            return .profile(profile, basis: .byPath)
        }
        if provider == .grok, let sole = soleGrokProfile {
            return .profile(sole, basis: .soleAccount)
        }
        return timeline(provider: provider, at: at)
    }

    private func timeline(provider: TelemetryProvider, at: Date) -> Attribution {
        guard let records = byProvider[provider], let firstRecord = records.first, at >= firstRecord.at else {
            return .unattributed(.beforeLog)
        }
        // Last record at or before `at`.
        var low = 0, high = records.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if records[mid].at <= at { low = mid } else { high = mid - 1 }
        }
        let current = records[low]
        let next = low + 1 < records.count ? records[low + 1] : nil
        let exact = current.basis == .exactClaim || current.basis == .seededFromRing
        if !exact {
            if let next {
                // Observed owner, followed by a different owner that was only
                // observed: the switch happened somewhere in between.
                if next.profileId != current.profileId && next.basis != .exactClaim && next.basis != .seededFromRing {
                    return .unattributed(.gap)
                }
            } else if at.timeIntervalSince(current.at) > Self.trailingTrust {
                return .unattributed(.gap)
            }
        }
        guard let owner = current.profileId else { return .unattributed(.noOwner) }
        return .profile(owner, basis: .timeline)
    }
}
