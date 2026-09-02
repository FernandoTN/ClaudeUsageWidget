//
//  StatusBarUIManager.swift
//  Claude Usage
//
//  Created by Claude Code on 2025-12-27.
//

import Cocoa
import Combine

/// Manages multiple menu bar status items for different metrics
final class StatusBarUIManager {
    // Dictionary to hold multiple status items keyed by metric type (single profile mode)
    private var statusItems: [MenuBarMetricType: NSStatusItem] = [:]

    // Dictionary to hold status items keyed by profile ID (multi-profile mode)
    private var multiProfileStatusItems: [UUID: NSStatusItem] = [:]

    // The creation order the multi-profile items were built with, plus the
    // target/action they were wired to — kept so the group can be rebuilt in
    // place when the weekly-reset ranking reshuffles the desired order
    // (NSStatusItems cannot be moved, only recreated).
    private var multiProfileOrder: [UUID] = []
    private weak var multiProfileTarget: AnyObject?
    private var multiProfileAction: Selector?

    // Current display mode
    private var isMultiProfileMode: Bool = false

    private var appearanceObservers: [NSKeyValueObservation] = []

    // Image cache to avoid redundant button.image assignments (which trigger KVO)
    private var lastImageData: [ObjectIdentifier: Data] = [:]

    // Per-profile render-input key: skip the NSImage render when nothing visible changed.
    // TIFF comparison in setButtonImage remains the correctness guard on assignment.
    private var lastRenderKey: [UUID: TileRenderKey] = [:]

    /// Profile ids whose status items are overflow-parked off-screen (duplicate
    /// x-positions). Recomputed each layout evaluation; skipped in the paint loop
    /// except for first paint (button.image == nil).
    /// A tile that leaves the parked set may be showing an image baked while it
    /// was hidden (possibly under a provisional appearance) — drop its render key
    /// so the next paint re-renders it unconditionally.
    private var overflowParkedIds: Set<UUID> = [] {
        didSet {
            for id in oldValue.subtracting(overflowParkedIds) {
                lastRenderKey.removeValue(forKey: id)
            }
        }
    }

    // Icon renderer for creating menu bar images
    private let renderer = MenuBarIconRenderer()

    // MARK: Composite provider-group tiles (default mode)

    /// Composite mode (default): ONE NSStatusItem per provider group, hosting
    /// all of that provider's tiles side-by-side in a single fixed-length
    /// image. Motivation (2026-07-29 storm investigation): every scene-hosted
    /// status window is re-evaluated per display frame while the OS-side
    /// per-bundle wedge is active — prevention and in-place remediation are
    /// both proven impossible on macOS 26/27, so the only structural lever is
    /// window count: 14 tiles = 42 scene windows ≈ 9-11% CPU wedged; 3 group
    /// items = 9 scenes ≈ ~2%. Ranking reshuffles become pure paint order,
    /// and membership changes only resize the composite — status items are
    /// created/destroyed ONLY when a provider group appears/disappears.
    /// `CUW_SEPARATE_TILES=1` restores the legacy one-item-per-profile mode.
    static let useCompositeTiles: Bool =
        ProcessInfo.processInfo.environment["CUW_SEPARATE_TILES"] != "1"

    /// One status item per provider group (composite mode).
    private var groupItems: [Profile.ProviderKind: NSStatusItem] = [:]

    /// Latest rendered per-tile image (composite mode) — the per-tile render
    /// pipeline (render keys, TIFF guard) is unchanged; composites are
    /// re-assembled from these.
    private var tileImages: [UUID: NSImage] = [:]

    /// Size of each group's composite image — needed to map a click in BUTTON
    /// space onto the segments, which are in IMAGE space.
    private var groupCompositeSize: [Profile.ProviderKind: NSSize] = [:]

    /// Per-group horizontal segment layout, in the composite IMAGE's coordinate
    /// space: which x-range belongs to which profile. Ordered LEFT-TO-RIGHT on
    /// screen. Drives click routing and popover anchoring.
    private var groupSegments: [Profile.ProviderKind: [TileSegment]] = [:]

    /// A profile's horizontal slice of a composite group button, in the
    /// button's coordinate space. Ranges are contiguous and cover the whole
    /// button, so every click inside a group resolves to exactly one tile.
    struct TileSegment: Equatable {
        var profileId: UUID
        var range: Range<CGFloat>
    }

    /// Monotonic render sequence per tile: bumped whenever a tile's image is
    /// re-rendered. `assembleComposites` keys its memo on these, so the
    /// steady-state sweep (nothing changed) does no drawing at all.
    private var tileImageSeq: [UUID: Int] = [:]
    private var nextTileSeq = 0

    /// Inputs a group's composite image is a pure function of — equal ⇒ the
    /// existing composite is already correct and re-assembly is skipped.
    private struct CompositeKey: Equatable {
        var members: [UUID]
        var seqs: [Int]
        var isTemplate: Bool
        /// Destination backing scale × 100 — a display change must re-rasterize.
        var scaleQ: Int
    }
    private var lastCompositeKey: [Profile.ProviderKind: CompositeKey] = [:]

    /// Horizontal gap between tiles inside a composite — near-touching by
    /// owner preference (2026-07-29): the tiles read as one tight group.
    static let compositeTileSpacing: CGFloat = 3
    /// Padding at each composite edge (the system adds its own margins too).
    static let compositeEdgePadding: CGFloat = 1

