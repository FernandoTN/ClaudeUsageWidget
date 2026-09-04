//
//  AccountsView.swift
//  Claude Usage
//
//  The Accounts inspector (docs/specs/ux-revamp.md §2.2; design pass §12.2):
//  the Settings window's sidebar becomes the roster — one section per
//  provider with its counts, one 22 pt row per account — and the detail pane
//  shows the VIEWED account. Selecting a row only VIEWS
//  (`ProfileManager.viewProfile`); the only switching controls are the
//  explicit "Make active for <provider>…" button (same confirmation as the ⇄
//  selector) and, on the Login tab (stage 2c), a named Import. Everything is
//  read from the same `ProviderActiveSelection` snapshot the selector and the
//  dashboard use.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Store

/// One snapshot for the whole inspector, rebuilt when the roster or an owner
/// changes (coalesced) — no row observes the managers on its own.
@MainActor
final class AccountsInspectorStore: ObservableObject {
    @Published private(set) var selections: [ProviderActiveSelection] = []
    @Published private(set) var profiles: [Profile] = []
    private var cancellables = Set<AnyCancellable>()

    init() {
        let manager = ProfileManager.shared
        let triggers: [AnyPublisher<Void, Never>] = [
            manager.$profiles.map { _ in () }.eraseToAnyPublisher(),
            manager.$activeProfile.map { _ in () }.eraseToAnyPublisher(),
            manager.$activeClaudeProfileId.map { _ in () }.eraseToAnyPublisher(),
            manager.$activeCodexProfileId.map { _ in () }.eraseToAnyPublisher(),
            manager.$activeGrokProfileId.map { _ in () }.eraseToAnyPublisher(),
            manager.$isSwitchingProfile.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        refresh()
    }

    func refresh() {
        profiles = ProfileManager.shared.profiles
        if let manager = MenuBarManager.current {
            selections = manager.buildActiveSelections()
        } else {
            selections = Self.fallbackSelections(profiles)
        }
    }

    /// Without a live MenuBarManager (previews, tests) build from the public
    /// pieces: thresholds, dead flags, the eligibility toggle; no candidate
    /// prediction or preflight verdicts.
    static func fallbackSelections(_ profiles: [Profile]) -> [ProviderActiveSelection] {
        let manager = ProfileManager.shared
        let context = FleetSummaryContext(
            thresholds: ReadinessThresholds(
                session: SharedDataStore.shared.loadAutoSwitchThreshold(),
                weekly: SharedDataStore.shared.loadAutoSwitchWeeklyThreshold()),
            isLoginDead: { ProfileCredentialStatusCache.hasDeadLogin($0) },
            isExcluded: { !$0.isAutoSwitchEnabled },
            nextCandidates: [:], preflightVerdicts: [:],
            preferencesDegraded: manager.preferencesDegraded,
            isSwitching: manager.isSwitchingProfile, now: Date())
        return ProviderActiveSelection.build(ProviderActiveSelection.Inputs(
            profiles: profiles,
            activeIds: manager.activeAccountIds(among: profiles),
            focusedId: manager.activeProfile?.id,
            context: context,
            queue: SharedDataStore.shared.loadAutoSwitchQueue(),
            duplicateGroups: FleetCounts.duplicateGroups(in: profiles, published: manager.duplicateClaudeAccountGroups),
            needsRelogin: manager.profilesNeedingAccountRelogin,
            autoSwitchEnabled: SharedDataStore.shared.loadAutoSwitchProfileEnabled()))
    }

    func selection(for provider: Profile.ProviderKind) -> ProviderActiveSelection? {
        selections.first { $0.provider == provider }
    }
}

// MARK: - Sidebar (the roster)

struct AccountsSidebar: View {
    @ObservedObject var store: AccountsInspectorStore
    @StateObject private var profileManager = ProfileManager.shared
    @State private var filter = ""
    @State private var sort: AccountsRosterModel.Sort = .bar
    @State private var showingCreate = false
    @State private var newName = ""
    let onBack: () -> Void

