//
//  DashboardModel.swift
//  Claude Usage
//
//  The snapshot the fleet dashboard renders (docs/specs/menubar-redesign.md
//  §3): every provider with its active account, the next executable switch
//  target, the provider's slice of the queue, the roster in the bar's order,
//  recent switches and the health banners. Built ONCE per paint from plain
//  values and read by the view — no view observes the managers row by row.
//  Every number carries its provenance and age; a value that was not
//  measured with the account's own credentials is never presented as one.
//

import Foundation

// MARK: - Leaves

/// One quota window as the dashboard draws it.
struct WindowGauge: Hashable {
    enum Kind: String, Hashable { case session, weekly, fable }
    var kind: Kind
    /// Display seam (`displaySessionPercentage` for the session window).
    var percentage: Double
    var resetAt: Date?
    var duration: TimeInterval
    /// The auto-switch threshold this window fires at.
    var threshold: Double
}

/// Provenance + age of the value behind a row or card.
struct UsageMeasurement: Hashable {
    var provenance: MeasurementProvenance
    var measuredAt: Date
    /// True when the value was measured with the account's own credentials.
    var isOwn: Bool { provenance.isOwnMeasurement }
}

/// The caveat shown beside a suspected (inferred-throttle) account.
struct SuspectedCaveat: Hashable {
    var lastMeasured: Double
    var measuredAt: Date
    var projected: Double?
}

/// The one-line state chip of a roster row. Associated values are raw so
/// the view formats dates and numbers for the locale.
enum RowChip: Hashable {
    case ready
    case readyLight
    case nearLimit
    case sessionExhausted(resetAt: Date)
    case weeklyMaxed
    case fableMaxed
    case rateLimited(until: Date)
    case suspected(lastMeasured: Double, at: Date)
    case unmeasured
    case autoSwitchOff
    case freePlan
    case deadLogin
}

/// The one-click route out of a dead login. Settings sections are named by
/// raw value so the model stays free of view types.
enum RepairAction: Hashable {
    case claudeLogin
    case codexLogin
    case grokLogin

    var settingsSectionRawValue: String? {
        switch self {
        case .claudeLogin: return "cliAccount"
        case .codexLogin: return "codexAccount"
        case .grokLogin: return nil
        }
    }
}

// MARK: - Cards and rows

struct ActiveCard: Hashable {
    var id: UUID
    var name: String
    var isFocused: Bool
    var readiness: AccountReadiness
    var gauges: [WindowGauge]
    var measurement: UsageMeasurement?
    var suspected: SuspectedCaveat?
    /// Seconds until the firing window reaches its threshold at the current
    /// pace; nil when it will not before the window resets (or no pace yet).
    var etaToThreshold: TimeInterval?
    /// Other profiles that are the SAME provider account (one quota): named
    /// so the card can say "same account as Beacon".
    var sameAccountAs: [String] = []
}

struct NextCard: Hashable {
    enum Source: Hashable { case queued, ranked, rankedBehindBlockedQueueHead }
    var candidateId: UUID
    var name: String
    var source: Source
    var readiness: AccountReadiness
    var verdict: NextCandidate.Verdict
    var verdictAt: Date?
    var quotaMeasuredAt: Date?
}

struct QueueEntry: Hashable {
    var id: UUID
    var name: String
    var position: Int
    /// Not executable right now (dead, no headroom, excluded).
    var blocked: Bool
}

struct RosterRow: Hashable {
    var id: UUID
    var name: String
    var readiness: AccountReadiness
    var isStale: Bool
    var gauges: [WindowGauge]
    var measurement: UsageMeasurement?
    var chip: RowChip
    var queuePosition: Int?
    var repair: RepairAction?
    var isSelectedForDisplay: Bool
    /// Other profiles that are the SAME provider account (one quota). A
    /// duplicate is never a switch candidate — switching to it changes nothing.
    var sameAccountAs: [String] = []
    /// The ⇄ selector's verdict on this row (eligible / blocked / duplicate
    /// of the owner / excluded), from the shared `ProviderActiveSelection`.
    var candidateStatus: CandidateRow.Status?
    /// The auto-switch's predicted next target.
    var isNext: Bool = false
    /// Named by `ProfileManager.profilesNeedingAccountRelogin` (a login that
    /// carried another account, or a duplicate of the CLI's login).
    var needsRelogin: Bool = false
}

