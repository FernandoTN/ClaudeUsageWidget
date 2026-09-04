//
//  DisplaySettingsView.swift
//  Claude Usage
//
//  Settings › Display (docs/specs/ux-revamp.md §5.1; design pass §12.5): how the
//  menu bar is drawn (mode, per-provider layout, what a click opens, tile
//  cosmetics), the ⇄ selector item, the popover's time display. WHICH accounts
//  show is each account's own choice (Accounts › Monitoring). The single-account
//  icon configuration (`SingleAccountBarCards`) is here since stage 3d.
//

import SwiftUI

struct DisplaySettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.section) {
                SettingsPageHeader(title: "display.title".localized, subtitle: "display.subtitle".localized)
                SettingsSectionCard(title: "display.bar_title".localized, subtitle: "display.bar_subtitle".localized) {
                    DisplayMenuBarCard()
                }
                SettingsSectionCard(title: "selector.setting_title".localized, subtitle: "selector.setting_subtitle".localized) {
                    DisplaySelectorCard()
                }
                SettingsSectionCard(title: "display.popover_title".localized, subtitle: "display.popover_subtitle".localized) {
                    DisplayPopoverCard()
                }
                // Single-account bar: the two cards that were the Appearance page (stage 3d).
                Text("display.single_note".localized)
                    .font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SingleAccountBarCards()
            }
            .padding()
        }
    }
}

// MARK: - Menu bar

struct DisplayMenuBarCard: View {
    @StateObject private var profileManager = ProfileManager.shared

    private func config<T>(_ keyPath: WritableKeyPath<MultiProfileDisplayConfig, T>) -> Binding<T> {
        Binding(get: { profileManager.multiProfileConfig[keyPath: keyPath] },
                set: { value in
                    var updated = profileManager.multiProfileConfig
                    updated[keyPath: keyPath] = value
                    profileManager.updateMultiProfileConfig(updated)
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
            labeled("display.mode".localized, note: "display.mode_note".localized) {
                Picker("", selection: Binding(get: { profileManager.displayMode }, set: { profileManager.updateDisplayMode($0) })) {
                    Text("display.mode_single".localized).tag(ProfileDisplayMode.single)
                    Text("display.mode_multi".localized).tag(ProfileDisplayMode.multi)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if profileManager.displayMode == .multi {
                Divider()
                labeled("multiprofile.icon_style".localized) {
                    Picker("", selection: config(\.iconStyle)) {
                        ForEach(MultiProfileIconStyle.allCases, id: \.self) { Text($0.shortNameKey.localized).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                labeled("multiprofile.layout".localized, note: "multiprofile.layout_description".localized) {
                    Picker("", selection: config(\.barLayout)) {
                        ForEach(MenuBarLayout.allCases, id: \.self) { Text($0.shortNameKey.localized).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                labeled("multiprofile.click_surface".localized, note: "multiprofile.click_surface_description".localized) {
                    Picker("", selection: Binding(
                        get: { profileManager.multiProfileConfig.clickSurface?.rawValue ?? "auto" },
                        set: { raw in
                            var updated = profileManager.multiProfileConfig
                            updated.clickSurface = ClickSurface(rawValue: raw)
                            profileManager.updateMultiProfileConfig(updated)
                        })) {
                        Text("multiprofile.click_surface_auto".localized).tag("auto")
                        Text("multiprofile.click_surface_dashboard".localized).tag(ClickSurface.dashboard.rawValue)
                        Text("multiprofile.click_surface_classic".localized).tag(ClickSurface.classic.rawValue)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                Divider()
                SettingToggle(title: "multiprofile.show_week".localized, description: "multiprofile.show_week_description".localized, isOn: config(\.showWeek))
                SettingToggle(title: "multiprofile.show_label".localized, description: "multiprofile.show_label_description".localized, isOn: config(\.showProfileLabel))
                SettingToggle(title: "multiprofile.use_system_color".localized, description: "multiprofile.use_system_color_description".localized, isOn: config(\.useSystemColor))
                SettingToggle(title: "appearance.show_time_marker_title".localized, description: "appearance.show_time_marker_description".localized, isOn: config(\.showTimeMarker))
                SettingToggle(title: "appearance.show_pace_marker_title".localized, description: "appearance.show_pace_marker_description".localized, isOn: config(\.showPaceMarker))
                SettingToggle(title: "appearance.pace_coloring_title".localized, description: "appearance.pace_coloring_description".localized, isOn: config(\.usePaceColoring))
            }
        }
    }

    @ViewBuilder
    private func labeled<Content: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            Text(title).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
            content()
            if let note {
                Text(note).font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - ⇄ selector item

struct DisplaySelectorCard: View {
    @State private var enabled = SharedDataStore.shared.loadActiveSelectorItemEnabled()

    var body: some View {
        SettingToggle(
            title: "selector.setting_toggle".localized,
            description: "selector.setting_toggle_desc".localized,
            isOn: Binding(get: { enabled }, set: { on in
                enabled = on
                SharedDataStore.shared.saveActiveSelectorItemEnabled(on)
                NotificationCenter.default.post(name: .activeSelectorVisibilityChanged, object: nil)
            })
        )
    }
}

// MARK: - Popover

struct DisplayPopoverCard: View {
    @State private var timeDisplay: PopoverTimeDisplay = SharedDataStore.shared.loadPopoverTimeDisplay()
    @State private var timeFormat: TimeFormatPreference = SharedDataStore.shared.loadTimeFormatPreference()

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.cardPadding) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text("popover.time_display".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                Picker("", selection: $timeDisplay) {
                    Text("popover.time_display_reset".localized).tag(PopoverTimeDisplay.resetTime)
                    Text("popover.time_display_remaining".localized).tag(PopoverTimeDisplay.remainingTime)
                    Text("popover.time_display_both".localized).tag(PopoverTimeDisplay.both)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text("popover.time_format".localized).font(DesignTokens.Typography.caption).foregroundColor(.secondary)
                Picker("", selection: $timeFormat) {
                    Text("popover.time_format_system".localized).tag(TimeFormatPreference.system)
                    Text("popover.time_format_12h".localized).tag(TimeFormatPreference.twelveHour)
                    Text("popover.time_format_24h".localized).tag(TimeFormatPreference.twentyFourHour)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .onChange(of: timeDisplay) { _, value in SharedDataStore.shared.savePopoverTimeDisplay(value) }
        .onChange(of: timeFormat) { _, value in SharedDataStore.shared.saveTimeFormatPreference(value) }
    }
}
