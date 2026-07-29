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

    /// Sets up status bar for multi-profile display mode
    func setupMultiProfile(profiles: [Profile], target: AnyObject, action: Selector) {
        // Clean up existing items
        cleanup()

        isMultiProfileMode = true
        multiProfileTarget = target
        multiProfileAction = action

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
        // selected set). Status items cannot be reordered in place, so rebuild the
        // group when the desired order differs — rare, so the flicker is acceptable.
        // Same remedy when macOS has physically relocated a tile out of the group
        // (see strandedTileDetected): recreating the whole group in one burst
        // restores contiguity.
        let desiredOrder = Self.multiProfileCreationOrder(for: profiles).map(\.id)
        var rebuildReason: String?
        if desiredOrder != multiProfileOrder {
            rebuildReason = "weekly-reset order changed"
            // Order change skips strandedTileDetected — clear parked set so a
            // later evaluation re-derives it rather than skipping newly visible tiles.
            overflowParkedIds = []
        } else if strandedTileDetected() {
            // strandedTileDetected always refreshes overflowParkedIds on this path.
            rebuildReason = "a tile was relocated out of the group by the system"
            lastLayoutHealAt = Date()
            // One attempt per distinct broken layout: if the rebuild reproduces
            // this same arrangement, stop retrying until something changes.
            healFailedSignature = lastEvaluatedSignature
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

        for profile in profiles where profile.isSelectedForDisplay {
            guard let statusItem = multiProfileStatusItems[profile.id],
                  let button = statusItem.button else {
                continue
            }

            // Skip overflow-parked tiles except first paint (must always render).
            if overflowParkedIds.contains(profile.id), button.image != nil {
                continue
            }

            // Use the APP-level appearance, not the per-button one: individual
            // NSStatusBarButton windows can report a stale/provisional LIGHT
            // appearance indefinitely (notably items created while
            // overflow-parked), baking black labels and desaturated bars onto a
            // dark menu bar — observed live 2026-07-28 with a rotating subset of
            // tiles. The app-level appearance matches the system status items
            // (clock, control center) rendered alongside our tiles.
            let renderAppearance = NSApp.effectiveAppearance
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

            // Calculate percentages
            let sessionUsed = weeklyOnly ? usage.weeklyPercentage : usage.effectiveSessionPercentage
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
                backingScaleQ: Int((backingScale * 100).rounded())
            )

            // Skip-not-replace: unchanged inputs + existing image ⇒ no render.
            if lastRenderKey[profile.id] == renderKey, button.image != nil {
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
                    useSystemColor: false,
                    sessionPaceStatus: sessionPaceStatus,
                    weekPaceStatus: showWeekSlot ? weekPaceStatus : nil,
                    showPaceMarker: config.showPaceMarker
                )
            }
            }

            image.isTemplate = useMonochrome && !config.showPaceMarker
            lastRenderKey[profile.id] = renderKey
            setButtonImage(button, image: image)
        }
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
        return false
    }

    /// Get button for a specific profile (multi-profile mode)
    func button(for profileId: UUID) -> NSStatusBarButton? {
        return multiProfileStatusItems[profileId]?.button
    }

    /// Find which profile ID owns the given button (multi-profile mode)
    func profileId(for sender: NSStatusBarButton?) -> UUID? {
        guard let sender = sender else { return nil }

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
