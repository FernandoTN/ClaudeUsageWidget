//
//  MenuBarIconConfig.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-27.
//

import Foundation

/// Menu bar icon style options
enum MenuBarIconStyle: String, CaseIterable, Codable {
    case battery
    case progressBar
    case percentageOnly
    case icon
    case compact

    var displayName: String {
        switch self {
        case .battery:
            return "Battery (Classic)"
        case .progressBar:
            return "Progress Bar"
        case .percentageOnly:
            return "Percentage"
        case .icon:
            return "Icon with Bar"
        case .compact:
            return "Compact"
        }
    }

    var description: String {
        switch self {
        case .battery:
            return "Original battery-style bar with Claude text below"
        case .progressBar:
            return "Clean horizontal progress bar only"
        case .percentageOnly:
            return "Just the percentage in color-coded text"
        case .icon:
            return "Circular ring with progress indicator"
        case .compact:
            return "Minimalist dot indicator"
        }
    }
}

/// Types of metrics that can be displayed in the menu bar
enum MenuBarMetricType: String, Codable, CaseIterable, Identifiable {
    case session
    case week
    /// Decode-only legacy case — API Console billing feature removed 2026-07.
    /// Kept so existing MenuBarIconConfiguration JSON with `"api"` still decodes.
    case api

    var id: String { rawValue }

    /// Metric types still shown in UI pickers / defaults (excludes decode-only `.api`).
    static var activeCases: [MenuBarMetricType] { [.session, .week] }

    var displayName: String {
        switch self {
        case .session:
            return "Session Usage"
        case .week:
            return "Week Usage"
        case .api:
            // decode-only legacy case
            return "API Credits"
        }
    }

    var prefixText: String {
        switch self {
        case .session:
            return "S:"
        case .week:
            return "W:"
        case .api:
            // decode-only legacy case
            return "API:"
        }
    }

    var description: String {
        switch self {
        case .session:
            return "5-hour rolling window usage"
        case .week:
            return "Weekly token usage (all models)"
        case .api:
            // decode-only legacy case
            return "API Console billing credits"
        }
    }

    var icon: String {
        switch self {
        case .session:
            return "clock.fill"
        case .week:
            return "calendar.badge.clock"
        case .api:
            // decode-only legacy case
            return "dollarsign.circle.fill"
        }
    }
}

/// Color mode for menu bar icons
enum MenuBarColorMode: String, Codable, CaseIterable {
    case multiColor = "multiColor"
    case monochrome = "monochrome"
    case singleColor = "singleColor"

    var displayName: String {
        switch self {
        case .multiColor:
            return "Multi-Color"
        case .monochrome:
            return "Greyscale"
        case .singleColor:
            return "Single Color"
        }
    }

    var description: String {
        switch self {
        case .multiColor:
            return "Green, orange, red based on usage level"
        case .monochrome:
            return "Adapts to menu bar appearance"
        case .singleColor:
            return "Custom color of your choice"
        }
    }

    var icon: String {
        switch self {
        case .multiColor:
            return "paintpalette.fill"
        case .monochrome:
            return "circle.lefthalf.filled"
        case .singleColor:
            return "paintbrush.fill"
        }
    }
}

/// Display mode for API usage.
/// Decode-only legacy — API Console billing feature removed 2026-07; field kept on
/// `MetricIconConfig` so existing saved JSON still decodes.
enum APIDisplayMode: String, Codable, CaseIterable {
    case remaining
    case used
    case both

    var displayName: String {
        switch self {
        case .remaining:
            return "Remaining Credits"
        case .used:
            return "Used Amount"
        case .both:
            return "Both (Used / Total)"
        }
    }

    var description: String {
        switch self {
        case .remaining:
            return "Show only remaining credits"
        case .used:
            return "Show only amount spent"
        case .both:
            return "Show both used and total"
        }
    }
}

/// Display mode for week usage
enum WeekDisplayMode: String, Codable, CaseIterable {
    case percentage
    case tokens

