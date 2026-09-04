//
//  FleetInsights.swift
//  Claude Usage
//
//  Dashboard depth beyond B2 (docs/specs/ux-revamp.md §4, stage 4a — models and
//  persistence only; the redesign session embeds the view in 4b). Every number
//  here is derived from data the app already keeps: the fleet selections, the
//  switch ring, the measured-session history, the rate-limit incident ring and
//  the drift episodes. Nothing reshapes an existing type.
//

import Foundation

struct FleetInsights: Hashable {
    // MARK: 1. Reset timeline

    /// One marker per DISTINCT account per window: when the window resets and
    /// how much headroom comes back with it.
    struct ResetMarker: Hashable {
        var id: UUID
        var name: String
        var provider: Profile.ProviderKind
        var window: WindowGauge.Kind
        var resetAt: Date
        /// `100 − percentage` of the window at the reset — what returns.
        var headroomReturning: Double
    }
    var resetTimeline: [ResetMarker]

    // MARK: 2. Blind spots

    struct Backoff: Hashable {
        var until: Date
        var streak: Int
    }

    /// The provider-active account's measurement health.
    struct BlindSpot: Hashable {
        var id: UUID
        var name: String
        var provider: Profile.ProviderKind
        /// Seconds since a measurement of the account's OWN endpoint (nil = never).
        var sinceOwnMeasurement: TimeInterval?
        var provenance: MeasurementProvenance?
        var headerRescuesLastHour: Int
        var backoff: Backoff?
        /// True when the shown number is older than the stale threshold or not
        /// the account's own — the dashboard paints the row as a blind spot.
        var isBlind: Bool
    }
    var blindness: [BlindSpot]

    // MARK: 3. Drift

    /// The CLI's login moved without this app doing it (adoption repaired the
    /// pointer silently; the user should still see that it happened).
    struct Drift: Hashable {
        var at: Date
        var provider: Profile.ProviderKind
        var newOwnerId: UUID?
        var newOwnerName: String
    }
    var drift: [Drift]

    // MARK: 4. Switch log

    struct SwitchRow: Hashable {
        var at: Date
        var from: String
        var to: String
        var trigger: SwitchEvent.Trigger
        var reason: String?
        /// Inferred from the profile names; nil when neither name resolves.
        var provider: Profile.ProviderKind?
        /// Recorded before the Viewing / Active split, when a focus change also
        /// wrote a switch row (R2: viewing never records one now).
        var isLegacy: Bool
        var fromHeadroom: Double?
    }
    var switchLog: [SwitchRow]

    // MARK: 5. Burn

    struct Burn: Hashable {
        struct Sample: Hashable {
            var at: Date
            var pct: Double
        }
        var id: UUID
        var name: String
        var provider: Profile.ProviderKind
        /// Percentage points per minute over the retained samples; nil below
        /// the evidence bar (two samples ≥ 25 s apart, rising).
        var ratePerMinute: Double?
        var samples: [Sample]
        /// When the session window crosses its auto-switch threshold at this
        /// rate; nil when not rising.
        var projectedCrossing: Date?
    }
    var burn: [Burn]

    // MARK: 6. Incidents

    struct Incident: Hashable {
        enum Kind: Hashable {
            /// A running CLI transcript reported the account's own rate limit.
            case tripwire
            /// `oauth/usage` answered 429 with a real Retry-After (server-affirmed).
            case affirmedStamp(until: Date)
            /// The consecutive-429 inference marked the account suspected.
            case inferredStamp
            /// The Messages-API header probe was refused.
            case headerProbe429
            /// The header probe measured the account (blind-spot rescue).
            case headerRescue
            /// A burst-class 429 backed the fetch off.
            case burst429(streak: Int)
            /// A fresh reading claimed LESS utilization than the last
            /// server-affirmed one before the window's boundary had passed, so
            /// the previous percentage was held (see
            /// `ClaudeUsage.reconciledWithPrevious`).
            case heldLowReading
        }
        var at: Date
        var profileId: UUID?
        var name: String
        var provider: Profile.ProviderKind
        var kind: Kind
        var detail: String?
    }
    var incidents: [Incident]

    // MARK: 7–9. Capacity and "why not the others"

    var capacity: [Profile.ProviderKind: Double]

    struct WhyNot: Hashable {
        var id: UUID
        var name: String
        var provider: Profile.ProviderKind
        var status: CandidateRow.Status
        /// The block's evidence in words (readiness / duplicate / excluded).
        var evidence: String
        /// The preflight verdict and its age, when one exists.
        var verdictText: String?
        var evidenceAge: TimeInterval?
    }
    var whyNotOthers: [WhyNot]

