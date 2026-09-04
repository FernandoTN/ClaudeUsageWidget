//
//  ActiveSwitchView.swift
//  Claude Usage
//
//  Settings › Active & Auto-switch (docs/specs/ux-revamp.md §5.1; design pass
//  §12.3): the three "Active for <provider>" cards — a mirror of the ⇄ menu, on
//  a page — then the policy: the fleet-wide enable toggle, the two thresholds,
//  the hand-off queue with a provider filter, and the ONE place the per-account
//  eligibility toggles live. Every switch goes through the shared, never-
//  suppressible confirmation; nothing here reads the viewed profile as authority.
//

import SwiftUI

struct ActiveSwitchView: View {
    @StateObject private var store = AccountsInspectorStore()
    @StateObject private var profileManager = ProfileManager.shared
    @State private var autoSwitchEnabled = SharedDataStore.shared.loadAutoSwitchProfileEnabled()
    @State private var sessionThreshold = SharedDataStore.shared.loadAutoSwitchThreshold()
    @State private var weeklyThreshold = SharedDataStore.shared.loadAutoSwitchWeeklyThreshold()
    @State private var queue: [UUID] = SharedDataStore.shared.loadAutoSwitchQueue()
    @State private var queueFilter: Profile.ProviderKind?
    @State private var switchNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(title: "active.title".localized, subtitle: "active.subtitle".localized)

                // The three owners, one card each.
                ForEach(store.selections, id: \.provider) { selection in
                    ActiveProviderCard(selection: selection, isEnabled: autoSwitchEnabled) { candidate in
                        Task { await makeActive(candidate, selection: selection) }
                    }
                }
                if let switchNote {
                    Text(switchNote).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                }