    var displayName: String {
        switch self {
        case .percentage:
            return "Percentage"
        case .tokens:
            return "Token Count"
        }
    }

    var description: String {
        switch self {
        case .percentage:
            return "Show as percentage (e.g., 60%)"
        case .tokens:
            return "Show token numbers (e.g., 600K/1M)"
        }
    }
}

/// Configuration for a single metric icon
struct MetricIconConfig: Codable, Equatable {
    var metricType: MenuBarMetricType
    var isEnabled: Bool
    var iconStyle: MenuBarIconStyle
    var order: Int

    /// Week-specific configuration
    var weekDisplayMode: WeekDisplayMode

    /// API-specific configuration (decode-only legacy field)
    var apiDisplayMode: APIDisplayMode

    /// Session-specific configuration
    var showNextSessionTime: Bool

    init(
        metricType: MenuBarMetricType,
        isEnabled: Bool = false,
        iconStyle: MenuBarIconStyle = .battery,
        order: Int = 0,
        weekDisplayMode: WeekDisplayMode = .percentage,
        apiDisplayMode: APIDisplayMode = .remaining,
        showNextSessionTime: Bool = false
    ) {
        self.metricType = metricType
        self.isEnabled = isEnabled
        self.iconStyle = iconStyle
        self.order = order
        self.weekDisplayMode = weekDisplayMode
        self.apiDisplayMode = apiDisplayMode
        self.showNextSessionTime = showNextSessionTime
    }

    /// Default config for session (enabled by default)
    static var sessionDefault: MetricIconConfig {
        MetricIconConfig(
            metricType: .session,
            isEnabled: true,
            iconStyle: .battery,
            order: 0,
            showNextSessionTime: false
        )
    }

    /// Default config for week (disabled by default)
    static var weekDefault: MetricIconConfig {
        MetricIconConfig(
            metricType: .week,
            isEnabled: false,
            iconStyle: .battery,
            order: 1,
            weekDisplayMode: .percentage
        )
    }
}

/// Icon style for multi-profile display
enum MultiProfileIconStyle: String, Codable, CaseIterable, Hashable {
    case concentric   // Concentric circles (session inner, week outer)
    case progressBar  // Horizontal progress bars stacked
    case compact      // Minimal dot indicators
    case percentage   // Percentage text (e.g. "30 · 4")

    var displayName: String {
        switch self {
        case .concentric:
            return "Concentric Circles"
        case .progressBar:
            return "Progress Bars"
        case .compact:
            return "Compact Dots"
        case .percentage:
            return "Percentage"
        }
    }

    /// Localization key for short segmented picker label
    var shortNameKey: String {
        switch self {
        case .concentric:
            return "multiprofile.style_circles"
        case .progressBar:
            return "multiprofile.style_bars"
        case .compact:
            return "multiprofile.style_dots"
        case .percentage:
            return "multiprofile.style_percent"
        }
    }

    var description: String {
        switch self {
        case .concentric:
            return "Session inside, week outside ring"
        case .progressBar:
            return "Horizontal bars stacked vertically"
        case .compact:
            return "Minimal colored dots"
        case .percentage:
            return "Session and week as colored numbers"
        }
    }

    var icon: String {
        switch self {
        case .concentric:
            return "circle.circle"
        case .progressBar:
            return "chart.bar.fill"
        case .compact:
            return "circle.fill"
        case .percentage:
            return "percent"
        }
    }
}

/// What the multi-profile menu bar shows per provider group.
///
/// `everyAccount` is the layout the app has always had: one tile per selected
/// account, concatenated per provider. It stops being a summary somewhere
/// around ten accounts (22 selected accounts ≈ 600 pt of bar on the owner's
/// Mac, 2026-09-03) and macOS then hides a whole provider group on overflow.
/// The fleet layouts keep ONE tile per provider — the provider-active account
/// rendered exactly as before — and abstract the other accounts into a
/// readiness fleet (dots, or counts when the group is too large for dots).
/// Absent in saved JSON from before this option existed → `everyAccount`,
/// so an upgrade never changes what is on the bar.
enum MenuBarLayout: String, Codable, CaseIterable, Hashable {
    /// One tile per selected account (the original composite layout).
    case everyAccount
    /// Active account's tile + one readiness dot per other account.
    case fleetDots
    /// Active account's tile + readiness counts (ready / exhausted / dead / suspected).
    case fleetCounts