    // MARK: Build

    static let timelineHorizon: TimeInterval = 7 * 24 * 3600
    static let incidentsWindow: TimeInterval = 24 * 3600
    /// Rows recorded before this moment come from the era when viewing a
    /// profile also wrote a switch row (the split landed 2026-09-03, #58).
    static let viewingSplitDate = Date(timeIntervalSince1970: 1_756_918_800)

    struct Inputs {
        var selections: [ProviderActiveSelection]
        var profiles: [Profile]
        var switchHistory: [SwitchEvent]
        var measured: [UUID: [(at: Date, pct: Double)]]
        var incidents: [Incident]
        var drift: [Drift]
        var backoffs: [UUID: Backoff]
        var counts: [FleetCounts.Provider]
        var staleAfter: TimeInterval = 180
        var now: Date = Date()
    }

    static func build(_ input: Inputs) -> FleetInsights {
        let now = input.now
        let byId = Dictionary(uniqueKeysWithValues: input.profiles.map { ($0.id, $0) })
        let byName = Dictionary(input.profiles.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })

        // 1. Reset timeline — one marker per distinct account per window.
        var seen: Set<String> = []
        var timeline: [ResetMarker] = []
        for profile in input.profiles {
            guard let usage = profile.claudeUsage else { continue }
            let key = FleetCounts.accountKey(profile)
            var windows: [(WindowGauge.Kind, Date, Double)] = [(.weekly, usage.weeklyResetTime, usage.weeklyPercentage)]
            if let fable = usage.fableWeeklyPercentage, let at = usage.fableWeeklyResetTime { windows.append((.fable, at, fable)) }
            for (kind, at, pct) in windows {
                guard at > now, at <= now.addingTimeInterval(timelineHorizon) else { continue }
                let dedupe = "\(key)|\(kind.rawValue)"
                guard !seen.contains(dedupe) else { continue }
                seen.insert(dedupe)
                timeline.append(ResetMarker(id: profile.id, name: profile.name, provider: profile.providerKind,
                                            window: kind, resetAt: at, headroomReturning: max(0, min(100, pct))))
            }
        }
        timeline.sort { $0.resetAt < $1.resetAt }

        // 2. Blind spots — the provider-active accounts.
        let recentRescues = input.incidents.filter { $0.kind == .headerRescue && now.timeIntervalSince($0.at) <= 3600 }
        var blindness: [BlindSpot] = []
        for selection in input.selections {
            guard let owner = selection.owner else { continue }
            let since = owner.measurement?.isOwn == true ? now.timeIntervalSince(owner.measurement!.measuredAt) : nil
            let provenance = owner.measurement?.provenance
            let blind = since.map { $0 > input.staleAfter } ?? true || provenance?.isOwnMeasurement == false
            blindness.append(BlindSpot(id: owner.id, name: owner.name, provider: selection.provider,
                                       sinceOwnMeasurement: since, provenance: provenance,
                                       headerRescuesLastHour: recentRescues.filter { $0.profileId == owner.id }.count,
                                       backoff: input.backoffs[owner.id].flatMap { $0.until > now ? $0 : nil },
                                       isBlind: blind))
        }

        // 4. Switch log — newest first, provider inferred from the names.
        let switchLog: [SwitchRow] = input.switchHistory.reversed().map { event in
            let provider = byName[event.to]?.providerKind ?? byName[event.from]?.providerKind
                ?? event.providerRaw.flatMap(providerKind(from:))
            return SwitchRow(at: event.at, from: event.from, to: event.to, trigger: event.trigger, reason: event.reason,
                             provider: provider, isLegacy: event.at < viewingSplitDate, fromHeadroom: event.fromHeadroom)
        }

        // 5. Burn — per profile with samples.
        var burn: [Burn] = []
        for (id, raw) in input.measured {
            guard let profile = byId[id], !raw.isEmpty else { continue }
            let samples = raw.sorted { $0.at < $1.at }.suffix(4).map { Burn.Sample(at: $0.at, pct: $0.pct) }
            let rate = burnRate(samples)
            var crossing: Date?
            if let rate, rate > 0, let last = samples.last,
               let threshold = input.selections.first(where: { $0.provider == profile.providerKind })?.owner?.gauges.first(where: { $0.kind == .session })?.threshold,
               last.pct < threshold {
                crossing = last.at.addingTimeInterval((threshold - last.pct) / rate * 60)
            }
            burn.append(Burn(id: id, name: profile.name, provider: profile.providerKind, ratePerMinute: rate,
                             samples: Array(samples), projectedCrossing: crossing))
        }
        burn.sort { ($0.ratePerMinute ?? -1) > ($1.ratePerMinute ?? -1) }

