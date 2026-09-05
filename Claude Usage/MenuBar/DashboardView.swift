//
//  DashboardView.swift
//  Claude Usage
//
//  The fleet dashboard — the click surface for the fleet-summary layouts
//  (docs/specs/menubar-redesign.md §3). Stacked provider sections, each with
//  the provider-active account's card, the next executable switch target, the
//  provider's slice of the queue and a two-line roster; recent switches
//  collapsed at the bottom. Renders a `DashboardSnapshot` the manager rebuilds
//  once per paint; every number carries its provenance and age, and a value
//  that was not measured with the account's own credentials is drawn dimmed
//  with a label. Account detail reuses the classic usage rows.
//

import Combine
import SwiftUI

// MARK: - Actions

/// Everything the dashboard can DO. The manager supplies these so the view
/// never reaches into services; every switch goes through the one activation
/// seam (`activateProfileDetailed`) and reports its outcome.
struct DashboardActions {
    var refresh: () -> Void
    /// Settings section raw value, or nil for the default section.
    var openSettings: (String?) -> Void
    var makeActive: (UUID) async -> ProfileManager.ActivationOutcome
    var queueNext: (UUID) -> Void
    var removeFromQueue: (UUID) -> Void
    /// Open the ⇄ selector menu on one provider's section
    /// (`Notification.Name.activeSelectorRequested`).
    var openActiveSelector: (Profile.ProviderKind) -> Void = { _ in }
    /// Open the token-usage window for one account, or the fleet (nil)
    /// (`Notification.Name.telemetryWindowRequested`).
    var openTokenUsage: (UUID?, Profile.ProviderKind?) -> Void = { _, _ in }
}

// MARK: - Store

/// What the dashboard observes: ONE snapshot per paint plus the clicked
/// provider. Deliberately not `MenuBarManager` itself — its other publishes
/// (usage, refresh state, the classic popover's clicked account) would
/// re-render twenty rows for nothing.
final class DashboardStore: ObservableObject {
    @Published var snapshot: DashboardSnapshot?
    @Published var clickedProvider: Profile.ProviderKind?

    init(snapshot: DashboardSnapshot? = nil, clickedProvider: Profile.ProviderKind? = nil) {
        self.snapshot = snapshot
        self.clickedProvider = clickedProvider
    }
}

// MARK: - Geometry

enum DashboardSurface {
    /// The dashboard popover / detached panel size. Wider than the classic
    /// popover (320): two-line roster rows need it.
    static let dashboardSize = NSSize(width: 380, height: 640)

    static func size(for surface: ClickSurface) -> NSSize {
        switch surface {
        case .classic: return Constants.WindowSizes.popoverSize
        case .dashboard: return dashboardSize
        }
    }
}

// MARK: - Formatting (pure, tested)