    /// True for the layouts that collapse a provider group into one summary tile.
    var isFleetSummary: Bool { self != .everyAccount }

    var displayName: String {
        switch self {
        case .everyAccount: return "Every account"
        case .fleetDots: return "Active + fleet dots"
        case .fleetCounts: return "Active + fleet counts"
        }
    }

    /// Localization key for the short segmented picker label.
    var shortNameKey: String {
        switch self {
        case .everyAccount: return "multiprofile.layout_every"
        case .fleetDots: return "multiprofile.layout_dots"
        case .fleetCounts: return "multiprofile.layout_counts"
        }
    }
}

/// What a click on a menu-bar tile opens.
///
/// The classic popover shows ONE account; the dashboard shows every provider
/// with its active account, roster, next candidate and recent switches
/// (docs/specs/menubar-redesign.md §3). Absent in saved JSON → follows the
/// bar layout: the per-account layout keeps the classic popover it always
/// had, a fleet layout opens the dashboard (its tiles have no per-account
/// click target to land the classic view on).
enum ClickSurface: String, Codable, CaseIterable, Hashable {
    case classic
    case dashboard

    var displayName: String {
        switch self {
        case .classic: return "Account popover"
        case .dashboard: return "Fleet dashboard"
        }
    }

    /// The surface a layout implies when the user has not chosen one.
    nonisolated static func implied(by layout: MenuBarLayout) -> ClickSurface {
        layout.isFleetSummary ? .dashboard : .classic
    }
}

/// Configuration for multi-profile display mode
struct MultiProfileDisplayConfig: Codable, Equatable, Hashable {
    var iconStyle: MultiProfileIconStyle
    var showWeek: Bool        // If false, only show session
    var showProfileLabel: Bool // Show profile name below icon
    var useSystemColor: Bool  // If true, use system accent color instead of status colors
    var showTimeMarker: Bool  // If true, show time-elapsed tick mark on progress indicators
    var showPaceMarker: Bool  // If true, color time marker by projected usage pace (6-tier)
    var usePaceColoring: Bool // If true, color indicators based on projected usage pace
    var barLayout: MenuBarLayout // Per-provider tile layout (every account vs fleet summary)
    /// nil = not chosen; resolve with `effectiveClickSurface`.
    var clickSurface: ClickSurface?

    /// The chosen click surface, else the one the bar layout implies.
    var effectiveClickSurface: ClickSurface {
        clickSurface ?? ClickSurface.implied(by: barLayout)
    }

    init(
        iconStyle: MultiProfileIconStyle = .concentric,
        showWeek: Bool = true,
        showProfileLabel: Bool = true,
        useSystemColor: Bool = false,
        showTimeMarker: Bool = true,
        showPaceMarker: Bool = true,
        usePaceColoring: Bool = true,
        barLayout: MenuBarLayout = .everyAccount,
        clickSurface: ClickSurface? = nil
    ) {
        self.iconStyle = iconStyle
        self.showWeek = showWeek
        self.showProfileLabel = showProfileLabel
        self.useSystemColor = useSystemColor
        self.showTimeMarker = showTimeMarker
        self.showPaceMarker = showPaceMarker
        self.usePaceColoring = usePaceColoring
        self.barLayout = barLayout
        self.clickSurface = clickSurface
    }

    // MARK: - Codable (Custom decoder for backwards compatibility)