struct ProviderSection: Hashable {
    var provider: Profile.ProviderKind
    var active: ActiveCard?
    var next: NextCard?
    /// The auto-switch thresholds this provider fires on (session nil for
    /// weekly-only providers).
    var sessionThreshold: Double?
    var weeklyThreshold: Double
    var queue: [QueueEntry]
    /// The OTHER accounts, in the bar's painted order.
    var roster: [RosterRow]
    var hiddenByOverflow: Bool
    var summary: ProviderSummary
    /// What the ⇄ selector menu shows for this provider (owner, viewing,
    /// ranked candidates, counts) — the same value, built once here, so the
    /// dashboard and the menu can never disagree (docs/specs/ux-revamp.md D6).
    var selection: ProviderActiveSelection?
}

struct RecentSwitch: Hashable {
    var at: Date
    var from: String
    var to: String
    var trigger: SwitchEvent.Trigger
    var reason: String?
    var provider: Profile.ProviderKind?
}

enum DashboardBanner: Hashable {
    case preferencesDegraded
    case deadLogins(count: Int)
    case noCandidate(Profile.ProviderKind)
    case hiddenByOverflow(Profile.ProviderKind)
}

// MARK: - Filter

/// What the dashboard's roster can be narrowed to (UX revamp stage 4, the
/// Insights block's filter). Pure; nil / empty means "no constraint".
struct DashboardFilter: Hashable {
    var readiness: Set<AccountReadiness> = []
    var provenance: Set<MeasurementProvenance> = []
    /// Only rows whose own reading is older than this many minutes.
    var staleMinutes: Int?
    var queuedOnly = false
    var provider: Profile.ProviderKind?

    var isEmpty: Bool {
        readiness.isEmpty && provenance.isEmpty && staleMinutes == nil && !queuedOnly && provider == nil
    }
}

extension RosterRow {
    /// Whether this row of `provider`'s roster survives `filter` at `now`.
    /// A row with no measurement never matches a provenance or staleness
    /// constraint: absence is not evidence of either.
    nonisolated func matches(_ filter: DashboardFilter, provider: Profile.ProviderKind, now: Date) -> Bool {
        if let wanted = filter.provider, wanted != provider { return false }
        if !filter.readiness.isEmpty, !filter.readiness.contains(readiness) { return false }
        if filter.queuedOnly, queuePosition == nil { return false }
        if !filter.provenance.isEmpty {
            guard let m = measurement, filter.provenance.contains(m.provenance) else { return false }
        }
        if let minutes = filter.staleMinutes {
            guard let m = measurement, now.timeIntervalSince(m.measuredAt) > Double(minutes) * 60 else { return false }
        }
        return true
    }
}

// MARK: - Snapshot

struct DashboardSnapshot: Hashable {
    /// Dashboard reading order (largest group first).
    static let sectionOrder: [Profile.ProviderKind] = [.claude, .codex, .grok]
    static let recentSwitchLimit = 5

    var banners: [DashboardBanner]
    var sections: [ProviderSection]
    var recentSwitches: [RecentSwitch]
    var generatedAt: Date
    /// The fleet-level insights (UX revamp stage 4a: reset timeline, blind
    /// spots, drift, switch log, burn, incidents, capacity, why-not), built
    /// by the manager beside the snapshot and rendered as the collapsed
    /// Insights block under the last section. nil until assigned.
    var insights: FleetInsights?

    var accountCount: Int { sections.reduce(0) { $0 + $1.roster.count + ($1.active == nil ? 0 : 1) } }

    struct Inputs {
        var profiles: [Profile]
        /// Provider owners (`ProfileManager.activeAccountIds`).
        var activeIds: Set<UUID>
        var focusedId: UUID?
        /// The bar's painted order per provider when known; else the ranking.
        var paintedOrder: [Profile.ProviderKind: [UUID]] = [:]
        var context: FleetSummaryContext
        var queue: [UUID]
        var history: [SwitchEvent]
        var hiddenProviders: Set<Profile.ProviderKind> = []
        /// Groups of profile ids that resolve to one provider account
        /// (`FleetCounts.duplicateGroups(in:published:)`).
        var duplicateGroups: [[UUID]] = []
        /// `MenuBarManager.autoSwitchedProfileIds`: user-chosen owners the
        /// auto-switch will not move while they are over a threshold.
        var manuallyPinned: Set<UUID> = []
        /// `ProfileManager.profilesNeedingAccountRelogin`.
        var needsRelogin: Set<UUID> = []
    }

