//
//  DashboardInsightsView.swift
//  Claude Usage
//
//  The dashboard's Insights block (docs/specs/ux-revamp.md §4, stage 4b): the
//  sections of a `FleetInsights`, in the agreed order — timeline first — drawn
//  in the dashboard's own scale (9.5-pt rows, 9-pt bold sub-headers, 8.5-pt
//  details — one step under its 10-pt section titles). Takes the model and `now`, nothing else; the redesign session
//  embeds it collapsed under the last provider section.
//

import SwiftUI

struct DashboardInsightsView: View {
    let insights: FleetInsights
    var now: Date = Date()
    @State private var logProvider: Profile.ProviderKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("insights.timeline".localized, empty: insights.resetTimeline.isEmpty ? "insights.timeline_empty".localized : nil) {
                InsightsTimelineStrip(markers: insights.resetTimeline, now: now)
            }
            section("insights.blind".localized, empty: insights.blindness.isEmpty ? "insights.blind_empty".localized : nil) {
                ForEach(insights.blindness, id: \.id) { spot in
                    row(glyph: spot.isBlind ? DesignGlyph.unmeasured : DesignGlyph.ready,
                        tint: spot.isBlind ? DesignRole.caution.color : DesignRole.ready.color,
                        title: spot.name, detail: InsightsFormatting.blind(spot, now: now))
                }
            }
            if !insights.drift.isEmpty {
                section("insights.drift".localized, empty: nil) {
                    ForEach(insights.drift, id: \.self) { drift in
                        row(glyph: DesignGlyph.next, tint: DesignRole.caution.color,
                            title: "insights.drift_row".localized(with: ActiveVocabulary.providerName(drift.provider), drift.newOwnerName),
                            detail: DashboardFormatting.age(drift.at, now: now))
                    }
                }
            }
            section("insights.switch_log".localized, empty: insights.switchLog.isEmpty ? "insights.switch_log_empty".localized : nil) {
                Picker("", selection: $logProvider) {
                    Text("insights.all".localized).tag(Profile.ProviderKind?.none)
                    ForEach([Profile.ProviderKind.claude, .codex, .grok], id: \.self) { p in
                        Text(ActiveVocabulary.providerName(p)).tag(Profile.ProviderKind?.some(p))
                    }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(maxWidth: 220)
                ForEach(filteredLog, id: \.self) { entry in
                    row(glyph: DesignGlyph.next, tint: entry.isLegacy ? DesignRole.informational.color : DesignRole.action.color,
                        title: "\(entry.from) → \(entry.to)", detail: InsightsFormatting.switchDetail(entry, now: now))
                }
            }
            section("insights.burn".localized, empty: insights.burn.isEmpty ? "insights.burn_empty".localized : nil) {
                ForEach(insights.burn, id: \.id) { burn in
                    HStack(spacing: 6) {
                        InsightsSparkline(samples: burn.samples).frame(width: 40, height: 12)
                        Text(burn.name).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
                        Text(InsightsFormatting.burn(burn, now: now)).font(.system(size: 8.5)).foregroundColor(.secondary).monospacedDigit()
                        Spacer(minLength: 0)
                    }
                }
            }
            section("insights.incidents".localized, empty: insights.incidents.isEmpty ? "insights.incidents_empty".localized : nil) {
                ForEach(insights.incidents.prefix(20), id: \.self) { incident in
                    row(glyph: InsightsFormatting.glyph(for: incident.kind), tint: InsightsFormatting.tint(for: incident.kind),
                        title: incident.name, detail: InsightsFormatting.incident(incident, now: now))
                }
            }
            section("insights.capacity".localized, empty: insights.capacity.isEmpty ? "insights.capacity_empty".localized : nil) {
                ForEach([Profile.ProviderKind.claude, .codex, .grok], id: \.self) { p in
                    if let value = insights.capacity[p] {
                        Text("insights.capacity_line".localized(with: ActiveVocabulary.providerName(p), value))
                            .font(.system(size: 9.5)).monospacedDigit()
                    }
                }
            }
            if !insights.whyNotOthers.isEmpty {
                section("insights.why_not".localized, empty: nil) {
                    ForEach(insights.whyNotOthers, id: \.id) { why in
                        row(glyph: InsightsFormatting.glyph(for: why.status), tint: InsightsFormatting.tint(for: why.status),
                            title: why.name, detail: InsightsFormatting.whyNot(why))
                    }
                }
            }
        }
    }

    private var filteredLog: [FleetInsights.SwitchRow] {
        insights.switchLog.filter { logProvider == nil || $0.provider == logProvider }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, empty: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.5).foregroundColor(.secondary)
            if let empty {
                Text(empty).font(.system(size: 9)).foregroundColor(.secondary)
            } else {
                content()
            }
        }
    }

    private func row(glyph: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(glyph).font(.system(size: 9)).foregroundColor(tint).frame(width: 10)
            Text(title).font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
            Text(detail).font(.system(size: 8.5)).foregroundColor(.secondary).monospacedDigit().lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Timeline strip (7 days)

struct InsightsTimelineStrip: View {
    let markers: [FleetInsights.ResetMarker]
    let now: Date

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 10)); p.addLine(to: CGPoint(x: width, y: 10))
                    for day in 0...7 {
                        let x = width * CGFloat(day) / 7
                        p.move(to: CGPoint(x: x, y: 6)); p.addLine(to: CGPoint(x: x, y: 14))
                    }
                }
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                ForEach(Array(markers.enumerated()), id: \.offset) { index, marker in
                    let x = width * InsightsFormatting.timelinePosition(marker.resetAt, now: now)
                    Circle().fill(marker.window == .fable ? DesignRole.suspected.color : DesignRole.ready.color)
                        .frame(width: 6, height: 6).position(x: x, y: 10)
                    Text(InsightsFormatting.timelineLabel(marker))
                        .font(.system(size: 8)).monospacedDigit().lineLimit(1)
                        .position(x: min(max(x, 22), width - 22), y: index.isMultiple(of: 2) ? 22 : 32)
                }
            }
        }
        .frame(height: 40)
        .accessibilityLabel(markers.map(InsightsFormatting.timelineLabel).joined(separator: ", "))
    }
}