                SettingsSectionCard(title: "auto_switch.title".localized, subtitle: "auto_switch.subtitle".localized) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
                        SettingToggle(
                            title: "auto_switch.enable_title".localized,
                            description: "auto_switch.enable_description".localized,
                            isOn: Binding(get: { autoSwitchEnabled }, set: { on in
                                autoSwitchEnabled = on
                                SharedDataStore.shared.saveAutoSwitchProfileEnabled(on)
                            })
                        )
                        Divider()
                        ThresholdField(title: "auto_switch.threshold_title".localized,
                                       description: "auto_switch.threshold_description".localized,
                                       value: $sessionThreshold) { SharedDataStore.shared.saveAutoSwitchThreshold($0) }
                        ThresholdField(title: "auto_switch.weekly_threshold_title".localized,
                                       description: "auto_switch.weekly_threshold_description".localized,
                                       value: $weeklyThreshold) { SharedDataStore.shared.saveAutoSwitchWeeklyThreshold($0) }
                        Text("active.rules".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                SettingsSectionCard(title: "active.queue_title".localized, subtitle: "active.queue_subtitle".localized) {
                    queueEditor
                }

                SettingsSectionCard(title: "auto_switch.eligible_profiles".localized, subtitle: "auto_switch.eligible_profiles_hint".localized) {
                    eligibilityList
                }
            }
            .padding()
        }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsChanged)) { _ in
            queue = SharedDataStore.shared.loadAutoSwitchQueue()
            autoSwitchEnabled = SharedDataStore.shared.loadAutoSwitchProfileEnabled()
        }
    }

    // MARK: - Queue (with a provider filter)

    private var queueEditor: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack {
                Picker("", selection: $queueFilter) {
                    Text("active.queue_all".localized).tag(Profile.ProviderKind?.none)
                    ForEach([Profile.ProviderKind.claude, .codex, .grok], id: \.self) { provider in
                        Text(ActiveVocabulary.providerName(provider)).tag(Profile.ProviderKind?.some(provider))
                    }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                Spacer()
                Menu("active.queue_add".localized) {
                    ForEach(ActiveSwitchQueueModel.addable(profiles: profileManager.profiles, queue: queue, filter: queueFilter), id: \.id) { profile in
                        Button("\(profile.name)  (\(ActiveVocabulary.providerName(profile.providerKind)))") {
                            queue.append(profile.id)
                            SharedDataStore.shared.saveAutoSwitchQueue(queue)
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            let rows = ActiveSwitchQueueModel.rows(queue: queue, profiles: profileManager.profiles, filter: queueFilter)
            if rows.isEmpty {
                Text(queueFilter == nil ? "active.queue_empty".localized : "active.queue_empty_provider".localized(with: ActiveVocabulary.providerName(queueFilter!)))
                    .font(DesignTokens.Typography.caption).foregroundColor(.secondary)
            } else {
                ForEach(rows, id: \.id) { row in
                    HStack(spacing: DesignTokens.Spacing.small) {
                        Text(row.isNextForProvider ? "active.queue_next_label".localized : "\(row.position).")
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit().frame(width: 36, alignment: .trailing)
                        Text(row.name).font(DesignTokens.Typography.body)
                        Text(ActiveVocabulary.providerName(row.provider)).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                        Spacer()
                        Button { move(row.position - 1, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(row.position == 1)
                        Button { move(row.position - 1, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(row.position == queue.count)
                        Button { remove(row.id) } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }.buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
                Text("active.queue_note".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard queue.indices.contains(index), queue.indices.contains(target) else { return }
        queue.swapAt(index, target)
        SharedDataStore.shared.saveAutoSwitchQueue(queue)
    }

    private func remove(_ id: UUID) {
        queue.removeAll { $0 == id }
        SharedDataStore.shared.saveAutoSwitchQueue(queue)
    }

    // MARK: - Eligibility (the one primary location)

    private var eligibilityList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            ForEach([Profile.ProviderKind.claude, .codex, .grok], id: \.self) { provider in
                let members = profileManager.profiles.filter { $0.providerKind == provider }
                if !members.isEmpty {
                    Text(ActiveVocabulary.providerName(provider).uppercased())
                        .font(.system(size: 10, weight: .bold)).foregroundColor(.secondary).padding(.top, 4)
                    ForEach(members) { profile in
                        Toggle(isOn: Binding(get: { profile.isAutoSwitchEnabled },
                                             set: { profileManager.updateAutoSwitchEnabled($0, for: profile.id) })) {
                            HStack(spacing: DesignTokens.Spacing.small) {
                                Text(profile.name).font(DesignTokens.Typography.body).lineLimit(1)
                                if profileManager.isProviderActive(profile) {
                                    Text(ActiveVocabulary.activeFor(provider))
                                        .font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(DesignRole.active.color))
                                }
                            }
                        }
                        .toggleStyle(.switch).controlSize(.mini)
                    }
                }
            }
        }
    }

    private func makeActive(_ candidate: CandidateRow, selection: ProviderActiveSelection) async {
        let outcome = await SwitchConfirmation.confirmAndSwitch(
            provider: selection.provider, candidate: candidate, owner: selection.owner,
            makeActive: { id in await profileManager.activateProfileDetailed(id, userInitiated: true) })
        if let outcome { switchNote = DashboardFormatting.outcome(outcome, name: candidate.name) }
        store.refresh()
    }
}

// MARK: - Provider card (a mirror of the ⇄ menu's section)

struct ActiveProviderCard: View {
    let selection: ProviderActiveSelection
    let isEnabled: Bool
    let onSwitch: (CandidateRow) -> Void

    var body: some View {
        SettingsContentCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                HStack(alignment: .firstTextBaseline) {
                    Text(ActiveVocabulary.activeFor(selection.provider)).font(DesignTokens.Typography.sectionTitle)
                    Spacer()
                    if selection.isSwitching {
                        Text("selector.switching_short".localized).font(DesignTokens.Typography.caption).foregroundColor(DesignRole.active.color)
                    }
                }
                if let owner = selection.owner {
                    HStack(spacing: 8) {
                        Text(ActiveSelectorMenuModel.glyph(for: owner.readiness)).foregroundColor(DesignRole.active.color)
                        Text(owner.name).font(DesignTokens.Typography.bodyMedium)
                        Text(ActiveSelectorMenuModel.compactGaugeText(owner.gauges)).font(DesignTokens.Typography.captionMono).foregroundColor(.secondary)
                        if let m = owner.measurement { Text(DashboardFormatting.provenance(m)).font(DesignTokens.Typography.caption).foregroundColor(.secondary) }
                        if owner.isManuallyPinned { Text("selector.pinned".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary) }
                    }
                    if let caveat = owner.suspected {
                        Text("selector.last_measured".localized(with: Int(caveat.lastMeasured.rounded()), DashboardFormatting.age(caveat.measuredAt)))
                            .font(DesignTokens.Typography.caption).foregroundColor(DesignRole.suspected.color)
                    }
                } else {
                    Text(ActiveVocabulary.noActiveLogin(selection.provider)).font(DesignTokens.Typography.body).foregroundColor(.secondary)
                }
                if selection.candidates.isEmpty {
                    Text("selector.single_account".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                } else if let next = selection.next, let row = selection.candidates.first(where: { $0.id == next.id }) {
                    HStack(spacing: 8) {
                        Text("selector.next".localized(with: row.name)).font(DesignTokens.Typography.body)
                        Text(ActiveSelectorMenuModel.verdictText(row.verdict, kind: row.verdictKind, at: row.verdictAt, now: Date()))
                            .font(DesignTokens.Typography.caption)
                            .foregroundColor(ActiveSelectorItem.color(ActiveSelectorMenuModel.tint(for: next.verdict)).asColor)
                        Spacer()
                        if row.status == .eligible {
                            Button(ActiveVocabulary.makeActive(selection.provider)) { onSwitch(row) }
                                .disabled(selection.isSwitching)
                        }
                    }
                } else {
                    Text("selector.no_candidate".localized).font(DesignTokens.Typography.body).foregroundColor(DesignRole.blocking.color)
                }
                if !isEnabled {
                    Text("active.disabled_note".localized).font(DesignTokens.Typography.caption).foregroundColor(DesignRole.caution.color)
                }
            }
        }
    }
}

private extension NSColor {
    var asColor: Color { Color(nsColor: self) }
}

// MARK: - Queue view model (pure, tested)

enum ActiveSwitchQueueModel {
    struct Row: Hashable {
        var id: UUID
        var name: String
        var provider: Profile.ProviderKind
        /// 1-based position in the whole queue.
        var position: Int
        /// The first entry of ITS provider — what that provider's next switch takes.
        var isNextForProvider: Bool
    }

    /// The queue's rows, in queue order, optionally one provider only. Entries
    /// whose profile no longer exists are skipped.
    static func rows(queue: [UUID], profiles: [Profile], filter: Profile.ProviderKind?) -> [Row] {
        let byId = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var seen: Set<Profile.ProviderKind> = []
        var out: [Row] = []
        for (index, id) in queue.enumerated() {
            guard let profile = byId[id] else { continue }
            let first = !seen.contains(profile.providerKind)
            seen.insert(profile.providerKind)
            if let filter, profile.providerKind != filter { continue }
            out.append(Row(id: id, name: profile.name, provider: profile.providerKind, position: index + 1, isNextForProvider: first))
        }
        return out
    }

    /// Profiles that can still be queued: not queued yet, credentialed, and of
    /// the filtered provider when one is set.
    static func addable(profiles: [Profile], queue: [UUID], filter: Profile.ProviderKind?) -> [Profile] {
        let queued = Set(queue)
        return profiles.filter { !queued.contains($0.id) && $0.hasUsageCredentials && (filter == nil || $0.providerKind == filter) }
    }
}
