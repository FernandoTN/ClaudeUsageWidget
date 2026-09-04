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
        case .verified: parts.append("✓ proven" + (next.verdictAt.map { " \(age($0, now: now))" } ?? ""))
        case .unverified: parts.append("? unverified")
        case .dead: parts.append("× dead")
        }
        if let quota = next.quotaMeasuredAt { parts.append("headroom \(age(quota, now: now))") }
        return parts.joined(separator: " · ")
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

    static func outcome(_ outcome: ProfileManager.ActivationOutcome, name: String) -> String {
        switch outcome {
        case .activated: return "Switched to \(name)."
        case .alreadyActive: return "\(name) is already active."
        case .switchInFlight: return "Another switch is in progress — try again in a moment."
        case .profileNotFound: return "\(name) no longer exists."
        case .credentialsRefused: return "\(name)'s login is dead — the CLI login was not changed. Log in again, then Sync."
        case .focusedWithoutApplying: return "\(name) is focused, but its login is dead so the CLI login was not changed. Log in again, then Sync."
        }
    }

    /// The section's second line — the Viewing / Active-for vocabulary
    /// (docs/specs/ux-revamp.md R3), read from the same selection the ⇄
    /// menu shows, so the two surfaces can never disagree about who is
    /// active. "Viewing dJormun · Active for Claude: dRir", or just the
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
    var dashboardColor: Color {
        switch self {
        case .ready: return .adaptiveGreen
        case .low: return .orange
        case .exhausted: return .red
        case .suspected: return .purple
        case .dead: return .orange
        case .excluded, .unknown: return .secondary
        }
    }

    var dashboardGlyph: String {
        switch self {
        case .dead: return "✕"
        case .excluded: return "–"
        case .unknown: return "○"
        case .ready, .low, .exhausted, .suspected: return "●"
        }
    }
}

