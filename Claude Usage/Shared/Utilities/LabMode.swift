//
//  LabMode.swift
//  Claude Usage
//
//  Phase 0 causality harness: env-var-gated lab mode + render instrumentation.
//  With no env vars set, every path below is a no-op / false — byte-identical
//  production behavior.
//

import AppKit
import Foundation

/// Launch-time flags for the Phase 0 lab / instrumentation harness.
/// Values are snapshotted once from `ProcessInfo.processInfo.environment`.
enum LabMode {
    /// `CUW_LAB=1` — synthetic tiles only; no profiles / network / Keychain.
    static let isEnabled: Bool = ProcessInfo.processInfo.environment["CUW_LAB"] == "1"

    /// `CUW_LAB_TILES=<n>` — synthetic tile count (default 14).
    static let tileCount: Int = {
        if let raw = ProcessInfo.processInfo.environment["CUW_LAB_TILES"],
           let n = Int(raw), n > 0 {
            return n
        }
        return 14
    }()

    /// `CUW_LAB_FREEZE=1` — after initial tile creation, no repaints/timers.
    static let freeze: Bool = ProcessInfo.processInfo.environment["CUW_LAB_FREEZE"] == "1"

    /// `CUW_LAB_POPOVER=1` — open a popover against the first tile at launch.
    static let openPopover: Bool = ProcessInfo.processInfo.environment["CUW_LAB_POPOVER"] == "1"

    /// `CUW_RENDER_LOG=1` — window census + render counters (lab AND normal mode).
    static let renderLog: Bool = ProcessInfo.processInfo.environment["CUW_RENDER_LOG"] == "1"
}

/// Cheap render-path counters + optional window census.
/// Counter increments are unconditional (plain Ints on the main actor); logging
/// is gated on `LabMode.renderLog`.
enum RenderInstrumentation {
    static var updateMultiProfileButtonsCalls = 0
    static var tileRenders = 0
    static var setButtonImageAssignments = 0
    static var strandedTileEvaluations = 0

    private static var censusTimer: Timer?
    private static var didStart = false

    /// Starts the +5s one-shot census and the 30s census/counter timer when
    /// `CUW_RENDER_LOG=1`. Safe to call from both lab and normal launch paths.
    static func startIfNeeded() {
        guard LabMode.renderLog, !didStart else { return }
        didStart = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            logCensus()
        }

        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            logCensus()
            logCounters()
        }
        // Keep firing during tracking-mode event loops (menu tracking, etc.).
        RunLoop.main.add(timer, forMode: .common)
        censusTimer = timer

        LoggingService.shared.log("RenderInstrumentation: CUW_RENDER_LOG enabled")
    }

    static func logCensus() {
        guard LabMode.renderLog else { return }
        let windows = NSApp.windows
        LoggingService.shared.log("LabCensus: count=\(windows.count)")
        for window in windows {
            let className = NSStringFromClass(type(of: window))
            let frame = NSStringFromRect(window.frame)
            LoggingService.shared.log(
                "LabCensus: class=\(className) frame=\(frame) level=\(window.level.rawValue) isVisible=\(window.isVisible) windowNumber=\(window.windowNumber)"
            )
        }
    }

    static func logCounters() {
        guard LabMode.renderLog else { return }
        LoggingService.shared.log(
            "LabCounters: updateMultiProfileButtons=\(updateMultiProfileButtonsCalls) tileRenders=\(tileRenders) setButtonImage=\(setButtonImageAssignments) strandedTileDetected=\(strandedTileEvaluations)"
        )
    }
}