    /// Light red for weekly-maxed tile titles — softer than systemRed so it
    /// reads well on the dark bar (and distinct from the red critical bar fill).
    static let weeklyMaxedLabelColor = NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)

    /// Label tint for a SUSPECTED rate-limited account (inferred, unverified).
    /// Purple is deliberately outside the usage-status palette (green/orange/
    /// red = capacity, cyan = active, light-red = weekly-maxed): it marks DATA
    /// QUALITY, not usage level — the percentage shown is the last measured
    /// value, possibly stale, because the endpoint keeps refusing reads.
    static let suspectedLabelColor = NSColor.systemPurple

    /// One precedence order for the tile label tint. Weekly-maxed outranks
    /// suspected (a hard, week-long fact beats a transient suspicion);
    /// suspected outranks the active-account cyan (data quality is the rarer,
    /// more actionable signal).
    private func tileLabelColor(isWeeklyMaxed: Bool, isSuspected: Bool, isActiveAccount: Bool) -> NSColor? {
        if isWeeklyMaxed { return Self.weeklyMaxedLabelColor }
        if isSuspected { return Self.suspectedLabelColor }
        return isActiveAccount ? NSColor.systemCyan : nil
    }

    /// Multi-profile progress-bar width used by the renderer for marker ticks
    /// (`round(barWidth * fraction)`). Shared so the render-key quantizes identically.
    private static let multiProfileBarWidth: CGFloat = 24

    weak var delegate: StatusBarUIManagerDelegate?

    /// Inputs the multi-profile render path consumes — hash-equal ⇒ skip re-render.
    private struct TileRenderKey: Hashable {
        /// Display percentages after `getDisplayPercentage`, quantized to 0.1
        var sessionDisplayQ: Int
        var weekDisplayQ: Int
        var sessionStatus: UsageStatusLevel
        var weekStatus: UsageStatusLevel
        var sessionPace: PaceStatus?
        var weekPace: PaceStatus?
        /// Marker tick quantized to the style's pixel/degree step (nil when marker off)
        var sessionMarkerTick: Int?
        var weekMarkerTick: Int?
        /// 3-char (or 1-char) label actually passed to the renderer
        var label: String
        var config: MultiProfileDisplayConfig
        /// Full appearance NAME, not a dark bool: freshly created buttons pass
        /// through provisional appearance variants that can resolve dynamic
        /// system colors differently while agreeing on "is dark" — the name
        /// transition is what guarantees a re-render once AppKit settles.
        var appearanceName: String
        /// Active accounts render a highlighted label — a switch must repaint them
        var isActiveAccount: Bool
        /// Suspected-rate-limited tint (purple label) — a suspicion transition
        /// must repaint even when the displayed numbers are unchanged, or the
        /// skip-not-replace path leaves the previous tint on screen.
        var isSuspected: Bool
        /// Weekly-maxed accounts render a light-red label
        var isWeeklyMaxed: Bool
        /// Backing scale × 100 when reachable, else 0
        var backingScaleQ: Int
    }

    /// Quantize a time-marker fraction to the same discrete step the active
    /// style's renderer uses. Progress bars: `round(barWidth * fraction)`.
    /// Concentric rings: whole degrees (`round(360 * fraction)`) matching the
    /// angle formula. False-misses are acceptable; false-hits are not.
    private static func quantizeMarkerTick(
        _ fraction: CGFloat?,
        style: MultiProfileIconStyle
    ) -> Int? {
        guard let fraction else { return nil }
        switch style {
        case .progressBar:
            return Int(round(multiProfileBarWidth * fraction))
        case .concentric:
            return Int(round(360 * fraction))
        case .compact, .percentage:
            // Markers are not drawn; keep a stable integer if present.
            return Int(round(multiProfileBarWidth * fraction))
        }
    }

    // MARK: - Initialization

    init() {}

    // MARK: - Setup

    /// Sets up status bar items based on configuration
    func setup(target: AnyObject, action: Selector, config: MenuBarIconConfiguration) {
        // Remove all existing items first
        cleanup()

        // Check if there are any enabled metrics
        if config.enabledMetrics.isEmpty {
            // No credentials/metrics - show default app logo
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

            if let button = statusItem.button {
                button.action = action
                button.target = target
                // Set a temporary placeholder - will be updated with actual logo
                button.title = ""
            } else {
                LoggingService.shared.logWarning("Status bar button is nil - screens: \(NSScreen.screens.count)")
            }

            // Use a special key to identify the default icon
            statusItems[.session] = statusItem  // Use session as placeholder key
            LoggingService.shared.logUIEvent("Status bar initialized with default app logo (no credentials)")
        } else {
            // Create status items for enabled metrics
            for metricConfig in config.enabledMetrics {
                let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

                if let button = statusItem.button {
                    button.action = action
                    button.target = target
                } else {
                    LoggingService.shared.logWarning("Status bar button is nil for \(metricConfig.metricType.displayName) - screens: \(NSScreen.screens.count)")
                }

                statusItems[metricConfig.metricType] = statusItem
            }

            LoggingService.shared.logUIEvent("Status bar initialized with \(config.enabledMetrics.count) metrics")
        }

        observeAppearanceChanges()
    }

    /// Updates status bar items based on new configuration (incremental approach)
    func updateConfiguration(target: AnyObject, action: Selector, config: MenuBarIconConfiguration) {
        // Determine what the new set of items should be
        let newMetricTypes: Set<MenuBarMetricType>
        if config.enabledMetrics.isEmpty {
            // No credentials/metrics - show default app logo using .session as placeholder
            newMetricTypes = [.session]
        } else {
            newMetricTypes = Set(config.enabledMetrics.map { $0.metricType })
        }

        let currentMetricTypes = Set(statusItems.keys)

        // Step 1: Remove items that are no longer needed
        let itemsToRemove = currentMetricTypes.subtracting(newMetricTypes)
        for metricType in itemsToRemove {
            if let statusItem = statusItems[metricType] {
                if let button = statusItem.button {
                    // Drop the dedup entry keyed by this button's identity: a
                    // later NSButton allocation can reuse the address, and a
                    // stale entry would make setButtonImage skip the first
                    // paint of a re-added metric (blank icon).
                    lastImageData.removeValue(forKey: ObjectIdentifier(button))
                    button.image = nil
                    button.action = nil
                    button.target = nil
                }
                NSStatusBar.system.removeStatusItem(statusItem)
                LoggingService.shared.logUIEvent("Removed status item for \(metricType.displayName)")
            }
            statusItems.removeValue(forKey: metricType)
        }

        // Step 2: Add items that are new
        let itemsToAdd = newMetricTypes.subtracting(currentMetricTypes)
        for metricType in itemsToAdd {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

            if let button = statusItem.button {
                button.action = action
                button.target = target
                if metricType == .session {
                    // Default logo placeholder
                    button.title = ""
                }
            }

            statusItems[metricType] = statusItem
            LoggingService.shared.logUIEvent("Created status item for \(metricType.displayName)")
        }

        // Step 3: Items that already exist don't need recreation, just keep them
        // Their images will be updated by updateAllButtons() or updateButton()

        LoggingService.shared.logUIEvent("Status bar configuration updated: removed=\(itemsToRemove.count), added=\(itemsToAdd.count), kept=\(currentMetricTypes.intersection(newMetricTypes).count)")
    }

    func cleanup() {
        appearanceObservers.forEach { $0.invalidate() }
        appearanceObservers.removeAll()

        // Clean up single profile status items
        for (_, statusItem) in statusItems {
            // Clear button references first
            if let button = statusItem.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            // Then remove from status bar
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItems.removeAll()

        // Clean up multi-profile status items
        for (_, statusItem) in multiProfileStatusItems {
            if let button = statusItem.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        multiProfileStatusItems.removeAll()
        multiProfileOrder.removeAll()

        // Composite-mode state
        for (_, statusItem) in groupItems {
            if let button = statusItem.button {
                button.image = nil
                button.action = nil
                button.target = nil
            }
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        groupItems.removeAll()
        groupSegments.removeAll()
        groupCompositeSize.removeAll()
        tileImages.removeAll()
        tileImageSeq.removeAll()
        lastCompositeKey.removeAll()

        // Deallocated buttons can leave ObjectIdentifier keys that a NEW button
        // may reuse (same address) — a stale cache hit would skip drawing its
        // icon after a rebuild, so drop the cache with the items.
        lastImageData.removeAll()
        lastRenderKey.removeAll()
        overflowParkedIds.removeAll()

        isMultiProfileMode = false

        LoggingService.shared.logUIEvent("Status bar cleaned up")
    }

    /// Clears overflow-parked state so the next paint re-evaluates parking and
    /// re-renders any tile that became visible after a screen geometry change.
    func clearOverflowParkedState() {
        overflowParkedIds.removeAll()
        lastRenderKey.removeAll()
    }

    /// Storm-remediation stage 1: cycle every multi-profile item's visibility
    /// off and back on across one runloop turn. A fullscreen menu-bar-reveal
    /// fence burst can leave tile scenes in a per-frame event-shape-recompute
    /// state (2026-07-29 investigation); re-establishing the scene layer is
    /// the cheapest candidate reset short of relaunching. Render caches are
    /// dropped so the re-shown tiles repaint fresh.
    func cycleTileVisibility() {
        let items = Array(multiProfileStatusItems.values) + Array(groupItems.values)
        guard !items.isEmpty else { return }
        LoggingService.shared.logWarning("StatusBar: cycling visibility of \(items.count) tiles (storm remediation)")
        for item in items { item.isVisible = false }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Re-read the LIVE collections instead of re-showing the array
            // captured a runloop turn ago. A rebuild can land in between
            // (setupMultiProfile(forceRecreate:) → cleanup() → removeStatusItem),
            // and re-showing an item that has already been removed from the
            // status bar strands an orphaned ghost tile beside the new set —
            // reachable from StormWatchdog's manual remediate trigger. Items no
            // longer owned here are simply skipped; freshly created ones are
            // already visible, so re-asserting it is a no-op.
            let liveItems = Array(self.multiProfileStatusItems.values) + Array(self.groupItems.values)
            for item in liveItems { item.isVisible = true }
            self.lastRenderKey.removeAll()
            self.lastImageData.removeAll()
            self.overflowParkedIds.removeAll()
            // Composites must be re-assembled and re-assigned too: the tiles
            // will re-render, but the memo would otherwise let a re-shown group
            // keep whatever image survived the visibility cycle.
            self.lastCompositeKey.removeAll()
        }
    }

    // MARK: - Multi-Profile Mode

    /// Creation order for the multi-profile status items. Each new item is
    /// inserted to the LEFT of the app's existing items, so creation order maps
    /// right-to-left on screen, and macOS clips the LEFTMOST items first when
    /// the bar overflows. Desired layout right-to-left: the Claude group
    /// (usually the largest), then Grok, then Codex at the overflow edge —
    /// Grok sits immediately left of Claude so a freshly-added Grok account
    /// stays visible on a full bar, and Codex (rather than Grok) is what clips
    /// when there is no room. Within each group the account whose weekly limit
    /// resets SOONEST sits rightmost — the same "use it or lose it" ranking the
    /// auto-switch uses, so the rightmost account of a group is always the one
    /// to burn first. Name breaks ties so equal resets (e.g. two profiles with
    /// no cached usage) don't reshuffle. Static and `now`-injectable so the
    /// ordering/quantization rules are unit-testable.
    static func multiProfileCreationOrder(for profiles: [Profile], now: Date = Date()) -> [Profile] {
        // The usage API reports the SAME weekly boundary with ±1s jitter between
        // fetches (22:59:59.8 one sweep, 23:00:00.1 the next), and two accounts can
        // share a boundary. Quantize the ranking key to the minute so jitter can't
        // flip the order — every flip tears down and rebuilds the whole status-item
        // group, which the user sees as the menu bar going dark.
        func rank(_ profile: Profile) -> Date {
            let reset = profile.nextWeeklyReset(after: now)
            guard reset != .distantFuture else { return reset }
            return Date(timeIntervalSinceReferenceDate: (reset.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        }
        func ranked(_ group: [Profile]) -> [Profile] {
            group.sorted {
                let a = rank($0)
                let b = rank($1)
                return a != b ? a < b : $0.name < $1.name
            }
        }
        let selected = profiles.filter { $0.isSelectedForDisplay }
        return ranked(selected.filter { $0.providerKind == .claude })
            + ranked(selected.filter { $0.providerKind == .grok })
            + ranked(selected.filter { $0.providerKind == .codex })
    }

    /// Paint order for one provider group's composite image.
    ///
    /// `multiProfileCreationOrder` ranks the SOONEST weekly reset FIRST because
    /// legacy per-profile status items are created right-to-left — first
    /// created lands RIGHTMOST on screen. A composite image is drawn with x
    /// INCREASING, so the same array painted in order would put the
    /// soonest-reset account at the LEFT edge: the owner's "the rightmost
    /// account is the one to burn first" layout, silently inverted. Reversing
    /// here is the single place that difference is reconciled; pure and
    /// generic so the orientation is unit-testable (the inversion shipped
    /// undetected because the ordering tests only assert the rank array —
    /// Codex + Grok verification, 2026-07-29).
    nonisolated static func compositePaintOrder<T>(_ rankOrder: [T]) -> [T] {
        rankOrder.reversed()
    }

    /// One provider group's tiles in LEFT-TO-RIGHT on-screen order. Shared by
    /// the composite painter and the popover's group navigator, so "the tile to
    /// the right" means the same thing in the menu bar and in the popover.
    static func onScreenGroupMembers(
        for profiles: [Profile],
        provider: Profile.ProviderKind,
        now: Date = Date()
    ) -> [Profile] {
        compositePaintOrder(
            multiProfileCreationOrder(for: profiles, now: now)
                .filter { $0.providerKind == provider }
        )
    }

    /// One provider group's tiles in LEFT-TO-RIGHT on-screen order, preferring
    /// what the bar ACTUALLY painted over a freshly recomputed ranking.
    ///
    /// The ranking key is the weekly reset time, so it flips the moment a
    /// boundary passes — but the tiles keep the order they were painted in
    /// until the next rebuild. A surface that recomputes independently (the
    /// popover's navigator did) therefore starts numbering chips differently
    /// from the tiles beside them: chip N stops meaning tile N and the ‹ ›
    /// walk follows an order the bar does not show (audit M10). Passing the
    /// painted ids in makes the bar the single source of truth; the static
    /// ranking stays as the fallback for "nothing painted yet".
    ///
    /// Ids no longer backed by a profile are dropped, so a deleted account
    /// cannot survive in the navigator.
    static func onScreenGroupMembers(
        for profiles: [Profile],
        provider: Profile.ProviderKind,
        paintedOrder: [UUID],
        now: Date = Date()
    ) -> [Profile] {
        let painted = paintedOrder
            .compactMap { id in profiles.first(where: { $0.id == id }) }
            .filter { $0.providerKind == provider }
        if !painted.isEmpty { return painted }
        return onScreenGroupMembers(for: profiles, provider: provider, now: now)
    }

    /// Pure composite geometry from the member tile widths in LEFT-TO-RIGHT
    /// paint order: the canvas width, each tile's x origin, and the click
    /// segments. Each tile owns half of the gap on either side of it, and the
    /// first/last segments extend to the canvas edges, so the ranges are
    /// contiguous and cover `0..<totalWidth` — every x inside the group button
    /// resolves to exactly one tile, with no dead gaps.
    static func compositeLayout(
        tileWidths: [CGFloat],
        spacing: CGFloat = compositeTileSpacing,
        edgePadding: CGFloat = compositeEdgePadding
    ) -> (totalWidth: CGFloat, origins: [CGFloat], ranges: [Range<CGFloat>]) {
        guard !tileWidths.isEmpty else { return (0, [], []) }
        let totalWidth = tileWidths.reduce(0) { $0 + $1.rounded() }
            + spacing * CGFloat(tileWidths.count - 1)
            + edgePadding * 2
        var origins: [CGFloat] = []
        var ranges: [Range<CGFloat>] = []
        var x = edgePadding
        for (i, rawWidth) in tileWidths.enumerated() {
            // Whole-point advances: a fractional tile width (the `.percentage`
            // style sizes to text metrics) would otherwise land every later
            // tile on a half-pixel and blur it.
            let width = rawWidth.rounded()
            origins.append(x)
            let start = i == 0 ? 0 : x - spacing / 2
            let end = i == tileWidths.count - 1 ? totalWidth : x + width + spacing / 2
            ranges.append(start..<end)
            x += width + spacing
        }
        return (totalWidth, origins, ranges)
    }

    /// True when the live composite group items already match the providers
    /// `profiles` needs, so a "structural" setup call is really just a repaint.
    /// Selecting or deselecting an account is a MEMBERSHIP change, which a
    /// composite absorbs by re-drawing one image — but the notification that
    /// carries it routes through `setupMultiProfile`, which would otherwise
    /// tear down and recreate every group item. Each teardown+recreate
    /// permanently leaks registered CAContexts on macOS 26/27, so reuse is the
    /// whole point of the composite design.
    private func canReuseCompositeGroups(for profiles: [Profile]) -> Bool {
        guard Self.useCompositeTiles, isMultiProfileMode, !groupItems.isEmpty else { return false }
        // Every live item must still have a button (a lost button needs a rebuild).
        guard groupItems.values.allSatisfy({ $0.button != nil }) else { return false }
        let selected = profiles.filter { $0.isSelectedForDisplay }
        guard !selected.isEmpty else { return false }
        // The placeholder item is keyed under .claude but hosts no tiles.
        guard !multiProfileOrder.isEmpty else { return false }
        return Set(selected.map(\.providerKind)) == Set(groupItems.keys)
    }

    /// Sets up status bar for multi-profile display mode.
    /// `forceRecreate` skips the composite reuse path — the lab's rebuild probe
    /// exists to MEASURE a teardown+recreate, so it must still get one.
    func setupMultiProfile(
        profiles: [Profile],
        target: AnyObject,
        action: Selector,
        forceRecreate: Bool = false
    ) {
        if !forceRecreate, canReuseCompositeGroups(for: profiles) {
            multiProfileTarget = target
            multiProfileAction = action
            multiProfileOrder = Self.multiProfileCreationOrder(for: profiles).map(\.id)
            LoggingService.shared.logUIEvent(
                "Multi-profile: composite membership change — reused \(groupItems.count) group items (no window changes)")
            return
        }

        // Clean up existing items
        cleanup()

        isMultiProfileMode = true
        multiProfileTarget = target
        multiProfileAction = action

        if Self.useCompositeTiles {
            setupCompositeGroups(profiles: profiles, target: target, action: action)
            observeAppearanceChanges()
            return
        }

        // Filter to only profiles selected for display
        let selectedProfiles = profiles.filter { $0.isSelectedForDisplay }

        if selectedProfiles.isEmpty {
            // No profiles selected - show default logo
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = statusItem.button {
                button.action = action
                button.target = target
                button.title = ""
            } else {
                LoggingService.shared.logWarning("Multi-profile status bar button is nil - screens: \(NSScreen.screens.count)")
            }
            // Use a placeholder UUID for default logo
            multiProfileStatusItems[UUID()] = statusItem
            LoggingService.shared.logUIEvent("Multi-profile: No profiles selected, showing default logo")
        } else {
            let orderedProfiles = Self.multiProfileCreationOrder(for: profiles)
            multiProfileOrder = orderedProfiles.map(\.id)

            // Create one status item per selected profile. Deliberately NO
            // autosaveName: naming the items makes the window server remember
            // per-name positions in a private store the app cannot reliably
            // clear or overwrite — a pinning experiment (2026-07-17) left the
            // group SPLIT across remembered positions with no code-side way
            // back. Anonymous items always place by fresh creation order.
            for profile in orderedProfiles {
                let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

                if let button = statusItem.button {
                    button.action = action
                    button.target = target
                } else {
                    LoggingService.shared.logWarning("Multi-profile status bar button is nil for \(profile.name) - screens: \(NSScreen.screens.count)")
                }

                multiProfileStatusItems[profile.id] = statusItem
            }

            LoggingService.shared.logUIEvent("Multi-profile: Created \(selectedProfiles.count) status items")
        }

        observeAppearanceChanges()
    }

    /// Composite mode: create ONE status item per provider that has selected
    /// profiles. Creation order Claude → Grok → Codex (each new item lands
    /// LEFT of existing ones, so Claude ends up rightmost and Codex clips
    /// first on overflow — same policy as the legacy per-tile layout).
    private func setupCompositeGroups(profiles: [Profile], target: AnyObject, action: Selector) {
        let selectedProfiles = profiles.filter { $0.isSelectedForDisplay }

        guard !selectedProfiles.isEmpty else {
            // No profiles selected: one placeholder item keyed under .claude,
            // painted by `paintPlaceholderLogo` (NOT by updateAllButtons, whose
            // logo path only covers single-profile `statusItems`).
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = statusItem.button {
                button.action = action
                button.target = target
                button.title = ""
                button.imageScaling = .scaleProportionallyDown
            }
            groupItems[.claude] = statusItem
            LoggingService.shared.logUIEvent("Multi-profile: No profiles selected, showing default logo (composite)")
            return
        }

        let orderedProfiles = Self.multiProfileCreationOrder(for: profiles)
        multiProfileOrder = orderedProfiles.map(\.id)

        for provider in [Profile.ProviderKind.claude, .grok, .codex]
        where selectedProfiles.contains(where: { $0.providerKind == provider }) {
            let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = statusItem.button {
                button.action = action
                button.target = target
                // Pin the scaling mode the click-x mapping assumes
                // (`compositeDrawnRect`) instead of inheriting a default.
                button.imageScaling = .scaleProportionallyDown
            } else {
                LoggingService.shared.logWarning("Composite group button is nil for \(provider) - screens: \(NSScreen.screens.count)")
            }
            groupItems[provider] = statusItem
        }

        LoggingService.shared.logUIEvent(
            "Multi-profile: composite mode — \(groupItems.count) group items for \(selectedProfiles.count) profiles")
    }

    /// True when on-screen x-positions no longer strictly DESCEND in creation
    /// order (creation order maps right-to-left, so each later-created item
    /// must sit further left), OR when the group is SPLIT — adjacent tiles
    /// separated by more than `maxAdjacentGap` points (a rejected pin drops a
    /// tile into the system default slot with other apps' icons in between;
    /// legitimate tiles pack at ~27pt). A real report: one Codex tile stranded
    /// at the far right of the whole menu bar, past other apps' icons, instead
    /// of at the group's left edge. Pure so it is unit-testable.
    nonisolated static func layoutDivergesFromCreationOrder(
        _ xPositions: [CGFloat],
        maxAdjacentGap: CGFloat = 90
    ) -> Bool {
        guard xPositions.count > 1 else { return false }
        for i in 1..<xPositions.count {
            if xPositions[i] >= xPositions[i - 1] { return true }
            if xPositions[i - 1] - xPositions[i] > maxAdjacentGap { return true }
        }
        return false
    }

    /// True when two or more tiles report the SAME x-position. Visible status
    /// items each own a distinct ~27pt frame, so identical minX values can only
    /// mean macOS has hidden those tiles — an overflowing bar parks every
    /// clipped item at one shared off-edge frame (a real bar showed four of
    /// twelve tiles all at x=1701). Overflow is not a broken layout: a rebuild
    /// cannot make the tiles fit, so the heal must not fire on it.
    nonisolated static func containsOverflowParkedTiles(_ xPositions: [CGFloat]) -> Bool {
        Set(xPositions.map { Int($0) }).count != xPositions.count
    }

    /// Rebuild-on-heal is rate-limited: if a rebuild cannot fix the layout
    /// (e.g. the bar is genuinely overflowing), retrying every sweep would
    /// flicker the whole group twice a minute.
    private var lastLayoutHealAt: Date = .distantPast

    /// Hard lifetime cap on heal rebuilds: every teardown+recreate of the
    /// group permanently leaks ~42 registered CAContexts on macOS 26/27
    /// (2026-07-29 storm investigation), so self-repair gets two shots per
    /// process and then only logs. A genuinely stranded tile after that is a
    /// cosmetic defect; an unbounded rebuild loop is a CPU incident.
    private var healRebuildsThisLaunch = 0
    private static let maxHealRebuildsPerLaunch = 2

    /// Signature of a broken layout a heal-rebuild already failed to fix — the
    /// system reproduces some placements deterministically, so retrying the
    /// same layout forever only flickers the bar. A DIFFERENT broken layout
    /// (display change, new profile count) gets a fresh attempt.
    private var healFailedSignature: String?
    private var lastEvaluatedSignature: String?

    /// Last `debugTileLayout` payload written without its timestamp — suppress
    /// identical rewrites every sweep.
    private var lastDebugTileLayoutValue: String?

    private static let debugTileLayoutDateFormatter = ISO8601DateFormatter()

    /// True when every item's window is measurable on ONE shared screen and
    /// the x-order contradicts the creation order. Bails out (false) whenever
    /// any window is missing, off-screen, or on another display — a hidden
    /// tile can't be judged, only a visibly misplaced one. Each evaluation
    /// records a layout snapshot in UserDefaults (`debugTileLayout`) so a
    /// stranded tile can be diagnosed from outside a Release build.
    /// Also recomputes `overflowParkedIds` (tiles parked at a duplicated
    /// off-edge x) every evaluation so the paint loop can skip them.
    private func strandedTileDetected() -> Bool {
        RenderInstrumentation.strandedTileEvaluations += 1
        guard multiProfileOrder.count > 1 else {
            overflowParkedIds = []
            return false
        }
        var xPositions: [CGFloat] = []
        var measuredIds: [UUID] = []
        var screens = Set<ObjectIdentifier>()
        var snapshot: [String] = []
        var unmeasurable = false
        for profileId in multiProfileOrder {
            let window = multiProfileStatusItems[profileId]?.button?.window
            let x = window.map { Int($0.frame.minX) } ?? -1
            let screenId = window?.screen.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue) % 1000) } ?? "nil"
            snapshot.append("\(String(profileId.uuidString.prefix(4))):x=\(x),s=\(screenId)")
            guard let window, let screen = window.screen, window.frame.minX > 0 else {
                unmeasurable = true
                continue
            }
            screens.insert(ObjectIdentifier(screen))
            xPositions.append(window.frame.minX)
            measuredIds.append(profileId)
        }
        // Quantized to 10pt buckets: tile widths change with every usage
        // repaint, drifting positions a few points between evaluations. The
        // failed-heal latch compares signatures, so pixel drift must not mint
        // a "new" broken layout every rate-limit window (that was an infinite
        // rebuild loop — the whole group flickered every ~5 minutes for days).
        let signature = xPositions.map { Int(($0 / 10).rounded() * 10) }.description
        lastEvaluatedSignature = signature
        var verdict: String
        let broken: Bool
        if unmeasurable {
            verdict = "unmeasurable"
            broken = false
            overflowParkedIds = []
        } else if screens.count != 1 {
            verdict = "multi-screen(\(screens.count))"
            broken = false
            overflowParkedIds = []
        } else if Self.containsOverflowParkedTiles(xPositions) {
            // Hidden tiles can't be judged, and their duplicate frames would
            // read as an order violation below. Surface the parked id set so
            // the paint loop can skip re-rendering overflow-hidden tiles.
            verdict = "overflow-hidden"
            broken = false
            overflowParkedIds = Self.overflowParkedProfileIds(
                order: measuredIds,
                xPositions: xPositions
            )
        } else {
            broken = Self.layoutDivergesFromCreationOrder(xPositions)
            verdict = broken ? "STRANDED" : "ok"
            overflowParkedIds = []
        }
        if broken, signature == healFailedSignature {
            verdict = "STRANDED-unfixable"
        }
        // Write only when the verdict (minus timestamp) actually changed.
        let layoutValue = "\(verdict) | \(snapshot.joined(separator: " "))"
        if layoutValue != lastDebugTileLayoutValue {
            lastDebugTileLayoutValue = layoutValue
            let stamp = Self.debugTileLayoutDateFormatter.string(from: Date())
            UserDefaults.standard.set("\(stamp) \(layoutValue)", forKey: "debugTileLayout")
        }
        guard broken, signature != healFailedSignature,
              Date().timeIntervalSince(lastLayoutHealAt) > 300 else { return false }
        return true
    }

    /// Reassign which profile owns which existing status item so the on-screen
    /// slot sequence matches `desiredOrder` without tearing anything down.
    /// Slot k (k-th created item) simply takes the k-th profile of the new
    /// order; images repaint on the next paint pass because every render key
    /// is dropped. Returns false (caller falls back to a full rebuild) if any
    /// expected item is missing.
    ///
    /// Overflow-parked slots keep their stale image while hidden (macOS parks
    /// them off-edge, nothing is visible); `overflowParkedIds` is cleared by
    /// the caller and re-derived against the new mapping on the next
    /// evaluation, and un-parking already forces a fresh render via the
    /// `overflowParkedIds.didSet` key drop.
    private func remapProfilesToExistingItems(desiredOrder: [UUID]) -> Bool {
        let slotItems = multiProfileOrder.compactMap { multiProfileStatusItems[$0] }
        guard slotItems.count == multiProfileOrder.count,
              slotItems.count == desiredOrder.count else { return false }
        multiProfileStatusItems = Dictionary(uniqueKeysWithValues: zip(desiredOrder, slotItems))
        multiProfileOrder = desiredOrder
        // Profile→button pairing changed everywhere: repaint every tile.
        lastRenderKey.removeAll()
        return true
    }

    /// Profile ids whose window x is a duplicated off-edge parking slot
    /// (overflow-hidden). Visible tiles each own a distinct minX; overflowed
    /// tiles share one frame. Pure so it is unit-testable.
    nonisolated static func overflowParkedProfileIds(
        order: [UUID],
        xPositions: [CGFloat]
    ) -> Set<UUID> {
        guard order.count == xPositions.count, !order.isEmpty else { return [] }
        var counts: [Int: Int] = [:]
        let intXs = xPositions.map { Int($0) }
        for x in intXs {
            counts[x, default: 0] += 1
        }
        var parked = Set<UUID>()
        for (i, id) in order.enumerated() {
            if counts[intXs[i], default: 0] > 1 {
                parked.insert(id)
            }
        }
        return parked
    }

    /// Updates all multi-profile status items
    func updateMultiProfileButtons(profiles: [Profile], config: MultiProfileDisplayConfig) {
        RenderInstrumentation.updateMultiProfileButtonsCalls += 1
        guard isMultiProfileMode else { return }

        // Fresh usage may have reshuffled the weekly-reset ranking (or changed the
        // selected set). Status items cannot be reordered in place — but they
        // don't need to be: every pixel of a tile's identity (label, colors,
        // bars) is painted into its image, so a pure ORDER change is satisfied
        // by remapping which profile paints into which existing item. Only a
        // changed SELECTION SET (different profiles) still requires recreating
        // items. This distinction is load-bearing on macOS 26/27: each item is
        // hosted as FrontBoard scenes whose teardown+recreate permanently leaks
        // ~1 registered CAContext per tile (measured 2026-07-29: +14–21 contexts
        // per rebuild, never reclaimed) — and the WindowServer iterates every
        // registered context on each remote-context datagram, so rebuild-per-
        // reshuffle turned ranking jitter into an unbounded main-thread tax.
        let desiredOrder = Self.multiProfileCreationOrder(for: profiles).map(\.id)

        if Self.useCompositeTiles {
            // Composite mode: items exist per provider GROUP, so ranking and
            // membership changes are pure repaint/re-composite. Only a change
            // in WHICH PROVIDERS have selected profiles (or the empty↔non-empty
            // transition) needs item recreation — a rare user action.
            let selected = profiles.filter { $0.isSelectedForDisplay }
            let desiredProviders = Set(selected.map(\.providerKind))
            let currentProviders = Set(groupItems.keys)
            let placeholderActive = groupItems.count == 1 && multiProfileOrder.isEmpty
            let needsRebuild = selected.isEmpty
                ? !placeholderActive
                : (desiredProviders != currentProviders || placeholderActive)
            if needsRebuild, let target = multiProfileTarget, let action = multiProfileAction {
                LoggingService.shared.logUIEvent("Multi-profile: provider set changed, rebuilding composite groups")
                // A provider group appearing/disappearing changes the ITEM SET,
                // and item creation order is the only handle on left-to-right
                // group placement (Claude rightmost, Codex clipping first), so
                // the whole set is recreated in the canonical order rather than
                // patched incrementally — a re-added Grok item created last
                // would land at the wrong end of the bar.
                setupMultiProfile(profiles: profiles, target: target, action: action, forceRecreate: true)
                DispatchQueue.main.async { [weak self] in
                    self?.lastRenderKey.removeAll()
                    self?.updateMultiProfileButtons(profiles: profiles, config: config)
                }
            } else if desiredOrder != multiProfileOrder {
                multiProfileOrder = desiredOrder
                LoggingService.shared.logUIEvent(
                    "Multi-profile: ranking reshuffled — composite paint order updated (no window changes)")
            }
            if selected.isEmpty {
                // Placeholder state: there are no tiles to paint, and nothing
                // else ever paints this item.
                pruneTileState(keeping: [])
                assembleComposites(profiles: profiles)
                paintPlaceholderLogo()
                return
            }
            paintTiles(profiles: profiles, config: config)
            pruneTileState(keeping: Set(selected.map(\.id)))
            assembleComposites(profiles: profiles)
            return
        }

        var rebuildReason: String?
        if desiredOrder != multiProfileOrder {
            if Set(desiredOrder) == Set(multiProfileOrder),
               remapProfilesToExistingItems(desiredOrder: desiredOrder) {
                LoggingService.shared.logUIEvent(
                    "Multi-profile: ranking reshuffled — remapped \(desiredOrder.count) tiles in place (no rebuild)")
            } else {
                rebuildReason = "selected profile set changed"
            }
            // Order change skips strandedTileDetected — clear parked set so a
            // later evaluation re-derives it rather than skipping newly visible tiles.
            overflowParkedIds = []
        } else if strandedTileDetected() {
            // strandedTileDetected always refreshes overflowParkedIds on this path.
            if healRebuildsThisLaunch < Self.maxHealRebuildsPerLaunch {
                healRebuildsThisLaunch += 1
                rebuildReason = "a tile was relocated out of the group by the system"
                lastLayoutHealAt = Date()
                // One attempt per distinct broken layout: if the rebuild reproduces
                // this same arrangement, stop retrying until something changes.
                healFailedSignature = lastEvaluatedSignature
            } else {
                LoggingService.shared.logWarning(
                    "Multi-profile: stranded layout detected but heal-rebuild cap (\(Self.maxHealRebuildsPerLaunch)) reached — leaving layout as-is")
            }
        }
        // When order is stable, the else-if above always runs strandedTileDetected
        // (updating overflowParkedIds even when the heal verdict is not stranded).

        if let rebuildReason,
           let target = multiProfileTarget, let action = multiProfileAction {
            LoggingService.shared.logUIEvent("Multi-profile: \(rebuildReason), rebuilding status items")
            setupMultiProfile(profiles: profiles, target: target, action: action)

            // Buttons created microseconds ago still report a provisional
            // effectiveAppearance (usually light) — the label color bakes into the
            // image, so painting now can leave BLACK labels on a dark menu bar
            // until the next sweep. Repaint on the next runloop, when AppKit has
            // resolved the real menu-bar appearance (the order is now recorded, so
            // this cannot recurse into another rebuild).
            DispatchQueue.main.async { [weak self] in
                // The repaint below this rebuild ran under provisional button
                // appearances and populated render keys for those bakes — drop
                // them so THIS resolved-appearance paint re-renders every tile
                // instead of key-matching against a provisional-appearance image.
                self?.lastRenderKey.removeAll()
                self?.updateMultiProfileButtons(profiles: profiles, config: config)
            }
        }

        if profiles.contains(where: { $0.isSelectedForDisplay }) {
            paintTiles(profiles: profiles, config: config)
        } else {
            paintPlaceholderLogo()
        }
    }

    /// Paint the app logo onto the placeholder item that stands in when NO
    /// profile is selected for display. Nothing else ever paints it: the
    /// default-logo path in `updateAllButtons` only covers single-profile
    /// `statusItems`, so both multi-profile modes used to leave an invisible,
    /// contentless status item on the bar — the app looked like it had
    /// disappeared (Codex verification 2026-07-29).
    private func paintPlaceholderLogo() {
        let button = Self.useCompositeTiles
            ? groupItems.values.first?.button
            : multiProfileStatusItems.values.first?.button
        guard let button else { return }
        let logo = renderer.createDefaultAppLogo(isDarkMode: true)
        logo.isTemplate = true
        setButtonImage(button, image: logo)
    }

    /// Renders every selected profile's tile (render-key gated). Legacy mode
    /// assigns each image to its own status item; composite mode stores the
    /// image for `assembleComposites` to concatenate per provider group.
    private func paintTiles(profiles: [Profile], config: MultiProfileDisplayConfig) {
        // ONE appearance for the whole tile group, taken from the first VISIBLE
        // non-parked button. Rationale (two real incidents, 2026-07-28/29):
        // per-button effectiveAppearance is stale/provisional-LIGHT on some
        // buttons indefinitely (notably ones created while overflow-parked) —
        // black labels on a dark bar for a rotating subset of tiles; and the
        // app-level appearance follows the SYSTEM theme, which is wrong when a
        // dark wallpaper darkens the menu bar under a light system theme (black
        // labels on ALL tiles). A visible button's appearance is the only
        // wallpaper-correct source; all tiles share one physical menu bar.
        // FORCED dark appearance -> WHITE labels, always (owner decision
        // 2026-07-29). Every "detect the menu bar appearance" source proved
        // unreliable in production: per-button effectiveAppearance goes
        // stale/provisional-light on a rotating subset of buttons, the
        // app-level appearance follows the SYSTEM theme rather than the
        // wallpaper-darkened bar, and even a VISIBLE button's appearance
        // disagreed with how macOS actually rendered its own white menu-bar
        // items alongside ours. The owner's bars are always dark; white labels
        // match the system clock deterministically on every repaint.
        let groupAppearance = NSAppearance(named: .darkAqua) ?? NSApp.effectiveAppearance

        // Active accounts get a distinct label color (owner request 2026-07-29):
        // the provider-active Claude and Codex accounts, and Grok's active one
        // (Grok has no shared-login pointer — the focused Grok profile counts,
        // else a sole Grok profile is trivially the active one).
        // Weekly-maxed tiles render a light-red title (owner spec 2026-07-29):
        // at/over the auto-switch WEEKLY threshold (all-models or Fable; the
        // single weekly window for Codex/Grok). Session 5h is not consulted.
        // Precedence: maxed-red beats active-cyan — "unusable this week" is the
        // more urgent fact about an account.
        let weeklyMaxThreshold = SharedDataStore.shared.loadAutoSwitchWeeklyThreshold()

        let activeIds = ProfileManager.shared.activeAccountIds(among: profiles)

        // Capture each group's active account for ambiguous click/shortcut
        // resolution (profileId(for:atX:) with no usable coordinate).
        groupActiveIds = Dictionary(
            profiles
                .filter { $0.isSelectedForDisplay && activeIds.contains($0.id) }
                .map { ($0.providerKind, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        for profile in profiles where profile.isSelectedForDisplay {
            let button: NSStatusBarButton?
            if Self.useCompositeTiles {
                // Composite: the group button supplies appearance/backing
                // scale; per-tile images are stored and composited afterwards.
                button = groupItems[profile.providerKind]?.button
            } else {
                button = multiProfileStatusItems[profile.id]?.button
            }
            guard let button else { continue }

            // Skip overflow-parked tiles except first paint (must always
            // render). Legacy mode only: composites always paint (3 windows).
            if !Self.useCompositeTiles,
               overflowParkedIds.contains(profile.id), button.image != nil {
                continue
            }

            let renderAppearance = groupAppearance
            let isActiveAccount = activeIds.contains(profile.id)
            let isWeeklyMaxed = MenuBarManager.isWeeklyMaxed(profile.claudeUsage, weeklyThreshold: weeklyMaxThreshold)
            let isSuspected = profile.claudeUsage?.isSuspectedRateLimited ?? false
            let menuBarIsDark = renderAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            // Get usage data for this profile
            let usage = profile.claudeUsage ?? ClaudeUsage.empty
            let showRemaining = profile.iconConfig.showRemainingPercentage

            // Weekly-only providers (Grok always; Codex since OpenAI collapsed
            // the 5h/weekly pair into one 7-day window): the weekly quota IS the
            // gauge — render it in the primary slot and drop the second bar
            // instead of drawing a meaningless permanent-0% session bar.
            let weeklyOnly = !usage.providesSessionWindow
            let showWeekSlot = config.showWeek && !weeklyOnly

            // Calculate percentages. Display uses displaySessionPercentage:
            // a SUSPECTED (inferred, unverified) rate limit shows the last
            // MEASURED value — a synthetic 100% here caused a costly manual
            // account switch on a false signal (2026-08-12). The suspicion is
            // conveyed by the label color below, not by faking the number.
            let sessionUsed = weeklyOnly ? usage.weeklyPercentage : usage.displaySessionPercentage
            let weekUsed = usage.weeklyPercentage

            let sessionDisplay = UsageStatusCalculator.getDisplayPercentage(
                usedPercentage: sessionUsed,
                showRemaining: showRemaining
            )
            let weekDisplay = UsageStatusCalculator.getDisplayPercentage(
                usedPercentage: weekUsed,
                showRemaining: showRemaining
            )

            let sessionElapsed = UsageStatusCalculator.elapsedFraction(
                resetTime: weeklyOnly ? usage.weeklyResetTime : usage.sessionResetTime,
                duration: weeklyOnly ? Constants.weeklyWindow : Constants.sessionWindow,
                showRemaining: false
            )
            let weekElapsed = UsageStatusCalculator.elapsedFraction(
                resetTime: usage.weeklyResetTime,
                duration: Constants.weeklyWindow,
                showRemaining: false
            )
            let sessionStatus = UsageStatusCalculator.calculateStatus(
                usedPercentage: sessionUsed,
                showRemaining: showRemaining,
                elapsedFraction: config.usePaceColoring ? sessionElapsed : nil
            )
            let weekStatus = UsageStatusCalculator.calculateStatus(
                usedPercentage: weekUsed,
                showRemaining: showRemaining,
                elapsedFraction: config.usePaceColoring ? weekElapsed : nil
            )

            // Use multi-profile config's useSystemColor as monochrome mode
            // When useSystemColor is ON, icons will be white (like single-profile monochrome)
            let useMonochrome = config.useSystemColor

            // Calculate time marker fractions for multi-profile display
            let sessionMarker: CGFloat? = config.showTimeMarker
                ? sessionElapsed.map { CGFloat(showRemaining ? 1.0 - $0 : $0) }
                : nil
            let weekMarker: CGFloat? = config.showTimeMarker
                ? weekElapsed.map { CGFloat(showRemaining ? 1.0 - $0 : $0) }
                : nil

            // Compute pace status for multi-profile rendering
            let sessionPaceStatus: PaceStatus? = {
                guard config.showPaceMarker, let elapsed = sessionElapsed else { return nil }
                return PaceStatus.calculate(usedPercentage: sessionUsed, elapsedFraction: elapsed)
            }()
            let weekPaceStatus: PaceStatus? = {
                guard config.showPaceMarker, let elapsed = weekElapsed else { return nil }
                return PaceStatus.calculate(usedPercentage: weekUsed, elapsedFraction: elapsed)
            }()

            // Label string actually consumed by the active style
            let label: String = {
                switch config.iconStyle {
                case .concentric:
                    return config.showProfileLabel
                        ? String(profile.menuBarDisplayName.prefix(3))
                        : String(profile.name.prefix(1))
                case .progressBar, .percentage:
                    return config.showProfileLabel
                        ? String(profile.menuBarDisplayName.prefix(3))
                        : ""
                case .compact:
                    return config.showProfileLabel
                        ? String(profile.name.prefix(1))
                        : ""
                }
            }()

            let weekDisplayForKey = showWeekSlot ? weekDisplay : 0
            let weekMarkerForKey: CGFloat? = showWeekSlot ? weekMarker : nil
            let weekPaceForKey: PaceStatus? = showWeekSlot ? weekPaceStatus : nil
            let backingScale = button.window?.backingScaleFactor
                ?? button.superview?.window?.backingScaleFactor
                ?? 0

            let renderKey = TileRenderKey(
                sessionDisplayQ: Int((sessionDisplay * 10).rounded()),
                weekDisplayQ: Int((weekDisplayForKey * 10).rounded()),
                sessionStatus: sessionStatus,
                weekStatus: weekStatus,
                sessionPace: sessionPaceStatus,
                weekPace: weekPaceForKey,
                sessionMarkerTick: Self.quantizeMarkerTick(sessionMarker, style: config.iconStyle),
                weekMarkerTick: Self.quantizeMarkerTick(weekMarkerForKey, style: config.iconStyle),
                label: label,
                config: config,
                appearanceName: renderAppearance.name.rawValue,
                isActiveAccount: isActiveAccount,
                isSuspected: isSuspected,
                isWeeklyMaxed: isWeeklyMaxed,
                backingScaleQ: Int((backingScale * 100).rounded())
            )

            // Skip-not-replace: unchanged inputs + existing image ⇒ no render.
            let hasImage = Self.useCompositeTiles
                ? tileImages[profile.id] != nil
                : button.image != nil
            if lastRenderKey[profile.id] == renderKey, hasImage {
                continue
            }

            // Create icon based on selected style. Render inside the BUTTON's
            // appearance context: bar fills use dynamic system colors
            // (systemGreen/Orange/Red) that resolve against the thread's current
            // drawing appearance at setFill time, NOT the isDarkMode flag — a
            // render outside this context can bake desaturated/dark bars that the
            // render key cannot detect.
            RenderInstrumentation.tileRenders += 1
            var image = NSImage()
            renderAppearance.performAsCurrentDrawingAppearance {
            switch config.iconStyle {
            case .concentric:
                if config.showProfileLabel {
                    image = renderer.createConcentricIconWithLabel(
                        sessionPercentage: sessionDisplay,
                        weekPercentage: showWeekSlot ? weekDisplay : 0,
                        sessionStatus: sessionStatus,
                        weekStatus: weekStatus,
                        profileName: profile.menuBarDisplayName,
                        monochromeMode: useMonochrome,
                        isDarkMode: menuBarIsDark,
                        activeLabelColor: tileLabelColor(isWeeklyMaxed: isWeeklyMaxed, isSuspected: isSuspected, isActiveAccount: isActiveAccount),
                        useSystemColor: false,
                        sessionTimeMarker: sessionMarker,
                        weekTimeMarker: showWeekSlot ? weekMarker : nil,
                        sessionPaceStatus: sessionPaceStatus,
                        weekPaceStatus: showWeekSlot ? weekPaceStatus : nil,
                        showPaceMarker: config.showPaceMarker
                    )
                } else {
                    image = renderer.createConcentricIcon(
                        sessionPercentage: sessionDisplay,
                        weekPercentage: showWeekSlot ? weekDisplay : 0,
                        sessionStatus: sessionStatus,
                        weekStatus: weekStatus,
                        profileInitial: String(profile.name.prefix(1)),
                        monochromeMode: useMonochrome,
                        isDarkMode: menuBarIsDark,
                        activeLabelColor: tileLabelColor(isWeeklyMaxed: isWeeklyMaxed, isSuspected: isSuspected, isActiveAccount: isActiveAccount),
                        useSystemColor: false,
                        sessionTimeMarker: sessionMarker,
                        weekTimeMarker: showWeekSlot ? weekMarker : nil,
                        sessionPaceStatus: sessionPaceStatus,
                        weekPaceStatus: showWeekSlot ? weekPaceStatus : nil,
                        showPaceMarker: config.showPaceMarker
                    )
                }
            case .progressBar:
                image = renderer.createMultiProfileProgressBar(
                    sessionPercentage: sessionDisplay,
                    weekPercentage: showWeekSlot ? weekDisplay : nil,
                    sessionStatus: sessionStatus,
                    weekStatus: weekStatus,
                    profileName: config.showProfileLabel ? profile.menuBarDisplayName : nil,
                    monochromeMode: useMonochrome,
                    isDarkMode: menuBarIsDark,
                    activeLabelColor: tileLabelColor(isWeeklyMaxed: isWeeklyMaxed, isSuspected: isSuspected, isActiveAccount: isActiveAccount),
                    useSystemColor: false,
                    sessionTimeMarker: sessionMarker,
                    weekTimeMarker: showWeekSlot ? weekMarker : nil,
                    sessionPaceStatus: sessionPaceStatus,
                    weekPaceStatus: showWeekSlot ? weekPaceStatus : nil,
                    showPaceMarker: config.showPaceMarker
                )
            case .compact:
                image = renderer.createCompactDot(
                    percentage: sessionDisplay,
                    status: sessionStatus,
                    profileInitial: config.showProfileLabel ? String(profile.name.prefix(1)) : nil,
                    monochromeMode: useMonochrome,
                    isDarkMode: menuBarIsDark,
                    activeLabelColor: tileLabelColor(isWeeklyMaxed: isWeeklyMaxed, isSuspected: isSuspected, isActiveAccount: isActiveAccount),
                    useSystemColor: false,
                    paceStatus: sessionPaceStatus,
                    showPaceMarker: config.showPaceMarker
                )
            case .percentage:
                image = renderer.createMultiProfilePercentage(
                    sessionPercentage: sessionDisplay,
                    weekPercentage: showWeekSlot ? weekDisplay : nil,
                    sessionStatus: sessionStatus,
                    weekStatus: weekStatus,
                    profileName: config.showProfileLabel ? profile.menuBarDisplayName : nil,
                    monochromeMode: useMonochrome,
                    isDarkMode: menuBarIsDark,
                    activeLabelColor: tileLabelColor(isWeeklyMaxed: isWeeklyMaxed, isSuspected: isSuspected, isActiveAccount: isActiveAccount),
                    useSystemColor: false,
                    sessionPaceStatus: sessionPaceStatus,
                    weekPaceStatus: showWeekSlot ? weekPaceStatus : nil,
                    showPaceMarker: config.showPaceMarker
                )
            }
            }

            image.isTemplate = useMonochrome && !config.showPaceMarker
            lastRenderKey[profile.id] = renderKey
            if Self.useCompositeTiles {
                tileImages[profile.id] = image
                // Monotonic stamp: `assembleComposites` compares these to decide
                // whether anything a composite is made of actually changed.
                nextTileSeq += 1
                tileImageSeq[profile.id] = nextTileSeq
            } else {
                setButtonImage(button, image: image)
            }
        }
    }

    /// Drop per-tile state for profiles that are no longer displayed (deselected
    /// or deleted). Without this, `tileImages` holds an NSImage per profile the
    /// user ever displayed for the life of the process.
    private func pruneTileState(keeping liveIds: Set<UUID>) {
        for id in Array(tileImages.keys) where !liveIds.contains(id) {
            tileImages.removeValue(forKey: id)
            tileImageSeq.removeValue(forKey: id)
            lastRenderKey.removeValue(forKey: id)
        }
    }

    /// Composite mode: concatenate each provider group's tile images into one
    /// image, assign it (TIFF-guarded), pin the item's length to the composite
    /// width (fixed length ⇒ repaints can never trigger a bar relayout), and
    /// record the per-profile segment layout for click routing / anchoring.
    private func assembleComposites(profiles: [Profile]) {
        let byId = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })

        // A provider that no longer owns an item must not leave routable
        // segments behind: a click resolved against stale segments would open
        // the popover on a deselected (or deleted) profile.
        for provider in Array(groupSegments.keys) where groupItems[provider] == nil {
            groupSegments.removeValue(forKey: provider)
            groupCompositeSize.removeValue(forKey: provider)
            lastCompositeKey.removeValue(forKey: provider)
        }

        // Rank order is soonest-reset-first; the composite is drawn
        // left-to-right, so it paints in the REVERSE of that (see
        // `compositePaintOrder`) to keep the soonest reset at the right edge.
        let paintOrder = Self.compositePaintOrder(multiProfileOrder)

        for (provider, statusItem) in groupItems {
            guard let button = statusItem.button else { continue }
            let members: [(id: UUID, image: NSImage)] = paintOrder.compactMap { id in
                guard let profile = byId[id], profile.providerKind == provider,
                      profile.isSelectedForDisplay, let image = tileImages[id] else { return nil }
                return (id, image)
            }
            guard !members.isEmpty else {
                // Nothing to draw for this group (all members unpainted or
                // deselected): drop its segments rather than keep routing
                // clicks to tiles that are no longer on screen.
                groupSegments[provider] = []
                groupCompositeSize.removeValue(forKey: provider)
                lastCompositeKey.removeValue(forKey: provider)
                continue
            }

            // Pixel scale of the display the menu bar is actually on — NOT the
            // main screen, which is what `lockFocus` would have used.
            let scale = button.window?.backingScaleFactor
                ?? button.superview?.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor
                ?? 2
            let isTemplate = members.allSatisfy { $0.image.isTemplate }
            let key = CompositeKey(
                members: members.map(\.id),
                seqs: members.map { tileImageSeq[$0.id] ?? 0 },
                isTemplate: isTemplate,
                scaleQ: Int((scale * 100).rounded())
            )
            // Steady state (no tile re-rendered, same membership and order):
            // the composite already on the button IS this composite. Skipping
            // is what keeps an idle 30s sweep from allocating three bitmaps,
            // re-drawing ~14 tiles and TIFF-encoding the whole strip three
            // times just to discover nothing changed.
            if lastCompositeKey[provider] == key, button.image != nil { continue }

            let layout = Self.compositeLayout(tileWidths: members.map { $0.image.size.width })
            let height = members.map { $0.image.size.height }.max() ?? 24
            guard let composite = compositeImage(
                members: members,
                origins: layout.origins,
                totalWidth: layout.totalWidth,
                height: height,
                scale: scale
            ) else {
                // Transient bitmap/context failure (memory or graphics
                // pressure): keep the previous image and segments on screen and
                // do NOT record the memo — the next sweep retries for real.
                LoggingService.shared.logWarning(
                    "Composite assembly failed for \(provider) — keeping previous image, retrying next sweep")
                continue
            }
            // Monochrome tiles are template images; the strip they are drawn
            // into must be one too, or the system stops tinting it.
            composite.isTemplate = isTemplate

            groupSegments[provider] = zip(members, layout.ranges).map {
                TileSegment(profileId: $0.0.id, range: $0.1)
            }
            groupCompositeSize[provider] = NSSize(width: layout.totalWidth, height: height)
            lastCompositeKey[provider] = key

            // Fixed length: assign BEFORE the image so the item never renders
            // a partially-clipped composite, and only when it changed.
            if abs(statusItem.length - layout.totalWidth) > 0.5 {
                statusItem.length = layout.totalWidth
            }
            setButtonImage(button, image: composite)
        }
    }

    /// Draw a group's tiles side-by-side into ONE image.
    ///
    /// Uses an explicit `NSBitmapImageRep` at the destination's pixel scale
    /// rather than `NSImage.lockFocus`, whose backing scale follows the MAIN
    /// screen: with the menu bar on a display of a different
    /// `backingScaleFactor` a lockFocus composite is rasterized at the wrong
    /// scale (soft or over-sampled tiles), and its bytes are not deterministic
    /// across sweeps, which can defeat `setButtonImage`'s TIFF guard and make
    /// every sweep re-assign the image.
    private func compositeImage(
        members: [(id: UUID, image: NSImage)],
        origins: [CGFloat],
        totalWidth: CGFloat,
        height: CGFloat,
        scale: CGFloat
    ) -> NSImage? {
        let size = NSSize(width: totalWidth, height: height)
        let image = NSImage(size: size)
        let pixelsWide = Int((totalWidth * scale).rounded())
        let pixelsHigh = Int((height * scale).rounded())
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil,
                  pixelsWide: pixelsWide,
                  pixelsHigh: pixelsHigh,
                  bitsPerSample: 8,
                  samplesPerPixel: 4,
                  hasAlpha: true,
                  isPlanar: false,
                  colorSpaceName: .deviceRGB,
                  bytesPerRow: 0,
                  bitsPerPixel: 0
              )
        else {
            // Allocation failure: nil tells the caller to keep the previous
            // image and SKIP the memo, so the next sweep genuinely retries —
            // returning an empty canvas here used to get memoized as success
            // and left the whole group blank until an unrelated tile changed.
            return nil
        }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Full-canvas backdrop FIRST: the tiles each carry one across their own
        // rect only, so the padding and the 3pt gaps would otherwise leave the
        // group window's event shape a comb of rectangles.
        renderer.applyEventShapeBackdrop(width: totalWidth, height: height)
        for (member, x) in zip(members, origins) {
            let y = ((height - member.image.size.height) / 2).rounded()
            member.image.draw(
                at: NSPoint(x: x, y: y),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        image.addRepresentation(rep)
        return image
    }

    /// The rect the composite image actually occupies inside its button.
    ///
    /// Segment ranges are in the composite IMAGE's coordinate space; a click
    /// arrives in the BUTTON's. They coincide only if the image is drawn 1:1 at
    /// the button's origin, and an `NSButton` does neither unconditionally: it
    /// scales the image PROPORTIONALLY DOWN to fit its bounds and CENTERS the
    /// result. A composite taller than the bar's content height is therefore
    /// drawn NARROWER than `totalWidth`, and every segment boundary shifts —
    /// clicks near the ends resolve to the wrong account. `setupCompositeGroups`
    /// pins `imageScaling` to `.scaleProportionallyDown` so the geometry below
    /// is the transform AppKit actually applies rather than an assumption.
    private func compositeDrawnRect(in button: NSStatusBarButton, imageSize: NSSize) -> CGRect {
        let bounds = button.bounds
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(1, min(bounds.width / imageSize.width, bounds.height / imageSize.height))
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: bounds.minX + (bounds.width - width) / 2,
            y: bounds.minY + (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// Scale + origin mapping between a group button's coordinates and its
    /// composite image's coordinates.
    private func compositeMapping(
        for provider: Profile.ProviderKind,
        in button: NSStatusBarButton,
        totalWidth: CGFloat
    ) -> (originX: CGFloat, scale: CGFloat) {
        let size = groupCompositeSize[provider]
            ?? NSSize(width: totalWidth, height: button.bounds.height)
        let drawn = compositeDrawnRect(in: button, imageSize: size)
        guard size.width > 0, drawn.width > 0 else { return (0, 1) }
        return (drawn.minX, drawn.width / size.width)
    }

    /// A provider group's button (composite mode; lab probes + tests).
    func groupButton(for provider: Profile.ProviderKind) -> NSStatusBarButton? {
        groupItems[provider]?.button
    }

    /// The PHYSICAL pointer position in `button`-local x, or nil when the
    /// pointer is not on the button.
    ///
    /// This — not the action's NSEvent — is the trustworthy click location.
    /// Scene-hosted status items (macOS 26/27) deliver clicks as FrontBoard
    /// NSMenuBarNavigateActions that AppKit re-dispatches through the button
    /// cell's trackMouse with a SYNTHESIZED event at the button's CENTER:
    /// 14 consecutive production clicks on different tiles all logged
    /// rawX=148 == compositeWidth/2 (2026-07-30), routing every click to the
    /// center tile. The window server's pointer position at action time is
    /// where the user actually clicked. A pointer outside the button means
    /// there was no physical click to resolve (keyboard activation, forwarded
    /// scene action) — callers treat that as ambiguous.
    static func pointerLocalX(in button: NSStatusBarButton) -> CGFloat? {
        guard let window = button.window else { return nil }
        let inWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = button.convert(inWindow, from: nil)
        guard button.bounds.insetBy(dx: -4, dy: -4).contains(local) else { return nil }
        return local.x
    }

    /// Resolve which profile a click at `locationInButton` (button-local x)
    /// landed on. Composite mode only; nil when unresolvable.
    func profileId(for sender: NSStatusBarButton?, atX locationInButton: CGFloat?) -> UUID? {
        guard let sender else { return nil }
        guard Self.useCompositeTiles else { return profileId(for: sender) }
        for (provider, statusItem) in groupItems where statusItem.button === sender {
            guard let segments = groupSegments[provider], !segments.isEmpty else { return nil }
            // Ambiguous resolution (no click coordinate) opens the group's
            // ACTIVE account — the account the user is operating on — not a
            // positional fallback. `segments.last` here is the soonest-reset
            // tile, and every ambiguous open landed on that same account
            // ("always opens Commits", owner report 2026-07-30).
            guard let rawX = locationInButton else {
                return groupActiveIds[provider] ?? segments.last?.profileId
            }
            let totalWidth = segments[segments.count - 1].range.upperBound
            let map = compositeMapping(for: provider, in: sender, totalWidth: totalWidth)
            let x = map.scale > 0 ? (rawX - map.originX) / map.scale : rawX
            if let hit = segments.first(where: { $0.range.contains(x) }) {
                LoggingService.shared.log(
                    "Composite click: rawX=\(Int(rawX)) mapped=\(Int(x)) → segment hit")
                return hit.profileId
            }
            // Off the ends: the ACTIVE account, else clamp to nearest.
            LoggingService.shared.log(
                "Composite click: rawX=\(Int(rawX)) mapped=\(Int(x)) OFF-SEGMENTS (0..\(Int(totalWidth))) → active/clamp fallback")
            if let active = groupActiveIds[provider] { return active }
            return x < segments[0].range.lowerBound ? segments[0].profileId : segments.last?.profileId
        }
        return nil
    }

    /// The active account of each provider group, captured during the last
    /// paint (same derivation the tile highlight uses). Ambiguous click/
    /// shortcut resolution defaults here.
    private var groupActiveIds: [Profile.ProviderKind: UUID] = [:]

    /// The sub-rect of the group button occupied by a profile's tile —
    /// popover anchoring. Falls back to nil when unknown.
    func anchorRect(for profileId: UUID, in sender: NSStatusBarButton) -> NSRect? {
        guard Self.useCompositeTiles else { return nil }
        for (provider, statusItem) in groupItems where statusItem.button === sender {
            guard let segments = groupSegments[provider], !segments.isEmpty,
                  let seg = segments.first(where: { $0.profileId == profileId }) else { return nil }
            let map = compositeMapping(
                for: provider,
                in: sender,
                totalWidth: segments[segments.count - 1].range.upperBound
            )
            return NSRect(
                x: map.originX + seg.range.lowerBound * map.scale,
                y: 0,
                width: (seg.range.upperBound - seg.range.lowerBound) * map.scale,
                height: sender.bounds.height
            )
        }
        return nil
    }

    /// Profile ids of one provider group's tiles, LEFT-TO-RIGHT as painted.
    ///
    /// Composite mode reads the group's own click segments. Legacy per-item
    /// mode has no segments, so the same order is derived from the live
    /// creation order (`multiProfileOrder` is right-to-left on screen, which is
    /// what `compositePaintOrder` reverses) — that needs `profiles` to tell the
    /// ids' providers apart. Empty when nothing has been painted yet, which is
    /// the caller's signal to fall back to a fresh ranking.
    func paintedGroupMembers(for provider: Profile.ProviderKind, among profiles: [Profile] = []) -> [UUID] {
        if let segments = groupSegments[provider], !segments.isEmpty {
            return segments.map(\.profileId)
        }
        guard !multiProfileOrder.isEmpty, !profiles.isEmpty else { return [] }
        let idsInGroup = Set(profiles.filter { $0.providerKind == provider }.map(\.id))
        return Self.compositePaintOrder(multiProfileOrder).filter { idsInGroup.contains($0) }
    }

    /// Checks if currently in multi-profile mode
    var isInMultiProfileMode: Bool {
        return isMultiProfileMode
    }

    /// Checks if status bar has at least one valid button (for headless mode detection)
    var hasValidStatusBar: Bool {
        // Check single-profile status items
        for (_, statusItem) in statusItems {
            if statusItem.button != nil {
                return true
            }
        }
        // Check multi-profile status items
        for (_, statusItem) in multiProfileStatusItems {
            if statusItem.button != nil {
                return true
            }
        }
        // Composite provider-group items
        for (_, statusItem) in groupItems {
            if statusItem.button != nil {
                return true
            }
        }
        return false
    }

    /// Get button for a specific profile (multi-profile mode). Composite mode
    /// returns the profile's GROUP button — use `anchorRect(for:in:)` for the
    /// tile's sub-rect within it.
    func button(for profileId: UUID) -> NSStatusBarButton? {
        if Self.useCompositeTiles {
            for (provider, segments) in groupSegments
            where segments.contains(where: { $0.profileId == profileId }) {
                return groupItems[provider]?.button
            }
            // Not painted yet: resolve the profile's OWN provider group. Falling
            // back to "any group button" would anchor the popover over an
            // unrelated provider's tiles.
            if let provider = ProfileManager.shared.profiles
                .first(where: { $0.id == profileId })?.providerKind {
                return groupItems[provider]?.button
            }
            return nil
        }
        return multiProfileStatusItems[profileId]?.button
    }

    /// Find which profile ID owns the given button (multi-profile mode).
    /// Composite mode: resolves to the group's RIGHTMOST tile; prefer
    /// `profileId(for:atX:)` when a click location is available.
    func profileId(for sender: NSStatusBarButton?) -> UUID? {
        guard let sender = sender else { return nil }

        if Self.useCompositeTiles {
            for (provider, statusItem) in groupItems where statusItem.button === sender {
                return groupSegments[provider]?.last?.profileId
            }
            return nil
        }

        for (profileId, statusItem) in multiProfileStatusItems {
            if statusItem.button === sender {
                return profileId
            }
        }
        return nil
    }

    // MARK: - UI Updates

    /// Updates all status bar buttons based on current usage data
    func updateAllButtons(
        usage: ClaudeUsage
    ) {
        // Get config from active profile
        let profile = ProfileManager.shared.activeProfile
        let config = profile?.iconConfig ?? .default

        // Check if we should show default logo (no usage credentials OR no enabled metrics)
        let hasUsageCredentials = profile?.hasUsageCredentials ?? false
        if !hasUsageCredentials || config.enabledMetrics.isEmpty {
            // Show default app logo
            if let statusItem = statusItems[.session],  // We use .session as placeholder key
               let button = statusItem.button {
                // Get actual menu bar appearance from the button
                let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let logoImage = renderer.createDefaultAppLogo(isDarkMode: menuBarIsDark)
                logoImage.isTemplate = true  // Let macOS handle the color
                setButtonImage(button, image: logoImage)
            }
            return
        }

        // Normal metric display
        for metricConfig in config.enabledMetrics {
            guard let statusItem = statusItems[metricConfig.metricType],
                  let button = statusItem.button else {
                continue
            }

            // Get actual menu bar appearance from the button
            let menuBarIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            // Create image directly using our renderer
            let image = renderer.createImage(
                for: metricConfig.metricType,
                config: metricConfig,
                globalConfig: config,
                usage: usage,
                isDarkMode: menuBarIsDark,
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconName: config.showIconNames,
                showNextSessionTime: metricConfig.showNextSessionTime
            )

            image.isTemplate = config.colorMode == .monochrome && !config.showPaceMarker
            setButtonImage(button, image: image)
        }
    }

    /// Get button for a specific metric (used for popover positioning)
    func button(for metricType: MenuBarMetricType) -> NSStatusBarButton? {
        return statusItems[metricType]?.button
    }

    /// Get the first enabled metric's button (for backwards compatibility)
    var primaryButton: NSStatusBarButton? {
        let config = MenuBarIconConfiguration.load()
        guard let firstMetric = config.enabledMetrics.first else {
            return nil
        }
        return statusItems[firstMetric.metricType]?.button
    }

    /// Find which metric type owns the given button (sender)
    func metricType(for sender: NSStatusBarButton?) -> MenuBarMetricType? {
        guard let sender = sender else { return nil }

        // Find which status item has this button
        for (metricType, statusItem) in statusItems {
            if statusItem.button === sender {
                return metricType
            }
        }
        return nil
    }

    // MARK: - Appearance Observation

    private var lastObservedAppearanceName: NSAppearance.Name?

    private func observeAppearanceChanges() {
        appearanceObservers.forEach { $0.invalidate() }
        appearanceObservers.removeAll()

        // IMPORTANT: Do NOT observe per-button effectiveAppearance.
        // Setting button.image triggers effectiveAppearance KVO on the button,
        // which causes an infinite redraw loop.
        let appObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, change in
            guard let self = self else { return }
            let newName = change.newValue?.name
            guard newName != self.lastObservedAppearanceName else { return }
            self.lastObservedAppearanceName = newName
            // Clear image cache so next update re-renders with new appearance
            self.lastImageData.removeAll()
            self.lastRenderKey.removeAll()
            self.delegate?.statusBarAppearanceDidChange()
        }
        appearanceObservers.append(appObserver)
    }

    /// Only sets button.image if the image data actually changed.
    /// This prevents triggering effectiveAppearance KVO when the image is identical.
    private func setButtonImage(_ button: NSStatusBarButton, image: NSImage) {
        let buttonId = ObjectIdentifier(button)
        guard let newData = image.tiffRepresentation else {
            RenderInstrumentation.setButtonImageAssignments += 1
            button.image = image
            return
        }
        if lastImageData[buttonId] == newData { return }
        lastImageData[buttonId] = newData
        RenderInstrumentation.setButtonImageAssignments += 1
        button.image = image
    }

}

// MARK: - Delegate Protocol

protocol StatusBarUIManagerDelegate: AnyObject {
    func statusBarAppearanceDidChange()
}
