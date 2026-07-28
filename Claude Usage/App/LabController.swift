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
        }

        if !LabMode.freeze {
            let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.nudgeAndRepaint()
            }
            RunLoop.main.add(timer, forMode: .common)
            repaintTimer = timer
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

    private func nudgeAndRepaint() {
        for i in profiles.indices {
            guard var usage = profiles[i].claudeUsage else { continue }
            let sessionDelta = Bool.random() ? 1.0 : -1.0
            let weekDelta = Bool.random() ? 1.0 : -1.0
            usage.sessionPercentage = min(95, max(10, usage.sessionPercentage + sessionDelta))
            usage.weeklyPercentage = min(90, max(20, usage.weeklyPercentage + weekDelta))
            usage.lastUpdated = Date()
            profiles[i].claudeUsage = usage
        }
        statusBarUIManager.updateMultiProfileButtons(
            profiles: profiles,
            config: displayConfig
        )
    }

    // MARK: - Popover isolation

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
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
        LoggingService.shared.log("LabController: popover opened on first tile")
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