enum DashboardFormatting {
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) m ago" }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours < 24 { return rest == 0 ? "\(hours) h ago" : "\(hours) h \(rest) m ago" }
        return "\(hours / 24) d ago"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m"
    }

    /// "measured 28 s ago" / "via API headers · 2 m ago" / "CLI cache · 5 m ago".
    /// Short on purpose — it sits at the end of a roster row; the account
    /// detail spells the provenance out ("attributed from the CLI cache").
    static func provenance(_ measurement: UsageMeasurement, now: Date = Date()) -> String {
        let when = age(measurement.measuredAt, now: now)
        switch measurement.provenance {
        case .ownEndpoint: return "measured \(when)"
        case .headerRescue: return "via API headers · \(when)"
        case .cliCache: return "CLI cache · \(when)"
        }
    }

    static func chip(_ chip: RowChip, now: Date = Date()) -> String {
        switch chip {
        case .ready: return "ready"
        case .readyLight: return "ready · weekly under half"
        case .nearLimit: return "near limit"
        case .sessionExhausted(let resetAt): return "session exhausted · \(resetAt.timeRemainingString(from: now))"
        case .weeklyMaxed: return "weekly maxed"
        case .fableMaxed: return "Fable maxed"
        case .rateLimited(let until): return "rate limited · \(until.timeRemainingString(from: now))"
        case .suspected(let last, let at): return "suspected · \(Int(last.rounded())) % measured \(age(at, now: now))"
        case .unmeasured: return "not measured yet"
        case .autoSwitchOff: return "auto-switch off"
        case .freePlan: return "free plan"
        case .deadLogin: return "dead login"
        }
    }

    /// One line, fits 380 pt beside "→ name": source first (the fact the
    /// owner acts on), then the login verdict with its age, then the age of
    /// the headroom reading.
    static func next(_ next: NextCard, now: Date = Date()) -> String {
        var parts: [String] = []
        switch next.source {
        case .queued: parts.append("queued")
        case .ranked: parts.append("ranked")
        case .rankedBehindBlockedQueueHead: parts.append("ranked, queue head blocked")
        }
        switch next.verdict {
        case .verified: parts.append("\(DesignGlyph.verified) verified" + (next.verdictAt.map { " \(age($0, now: now))" } ?? ""))
        case .unverified: parts.append("not verified")
        case .dead: parts.append("\(DesignGlyph.dead) dead")
        }
        if let quota = next.quotaMeasuredAt { parts.append("headroom measured \(age(quota, now: now))") }
        return parts.joined(separator: " · ")
    }

    /// The counts of a provider in words, precedence order, for the section
    /// header (round 1, D3): "3 ready · 1 near limit · 4 exhausted · 1 dead · 2 duplicate".
    static func counts(_ counts: FleetCounts.Provider) -> String {
        // One entry per HUE for the header line (the dot carries the shade);
        // the six-way split lives on hover (`DesignLegend.line`) and in the
        // tooltip sentence.
        let groups: [(String, [AccountReadiness])] = [
            ("ready", [.ready, .readyLight]), ("session hit", [.sessionHit, .sessionHitLight]),
            ("weekly hit", [.weeklyHitSoon, .weeklyHit]), ("suspected", [.suspected]),
            ("unmeasured", [.unknown]), ("excluded", [.excluded]), ("dead", [.dead]),
        ]
        var parts: [String] = []
        for (word, states) in groups {
            let n = states.reduce(0) { $0 + counts.count($1) }
            if n > 0 { parts.append("\(n) \(word)") }
        }
        if counts.duplicateProfiles > 0 { parts.append("\(counts.duplicateProfiles) duplicate") }
        return parts.joined(separator: " · ")
    }

    static let gaugeLegend = "S 5-hour session · W weekly · F Fable weekly"

    /// "78 % session · resets in 2h 59m": the firing window (session where
    /// one exists, else weekly) — what a switch decision is judged on.
    static func headline(_ gauges: [WindowGauge], now: Date = Date()) -> String? {
        guard let firing = gauges.first(where: { $0.kind == .session }) ?? gauges.first(where: { $0.kind == .weekly }) else { return nil }
        var text = "\(Int(firing.percentage.rounded())) % \(gaugeTitle(firing.kind, compact: false).lowercased())"
        if let reset = firing.resetAt, reset > now { text += " · resets in \(reset.timeRemainingString(from: now))" }
        return text
    }

    /// "nobody with headroom · 2 of 3 dead" — the ⇄ menu's form (round 2, R2-2).
    static func nobodyWithHeadroom(_ counts: FleetCounts.Provider?) -> String {
        var text = "nobody with headroom"
        if let counts, counts.count(.dead) > 0 {
            text += " · \(counts.count(.dead)) of \(counts.profiles) dead"
        }
        return text
    }

    /// Both sides named, with the candidate's headroom, so the trade can be
    /// judged before the CLI login moves (round 1, M2).
    static func switchQuestion(provider: Profile.ProviderKind, from: String?, fromHeadline: String?,
                               to: String, toHeadline: String?) -> String {
        let cli = ActiveVocabulary.providerName(provider)
        var text = "Switch the \(cli) login"
        if let from { text += " from \(from)" + (fromHeadline.map { " (\($0))" } ?? "") }
        text += " to \(to)" + (toHeadline.map { " (\($0))" } ?? "") + "?"
        return text
    }

    static func switchCost(_ provider: Profile.ProviderKind) -> String {
        let cli: String
        switch provider {
        case .claude: cli = "Claude Code"
        case .codex: cli = "Codex"
        case .grok: cli = "Grok"
        }
        return "Every running \(cli) session re-reads its context (~10–15 % of its quota)."
    }

    /// Provider-free variant kept for the UX-revamp surfaces until they pass
    /// the provider (round 1, M4 wants the success note to read as state).
    static func outcome(_ outcome: ProfileManager.ActivationOutcome, name: String) -> String {
        if case .activated = outcome { return "Switched to \(name)." }
        return self.outcome(outcome, name: name, provider: .claude)
    }

    static func outcome(_ outcome: ProfileManager.ActivationOutcome, name: String, provider: Profile.ProviderKind) -> String {
        switch outcome {
        case .activated: return "\(ActiveVocabulary.activeFor(provider)): \(name) \(DesignGlyph.verified) · just now"
        case .alreadyActive: return "\(name) is already active."
        case .switchInFlight: return "Another switch is in progress — try again in a moment."
        case .profileNotFound: return "\(name) no longer exists."
        case .credentialsRefused: return "\(name)'s login is dead — the CLI login was not changed. Log in again, then Sync."
        case .focusedWithoutApplying: return "\(name) is focused, but its login is dead so the CLI login was not changed. Log in again, then Sync."
        case .credentialWriteFailed: return "\(name)'s login could not be written to the CLI — the CLI login was not changed. Check the log, then try again."
        }
    }

    /// The section's second line — the Viewing / Active-for vocabulary
    /// (docs/specs/ux-revamp.md R3), read from the same selection the ⇄
    /// menu shows, so the two surfaces can never disagree about who is
    /// active. "Viewing Cedar · Active for Claude: Atlas", or just the
    /// owner when the focus is on another provider, or "No active Claude
    /// login"; "· pinned" when the user chose the owner and the auto-switch
    /// will not move it.
    static func sectionCaption(_ section: ProviderSection) -> String {
        let ownerName = section.selection?.owner?.name ?? section.active?.name
        var line: String
        if let selection = section.selection, let viewingId = selection.viewing,
           let viewingName = viewingId == selection.owner?.id
               ? selection.owner?.name
               : section.roster.first(where: { $0.id == viewingId })?.name {
            line = ActiveVocabulary.viewingLine(viewing: viewingName, provider: section.provider, owner: ownerName)
        } else if let ownerName {
            line = "\(ActiveVocabulary.activeFor(section.provider)): \(ownerName)"
        } else {
            line = ActiveVocabulary.noActiveLogin(section.provider)
        }
        if section.selection?.owner?.isManuallyPinned == true { line += " · pinned" }
        return line
    }

    /// "ROSTER · 17 · soonest weekly reset first · 7 eligible now".
    static func rosterHeader(_ section: ProviderSection) -> String {
        var line = "ROSTER · \(section.roster.count) · soonest weekly reset first"
        if let counts = section.selection?.counts {
            line += " · \(counts.autoSwitchEligible) eligible now"
        }
        return line
    }

    static func title(_ provider: Profile.ProviderKind) -> String {
        switch provider {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        }
    }

    static func gaugeTitle(_ kind: WindowGauge.Kind, compact: Bool) -> String {
        switch kind {
        case .session: return compact ? "S" : "Session"
        case .weekly: return compact ? "W" : "Weekly"
        case .fable: return compact ? "F" : "Fable"
        }
    }
}

