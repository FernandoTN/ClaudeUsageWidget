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
    private static let burnThreshold = 0.12
    /// Consecutive hot samples before alarming (3 × interval = 6 minutes).
    private static let hotSamplesBeforeAlarm = 3
    private static let interval: TimeInterval = 120

    /// Closed-state provider: returns true when no popover/settings window is
    /// open (i.e. the app SHOULD be idle). Injected by MenuBarManager.
    var isNominallyIdle: () -> Bool = { true }

    private var timer: Timer?
    private var lastCPUTime: TimeInterval = 0
    private var lastSampleAt: Date?
    private var consecutiveHotSamples = 0
    private var didNotifyThisLaunch = false

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
    }

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

        guard isNominallyIdle(), usage >= Self.burnThreshold else {
            consecutiveHotSamples = 0
            return
        }
        consecutiveHotSamples += 1
        LoggingService.shared.logWarning(
            "StormWatchdog: idle CPU \(Int(usage * 100))% of a core over \(Int(wall))s (\(consecutiveHotSamples)/\(Self.hotSamplesBeforeAlarm)); windows=\(NSApp.windows.count)"
        )
        guard consecutiveHotSamples >= Self.hotSamplesBeforeAlarm, !didNotifyThisLaunch else { return }
        didNotifyThisLaunch = true
        LoggingService.shared.logError(
            "StormWatchdog: SUSTAINED idle burn ≥\(Int(Self.burnThreshold * 100))% for \(Self.hotSamplesBeforeAlarm) samples — likely tracking-area/WindowServer storm. Capture `sample` + occlusion log rate, then relaunch."
        )
        let content = UNMutableNotificationContent()
        content.title = "Claude Usage: high idle CPU"
        content.body = "The widget has been burning CPU in the background for ~6 minutes. A relaunch clears it; logs were captured for diagnosis."
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