// MARK: - Sparkline

struct InsightsSparkline: View {
    let samples: [FleetInsights.Burn.Sample]

    var body: some View {
        GeometryReader { geo in
            Path { p in
                guard samples.count >= 2 else { return }
                let lo = samples.map(\.pct).min()!, hi = max(samples.map(\.pct).max()!, lo + 1)
                for (i, s) in samples.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(samples.count - 1)
                    let y = geo.size.height * (1 - CGFloat((s.pct - lo) / (hi - lo)))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(DesignRole.caution.color, lineWidth: 1.5)
        }
    }
}

// MARK: - Formatting (pure, tested)

enum InsightsFormatting {
    /// 0…1 across the 7-day horizon (clamped).
    static func timelinePosition(_ date: Date, now: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(now) / FleetInsights.timelineHorizon, 0), 1))
    }

    /// "dRir W 84 %" — name, window letter, the window's usage that resets.
    static func timelineLabel(_ marker: FleetInsights.ResetMarker) -> String {
        let letter = marker.window == .fable ? "F" : "W"
        return "\(marker.name) \(letter) \(Int(marker.headroomReturning.rounded())) %"
    }

    static func blind(_ spot: FleetInsights.BlindSpot, now: Date) -> String {
        var parts: [String] = []
        if let since = spot.sinceOwnMeasurement {
            parts.append("insights.own_ago".localized(with: DashboardFormatting.age(now.addingTimeInterval(-since), now: now)))
        } else {
            parts.append("insights.never_own".localized)
        }
        if let provenance = spot.provenance, !provenance.isOwnMeasurement { parts.append("insights.shown_from_cache".localized) }
        if spot.headerRescuesLastHour > 0 { parts.append("insights.header_rescues".localized(with: spot.headerRescuesLastHour)) }
        if let backoff = spot.backoff {
            parts.append("insights.backoff".localized(with: DashboardFormatting.duration(backoff.until.timeIntervalSince(now)), backoff.streak))
        }
        return parts.joined(separator: " · ")
    }

    static func trigger(_ trigger: SwitchEvent.Trigger) -> String {
        switch trigger {
        case .auto: return "insights.trigger_auto".localized
        case .manual: return "insights.trigger_manual".localized
        case .queued: return "insights.trigger_queued".localized
        }
    }

    static func switchDetail(_ row: FleetInsights.SwitchRow, now: Date) -> String {
        var parts = [DashboardFormatting.age(row.at, now: now), trigger(row.trigger)]
        if let reason = row.reason, !reason.isEmpty {
            parts.append(reason)
        } else if let headroom = row.fromHeadroom {
            parts.append("insights.left_at".localized(with: Int((100 - headroom).rounded())))
        }
        if row.isLegacy { parts.append("insights.legacy_row".localized) }
        return parts.joined(separator: " · ")
    }

    static func burn(_ burn: FleetInsights.Burn, now: Date) -> String {
        guard let rate = burn.ratePerMinute else { return "insights.burn_flat".localized }
        var text = "insights.burn_rate".localized(with: rate)
        if let crossing = burn.projectedCrossing {
            text += " · " + "insights.crosses_in".localized(with: DashboardFormatting.duration(max(0, crossing.timeIntervalSince(now))))
        }
        return text
    }

    static func incident(_ incident: FleetInsights.Incident, now: Date) -> String {
        let kind: String
        switch incident.kind {
        case .tripwire: kind = "insights.kind_tripwire".localized
        case .affirmedStamp(let until): kind = "insights.kind_affirmed".localized(with: DashboardFormatting.duration(max(0, until.timeIntervalSince(now))))
        case .inferredStamp: kind = "insights.kind_inferred".localized
        case .headerProbe429: kind = "insights.kind_probe_429".localized
        case .headerRescue: kind = "insights.kind_rescue".localized
        case .burst429(let streak): kind = "insights.kind_burst".localized(with: streak)
        }
        var parts = [DashboardFormatting.age(incident.at, now: now), kind]
        if let detail = incidentDetail(incident) { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    /// The recorder's free-text detail in human form: dropped for an affirmed
    /// stamp (its "left" phrase says it), the header ratio ("5h 0.86") as
    /// "5-hour window 86 %", anything else verbatim.
    static func incidentDetail(_ incident: FleetInsights.Incident) -> String? {
        guard let detail = incident.detail, !detail.isEmpty else { return nil }
        if case .affirmedStamp = incident.kind { return nil }
        let parts = detail.split(separator: " ")
        if parts.count == 2, parts[0] == "5h", let ratio = Double(parts[1]) {
            return "insights.window_ratio".localized(with: Int((ratio * 100).rounded()))
        }
        return detail
    }

    static func whyNot(_ why: FleetInsights.WhyNot) -> String {
        var parts: [String] = []
        if let verdict = why.verdictText {
            parts.append(verdict)
        } else if let age = why.evidenceAge {
            parts.append(why.evidence)
            parts.append("insights.evidence_age".localized(with: DashboardFormatting.duration(age)))
        } else {
            parts.append(why.evidence)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func glyph(for kind: FleetInsights.Incident.Kind) -> String {
        switch kind {
        case .headerRescue: return DesignGlyph.unmeasured
        case .inferredStamp: return DesignGlyph.suspected
        case .tripwire, .affirmedStamp, .headerProbe429, .burst429: return DesignGlyph.exhausted
        }
    }

    static func tint(for kind: FleetInsights.Incident.Kind) -> Color {
        switch kind {
        case .headerRescue: return DesignRole.informational.color
        case .inferredStamp: return DesignRole.suspected.color
        case .tripwire, .affirmedStamp: return DesignRole.blocking.color
        case .headerProbe429, .burst429: return DesignRole.caution.color
        }
    }

    static func glyph(for status: CandidateRow.Status) -> String {
        switch status {
        case .eligible: return DesignGlyph.ready
        case .blocked(let readiness): return readiness.legendGlyph
        case .duplicateOfOwner: return DesignGlyph.duplicate
        case .excluded: return DesignGlyph.excluded
        }
    }

    static func tint(for status: CandidateRow.Status) -> Color {
        switch status {
        case .eligible: return DesignRole.ready.color
        case .blocked(let readiness): return readiness.role.color
        case .duplicateOfOwner, .excluded: return DesignRole.informational.color
        }
    }
}

// MARK: - Fixture (frames and previews)

#if DEBUG
extension FleetInsights {
    static func fixture(now: Date) -> FleetInsights {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let h: TimeInterval = 3600
        return FleetInsights(
            resetTimeline: [
                ResetMarker(id: a, name: "dRir", provider: .claude, window: .weekly, resetAt: now.addingTimeInterval(9 * h), headroomReturning: 84),
                ResetMarker(id: b, name: "Commits", provider: .claude, window: .weekly, resetAt: now.addingTimeInterval(31 * h), headroomReturning: 100),
                ResetMarker(id: a, name: "dRir", provider: .claude, window: .fable, resetAt: now.addingTimeInterval(2 * 24 * h), headroomReturning: 10),
                ResetMarker(id: c, name: "xFho", provider: .codex, window: .weekly, resetAt: now.addingTimeInterval(4.5 * 24 * h), headroomReturning: 90),
                ResetMarker(id: d, name: "Grok", provider: .grok, window: .weekly, resetAt: now.addingTimeInterval(6.2 * 24 * h), headroomReturning: 88),
            ],
            blindness: [
                BlindSpot(id: a, name: "dRir", provider: .claude, sinceOwnMeasurement: 30, provenance: .ownEndpoint, headerRescuesLastHour: 0, backoff: nil, isBlind: false),
                BlindSpot(id: c, name: "xFernando(dev)", provider: .codex, sinceOwnMeasurement: 4 * 60, provenance: .headerRescue, headerRescuesLastHour: 2,
                          backoff: Backoff(until: now.addingTimeInterval(120), streak: 3), isBlind: true),
                BlindSpot(id: d, name: "Grok", provider: .grok, sinceOwnMeasurement: nil, provenance: .cliCache, headerRescuesLastHour: 0, backoff: nil, isBlind: true),
            ],
            drift: [Drift(at: now.addingTimeInterval(-12 * 60), provider: .claude, newOwnerId: b, newOwnerName: "jskxkxjssh")],
            switchLog: [
                SwitchRow(at: now.addingTimeInterval(-12 * 60), from: "Google", to: "jskxkxjssh", trigger: .auto, reason: "session 96 %", provider: .claude, isLegacy: false, fromHeadroom: 4),
                SwitchRow(at: now.addingTimeInterval(-3 * h), from: "xFenrir(dev)", to: "xFho", trigger: .queued, reason: nil, provider: .codex, isLegacy: false, fromHeadroom: nil),
                SwitchRow(at: now.addingTimeInterval(-26 * h), from: "Memori", to: "dRir", trigger: .manual, reason: nil, provider: .claude, isLegacy: true, fromHeadroom: nil),
            ],
            burn: [
                Burn(id: a, name: "dRir", provider: .claude, ratePerMinute: 2.1,
                     samples: [60, 90, 120, 150].enumerated().map { Burn.Sample(at: now.addingTimeInterval(-Double(150 - $0.element)), pct: 70 + Double($0.offset) * 3) },
                     projectedCrossing: now.addingTimeInterval(8 * 60)),
                Burn(id: c, name: "xFho", provider: .codex, ratePerMinute: nil,
                     samples: [Burn.Sample(at: now.addingTimeInterval(-90), pct: 30), Burn.Sample(at: now.addingTimeInterval(-30), pct: 30)], projectedCrossing: nil),
            ],
            incidents: [
                Incident(at: now.addingTimeInterval(-9 * 60), profileId: b, name: "Google", provider: .claude, kind: .affirmedStamp(until: now.addingTimeInterval(40 * 60)), detail: "retry-after 2918 s"),
                Incident(at: now.addingTimeInterval(-14 * 60), profileId: c, name: "xFernando(dev)", provider: .codex, kind: .headerRescue, detail: "5h 0.86"),
                Incident(at: now.addingTimeInterval(-50 * 60), profileId: a, name: "Outlook", provider: .claude, kind: .inferredStamp, detail: "streak 3, cache 89 %"),
                Incident(at: now.addingTimeInterval(-5 * h), profileId: nil, name: "BBR", provider: .claude, kind: .tripwire, detail: nil),
                Incident(at: now.addingTimeInterval(-7 * h), profileId: b, name: "Commits", provider: .claude, kind: .burst429(streak: 4), detail: nil),
            ],
            capacity: [.claude: 3.4, .codex: 1.1, .grok: 0.9],
            whyNotOthers: [
                WhyNot(id: b, name: "Ai", provider: .claude, status: .blocked(.dead), evidence: "dead login", verdictText: "× login dead 2 h ago", evidenceAge: 2 * h),
                WhyNot(id: c, name: "Google", provider: .claude, status: .duplicateOfOwner(ownerName: "dRir"), evidence: "same account as dRir", verdictText: nil, evidenceAge: 60),
                WhyNot(id: d, name: "Stanford", provider: .claude, status: .excluded(.freePlan), evidence: "free plan", verdictText: nil, evidenceAge: nil),
            ])
    }
}
#endif