    static func build(_ inputs: Inputs) -> DashboardSnapshot {
        let now = inputs.context.now
        let thresholds = inputs.context.thresholds
        let byId = Dictionary(uniqueKeysWithValues: inputs.profiles.map { ($0.id, $0) })
        let nameToProvider = Dictionary(inputs.profiles.map { ($0.name, $0.providerKind) }, uniquingKeysWith: { a, _ in a })

        // The selector's view of every provider, built ONCE per snapshot.
        let selections = Dictionary(uniqueKeysWithValues: ProviderActiveSelection.build(
            ProviderActiveSelection.Inputs(
                profiles: inputs.profiles, activeIds: inputs.activeIds, focusedId: inputs.focusedId,
                paintedOrder: inputs.paintedOrder, context: inputs.context, queue: inputs.queue,
                duplicateGroups: inputs.duplicateGroups, manuallyPinned: inputs.manuallyPinned,
                needsRelogin: inputs.needsRelogin
            )
        ).map { ($0.provider, $0) })

        // id → the names of its duplicates (same account, other profiles).
        var duplicates: [UUID: [String]] = [:]
        for group in inputs.duplicateGroups {
            for id in group {
                duplicates[id] = group.filter { $0 != id }.compactMap { byId[$0]?.name }
            }
        }

        var readiness: [UUID: AccountReadiness] = [:]
        var stale: Set<UUID> = []
        for profile in inputs.profiles {
            readiness[profile.id] = AccountReadiness.classify(
                usage: profile.claudeUsage,
                isLoginDead: inputs.context.isLoginDead(profile),
                isExcluded: inputs.context.isExcluded(profile),
                thresholds: thresholds,
                now: now
            )
            if AccountReadiness.isStale(profile.claudeUsage, thresholds: thresholds, now: now) {
                stale.insert(profile.id)
            }
        }

        var sections: [ProviderSection] = []
        var banners: [DashboardBanner] = []
        if inputs.context.preferencesDegraded { banners.append(.preferencesDegraded) }
        let deadCount = readiness.values.filter { $0 == .dead }.count
        if deadCount > 0 { banners.append(.deadLogins(count: deadCount)) }

        for provider in sectionOrder {
            let members = orderedMembers(provider: provider, inputs: inputs, now: now)
            guard !members.isEmpty else { continue }
            let activeId = members.first { inputs.activeIds.contains($0) }
            let activeProfile = activeId.flatMap { byId[$0] }

            let next = inputs.context.nextCandidates[provider].map { predicted -> NextCandidate in
                let candidateReadiness = readiness[predicted.id] ?? .unknown
                return NextCandidate(
                    id: predicted.id,
                    label: predicted.label,
                    queued: predicted.queued,
                    queueHeadBlocked: predicted.queueHeadBlocked,
                    readiness: candidateReadiness,
                    verdict: NextCandidate.verdict(
                        readiness: candidateReadiness,
                        preflight: inputs.context.preflightVerdicts[predicted.id],
                        now: now
                    )
                )
            }
            let summary = ProviderSummary.build(
                provider: provider,
                orderedMembers: members,
                activeId: activeId,
                readiness: readiness,
                stale: stale,
                keyedPercentage: activeProfile?.claudeUsage.map { ProviderSummary.keyedDisplayPercentage($0) },
                next: next,
                isSwitching: inputs.context.isSwitching,
                preferencesDegraded: inputs.context.preferencesDegraded,
                activeLastMeasured: activeProfile?.claudeUsage?.lastUpdated,
                now: now
            )
            if summary.alert == .noCandidate { banners.append(.noCandidate(provider)) }
            if inputs.hiddenProviders.contains(provider) { banners.append(.hiddenByOverflow(provider)) }

            let selection = selections[provider]
            let candidates = Dictionary(uniqueKeysWithValues: (selection?.candidates ?? []).map { ($0.id, $0) })
            let weeklyOnly = activeProfile?.claudeUsage.map { !$0.providesSessionWindow }
                ?? (provider != .claude)
            let queue = inputs.queue.enumerated().compactMap { index, id -> QueueEntry? in
                guard let profile = byId[id], profile.providerKind == provider else { return nil }
                return QueueEntry(
                    id: id, name: profile.name, position: index + 1,
                    blocked: readiness[id]?.blocksSwitchTarget ?? true
                )
            }

            sections.append(ProviderSection(
                provider: provider,
                active: activeProfile.map { profile in
                    var card = activeCard(profile, readiness: readiness[profile.id] ?? .unknown,
                                          isFocused: profile.id == inputs.focusedId, thresholds: thresholds, now: now)
                    card.sameAccountAs = duplicates[profile.id] ?? []
                    return card
                },
                next: next.map { candidate in
                    NextCard(
                        candidateId: candidate.id,
                        name: byId[candidate.id]?.name ?? candidate.label,
                        source: candidate.queued ? .queued
                            : (candidate.queueHeadBlocked ? .rankedBehindBlockedQueueHead : .ranked),
                        readiness: candidate.readiness,
                        verdict: candidate.verdict,
                        verdictAt: inputs.context.preflightVerdicts[candidate.id]?.at,
                        quotaMeasuredAt: byId[candidate.id]?.claudeUsage?.lastUpdated
                    )
                },
                sessionThreshold: weeklyOnly ? nil : thresholds.session,
                weeklyThreshold: thresholds.weekly,
                queue: queue,
                roster: members.filter { $0 != activeId }.compactMap { id in
                    byId[id].map { profile in
                        var row = rosterRow(profile, readiness: readiness[id] ?? .unknown, isStale: stale.contains(id),
                                            queuePosition: inputs.queue.firstIndex(of: id).map { $0 + 1 },
                                            thresholds: thresholds, now: now)
                        row.sameAccountAs = duplicates[id] ?? []
                        if let candidate = candidates[id] {
                            row.candidateStatus = candidate.status
                            row.isNext = candidate.isNext
                            row.needsRelogin = candidate.needsRelogin
                        }
                        return row
                    }
                },
                hiddenByOverflow: inputs.hiddenProviders.contains(provider),
                summary: summary,
                selection: selection
            ))
        }

        let recent = inputs.history.suffix(recentSwitchLimit).reversed().map { event in
            RecentSwitch(at: event.at, from: event.from, to: event.to, trigger: event.trigger,
                         reason: event.reason, provider: nameToProvider[event.to])
        }

        return DashboardSnapshot(banners: banners, sections: sections, recentSwitches: Array(recent), generatedAt: now)
    }

