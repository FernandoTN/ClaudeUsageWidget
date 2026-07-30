//
//  LabController.swift
//  Claude Usage
//
//  Phase 0 lab path: synthetic in-memory multi-profile tiles driven through
//  StatusBarUIManager. Never touches ProfileStore, UserDefaults profiles,
//  Keychain, or the network.
//

import AppKit
import SwiftUI

/// Owns synthetic menu-bar tiles for the `CUW_LAB=1` causality harness.
final class LabController: NSObject {
    static let shared = LabController()

    private let statusBarUIManager = StatusBarUIManager()
    private var profiles: [Profile] = []
    private let displayConfig = MultiProfileDisplayConfig.default
    private var repaintTimer: Timer?
    private var rebuildTimer: Timer?
    private var rebuildCount = 0
    private var popover: NSPopover?

    private override init() {
        super.init()
    }

    /// Create N synthetic tiles, paint once, optionally open a popover, and
    /// (unless frozen) repaint every 30s with ±1% usage jitter.
    func start() {
        let count = LabMode.tileCount
        profiles = Self.makeSyntheticProfiles(count: count)

        statusBarUIManager.setupMultiProfile(
            profiles: profiles,
            target: self,
            action: #selector(tileClicked(_:))
        )

        // Match production: paint after AppKit resolves menu-bar appearance.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusBarUIManager.updateMultiProfileButtons(
                profiles: self.profiles,
                config: self.displayConfig
            )
            if LabMode.openPopover {
                self.openPopoverOnFirstTile()
            }
            if LabMode.popoverCycle {
                self.cycleProductionStylePopover()
            }
            if LabMode.popoverStress {
                self.startPopoverStress()
            }
            if LabMode.activateOnce {
                NSApp.setActivationPolicy(.accessory)
                NSApp.activate(ignoringOtherApps: true)
                LoggingService.shared.log("LabController: activated app once")
            }
        }

        if !LabMode.freeze {
            let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.nudgeAndRepaint()
            }
            RunLoop.main.add(timer, forMode: .common)
            repaintTimer = timer
        }

        if let interval = LabMode.rebuildInterval {
            let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                self?.forceRebuild()
            }
            RunLoop.main.add(timer, forMode: .common)
            rebuildTimer = timer
        }

        LoggingService.shared.log(
            "LabController: started tiles=\(count) freeze=\(LabMode.freeze) popover=\(LabMode.openPopover)"
        )
    }

    // MARK: - Actions

    @objc private func tileClicked(_ sender: Any?) {
        // Lab tiles are inert; click handling is intentionally empty so freeze
        // measurements are not confounded by interaction side effects.
    }

    // MARK: - Repaint

    private var repaintCount = 0

    private func nudgeAndRepaint() {
        repaintCount += 1
        for i in profiles.indices {
            guard var usage = profiles[i].claudeUsage else { continue }
            let sessionDelta = Bool.random() ? 1.0 : -1.0
            let weekDelta = Bool.random() ? 1.0 : -1.0
            usage.sessionPercentage = min(95, max(10, usage.sessionPercentage + sessionDelta))
            usage.weeklyPercentage = min(90, max(20, usage.weeklyPercentage + weekDelta))
            usage.lastUpdated = Date()
            profiles[i].claudeUsage = usage
        }
        // Reshuffle probe: rotate the weekly-reset ranking within each provider
        // group every other repaint by pushing the soonest-resetting profile's
        // reset a week out — the desired creation order changes, exercising the
        // remap-not-rebuild path exactly like production ranking jitter.
        if LabMode.reshuffle, repaintCount % 2 == 0 {
            let ordered = StatusBarUIManager.multiProfileCreationOrder(for: profiles)
            if let first = ordered.first,
               let idx = profiles.firstIndex(where: { $0.id == first.id }),
               var usage = profiles[idx].claudeUsage {
                usage.weeklyResetTime = (usage.weeklyResetTime ?? Date())
                    .addingTimeInterval(7 * 24 * 3600)
                profiles[idx].claudeUsage = usage
                LoggingService.shared.log("LabController: reshuffle probe rotated '\(profiles[idx].name)'")
            }
        }
        statusBarUIManager.updateMultiProfileButtons(
            profiles: profiles,
            config: displayConfig
        )
    }

    /// Mirror the production ranking-reshuffle rebuild: full teardown+recreate
    /// via `setupMultiProfile`, then repaint on the next runloop (the same
    /// deferred-repaint dance `updateMultiProfileButtons` does after a rebuild).
    private func forceRebuild() {
        rebuildCount += 1
        let n = rebuildCount
        statusBarUIManager.setupMultiProfile(
            profiles: profiles,
            target: self,
            action: #selector(tileClicked(_:)),
            // The probe MEASURES teardown+recreate cost — never let the
            // composite reuse path short-circuit it.
            forceRecreate: true
        )
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusBarUIManager.updateMultiProfileButtons(
                profiles: self.profiles,
                config: self.displayConfig
            )
            LoggingService.shared.log("LabController: forced rebuild #\(n) complete")
            RenderInstrumentation.logCensus()
        }
    }

    // MARK: - Popover isolation

    /// Anchor rect for ONE profile's tile: its segment inside the provider
    /// group's composite button. Without this every "tile" in composite mode
    /// resolves to the same whole-group button rect, and the stress harness
    /// re-shows the popover on one identical anchor instead of reproducing
    /// production's tile-to-tile re-anchoring (Codex verification 2026-07-29).
    private func tileAnchor(_ profileId: UUID, in button: NSStatusBarButton) -> NSRect {
        statusBarUIManager.anchorRect(for: profileId, in: button) ?? button.bounds
    }

    private func openPopoverOnFirstTile() {
        let ordered = StatusBarUIManager.multiProfileCreationOrder(for: profiles)
        guard let firstId = ordered.first?.id,
              let button = statusBarUIManager.button(for: firstId) else {
            LoggingService.shared.logWarning("LabController: no first tile for popover")
            return
        }

        let popover = NSPopover()
        popover.contentSize = Constants.WindowSizes.popoverSize
        // Stay open for Phase 0.2 open-vs-closed measurements.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: LabPopoverStubView()
        )
        popover.show(relativeTo: tileAnchor(firstId, in: button), of: button, preferredEdge: .minY)
        self.popover = popover
        LoggingService.shared.log("LabController: popover opened on first tile")
    }

    /// Mirror production's popover lifecycle: semitransient NSPopover shown on
    /// the first tile, closed 8s later, contentViewController nil'd on close
    /// (like MenuBarManager.popoverDidClose) with the popover object kept
    /// alive — leaving the same persistent closed _NSPopoverWindow production
    /// carries.
    private func cycleProductionStylePopover() {
        let ordered = StatusBarUIManager.multiProfileCreationOrder(for: profiles)
        guard let firstId = ordered.first?.id,
              let button = statusBarUIManager.button(for: firstId) else {
            LoggingService.shared.logWarning("LabController: no first tile for popover cycle")
            return
        }
        let popover = NSPopover()
        popover.contentSize = Constants.WindowSizes.popoverSize
        popover.behavior = .semitransient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: LabPopoverStubView())
        popover.show(relativeTo: tileAnchor(firstId, in: button), of: button, preferredEdge: .minY)
        self.popover = popover
        LoggingService.shared.log("LabController: popover-cycle opened")
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, let popover = self.popover else { return }
            popover.performClose(nil)
            // Mirror MenuBarManager.popoverDidClose: release SwiftUI content,
            // keep the popover (and its window) alive.
            DispatchQueue.main.async {
                popover.contentViewController = nil
                LoggingService.shared.log("LabController: popover-cycle closed, content released")
            }
        }
    }

    private var stressTimer: Timer?
    private var stressIndex = 0

    /// Continuously re-anchor a semitransient popover across tiles, mirroring
    /// togglePopover's different-button branch (performClose + fresh content +
    /// immediate show). Every 4th cycle, close and leave closed for one beat
    /// (mirroring semitransient auto-close), then resume. Every 7th cycle,
    /// mirror `recreatePopover()`'s profile-switch parity instead: performClose
    /// the shown popover and, in the SAME runloop turn, replace it with a
    /// brand-new NSPopover + fresh hosting controller and show that — the
    /// production sequence that logs "cannot add handler to 2 from 2 -
    /// dropping" (the ignition precursor) when it races an in-flight commit.
    /// Anchors rotate over the first 6 creation-order ids (rightmost tiles,
    /// least likely to be overflow-parked on a crowded bar).
    private func startPopoverStress() {
        let popover = NSPopover()
        popover.contentSize = Constants.WindowSizes.popoverSize
        popover.behavior = .semitransient
        popover.animates = true
        self.popover = popover

        let ordered = Array(
            StatusBarUIManager.multiProfileCreationOrder(for: profiles).map(\.id).prefix(6)
        )
        guard !ordered.isEmpty else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, let popover = self.popover else { return }
            self.stressIndex += 1
            if self.stressIndex % 7 == 0 {
                // Switch parity: destroy-and-replace while the old one closes.
                popover.performClose(nil)
                let fresh = NSPopover()
                fresh.contentSize = Constants.WindowSizes.popoverSize
                fresh.behavior = .semitransient
                fresh.animates = true
                fresh.contentViewController = NSHostingController(rootView: LabPopoverStubView())
                self.popover = fresh
                let id = ordered[self.stressIndex % ordered.count]
                if let button = self.statusBarUIManager.button(for: id) {
                    fresh.show(relativeTo: self.tileAnchor(id, in: button),
                               of: button, preferredEdge: .minY)
                }
                LoggingService.shared.log("LabController: popover-stress recreate (switch parity)")
                return
            }
            if self.stressIndex % 4 == 0 {
                popover.performClose(nil)
                DispatchQueue.main.async {
                    if !popover.isShown { popover.contentViewController = nil }
                }
                LoggingService.shared.log("LabController: popover-stress closed (beat)")
                return
            }
            let id = ordered[self.stressIndex % ordered.count]
            guard let button = self.statusBarUIManager.button(for: id) else { return }
            popover.performClose(nil)
            popover.contentViewController = NSHostingController(rootView: LabPopoverStubView())
            popover.show(relativeTo: self.tileAnchor(id, in: button),
                         of: button, preferredEdge: .minY)
        }
        RunLoop.main.add(timer, forMode: .common)
        stressTimer = timer
        LoggingService.shared.log("LabController: popover stress started over \(ordered.count) tiles")
    }

    // MARK: - Synthetic data

    /// Build N in-memory profiles with varied usage. Provider mix for N≥3:
    /// N−3 Claude, 2 Codex, 1 Grok (via dummy non-nil credential JSON that is
    /// never persisted — only `providerKind` / labels matter for the paint path).
    private static func makeSyntheticProfiles(count: Int) -> [Profile] {
        let now = Date()
        var result: [Profile] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            let sessionPct = 10.0 + Double(i) * (85.0 / Double(max(count - 1, 1)))
            let weeklyPct = 20.0 + Double(i) * (70.0 / Double(max(count - 1, 1)))
            // Spread weekly resets across the next 7 days.
            let weeklyReset = now.addingTimeInterval(
                Double(i + 1) * (7.0 * 24.0 * 3600.0) / Double(max(count, 1))
            )
            let usage = ClaudeUsage(
                sessionTokensUsed: Int(sessionPct * 1000),
                sessionLimit: 100_000,
                sessionPercentage: sessionPct,
                sessionResetTime: now.addingTimeInterval(5 * 3600),
                weeklyTokensUsed: Int(weeklyPct * 10_000),
                weeklyLimit: 1_000_000,
                weeklyPercentage: weeklyPct,
                weeklyResetTime: weeklyReset,
                opusWeeklyTokensUsed: 0,
                opusWeeklyPercentage: 0,
                sonnetWeeklyTokensUsed: 0,
                sonnetWeeklyPercentage: 0,
                sonnetWeeklyResetTime: nil,
                costUsed: nil,
                costLimit: nil,
                costCurrency: nil,
                overageBalance: nil,
                overageBalanceCurrency: nil,
                lastUpdated: now,
                userTimezone: .current
            )

            // Last tile → Grok; next-to-last two → Codex; rest → Claude.
            let isGrok = count >= 1 && i == count - 1
            let isCodex = count >= 3 && (i == count - 2 || i == count - 3)

            let name: String
            let menuBarLabel: String?
            var codexJSON: String? = nil
            var grokJSON: String? = nil
            if isGrok {
                name = "Lab Grok"
                menuBarLabel = "Grk"
                // Non-nil dummy so providerKind == .grok; never saved.
                grokJSON = #"{}"#
            } else if isCodex {
                let idx = i - (count - 3) + 1
                name = "Lab Codex \(idx)"
                menuBarLabel = "Cd\(idx)"
                codexJSON = #"{}"#
            } else {
                name = "Lab Claude \(i + 1)"
                menuBarLabel = String(format: "C%02d", i + 1)
            }

            result.append(Profile(
                name: name,
                codexCredentialsJSON: codexJSON,
                grokCredentialsJSON: grokJSON,
                claudeUsage: usage,
                isSelectedForDisplay: true,
                menuBarLabel: menuBarLabel
            ))
        }

        return result
    }
}

/// Minimal popover body — enough to materialize the hosting window for Phase 0.2.
private struct LabPopoverStubView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Lab Popover")
                .font(.headline)
            Text("CUW_LAB_POPOVER isolation stub")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(
            width: Constants.WindowSizes.popoverSize.width,
            height: Constants.WindowSizes.popoverSize.height
        )
    }
}