    enum CodingKeys: String, CodingKey {
        case iconStyle
        case showWeek
        case showProfileLabel
        case useSystemColor
        case showTimeMarker
        case showPaceMarker
        case usePaceColoring
        case barLayout
        case clickSurface
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        iconStyle = try container.decode(MultiProfileIconStyle.self, forKey: .iconStyle)
        showWeek = try container.decode(Bool.self, forKey: .showWeek)
        showProfileLabel = try container.decode(Bool.self, forKey: .showProfileLabel)
        // New properties - provide default values if missing (backwards compatibility)
        useSystemColor = try container.decodeIfPresent(Bool.self, forKey: .useSystemColor) ?? false
        showTimeMarker = try container.decodeIfPresent(Bool.self, forKey: .showTimeMarker) ?? true
        showPaceMarker = try container.decodeIfPresent(Bool.self, forKey: .showPaceMarker) ?? false
        usePaceColoring = try container.decodeIfPresent(Bool.self, forKey: .usePaceColoring) ?? false
        // Absent (pre-redesign JSON) or unrecognised (a newer build's value)
        // → the original per-account layout; never fail the whole decode.
        barLayout = (try? container.decodeIfPresent(MenuBarLayout.self, forKey: .barLayout)) ?? .everyAccount
        // Absent or unrecognised → nil, i.e. "follow the layout" — never fail
        // the whole decode.
        clickSurface = try? container.decodeIfPresent(ClickSurface.self, forKey: .clickSurface)
    }

    /// Owner decision 2026-09-04 (menu-bar redesign decision card, question
    /// 3): the default bar layout is "Active + dots", and with no explicit
    /// click surface the click opens the fleet dashboard. A config saved
    /// WITHOUT `barLayout` still decodes to `.everyAccount` (compatibility);
    /// `MenuBarManager.migratedDefaultLayout` moves an untouched legacy
    /// config over once, after which the pickers are the user's.
    static var `default`: MultiProfileDisplayConfig {
        MultiProfileDisplayConfig(barLayout: .fleetDots)
    }
}

/// Global menu bar icon configuration
struct MenuBarIconConfiguration: Codable, Equatable {
    var colorMode: MenuBarColorMode
    var singleColorHex: String
    var showIconNames: Bool
    var showRemainingPercentage: Bool
    var showTimeMarker: Bool
    var showPaceMarker: Bool
    var usePaceColoring: Bool
    var metrics: [MetricIconConfig]

    init(
        colorMode: MenuBarColorMode = .multiColor,
        singleColorHex: String = "#00BFFF",
        showIconNames: Bool = true,
        showRemainingPercentage: Bool = false,
        showTimeMarker: Bool = true,
        showPaceMarker: Bool = true,
        usePaceColoring: Bool = true,
        metrics: [MetricIconConfig] = [
            .sessionDefault,
            .weekDefault
        ]
    ) {
        self.colorMode = colorMode
        self.singleColorHex = singleColorHex
        self.showIconNames = showIconNames
        self.showRemainingPercentage = showRemainingPercentage
        self.showTimeMarker = showTimeMarker
        self.showPaceMarker = showPaceMarker
        self.usePaceColoring = usePaceColoring
        self.metrics = metrics
    }

    // MARK: - Codable (Custom decoder for backwards compatibility)

    enum CodingKeys: String, CodingKey {
        case monochromeMode  // Legacy key for backwards compatibility
        case colorMode
        case singleColorHex
        case showIconNames
        case showRemainingPercentage
        case showTimeMarker
        case showPaceMarker
        case usePaceColoring
        case metrics
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Handle backwards compatibility: if old monochromeMode exists, convert it
        if let monochromeMode = try container.decodeIfPresent(Bool.self, forKey: .monochromeMode) {
            colorMode = monochromeMode ? .monochrome : .multiColor
        } else {
            colorMode = try container.decodeIfPresent(MenuBarColorMode.self, forKey: .colorMode) ?? .multiColor
        }