    // MARK: - Pieces

    /// Every account of the provider, left-to-right as the bar paints them
    /// (soonest weekly reset rightmost); the painted order wins when known.
    private static func orderedMembers(provider: Profile.ProviderKind, inputs: Inputs, now: Date) -> [UUID] {
        let inProvider = Set(inputs.profiles.filter { $0.providerKind == provider }.map(\.id))
        if let painted = inputs.paintedOrder[provider]?.filter({ inProvider.contains($0) }), !painted.isEmpty {
            let missing = inputs.profiles.filter { inProvider.contains($0.id) && !painted.contains($0.id) }.map(\.id)
            return missing + painted
        }
        return StatusBarUIManager.compositePaintOrder(
            StatusBarUIManager.multiProfileCreationOrder(for: inputs.profiles, now: now, includeUnselected: true)
                .filter { $0.providerKind == provider }
                .map(\.id)
        )
    }

    static func gauges(for usage: ClaudeUsage, thresholds: ReadinessThresholds) -> [WindowGauge] {
        var out: [WindowGauge] = []
        if usage.providesSessionWindow {
            out.append(WindowGauge(kind: .session, percentage: usage.displaySessionPercentage,
                                   resetAt: usage.sessionResetTime, duration: Constants.sessionWindow,
                                   threshold: thresholds.session))
        }
        out.append(WindowGauge(kind: .weekly, percentage: usage.weeklyPercentage,
                               resetAt: usage.weeklyResetTime, duration: Constants.weeklyWindow,
                               threshold: thresholds.weekly))
        if let fable = usage.fableWeeklyPercentage {
            out.append(WindowGauge(kind: .fable, percentage: fable, resetAt: usage.fableWeeklyResetTime,
                                   duration: Constants.weeklyWindow, threshold: thresholds.weekly))
        }
        return out
    }