    private var sections: [AccountsRosterModel.Section] {
        AccountsRosterModel.sections(selections: store.selections, profiles: store.profiles, sort: sort, filter: filter)
    }

    /// Viewing, as a List selection: setting it VIEWS (never activates).
    private var viewing: Binding<UUID?> {
        Binding(
            get: { profileManager.activeProfile?.id },
            set: { id in if let id { profileManager.viewProfile(id) } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 28)  // traffic lights
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundColor(.secondary)
                TextField("accounts.filter_placeholder".localized, text: $filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                Menu {
                    Picker("", selection: $sort) {
                        Text("accounts.sort_bar".localized).tag(AccountsRosterModel.Sort.bar)
                        Text("accounts.sort_alpha".localized).tag(AccountsRosterModel.Sort.alphabetical)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 18)
                .help("accounts.sort_help".localized)
                Button { showingCreate = true } label: { Image(systemName: "plus").font(.system(size: 10)) }
                    .buttonStyle(.plain)
                    .help("accounts.add".localized)
                    .sheet(isPresented: $showingCreate) {
                        CreateProfileSheet(profileName: $newName, onSave: {
                            let created = profileManager.createProfile(name: newName.isEmpty ? nil : newName)
                            profileManager.viewProfile(created.id)
                            newName = ""
                            showingCreate = false
                        }, onCancel: { showingCreate = false })
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .padding(.horizontal, 10)

            List(selection: viewing) {
                ForEach(sections, id: \.provider) { section in
                    Section {
                        ForEach(section.rows, id: \.id) { row in
                            AccountsRosterRow(row: row)
                                .tag(row.id)
                                .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        }
                    } header: {
                        AccountsSectionHeader(section: section)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider().padding(.horizontal, 10)
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("accounts.all_settings".localized).font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

struct AccountsSectionHeader: View {
    let section: AccountsRosterModel.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.title).font(.system(size: 10, weight: .bold)).tracking(0.5)
                Spacer()
                Text(section.subtitle).font(.system(size: 9.5)).foregroundColor(.secondary)
            }
            // Words, not glyphs (owner ruling 2026-09-04); the legend is on hover only.
            // One line at the sidebar's width — the List's header row clips a
            // second line (owner finding V2); the full sentence is the tooltip.
            Text(ActiveVocabulary.countsWords(section.counts))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(ActiveVocabulary.countsSentence(section.counts) + "\n" + DesignLegend.line)
        }
        .padding(.vertical, 2)
        .accessibilityLabel(ActiveVocabulary.countsSentence(section.counts))
    }
}

struct AccountsRosterRow: View {
    let row: AccountsRosterModel.Row

    var body: some View {
        HStack(spacing: 6) {
            Text(ActiveSelectorMenuModel.glyph(for: row.readiness))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(row.readiness.role.color.opacity(row.isStale ? 0.5 : 1))
                .frame(width: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                if row.needsRelogin {
                    Text("accounts.relogin_needed".localized).font(.system(size: 9)).foregroundColor(DesignRole.blocking.color)
                } else if let email = row.email {
                    Text(email).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Text(row.percentageText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(row.percentageText.hasPrefix(DesignGlyph.weeklyHit) || row.percentageText.hasPrefix(DesignGlyph.sessionHit)
                                 ? row.readiness.role.color : (row.readiness == .suspected ? DesignRole.suspected.color : .primary))
                .help(row.readiness == .suspected ? "accounts.suspected_help".localized : "")
            if let mark = row.badge.mark {
                if case .activeFor(let provider) = row.badge {
                    ActivePill(provider: provider)   // one mark for one concept (round-3 R2)
                } else {
                    Text(mark)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(markColor)
                        .lineLimit(1)
                }
            }
        }
        .frame(height: row.email == nil && !row.needsRelogin ? 22 : 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var markColor: Color {
        switch row.badge {
        case .activeFor: return DesignRole.active.color
        case .queued: return DesignRole.informational.color
        case .next(let verdict): return verdict == .verified ? DesignRole.ready.color : (verdict == .dead ? DesignRole.blocking.color : DesignRole.informational.color)
        case .duplicate, .excluded, .none: return DesignRole.informational.color
        }
    }

    private var accessibilityText: String {
        var parts = [row.name, row.stateWords.first ?? ""]
        if case .activeFor(let provider) = row.badge { parts.append(ActiveVocabulary.activeFor(provider)) }
        parts.append(row.percentageText == "—" ? "accounts.not_measured".localized : row.percentageText + " %")
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - Detail

struct AccountsDetailView: View {
    @ObservedObject var store: AccountsInspectorStore
    @StateObject private var profileManager = ProfileManager.shared
    @Binding var tab: AccountTab
    @State private var switchNote: String?

    private var profile: Profile? { profileManager.activeProfile }

    var body: some View {
        if let profile, let selection = store.selection(for: profile.providerKind) {
            let isOwner = selection.owner?.id == profile.id
            let candidate = selection.candidates.first { $0.id == profile.id }
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
                    header(profile: profile, selection: selection, isOwner: isOwner, candidate: candidate)
                    switch tab {
                    case .overview:
                        AccountOverviewTab(profile: profile, selection: selection, isOwner: isOwner, candidate: candidate,
                                           onRepair: { tab = .login })
                    case .login:
                        AccountLoginTab(profile: profile)
                    case .alerts:
                        AccountAlertsTab(profile: profile)
                    case .monitoring:
                        AccountMonitoringTab(profile: profile)
                    }
                    Divider().padding(.top, 8)
                    AccountFooter(profile: profile)
                }
                .padding(DesignTokens.Spacing.settingsCardPadding)
            }
        } else {
            VStack {
                Spacer()
                Text("accounts.nothing_viewed".localized).font(DesignTokens.Typography.body).foregroundColor(.secondary)
                Spacer()
            }
        }
    }

    private func header(profile: Profile, selection: ProviderActiveSelection, isOwner: Bool, candidate: CandidateRow?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ActiveVocabulary.viewing).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
                Text(profile.name).font(.system(size: 18, weight: .semibold))
                Spacer()
                Text(ActiveVocabulary.providerName(profile.providerKind)).font(.system(size: 11)).foregroundColor(.secondary)
            }
            if isOwner {
                Text(ActiveVocabulary.activeFor(profile.providerKind))
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.cyan)
            } else {
                Text(selection.owner.map { "accounts.not_active".localized(with: ActiveVocabulary.activeFor(profile.providerKind), $0.name) }
                     ?? ActiveVocabulary.noActiveLogin(profile.providerKind))
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                if !isOwner, let candidate {
                    Button(ActiveVocabulary.makeActive(profile.providerKind)) {
                        Task { await makeActive(candidate: candidate, selection: selection) }
                    }
                    .disabled(candidate.readiness == .dead || selection.isSwitching)
                    .help(candidate.readiness == .dead ? "accounts.make_active_dead_help".localized : "accounts.make_active_help".localized)
                    if candidate.queuePosition == nil, candidate.status == .eligible {
                        Button("accounts.queue_next".localized) {
                            let rest = SharedDataStore.shared.loadAutoSwitchQueue().filter { $0 != profile.id }
                            SharedDataStore.shared.saveAutoSwitchQueue([profile.id] + rest)
                            store.refresh()
                        }
                    }
                }
                Button("accounts.open_dashboard".localized) { MenuBarManager.current?.openDashboard() }
                    .disabled(MenuBarManager.current == nil)
                if let switchNote {
                    Text(switchNote).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(2)
                }
            }
            Picker("", selection: $tab) {
                ForEach(AccountTab.available, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 360)
            .padding(.top, 4)
        }
    }

    private func makeActive(candidate: CandidateRow, selection: ProviderActiveSelection) async {
        let outcome = await SwitchConfirmation.confirmAndSwitch(
            provider: selection.provider, candidate: candidate, owner: selection.owner,
            makeActive: { id in await profileManager.activateProfileDetailed(id, userInitiated: true) })
        if let outcome {
            switchNote = DashboardFormatting.outcome(outcome, name: candidate.name)
        }
        store.refresh()
    }
}

// MARK: - Overview tab (frame 3)

struct AccountOverviewTab: View {
    let profile: Profile
    let selection: ProviderActiveSelection
    let isOwner: Bool
    let candidate: CandidateRow?
    /// Opens the Login tab from the dead banner (O4).
    var onRepair: (() -> Void)? = nil

    private var gauges: [WindowGauge] { isOwner ? (selection.owner?.gauges ?? []) : (candidate?.gauges ?? []) }
    private var measurement: UsageMeasurement? { isOwner ? selection.owner?.measurement : candidate?.measurement }
    private var readiness: AccountReadiness { isOwner ? (selection.owner?.readiness ?? .unknown) : (candidate?.readiness ?? .unknown) }
    /// The inferred-throttle caveat for ANY viewed account (the selection only
    /// carries it for the owner): last measured value + age + projection —
    /// never a live-looking number.
    private var suspected: SuspectedCaveat? {
        guard let usage = profile.claudeUsage, usage.isSuspectedRateLimited else { return nil }
        return SuspectedCaveat(lastMeasured: usage.sessionPercentage, measuredAt: usage.lastUpdated,
                               projected: usage.projectedSessionPercentage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            if readiness == .dead {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                    Text("accounts.dead_banner".localized).font(DesignTokens.Typography.body)
                    Spacer()
                    if let onRepair { Button("accounts.dead_banner_action".localized, action: onRepair).buttonStyle(.link) }
                    Button("advanced.dead_forget".localized) {
                        DeadLoginFlags.forget(DeadLoginFlagRow(id: profile.id, name: profile.name, provider: profile.providerKind))
                    }
                    .controlSize(.small)
                    .help("advanced.dead_note".localized)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
            }
            if ProfileManager.shared.profilesNeedingAccountRelogin.contains(profile.id) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundColor(DesignRole.blocking.color)
                    Text("accounts.relogin_banner".localized).font(DesignTokens.Typography.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if let onRepair { Button("accounts.dead_banner_action".localized, action: onRepair).buttonStyle(.link) }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(DesignRole.blocking.color.opacity(0.12)))
            }
            SettingsContentCard {
                VStack(alignment: .leading, spacing: 8) {
                    if gauges.isEmpty {
                        Text("accounts.not_measured_yet".localized).font(DesignTokens.Typography.body).foregroundColor(.secondary)
                    } else {
                        ForEach(gauges, id: \.kind) { gauge in
                            GaugeRow(gauge: gauge, suspected: gauge.kind == .session ? suspected : nil)
                        }
                        if !gauges.contains(where: { $0.kind == .session }), let weekly = gauges.first(where: { $0.kind == .weekly }) {
                            Text("selector.fires_at".localized(with: Int(weekly.threshold))).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                        }
                    }
                    Text(provenanceLine).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                }
            }
            SettingsContentCard {
                VStack(alignment: .leading, spacing: 6) {
                    fact("accounts.fact.readiness".localized, readinessText)
                    fact("accounts.fact.identity".localized, identityText)
                    fact("accounts.fact.fetch".localized, "accounts.fact.fetch_interval".localized(with: Int(profile.refreshInterval)),
                         help: "accounts.fact.fetch_help".localized)
                    if !sameAccountAs.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Text("accounts.fact.same_account".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary).frame(width: 84, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sameAccountAs.joined(separator: ", ")).font(DesignTokens.Typography.body).foregroundColor(DesignRole.caution.color)
                                HStack(spacing: 8) {
                                    ForEach(sameAccountAs, id: \.self) { name in
                                        if let other = ProfileManager.shared.profiles.first(where: { $0.name == name }) {
                                            Button("accounts.fact.view_profile".localized(with: name)) {
                                                NotificationCenter.default.post(name: .settingsSectionRequested,
                                                                                object: SettingsRoute(section: .accounts, profileId: other.id))
                                            }
                                            .buttonStyle(.link).font(DesignTokens.Typography.caption)
                                        }
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .help("accounts.fact.same_account_help".localized)
                    }
                    if profile.providerKind == .codex {
                        HStack(alignment: .top, spacing: 10) {
                            Text("accounts.fact.resets".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary).frame(width: 84, alignment: .trailing)
                            CodexResetsCard(profile: profile, measurement: measurement, readiness: readiness)
                        }
                    }
                    fact("accounts.fact.history".localized, historyText)
                }
            }
        }
    }

    private var provenanceLine: String {
        guard let measurement else { return "accounts.not_measured_yet_short".localized }
        var line = DashboardFormatting.provenance(measurement)
        if let usage = profile.claudeUsage,
           AccountReadiness.isStale(usage, thresholds: ReadinessThresholds(session: selection.autoSwitch.sessionThreshold, weekly: selection.autoSwitch.weeklyThreshold), now: Date()) {
            line += " · " + "accounts.stale".localized
        }
        return line
    }

    private var readinessText: String {
        var text = DashboardFormatting.chip(chip(for: readiness))
        if readiness == .dead { return text }
        if let candidate {
            text += " · " + ActiveSelectorMenuModel.verdictText(candidate.verdict, kind: candidate.verdictKind, at: candidate.verdictAt, now: Date())
                .replacingOccurrences(of: "✓ ", with: "").replacingOccurrences(of: "? ", with: "").replacingOccurrences(of: "× ", with: "")
        } else if isOwner {
            text += " · " + "selector.verdict_owns_login".localized
        }
        return text
    }

    private func chip(for readiness: AccountReadiness) -> RowChip {
        switch readiness {
        case .ready: return .ready
        case .readyLight: return .readyLight
        case .unknown: return .unmeasured
        case .suspected: return .suspected(lastMeasured: profile.claudeUsage?.sessionPercentage ?? 0, at: profile.claudeUsage?.lastUpdated ?? Date())
        case .sessionHit, .sessionHitLight: return .sessionExhausted(resetAt: profile.claudeUsage?.sessionResetTime ?? Date())
        case .weeklyHit, .weeklyHitSoon: return .weeklyMaxed
        case .excluded: return profile.isAutoSwitchEnabled ? .freePlan : .autoSwitchOff
        case .dead: return .deadLogin
        }
    }

    private var identityText: String {
        var parts: [String] = []
        if let email = AccountsRosterModel.email(of: profile) { parts.append(email) }
        switch profile.providerKind {
        case .claude:
            if let uuid = profile.claudeAccountUUID { parts.append("accounts.account_suffix".localized(with: String(uuid.suffix(4)))) }
            if let org = profile.claudeOrganizationUUID { parts.append("accounts.org_suffix".localized(with: String(org.suffix(4)))) }
        case .codex:
            if let id = profile.codexAccountId { parts.append("accounts.account_suffix".localized(with: String(id.suffix(4)))) }
            if let home = profile.codexHomePath { parts.append(home) }
        case .grok:
            break
        }
        return parts.isEmpty ? "accounts.identity_unknown".localized : parts.joined(separator: " · ")
    }

    private var sameAccountAs: [String] {
        if isOwner { return selection.owner?.sameAccountAs ?? [] }
        if case .duplicateOfOwner(let name)? = candidate?.status { return [name] }
        return []
    }

    private var historyText: String {
        let events = SharedDataStore.shared.loadSwitchHistory()
            .filter { $0.from == profile.name || $0.to == profile.name }
            .suffix(3).reversed()
        guard !events.isEmpty else { return "accounts.history_none".localized }
        return events.map { event in
            let direction = event.to == profile.name
                ? "accounts.history_in".localized(with: event.from)
                : "accounts.history_out".localized(with: event.to)
            return "\(direction) · \(DashboardFormatting.age(event.at)) · \(event.trigger.rawValue)"
        }.joined(separator: "\n")
    }

    private func fact(_ label: String, _ value: String, help: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(DesignTokens.Typography.caption).foregroundColor(.secondary).frame(width: 84, alignment: .trailing)
            Text(value).font(DesignTokens.Typography.body).textSelection(.enabled).help(help ?? "")
            Spacer(minLength: 0)
        }
    }
}

struct GaugeRow: View {
    let gauge: WindowGauge
    var suspected: SuspectedCaveat? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(DashboardFormatting.gaugeTitle(gauge.kind, compact: false))
                .font(DesignTokens.Typography.caption).foregroundColor(.secondary).frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(color).frame(width: max(0, min(1, shownPercentage / 100)) * geo.size.width)
                    Rectangle().fill(Color.primary.opacity(0.45)).frame(width: 1)
                        .offset(x: max(0, min(1, gauge.threshold / 100)) * geo.size.width)
                }
            }
            .frame(height: 6)
            .help("accounts.tick_help".localized(with: Int(gauge.threshold)))
            Text(percentageText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(suspected == nil ? .primary : .purple)
                .lineLimit(1)
                .frame(width: suspected == nil ? 96 : 170, alignment: .trailing)
            Text(resetText).font(DesignTokens.Typography.caption).foregroundColor(.secondary).frame(width: 130, alignment: .leading)
        }
    }

    private var shownPercentage: Double { suspected?.lastMeasured ?? gauge.percentage }
    private var percentageText: String {
        if let suspected {
            // Last MEASURED value + its age, projection in brackets — never a
            // live-looking number for a blind account (spec R5).
            var text = "\(Int(suspected.lastMeasured.rounded())) % · \(DashboardFormatting.age(suspected.measuredAt))"
            if let projected = suspected.projected { text += " → \(Int(projected.rounded())) %" }
            return text
        }
        return "\(Int(gauge.percentage.rounded())) %"
    }
    private var color: Color {
        if suspected != nil { return .purple }
        if gauge.percentage >= gauge.threshold { return .red }
        if gauge.percentage >= 80 { return .orange }
        return .adaptiveGreen
    }
    private var resetText: String {
        guard let reset = gauge.resetAt, reset > Date() else { return "" }
        return "accounts.resets_in".localized(with: reset.timeRemainingString())
    }
}

// MARK: - Switch confirmation (shared with the ⇄ selector)

@MainActor
enum SwitchConfirmation {
    /// The never-suppressible confirmation (design pass §12.1 frame 9), then the
    /// ONE activation seam. Returns nil when cancelled. Activates the app before
    /// every alert — an accessory app's click grant has expired after an await.
    static func confirmAndSwitch(
        provider: Profile.ProviderKind,
        candidate: CandidateRow,
        owner: OwnerRow?,
        makeActive: (UUID) async -> ProfileManager.ActivationOutcome
    ) async -> ProfileManager.ActivationOutcome? {
        let confirmation = ActiveSelectorMenuModel.confirmation(provider: provider, candidate: candidate, owner: owner, now: Date())
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.body
        alert.alertStyle = confirmation.risky ? .warning : .informational
        alert.addButton(withTitle: confirmation.cancelButton)  // Cancel is the default: switching is the costly action
        let switchButton = alert.addButton(withTitle: confirmation.confirmButton)
        switchButton.isEnabled = confirmation.switchAllowed  // a dead login reads "Log in first", disabled
        guard alert.runModal() == .alertSecondButtonReturn, confirmation.switchAllowed else { return nil }
        return await makeActive(candidate.id)
    }
}
