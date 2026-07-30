//
//  StormWatchdog.swift
//  Claude Usage
//
//  Self-census guardrail from the 2026-07-29 storm investigation: the
//  WindowServer↔AppKit tracking-area feedback loop burned 15-25% CPU for
//  days across multiple "fixed" builds because nothing watched the app's own
//  idle cost. This watchdog samples the process's CPU time every 2 minutes;
//  sustained burn while the UI is nominally idle is logged loudly (and
//  surfaced once per launch via a user notification) so a regression of this
//  failure class is visible within minutes, not days.
//

import AppKit
import UserNotifications

final class StormWatchdog {
    static let shared = StormWatchdog()

    /// Fraction of one core considered pathological while idle.
    ///
    /// History, all 2026-07-29: 12% was arithmetically unreachable (the
    /// post-remap storm cost 8-11%) and the watchdog stayed silent through a
    /// full evening storm; 6% caught every storm observed with 14 per-profile
    /// tiles. COMPOSITE provider-group tiles then cut the wedged-state cost to
    /// ~2% by construction (42 scene windows → 9) — which puts the storm BACK
    /// UNDER the threshold and re-silences the tripwire. 1.5% sits above the
    /// measured idle baseline (0.0% healthy, sweeps invisible over a 2-minute
    /// window) and below the projected composite storm cost. The alarm is
    /// cheap when wrong: three consecutive idle-gated hot samples, a log line,
    /// and at most one notification per launch.
    private static let burnThreshold = 0.015
    /// Consecutive hot samples before alarming (3 × interval = 6 minutes).
    private static let hotSamplesBeforeAlarm = 3
    private static let interval: TimeInterval = 120

    /// Closed-state provider: returns true when no popover/settings window is
    /// open (i.e. the app SHOULD be idle). Injected by MenuBarManager.
    var isNominallyIdle: () -> Bool = { true }

    /// Staged in-place remediation, injected by MenuBarManager.
    /// Stage 0: cheap — clear render caches + full repaint.
    /// Stage 1: cycle every tile's `isVisible` off→on across a runloop turn
    ///          (forces the scene layer to re-establish; costs one scene
    ///          re-registration per tile — bounded, vs an endless storm).
    /// Called on sustained burn; the user notification only fires if the burn
    /// survives BOTH stages (each verified over the following sample).
    var remediate: (Int) -> Void = { _ in }

    private var timer: Timer?
    private var lastCPUTime: TimeInterval = 0
    private var lastSampleAt: Date?
    private var consecutiveHotSamples = 0
    private var consecutiveCleanSamples = 0
    private var didNotifyThisLaunch = false
    private var remediationStage = 0

    private init() {}

    func start() {
        guard timer == nil else { return }
        lastCPUTime = Self.processCPUSeconds()
        lastSampleAt = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        timer.tolerance = Self.interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Manual trigger for live-storm experiments (post with
        // deliverImmediately:true — accessory apps queue plain posts):
        //   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.claudeusagewidget.remediate"), object: nil, userInfo: nil, deliverImmediately: true)'
        // Debounced: queued duplicate deliveries once consumed two stages 3ms
        // apart, exhausting the ladder without a verification gap.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.claudeusagewidget.remediate"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastManualTrigger) > 5 else { return }
            self.lastManualTrigger = now
            LoggingService.shared.logWarning("StormWatchdog: manual remediation trigger (stage \(self.remediationStage))")
            self.remediate(self.remediationStage)
            self.remediationStage += 1
        }
    }

    private var lastManualTrigger: Date = .distantPast

    private func sample() {
        let now = Date()
        let cpu = Self.processCPUSeconds()
        defer {
            lastCPUTime = cpu
            lastSampleAt = now
        }
        guard let lastSampleAt else { return }
        let wall = now.timeIntervalSince(lastSampleAt)
        guard wall > 0 else { return }
        let usage = (cpu - lastCPUTime) / wall

        guard usage >= Self.burnThreshold else {
            // A clean sample re-arms the remediation ladder: a storm that was
            // cleared (or ended) should get fresh stage-0/1 attempts next time
            // instead of jumping straight to the notification.
            consecutiveCleanSamples += 1
            if consecutiveCleanSamples >= 3, remediationStage != 0 {
                remediationStage = 0
                LoggingService.shared.log("StormWatchdog: re-armed remediation ladder after 3 clean samples")
            }
            consecutiveHotSamples = 0
            return
        }
        consecutiveCleanSamples = 0
        guard isNominallyIdle() else {
            // Hot but the user has UI open: PAUSE rather than reset (Codex
            // consult) — brief foreground activity must not erase the hot
            // history of a storm that keeps burning underneath it.
            LoggingService.shared.log(
                "StormWatchdog: hot sample (\(Int(usage * 100))%) while UI open — pausing (hot streak \(consecutiveHotSamples)/\(Self.hotSamplesBeforeAlarm))")
            return
        }
        consecutiveHotSamples += 1
        LoggingService.shared.logWarning(
            "StormWatchdog: idle CPU \(Int(usage * 100))% of a core over \(Int(wall))s (\(consecutiveHotSamples)/\(Self.hotSamplesBeforeAlarm)); windows=\(NSApp.windows.count)"
        )
        guard consecutiveHotSamples >= Self.hotSamplesBeforeAlarm else { return }

        // Self-heal before alarming: try the next remediation stage and give
        // it one sample interval to prove itself (a successful stage resets
        // the hot counter via the guard above on the next sample).
        if remediationStage < 2 {
            LoggingService.shared.logWarning("StormWatchdog: attempting remediation stage \(remediationStage)")
            remediate(remediationStage)
            remediationStage += 1
            consecutiveHotSamples = 0
            return
        }

        guard !didNotifyThisLaunch else { return }
        didNotifyThisLaunch = true
        LoggingService.shared.logError(
            "StormWatchdog: SUSTAINED idle burn ≥\(Int(Self.burnThreshold * 100))% for \(Self.hotSamplesBeforeAlarm) samples — likely tracking-area/WindowServer storm. Capture `sample` + occlusion log rate, then relaunch."
        )
        let content = UNMutableNotificationContent()
        content.title = "Claude Usage: high idle CPU"
        content.body = "The widget has sustained background CPU burn and self-healing did not clear it. Quit it, wait ~2 minutes, then relaunch — an immediate relaunch re-inherits the OS-side wedge. Logs were captured for diagnosis."
        let request = UNNotificationRequest(
            identifier: "storm-watchdog",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Total user+system CPU seconds consumed by this process.
    private static func processCPUSeconds() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }
}