// MARK: - Colours

extension AccountReadiness {
    /// Kept for the UX-revamp surfaces until they consume `DesignLegend`
    /// directly (round 1, G1/G2): the one colour-role table and glyph set.
    var dashboardColor: Color { role.color }
    var dashboardGlyph: String { legendGlyph }
}

/// What the status strip shows for each condition (round 1, D1/D2): its
/// tier decides the colour and the order; the message is provider-neutral.
extension DashboardBanner {
    enum Tier: Int {
        case blocking, actionable, informational
        var role: DesignRole {
            switch self {
            case .blocking: return .blocking
            case .actionable: return .caution
            case .informational: return .informational
            }
        }
    }

    struct Action { var title: String; var sectionRawValue: String }

    var tier: Tier {
        switch self {
        case .preferencesDegraded: return .blocking
        case .deadLogins: return .actionable
        case .noCandidate, .hiddenByOverflow: return .informational
        }
    }

    var icon: String {
        switch self {
        case .preferencesDegraded: return "externaldrive.badge.exclamationmark"
        case .deadLogins: return "person.crop.circle.badge.exclamationmark"
        case .noCandidate: return "arrow.right.circle"
        case .hiddenByOverflow: return "eye.slash"
        }
    }

    var message: String {
        switch self {
        case .preferencesDegraded: return "popover.banner.preferences_degraded".localized
        case .deadLogins(let count): return "\(count) dead login\(count == 1 ? "" : "s") — repair in Accounts"
        case .noCandidate(let provider): return "\(DashboardFormatting.title(provider)): nowhere to switch to"
        case .hiddenByOverflow(let provider): return "\(DashboardFormatting.title(provider)) is not visible in the menu bar"
        }
    }