        // 6. Incidents — last 24 h, newest first.
        let incidents = input.incidents.filter { now.timeIntervalSince($0.at) <= incidentsWindow }.sorted { $0.at > $1.at }

        // 7–9.
        let capacity = Dictionary(uniqueKeysWithValues: input.counts.map { ($0.provider, $0.capacityRemaining) })
        var whyNot: [WhyNot] = []
        for selection in input.selections {
            for candidate in selection.candidates where candidate.status != .eligible {
                let verdictText = candidate.verdictAt == nil ? nil
                    : ActiveSelectorMenuModel.verdictText(candidate.verdict, kind: candidate.verdictKind, at: candidate.verdictAt, now: now)
                let age = candidate.measurement.map { now.timeIntervalSince($0.measuredAt) } ?? candidate.verdictAt.map { now.timeIntervalSince($0) }
                whyNot.append(WhyNot(id: candidate.id, name: candidate.name, provider: selection.provider, status: candidate.status,
                                     evidence: evidence(for: candidate), verdictText: verdictText, evidenceAge: age))
            }
        }

        return FleetInsights(resetTimeline: timeline, blindness: blindness, drift: input.drift.sorted { $0.at > $1.at },
                             switchLog: switchLog, burn: burn, incidents: incidents, capacity: capacity, whyNotOthers: whyNot)
    }

    /// Slope over the retained samples in percentage points per minute, or
    /// nil below the evidence bar (mirrors the projection's rule: two samples
    /// at least 25 s apart, rising).
    static func burnRate(_ samples: [Burn.Sample]) -> Double? {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else { return nil }
        let seconds = last.at.timeIntervalSince(first.at)
        guard seconds >= 25, last.pct > first.pct else { return nil }
        return (last.pct - first.pct) / (seconds / 60)
    }

    static func evidence(for candidate: CandidateRow) -> String {
        switch candidate.status {
        case .eligible: return ""
        case .blocked(let readiness): return readiness.legendWord
        case .duplicateOfOwner(let owner): return "insights.same_account_as".localized(with: owner)
        case .excluded(.autoSwitchOff): return "insights.excluded_toggle".localized
        case .excluded(.freePlan): return "insights.excluded_free".localized
        }
    }

    static func providerKind(from raw: String) -> Profile.ProviderKind? {
        Profile.ProviderKind.allCases.first { String(describing: $0) == raw }
    }
}

// The roster filter (spec §4 row 7) lives in the redesign's DashboardModel
// (`DashboardFilter` + `RosterRow.matches`), agreed 2026-09-04.

// MARK: - Rate-limit incident ring (spec §4 row 6)

/// In-memory ring of rate-limit incidents, capacity 100. The unified log keeps
/// ~12 h and persists nothing for this process; this keeps the last day's
/// evidence for the dashboard. Fed by `MenuBarManager` at the stamp sites.
final class IncidentRing {
    static let capacity = 100
    private(set) var entries: [FleetInsights.Incident] = []

    func record(_ incident: FleetInsights.Incident) {
        entries.append(incident)
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    func recent(within window: TimeInterval = FleetInsights.incidentsWindow, now: Date = Date()) -> [FleetInsights.Incident] {
        entries.filter { now.timeIntervalSince($0.at) <= window }
    }
}

// MARK: - Drift log (spec §4 row 3)

/// Remembers every `.providerOwnerChangedExternally` episode of this process
/// (the ⇄ menu shows only the latest until it is opened).
final class DriftLog {
    static let capacity = 20
    private(set) var episodes: [FleetInsights.Drift] = []
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = .default) {
        observer = center.addObserver(forName: .providerOwnerChangedExternally, object: nil, queue: .main) { [weak self] note in
            self?.record(note)
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func record(_ note: Notification, now: Date = Date()) {
        let raw = note.userInfo?["provider"] as? String ?? ""
        let provider = FleetInsights.providerKind(from: raw) ?? .claude
        let name = note.userInfo?["ownerName"] as? String ?? "?"
        episodes.append(FleetInsights.Drift(at: now, provider: provider, newOwnerId: note.object as? UUID, newOwnerName: name))
        if episodes.count > Self.capacity { episodes.removeFirst(episodes.count - Self.capacity) }
    }
}