        singleColorHex = try container.decodeIfPresent(String.self, forKey: .singleColorHex) ?? "#00BFFF"
        showIconNames = try container.decode(Bool.self, forKey: .showIconNames)
        showRemainingPercentage = try container.decodeIfPresent(Bool.self, forKey: .showRemainingPercentage) ?? false
        showTimeMarker = try container.decodeIfPresent(Bool.self, forKey: .showTimeMarker) ?? true
        showPaceMarker = try container.decodeIfPresent(Bool.self, forKey: .showPaceMarker) ?? false
        usePaceColoring = try container.decodeIfPresent(Bool.self, forKey: .usePaceColoring) ?? false
        metrics = try container.decode([MetricIconConfig].self, forKey: .metrics)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colorMode, forKey: .colorMode)
        try container.encode(singleColorHex, forKey: .singleColorHex)
        try container.encode(showIconNames, forKey: .showIconNames)
        try container.encode(showRemainingPercentage, forKey: .showRemainingPercentage)
        try container.encode(showTimeMarker, forKey: .showTimeMarker)
        try container.encode(showPaceMarker, forKey: .showPaceMarker)
        try container.encode(usePaceColoring, forKey: .usePaceColoring)
        try container.encode(metrics, forKey: .metrics)
        // Note: We don't encode monochromeMode anymore - it's only for reading legacy data
    }

    /// Get enabled metrics sorted by order.
    /// Excludes decode-only legacy `.api` so old saved configs never mint an API status item.
    var enabledMetrics: [MetricIconConfig] {
        metrics
            .filter { $0.isEnabled && $0.metricType != .api }
            .sorted { $0.order < $1.order }
    }

    /// Get config for specific metric type
    func config(for metricType: MenuBarMetricType) -> MetricIconConfig? {
        metrics.first { $0.metricType == metricType }
    }

    /// Update config for specific metric
    mutating func updateConfig(_ config: MetricIconConfig) {
        if let index = metrics.firstIndex(where: { $0.metricType == config.metricType }) {
            metrics[index] = config
        }
    }

    /// Default configuration (session only, like current behavior)
    static var `default`: MenuBarIconConfiguration {
        MenuBarIconConfiguration()
    }

    // MARK: - Persistence (UserDefaults)

    /// Loads complete menu bar icon configuration from UserDefaults.
    /// Migrates from legacy single-icon keys when the multi-metric config is absent.
    static func load() -> MenuBarIconConfiguration {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Constants.UserDefaultsKeys.menuBarIconConfiguration) {
            do {
                return try JSONDecoder().decode(MenuBarIconConfiguration.self, from: data)
            } catch {
                LoggingService.shared.logStorageError("loadMenuBarIconConfiguration", error: error)
            }
        }

        return migrateFromLegacySettings()
    }

    /// Migrates from legacy single-icon settings to the multi-metric system.
    private static func migrateFromLegacySettings() -> MenuBarIconConfiguration {
        var config = MenuBarIconConfiguration.default
        let defaults = UserDefaults.standard

        // Migrate monochrome mode (key: monochromeMode)
        let monochrome = defaults.bool(forKey: Constants.UserDefaultsKeys.monochromeMode)
        config.colorMode = monochrome ? .monochrome : .multiColor

        // Migrate icon style for session (key: menuBarIconStyle; was the only option before)
        let legacyStyle: MenuBarIconStyle
        if let rawValue = defaults.string(forKey: Constants.UserDefaultsKeys.menuBarIconStyle),
           let style = MenuBarIconStyle(rawValue: rawValue) {
            legacyStyle = style
        } else {
            legacyStyle = .battery
        }

        if var sessionConfig = config.config(for: .session) {
            sessionConfig.iconStyle = legacyStyle
            sessionConfig.isEnabled = true  // Session was always enabled before
            config.updateConfig(sessionConfig)
        }

        // Save migrated config under the same multi-metric key
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: Constants.UserDefaultsKeys.menuBarIconConfiguration)
        } catch {
            LoggingService.shared.logStorageError("saveMenuBarIconConfiguration", error: error)
        }

        return config
    }
}