    var action: Action? {
        switch self {
        case .deadLogins: return Action(title: "Accounts ›", sectionRawValue: "accounts")
        default: return nil
        }
    }
}

// MARK: - View

struct DashboardView: View {
    @ObservedObject var store: DashboardStore
    @StateObject private var profileManager = ProfileManager.shared
    let actions: DashboardActions
    /// The popover / panel height; the preview render passes a taller one to
    /// see the whole scroll content.
    var height: CGFloat = DashboardSurface.dashboardSize.height

    private enum Route: Equatable {
        case fleet
        case account(UUID)
    }

    @State private var route: Route = .fleet
    @State private var pendingSwitch: UUID?
    @State private var switchNote: String?
    @State private var showInsights: Bool?
    /// The harness seeds the Insights block open to render it in situ.
    var insightsExpanded = false
    @State private var isRefreshing = false
    @State private var expandedRosters: Set<Profile.ProviderKind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            PopoverDivider()
            if let snapshot = store.snapshot {
                switch route {
                case .fleet:
                    fleet(snapshot)
                case .account(let id):
                    account(id, snapshot: snapshot)
                }
            } else {
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(14)
                Spacer()
            }
        }
        .frame(width: DashboardSurface.dashboardSize.width, height: height)
        .background(VisualEffectBackground())
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(route == .fleet ? "Fleet" : "Account")
                    .font(.system(size: 13, weight: .bold))
                if let snapshot = store.snapshot {
                    Text("\(snapshot.accountCount) accounts · updated \(DashboardFormatting.age(snapshot.generatedAt))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    if let last = snapshot.recentSwitches.first {
                        Text("last switch: \(last.from) → \(last.to) · \(DashboardFormatting.age(last.at))")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            HStack(spacing: 0) {
                headerButton("arrow.clockwise", help: "Refresh the viewed accounts", refreshing: isRefreshing) {
                    withAnimation(.easeInOut(duration: 0.3)) { isRefreshing = true }
                    actions.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        withAnimation(.easeInOut(duration: 0.3)) { isRefreshing = false }
                    }
                }
                headerButton("chart.bar.xaxis", help: "popover.token_usage".localized) { actions.openTokenUsage(nil, nil) }
                headerButton("gearshape.fill", help: "Settings") { actions.openSettings(nil) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// 28 pt hit area and a tooltip on every header icon (round 1, D11).
    private func headerButton(_ icon: String, help: String, refreshing: Bool = false,
                              action: @escaping () -> Void) -> some View {
        HeaderIconButton(icon: icon, fontSize: 12, isRefreshing: refreshing, action: action)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .help(help)
            .disabled(refreshing)
    }

    // MARK: Fleet

    private func fleet(_ snapshot: DashboardSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if !snapshot.banners.isEmpty {
                        statusStrip(snapshot.banners)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                    ForEach(snapshot.sections, id: \.provider) { section in
                        Section {
                            sectionBody(section)
                        } header: {
                            sectionHeader(section)
                                .id(section.provider)
                        }
                    }
                    if let insights = snapshot.insights {
                        insightsBlock(insights, now: snapshot.generatedAt)
                    }
                }
                .padding(.bottom, 8)
            }
            .onAppear {
                if let provider = store.clickedProvider { proxy.scrollTo(provider, anchor: .top) }
            }
        }
    }

    /// ONE compact strip, one line per condition, tiered and ordered:
    /// blocking, then actionable, then informational (round 1, D1/D2).
    private func statusStrip(_ banners: [DashboardBanner]) -> some View {
        let ordered = banners.sorted { $0.tier.rawValue < $1.tier.rawValue }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { index, banner in
                if index > 0 { Divider().opacity(0.5) }
                statusLine(banner)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private func statusLine(_ banner: DashboardBanner) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: banner.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(banner.tier.role.color)
                .frame(width: 14)
            Text(banner.message)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action = banner.action {
                Button(action.title) { actions.openSettings(action.sectionRawValue) }
                    .buttonStyle(.plain)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(DesignRole.action.color)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Section

    /// Sticky while its section scrolls (round 1, D9); a hairline and one
    /// step of contrast so it reads as a band in dark (D10); words instead
    /// of the glyph strip, the legend on hover (D3).
    private func sectionHeader(_ section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(DashboardFormatting.title(section.provider).uppercased())
                    .font(.system(size: 10, weight: .bold))
                if let counts = section.selection?.counts {
                    Text("· \(counts.profiles) accounts")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button { actions.openActiveSelector(section.provider) } label: {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DesignRole.action.color)
                        .frame(width: 24, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ActiveVocabulary.makeActive(section.provider))
            }
            Text(DashboardFormatting.sectionCaption(section))
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
            if let counts = section.selection?.counts {
                Text(DashboardFormatting.counts(counts))
                    .font(.system(size: 8.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help(DesignLegend.line)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .background(VisualEffectBackground())
        .overlay(Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5), alignment: .bottom)
    }

    private func sectionBody(_ section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let active = section.active {
                activeCard(active, section: section)
                    .padding(.horizontal, 12)
            }
            nextAndQueue(section)
                .padding(.horizontal, 16)
            if !section.roster.isEmpty {
                roster(section)
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    /// Collapsed to the first rows by default (round 1, D9: 24 accounts made
    /// the fleet ~1500 pt tall); "Show all N" expands one section.
    private static let collapsedRosterRows = 3

    private func roster(_ section: ProviderSection) -> some View {
        let isExpanded = expandedRosters.contains(section.provider)
        let rows = isExpanded ? section.roster : Array(section.roster.prefix(Self.collapsedRosterRows))
        return VStack(alignment: .leading, spacing: 4) {
            Text(DashboardFormatting.rosterHeader(section))
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
            Text(DashboardFormatting.gaugeLegend)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
            ForEach(rows, id: \.id) { row in
                rosterRow(row, section: section)
            }
            if section.roster.count > Self.collapsedRosterRows {
                Button(isExpanded ? "Show fewer" : "Show all \(section.roster.count)") {
                    if isExpanded { expandedRosters.remove(section.provider) } else { expandedRosters.insert(section.provider) }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(DesignRole.action.color)
                .padding(.horizontal, 16)
                .padding(.top, 2)
            }
        }
    }

    // MARK: Active card

    private func activeCard(_ card: ActiveCard, section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("ACTIVE").font(.system(size: 8, weight: .bold)).foregroundColor(DesignRole.active.color)
                Text(card.name).font(.system(size: 12, weight: .bold))
                if card.isFocused {
                    Text("viewing").font(.system(size: 8)).foregroundColor(.secondary)
                }
                if !card.sameAccountAs.isEmpty {
                    chip("same account as \(card.sameAccountAs.joined(separator: ", "))", role: .informational)
                }
                Spacer()
                if let spot = store.snapshot?.insights?.blindness.first(where: { $0.id == card.id && $0.isBlind }) {
                    chip("blind · \(InsightsFormatting.blind(spot, now: store.snapshot?.generatedAt ?? Date()))", role: .caution)
                        .lineLimit(1)
                }
                if let m = card.measurement {
                    Text(DashboardFormatting.provenance(m))
                        .font(.system(size: 9))
                        .foregroundColor(m.provenance == .ownEndpoint ? .secondary : DesignRole.caution.color)
                }
            }
            ForEach(card.gauges, id: \.kind) { gauge in
                gaugeLine(gauge, isOwn: card.measurement?.isOwn ?? true)
            }
            if let caveat = card.suspected {
                Label {
                    Text("Suspected throttle — showing the last measured \(Int(caveat.lastMeasured.rounded())) % (\(DashboardFormatting.age(caveat.measuredAt)))"
                         + (caveat.projected.map { ", projected \(Int($0.rounded())) %" } ?? ""))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(DesignRole.suspected.color)
                }
            }
            if let eta = card.etaToThreshold, let firing = card.gauges.first {
                Text(eta == 0
                     ? "\(DashboardFormatting.gaugeTitle(firing.kind, compact: false)) is past its \(Int(firing.threshold)) % auto-switch threshold"
                     : "ETA to \(Int(firing.threshold)) % \(DashboardFormatting.gaugeTitle(firing.kind, compact: false).lowercased()): ~\(DashboardFormatting.duration(eta)) at the current pace")
                    .font(.system(size: 9))
                    .foregroundColor(DesignRole.caution.color)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private func chip(_ text: String, role: DesignRole) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(role.color)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(role.color.opacity(0.12)))
    }

    private func gaugeRole(_ gauge: WindowGauge) -> DesignRole {
        if gauge.percentage >= 100 { return .blocking }
        if gauge.percentage >= min(gauge.threshold, 80) { return .caution }
        return .ready
    }

    private func gaugeLine(_ gauge: WindowGauge, isOwn: Bool) -> some View {
        HStack(spacing: 8) {
            Text(DashboardFormatting.gaugeTitle(gauge.kind, compact: false))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 46, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(gaugeRole(gauge).color)
                        .frame(width: geometry.size.width * min(gauge.percentage / 100, 1))
                }
            }
            .frame(height: 4)
            .opacity(isOwn ? 1 : 0.5)
            Text("\(Int(gauge.percentage.rounded())) %")
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(gaugeRole(gauge).color)
                .frame(width: 36, alignment: .trailing)
            // The threshold is stated once per section ("Auto-switch at 95 %
            // session / 99 % weekly") — repeating it per gauge crowded the row
            // into wrapping (round 1 render). The reset text never yields.
            Text(gauge.resetAt.map { "resets \($0.timeRemainingString().lowercased() == "reset now" ? "now" : "in " + $0.timeRemainingString())" } ?? "")
                .font(.system(size: 8.5))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(width: 92, alignment: .leading)
        }
    }

    // MARK: Next + queue

    private func nextAndQueue(_ section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Next").font(.system(size: 9.5, weight: .medium)).foregroundColor(.secondary)
                if let next = section.next {
                    Text("\(DesignGlyph.next) \(next.name)").font(.system(size: 9.5, weight: .semibold))
                    Text(DashboardFormatting.next(next))
                        .font(.system(size: 8.5))
                        .foregroundColor(next.verdict == .verified ? DesignRole.ready.color
                                         : (next.verdict == .dead ? DesignRole.blocking.color : .secondary))
                        .lineLimit(1)
                } else if section.roster.isEmpty {
                    Text("single account").font(.system(size: 8.5)).foregroundColor(.secondary)
                } else {
                    Text(DashboardFormatting.nobodyWithHeadroom(section.selection?.counts))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(DesignRole.blocking.color)
                }
            }
            HStack(spacing: 6) {
                Text("Queue").font(.system(size: 9.5, weight: .medium)).foregroundColor(.secondary)
                if section.queue.isEmpty {
                    Text("empty — ranked by soonest weekly reset").font(.system(size: 8.5)).foregroundColor(.secondary)
                } else {
                    Text(section.queue.map { "\($0.name)\($0.blocked ? " (blocked)" : "")" }.joined(separator: " › "))
                        .font(.system(size: 8.5))
                        .foregroundColor(section.queue.first?.blocked == true ? DesignRole.blocking.color : .primary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Edit in Settings ›") { actions.openSettings("manageProfiles") }
                    .buttonStyle(.plain)
                    .font(.system(size: 8.5))
                    .foregroundColor(DesignRole.action.color)
            }
            Text("Auto-switch at "
                 + (section.sessionThreshold.map { "\(Int($0)) % session / " } ?? "")
                 + "\(Int(section.weeklyThreshold)) % weekly")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }

    // MARK: Roster

    /// Two lines: state on the left, a fixed right column (state chip over
    /// the reading's age) so the two never collide (round 1, D7); numerals
    /// monospaced-digit (G3); no bars — the letters carry the windows and
    /// the legend sits above the roster.
    private func rosterRow(_ row: RosterRow, section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                route = .account(row.id)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(row.readiness.legendGlyph)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(row.readiness.role.color)
                                .frame(width: 10)
                            Text(row.name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                            if row.isNext { tag("next", role: .informational) }
                            if let position = row.queuePosition { tag("queued #\(position)", role: .informational) }
                            if row.needsRelogin { tag("re-login needed", role: .caution) }
                            if !row.sameAccountAs.isEmpty {
                                tag("same account as \(row.sameAccountAs.joined(separator: ", "))", role: .informational)
                            }
                        }
                        HStack(spacing: 10) {
                            ForEach(row.gauges, id: \.kind) { gauge in
                                HStack(spacing: 3) {
                                    Text(DashboardFormatting.gaugeTitle(gauge.kind, compact: true))
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundColor(.secondary)
                                    Text("\(Int(gauge.percentage.rounded())) %")
                                        .font(.system(size: 9, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundColor(gaugeRole(gauge).color)
                                }
                            }
                        }
                        .padding(.leading, 16)
                        .opacity((row.measurement?.isOwn ?? true) ? 1 : 0.6)
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(DashboardFormatting.chip(row.chip))
                            .font(.system(size: 8.5))
                            .foregroundColor(row.readiness.role.color)
                            .lineLimit(1)
                        if let m = row.measurement {
                            Text(m.isOwn ? DashboardFormatting.age(m.measuredAt) : DashboardFormatting.provenance(m))
                                .font(.system(size: 8))
                                .monospacedDigit()
                                .foregroundColor(m.provenance == .cliCache ? DesignRole.caution.color : .secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 118, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.025)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(ActiveVocabulary.makeActive(section.provider)) { pendingSwitch = row.id; switchNote = nil }
                if row.queuePosition == nil {
                    Button("Queue next") { actions.queueNext(row.id) }
                } else {
                    Button("Remove from queue") { actions.removeFromQueue(row.id) }
                }
                if let repair = row.repair {
                    Button(repairTitle(repair)) { actions.openSettings(repair.settingsSectionRawValue ?? "manageProfiles") }
                }
                Button("popover.token_usage".localized) { actions.openTokenUsage(row.id, section.provider) }
                Button("Open in Settings") { actions.openSettings("manageProfiles") }
            }

            if pendingSwitch == row.id {
                switchConfirm(row, section: section)
            }
            if pendingSwitch == nil, let note = switchNote, noteFor == row.id {
                Text(note).font(.system(size: 9)).foregroundColor(.secondary).padding(.horizontal, 16)
            }
        }
        .padding(.horizontal, 12)
    }

    /// Informational tags are neutral pills (round 2, R2-3: "queued" and
    /// "next" are facts, not actions); caution tags keep their colour.
    private func tag(_ text: String, role: DesignRole) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(role == .informational ? .secondary : role.color)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(role == .informational ? Color.primary.opacity(0.08) : role.color.opacity(0.12)))
    }

    @State private var noteFor: UUID?

    private func switchConfirm(_ row: RosterRow, section: ProviderSection) -> some View {
        let dead = row.readiness == .dead
        return VStack(alignment: .leading, spacing: 5) {
            SwitchQuestionLines(
                provider: section.provider,
                from: section.active.map { ($0.name, DashboardFormatting.headline($0.gauges)) },
                to: (row.name, DashboardFormatting.headline(row.gauges)))
            Text(DashboardFormatting.switchCost(section.provider))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if dead {
                Text("This login is dead; the switch would be refused. Log in again first.")
                    .font(.system(size: 9)).foregroundColor(DesignRole.caution.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if dead {
                    Button("Log in first") {}.disabled(true)
                    Button("Cancel") { pendingSwitch = nil }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Switch") {
                        let id = row.id
                        let name = row.name
                        pendingSwitch = nil
                        Task { @MainActor in
                            let outcome = await actions.makeActive(id)
                            switchNote = DashboardFormatting.outcome(outcome, name: name, provider: section.provider)
                            noteFor = id
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Cancel") { pendingSwitch = nil }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(DesignRole.caution.color.opacity(0.10)))
    }

    private func repairTitle(_ repair: RepairAction) -> String {
        switch repair {
        case .claudeLogin: return "Repair: /login, then Sync (CLI Account)"
        case .codexLogin: return "Repair: Codex Account → Log in"
        case .grokLogin: return "Repair: grok login, then Sync"
        }
    }

    // MARK: Insights

    /// ONE collapsed block at fleet level under the last section (UX revamp
    /// stage 4b): reset timeline, blind spots, drift, switch log, burn,
    /// incidents, capacity, why-not. It replaced the recent-switches
    /// disclosure — the switch log inside it is the one switch surface; the
    /// header keeps its "last switch" line.
    private func insightsBlock(_ insights: FleetInsights, now: Date) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { showInsights ?? insightsExpanded },
            set: { showInsights = $0 }
        )) {
            DashboardInsightsView(insights: insights, now: now)
                .padding(.top, 4)
        } label: {
            Text("INSIGHTS")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: Account detail

    private func account(_ id: UUID, snapshot: DashboardSnapshot) -> some View {
        let profile = profileManager.profiles.first { $0.id == id }
        let row = snapshot.sections.flatMap(\.roster).first { $0.id == id }
        let active = snapshot.sections.compactMap(\.active).first { $0.id == id }
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { route = .fleet } label: {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    Text(profile?.name ?? "Account").font(.system(size: 12, weight: .bold))
                    if let readiness = row?.readiness ?? active?.readiness {
                        Text(readiness.legendGlyph).foregroundColor(readiness.role.color).font(.system(size: 9, weight: .bold))
                            .help(DesignLegend.line)
                    }
                    Spacer()
                    if let m = row?.measurement ?? active?.measurement {
                        Text(DashboardFormatting.provenance(m))
                            .font(.system(size: 9))
                            .foregroundColor(m.provenance == .ownEndpoint ? .secondary : DesignRole.caution.color)
                    }
                }
                .padding(.horizontal, 16)
                if let row, let repair = row.repair {
                    StatusBannerView(icon: "exclamationmark.triangle.fill",
                                     message: DashboardFormatting.chip(row.chip) + " — " + repairTitle(repair),
                                     color: DesignRole.blocking.color) { actions.openSettings(repair.settingsSectionRawValue ?? "manageProfiles") }
                }
                if let m = row?.measurement ?? active?.measurement, !m.isOwn {
                    StatusBannerView(icon: "info.circle",
                                     message: "These numbers were attributed from the CLI cache, not read with this account's credentials",
                                     color: DesignRole.caution.color)
                }
                SmartUsageDashboard(usage: profile?.claudeUsage ?? .empty)
            }
            .padding(.top, 8)
        }
    }
}