    static func measurement(for usage: ClaudeUsage?) -> UsageMeasurement? {
        usage.map { UsageMeasurement(provenance: $0.provenance ?? .ownEndpoint, measuredAt: $0.lastUpdated) }
    }

    /// Seconds until `gauge` reaches its threshold at the pace observed so far
    /// in its window (linear from the window start). nil when the pace is
    /// unknown (window just started), already past the threshold (0 is
    /// returned instead), or it will not get there before the reset.
    static func etaToThreshold(_ gauge: WindowGauge, now: Date) -> TimeInterval? {
        guard let resetAt = gauge.resetAt, resetAt > now, gauge.duration > 0 else { return nil }
        if gauge.percentage >= gauge.threshold { return 0 }
        let remaining = resetAt.timeIntervalSince(now)
        let elapsed = gauge.duration - remaining
        guard elapsed >= 60, gauge.percentage > 0 else { return nil }
        let rate = gauge.percentage / elapsed
        let eta = (gauge.threshold - gauge.percentage) / rate
        return eta <= remaining ? eta : nil
    }

    private static func activeCard(_ profile: Profile, readiness: AccountReadiness, isFocused: Bool,
                                   thresholds: ReadinessThresholds, now: Date) -> ActiveCard {
        let usage = profile.claudeUsage
        let gauges = usage.map { Self.gauges(for: $0, thresholds: thresholds) } ?? []
        // The firing window: the session window where one exists (sessions
        // stall on it), else the weekly window.
        let firing = gauges.first { $0.kind == .session } ?? gauges.first { $0.kind == .weekly }
        var caveat: SuspectedCaveat?
        if let usage, usage.isSuspectedRateLimited {
            caveat = SuspectedCaveat(lastMeasured: usage.sessionPercentage, measuredAt: usage.lastUpdated,
                                     projected: usage.projectedSessionPercentage)
        }
        return ActiveCard(
            id: profile.id, name: profile.name, isFocused: isFocused, readiness: readiness,
            gauges: gauges, measurement: measurement(for: usage), suspected: caveat,
            etaToThreshold: firing.flatMap { etaToThreshold($0, now: now) }
        )
    }

    private static func rosterRow(_ profile: Profile, readiness: AccountReadiness, isStale: Bool,
                                  queuePosition: Int?, thresholds: ReadinessThresholds, now: Date) -> RosterRow {
        let usage = profile.claudeUsage
        let chip: RowChip
        switch readiness {
        case .dead: chip = .deadLogin
        case .excluded: chip = profile.isAutoSwitchEnabled ? .freePlan : .autoSwitchOff
        case .unknown: chip = .unmeasured
        case .suspected: chip = .suspected(lastMeasured: usage?.sessionPercentage ?? 0, at: usage?.lastUpdated ?? now)
        case .ready: chip = .ready
        case .readyLight: chip = .readyLight
        case .sessionHit, .sessionHitLight:
            if let usage, let until = usage.rateLimitedUntil, until > now, usage.rateLimitedInferred != true {
                chip = .rateLimited(until: until)
            } else {
                chip = .sessionExhausted(resetAt: usage?.sessionResetTime ?? now)
            }
        case .weeklyHit, .weeklyHitSoon:
            if let usage, usage.weeklyResetTime >= now, usage.weeklyPercentage >= thresholds.weekly {
                chip = .weeklyMaxed
            } else {
                chip = .fableMaxed
            }
        }
        let repair: RepairAction? = readiness == .dead
            ? (profile.providerKind == .codex ? .codexLogin : (profile.providerKind == .grok ? .grokLogin : .claudeLogin))
            : nil
        return RosterRow(
            id: profile.id, name: profile.name, readiness: readiness, isStale: isStale,
            gauges: usage.map { Self.gauges(for: $0, thresholds: thresholds) } ?? [],
            measurement: measurement(for: usage), chip: chip, queuePosition: queuePosition,
            repair: repair, isSelectedForDisplay: profile.isSelectedForDisplay
        )
    }
}
