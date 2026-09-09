//
//  WeeklyPrimeSettingsCard.swift
//  Claude Usage
//
//  Settings › Active & Auto-switch › Weekly window priming
//  (docs/specs/weekly-window-priming.md): the one toggle — "Prime Codex weekly
//  windows after reset", ON by default — and the per-account "Never prime"
//  list, both persisted as `weeklyPrimePolicy_v1`. Codex only, by owner
//  decision; Claude and Grok have no row here.
//

import SwiftUI

struct WeeklyPrimeSettingsCard: View {
    /// The Codex profiles, in roster order.
    let profiles: [Profile]

    @State private var policy = SharedDataStore.shared.loadWeeklyPrimePolicy()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
            SettingToggle(
                title: "prime.codex_toggle".localized,
                description: "prime.codex_toggle_desc".localized,
                isOn: Binding(get: { policy.codexEnabled }, set: { on in
                    policy.codexEnabled = on
                    SharedDataStore.shared.saveWeeklyPrimePolicy(policy)
                })
            )
            if !profiles.isEmpty {
                Divider()
                Text("prime.never_title".localized.uppercased())
                    .font(.system(size: 10, weight: .bold)).foregroundColor(.secondary)
                Text("prime.never_hint".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(profiles) { profile in
                    Toggle(isOn: Binding(get: { !policy.neverPrime.contains(profile.id) }, set: { primes in
                        policy.neverPrime.removeAll { $0 == profile.id }
                        if !primes { policy.neverPrime.append(profile.id) }
                        SharedDataStore.shared.saveWeeklyPrimePolicy(policy)
                    })) {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            Text("prime.never_row".localized(with: profile.name)).font(DesignTokens.Typography.body).lineLimit(1)
                            if ProfileManager.shared.isProviderActive(profile) { ActivePill(provider: .codex) }
                        }
                    }
                    .toggleStyle(.switch).controlSize(.mini)
                    .disabled(!policy.codexEnabled)
                }
            }
        }
    }
}