private func gaugeColor(_ percentage: Double) -> Color {
    if percentage >= 80 { return .red }
    if percentage >= 50 { return .orange }
    return .adaptiveGreen
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
    @State private var showSwitches = false
    @State private var isRefreshing = false

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
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(route == .fleet ? "Fleet" : "Account")
                    .font(.system(size: 13, weight: .bold))
                if let snapshot = store.snapshot {
                    Text("\(snapshot.sections.reduce(0) { $0 + $1.roster.count + ($1.active == nil ? 0 : 1) }) accounts · updated \(DashboardFormatting.age(snapshot.generatedAt))")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                HeaderIconButton(icon: "arrow.clockwise", isRefreshing: isRefreshing) {
                    withAnimation(.easeInOut(duration: 0.3)) { isRefreshing = true }
                    actions.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        withAnimation(.easeInOut(duration: 0.3)) { isRefreshing = false }
                    }
                }
                .disabled(isRefreshing)
                HeaderIconButton(icon: "chart.bar.xaxis", fontSize: 11) { actions.openTokenUsage(nil, nil) }
                    .help("popover.token_usage".localized)
                HeaderIconButton(icon: "gearshape.fill", fontSize: 12) { actions.openSettings(nil) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Fleet

    private func fleet(_ snapshot: DashboardSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(snapshot.banners.enumerated()), id: \.offset) { _, banner in
                        bannerView(banner)
                    }
                    ForEach(snapshot.sections, id: \.provider) { section in
                        sectionView(section)
                            .id(section.provider)
                    }
                    recentSwitches(snapshot.recentSwitches)
                }
                .padding(.bottom, 10)
            }
            .onAppear {
                if let provider = store.clickedProvider { proxy.scrollTo(provider, anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private func bannerView(_ banner: DashboardBanner) -> some View {
        switch banner {
        case .preferencesDegraded:
            StatusBannerView(icon: "externaldrive.badge.exclamationmark",
                             message: "popover.banner.preferences_degraded".localized, color: .orange)
        case .deadLogins(let count):
            StatusBannerView(icon: "exclamationmark.triangle.fill",
                             message: "\(count) dead login\(count == 1 ? "" : "s") — log in again, then Sync",
                             color: .orange) { actions.openSettings("manageProfiles") }
        case .noCandidate(let provider):
            StatusBannerView(icon: "arrow.right.circle", message: "\(DashboardFormatting.title(provider)): nowhere to switch to",
                             color: .red)
        case .hiddenByOverflow(let provider):
            StatusBannerView(icon: "eye.slash", message: "\(DashboardFormatting.title(provider)) is not visible in the menu bar",
                             color: .gray)
        }
    }

    private func sectionView(_ section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(DashboardFormatting.title(section.provider).uppercased())
                        .font(.system(size: 10, weight: .bold))
                    Spacer()
                    if let counts = section.selection?.counts {
                        // The bar's glyph alphabet (● ◐ ○ ▲ × – †); the
                        // sentence behind it on hover.
                        Text(counts.strip)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(.secondary)
                            .help(ActiveVocabulary.countsSentence(counts))
                    }
                    Button { actions.openActiveSelector(section.provider) } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(ActiveVocabulary.makeActive(section.provider))
                }
                Text(DashboardFormatting.sectionCaption(section))
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if let active = section.active, !active.sameAccountAs.isEmpty {
                    Text("same account as \(active.sameAccountAs.joined(separator: ", "))")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))

            if let active = section.active {
                activeCard(active, section: section)
                    .padding(.horizontal, 10)
            }
            nextAndQueue(section)
                .padding(.horizontal, 14)

            if !section.roster.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text(DashboardFormatting.rosterHeader(section))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                    ForEach(section.roster, id: \.id) { row in
                        rosterRow(row, section: section)
                    }
                }
            }
        }
    }

    // MARK: Active card

    private func activeCard(_ card: ActiveCard, section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("ACTIVE").font(.system(size: 8, weight: .bold)).foregroundColor(Color(nsColor: .systemCyan))
                Text(card.name).font(.system(size: 12, weight: .bold))
                if card.isFocused {
                    Text("focused").font(.system(size: 8)).foregroundColor(.secondary)
                }
                Spacer()
                if let m = card.measurement {
                    Text(DashboardFormatting.provenance(m))
                        .font(.system(size: 9))
                        .foregroundColor(m.isOwn ? .secondary : .orange)
                }
            }
            ForEach(card.gauges, id: \.kind) { gauge in
                gaugeLine(gauge, compact: false, isOwn: card.measurement?.isOwn ?? true, showThreshold: true)
            }
            if let caveat = card.suspected {
                Label {
                    Text("Suspected throttle — showing the last measured \(Int(caveat.lastMeasured.rounded())) % (\(DashboardFormatting.age(caveat.measuredAt)))"
                         + (caveat.projected.map { ", projected \(Int($0.rounded())) %" } ?? ""))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundColor(.purple)
                }
            }
            if let eta = card.etaToThreshold, let firing = card.gauges.first {
                Text(eta == 0
                     ? "\(DashboardFormatting.gaugeTitle(firing.kind, compact: false)) is past its \(Int(firing.threshold)) % switch threshold"
                     : "ETA to \(Int(firing.threshold)) % \(DashboardFormatting.gaugeTitle(firing.kind, compact: false).lowercased()): ~\(DashboardFormatting.duration(eta)) at the current pace")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    private func gaugeLine(_ gauge: WindowGauge, compact: Bool, isOwn: Bool, showThreshold: Bool) -> some View {
        HStack(spacing: 6) {
            Text(DashboardFormatting.gaugeTitle(gauge.kind, compact: compact))
                .font(.system(size: compact ? 8 : 9.5, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: compact ? 10 : 46, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(gaugeColor(gauge.percentage))
                        .frame(width: geometry.size.width * min(gauge.percentage / 100, 1))
                }
            }
            .frame(height: 4)
            .opacity(isOwn ? 1 : 0.5)
            Text("\(Int(gauge.percentage.rounded())) %")
                .font(.system(size: compact ? 8.5 : 9.5, weight: .semibold, design: .rounded))
                .foregroundColor(gaugeColor(gauge.percentage))
                .frame(width: compact ? 30 : 36, alignment: .trailing)
            if !compact {
                Text(gauge.resetAt.map { "resets \($0.timeRemainingString().lowercased() == "reset now" ? "now" : "in " + $0.timeRemainingString())" } ?? "")
                    .font(.system(size: 8.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if showThreshold {
                    Text("fires at \(Int(gauge.threshold)) %")
                        .font(.system(size: 8))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: Next + queue

    private func nextAndQueue(_ section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Next").font(.system(size: 9.5, weight: .medium)).foregroundColor(.secondary)
                if let next = section.next {
                    Text("→ \(next.name)").font(.system(size: 9.5, weight: .semibold))
                    Text(DashboardFormatting.next(next))
                        .font(.system(size: 8.5))
                        .foregroundColor(next.verdict == .verified ? .adaptiveGreen : (next.verdict == .dead ? .red : .secondary))
                        .lineLimit(1)
                } else if section.roster.isEmpty {
                    Text("single account").font(.system(size: 8.5)).foregroundColor(.secondary)
                } else {
                    Text("→ — nobody with headroom").font(.system(size: 9.5, weight: .semibold)).foregroundColor(.red)
                }
            }
            HStack(spacing: 6) {
                Text("Queue").font(.system(size: 9.5, weight: .medium)).foregroundColor(.secondary)
                if section.queue.isEmpty {
                    Text("empty — ranked by soonest weekly reset").font(.system(size: 8.5)).foregroundColor(.secondary)
                } else {
                    Text(section.queue.map { "\($0.name)\($0.blocked ? " (blocked)" : "")" }.joined(separator: " › "))
                        .font(.system(size: 8.5))
                        .foregroundColor(section.queue.first?.blocked == true ? .red : .primary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Edit in Settings ›") { actions.openSettings("manageProfiles") }
                    .buttonStyle(.plain)
                    .font(.system(size: 8.5))
                    .foregroundColor(.accentColor)
            }
            Text("Auto-switch at "
                 + (section.sessionThreshold.map { "\(Int($0)) % session / " } ?? "")
                 + "\(Int(section.weeklyThreshold)) % weekly")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }

    // MARK: Roster

    private func rosterRow(_ row: RosterRow, section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                route = .account(row.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.readiness.dashboardGlyph)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(row.readiness.dashboardColor)
                            .frame(width: 10)
                        Text(row.name).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                        if row.isNext {
                            Text("next").font(.system(size: 8, weight: .bold)).foregroundColor(.accentColor)
                        }
                        if let position = row.queuePosition {
                            Text("queued #\(position)").font(.system(size: 8)).foregroundColor(.accentColor)
                        }
                        if row.needsRelogin {
                            Text("re-login needed").font(.system(size: 8)).foregroundColor(.orange)
                        }
                        if !row.sameAccountAs.isEmpty {
                            Text("same account as \(row.sameAccountAs.joined(separator: ", "))")
                                .font(.system(size: 8)).foregroundColor(.orange).lineLimit(1)
                        }
                        Spacer()
                        Text(DashboardFormatting.chip(row.chip))
                            .font(.system(size: 8.5))
                            .foregroundColor(row.readiness.dashboardColor)
                            .lineLimit(1)
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        ForEach(row.gauges, id: \.kind) { gauge in
                            gaugeLine(gauge, compact: true, isOwn: row.measurement?.isOwn ?? true, showThreshold: false)
                                .frame(width: gauge.kind == .fable ? 44 : 88)
                        }
                        Spacer(minLength: 4)
                        if let m = row.measurement {
                            Text(m.isOwn ? DashboardFormatting.age(m.measuredAt) : DashboardFormatting.provenance(m))
                                .font(.system(size: 8))
                                .foregroundColor(m.isOwn ? .secondary : .orange)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                    .padding(.leading, 16)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
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
        .padding(.horizontal, 10)
    }

    @State private var noteFor: UUID?

    private func switchConfirm(_ row: RosterRow, section: ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Switch the \(DashboardFormatting.title(section.provider)) login to \(row.name)?")
                .font(.system(size: 10, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(DashboardFormatting.switchCost(section.provider))
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if row.readiness == .dead {
                Text("This login is dead; the switch will be refused. Log in again first.")
                    .font(.system(size: 9)).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Switch") {
                    let id = row.id
                    let name = row.name
                    pendingSwitch = nil
                    Task { @MainActor in
                        let outcome = await actions.makeActive(id)
                        switchNote = DashboardFormatting.outcome(outcome, name: name)
                        noteFor = id
                    }
                }
                .keyboardShortcut(.defaultAction)
                Button("Cancel") { pendingSwitch = nil }
                    .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.10)))
    }

    private func repairTitle(_ repair: RepairAction) -> String {
        switch repair {
        case .claudeLogin: return "Repair: /login, then Sync (CLI Account)"
        case .codexLogin: return "Repair: Codex Account → Log in"
        case .grokLogin: return "Repair: grok login, then Sync"
        }
    }

    // MARK: Recent switches

    private func recentSwitches(_ switches: [RecentSwitch]) -> some View {
        DisclosureGroup(isExpanded: $showSwitches) {
            if switches.isEmpty {
                Text("none recorded").font(.system(size: 9)).foregroundColor(.secondary)
            }
            ForEach(Array(switches.enumerated()), id: \.offset) { _, s in
                HStack(spacing: 6) {
                    Text(s.at.formatted(date: .omitted, time: .shortened)).font(.system(size: 9)).foregroundColor(.secondary)
                    Text("\(s.from) → \(s.to)").font(.system(size: 9, weight: .medium))
                    Text(s.trigger.rawValue).font(.system(size: 8)).foregroundColor(.secondary)
                    if let reason = s.reason {
                        Text(reason).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
        } label: {
            Text("RECENT SWITCHES · \(switches.count)")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
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
                        Text(readiness.dashboardGlyph).foregroundColor(readiness.dashboardColor).font(.system(size: 9, weight: .bold))
                    }
                    Spacer()
                    if let m = row?.measurement ?? active?.measurement {
                        Text(DashboardFormatting.provenance(m))
                            .font(.system(size: 9))
                            .foregroundColor(m.isOwn ? .secondary : .orange)
                    }
                }
                .padding(.horizontal, 14)
                if let row, let repair = row.repair {
                    StatusBannerView(icon: "exclamationmark.triangle.fill",
                                     message: DashboardFormatting.chip(row.chip) + " — " + repairTitle(repair),
                                     color: .orange) { actions.openSettings(repair.settingsSectionRawValue ?? "manageProfiles") }
                }
                if let m = row?.measurement ?? active?.measurement, !m.isOwn {
                    StatusBannerView(icon: "info.circle",
                                     message: "These numbers were attributed from the CLI cache, not read with this account's credentials",
                                     color: .orange)
                }
                SmartUsageDashboard(usage: profile?.claudeUsage ?? .empty)
            }
            .padding(.top, 8)
        }
    }
}
