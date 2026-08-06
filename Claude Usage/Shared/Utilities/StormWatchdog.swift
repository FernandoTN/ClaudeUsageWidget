//
//  StormWatchdog.swift
//  Claude Usage
//
//  Self-census guardrail from the 2026-07-29 storm investigation: the
//  WindowServer↔AppKit tracking-area feedback loop burned 15-25% CPU for
//  days across multiple "fixed" builds because nothing watched the app's own
//  idle cost. This watchdog samples the process's CPU time every 2 minutes;
//  sustained burn while the UI is nominally idle is logged loudly and
//  surfaced via a user notification — once per storm EPISODE, re-posted on a
//  long backoff while the storm persists (a 6.5-day process once burned for
//  hours after its single per-launch notification was spent, silently).
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
    /// window) and below the projected composite storm cost.
    private static let burnThreshold = 0.015
    /// Consecutive hot samples before alarming (3 × interval = 6 minutes).
    private static let hotSamplesBeforeAlarm = 3
    private static let interval: TimeInterval = 120
    /// While a storm persists unremediated, re-post the notification on this
    /// backoff (same identifier — replaces, never stacks). The 2026-08-06
    /// storm burned all night behind a spent once-per-launch notification.
    private static let renotifyInterval: TimeInterval = 6 * 3600
    /// Hot samples tolerated while the UI reports "open" before the pause is
    /// overridden. A stranded-visible window (2026-07-29: a minimized-orphan
    /// settings window; also any detached popover panel left open) otherwise
    /// disarms the watchdog through an entire storm.
    private static let maxPausedHotSamples = 15 // 30 minutes

    /// Closed-state provider: returns true when no popover/settings window is
    /// open (i.e. the app SHOULD be idle). Injected by MenuBarManager.
    var isNominallyIdle: () -> Bool = { true }

    /// In-place remediation, injected by MenuBarManager.
    /// Stage 0: cheap — clear render caches + full repaint.
    /// Stage 1: cycle every tile's `isVisible` off→on. FALSIFIED as a storm
    ///          cure (E3 + live 2026-08-06: fired and the burn continued) and
    ///          it re-registers every tile's scene — the CAContext-leaking
    ///          operation class the remap invariant exists to avoid. The
    ///          automatic ladder therefore never calls it; it remains
    ///          reachable only from the manual distributed-notification
    ///          trigger for live-storm experiments.
    var remediate: (Int) -> Void = { _ in }

    private var timer: Timer?
    private var observerToken: NSObjectProtocol?
    private var lastCPUTime: TimeInterval = 0
    private var lastSampleAt: Date?
    private var consecutiveHotSamples = 0
    private var consecutiveCleanSamples = 0
    private var pausedHotSamples = 0
    /// Episode state: an episode opens at the first sustained-burn alarm and
    /// closes after 3 consecutive clean samples. Each episode gets one
    /// remediation attempt and its own notification; closing re-arms both, so
    /// a second storm days into the same launch is never silent.
    private var episodeStartedAt: Date?
    private var didRemediateThisEpisode = false
    private var didNotifyThisEpisode = false
    private var lastNotifiedAt: Date = .distantPast
    private var manualStage = 0
    private var lastManualTrigger: Date = .distantPast

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
        // apart. First trigger runs stage 0; repeats run stage 1 (clamped —
        // it must never walk past the defined stages).
        observerToken = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.claudeusagewidget.remediate"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastManualTrigger) > 5 else { return }
            self.lastManualTrigger = now
            let stage = min(self.manualStage, 1)
            LoggingService.shared.logWarning(
                "StormWatchdog: manual remediation trigger (stage \(stage))"
                    + (stage >= 1 ? " — stage 1 re-registers every tile scene (permanent CAContext cost) and is falsified as a cure" : ""))
            self.remediate(stage)
            self.manualStage = min(self.manualStage + 1, 1)
        }
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

        guard usage >= Self.burnThreshold else {
            consecutiveHotSamples = 0
            pausedHotSamples = 0
            consecutiveCleanSamples += 1
            if consecutiveCleanSamples >= 3,
               episodeStartedAt != nil || didRemediateThisEpisode || didNotifyThisEpisode {
                episodeStartedAt = nil
                didRemediateThisEpisode = false
                didNotifyThisEpisode = false
                manualStage = 0
                LoggingService.shared.log(
                    "StormWatchdog: storm episode ended (3 clean samples) — remediation and notification re-armed")
            }
            return
        }
        consecutiveCleanSamples = 0

        if !isNominallyIdle() {
            pausedHotSamples += 1
            if pausedHotSamples < Self.maxPausedHotSamples {
                // Hot but the user has UI open: PAUSE rather than reset (Codex
                // consult) — brief foreground activity must not erase the hot
                // history of a storm that keeps burning underneath it.
                LoggingService.shared.log(
                    "StormWatchdog: hot sample (\(Int(usage * 100))%) while UI open — pausing (\(pausedHotSamples)/\(Self.maxPausedHotSamples) before override; hot streak \(consecutiveHotSamples)/\(Self.hotSamplesBeforeAlarm))")
                return
            }
            // A window has been "open" through 30 minutes of continuous burn —
            // that is the stranded-window failure mode, not a user session.
            LoggingService.shared.logWarning(
                "StormWatchdog: pause override — hot for \(pausedHotSamples) samples with UI reported open (stranded window?); treating as idle burn")
        } else {
            pausedHotSamples = 0
        }

        consecutiveHotSamples += 1
        LoggingService.shared.logWarning(
            "StormWatchdog: idle CPU \(Int(usage * 100))% of a core over \(Int(wall))s (\(consecutiveHotSamples)/\(Self.hotSamplesBeforeAlarm)); windows=\(NSApp.windows.count)"
        )
        guard consecutiveHotSamples >= Self.hotSamplesBeforeAlarm else { return }

        if episodeStartedAt == nil {
            episodeStartedAt = now.addingTimeInterval(-TimeInterval(Self.hotSamplesBeforeAlarm) * Self.interval)
            LoggingService.shared.logWarning("StormWatchdog: storm episode opened")
        }

        // One cheap self-heal attempt per episode (render-cache repaint), with
        // a single sample interval to prove itself before alarming. The old
        // ladder required 3 fresh hot samples per rung and included the
        // falsified tile-visibility cycle — a live storm once took 4.8 hours
        // to walk from stage 0 to stage 1, all of it silent.
        if !didRemediateThisEpisode {
            didRemediateThisEpisode = true
            LoggingService.shared.logWarning("StormWatchdog: attempting remediation (render-cache repaint)")
            remediate(0)
            consecutiveHotSamples = Self.hotSamplesBeforeAlarm - 1
            return
        }

        notifyIfDue(now: now)
    }

    private func notifyIfDue(now: Date) {
        // GLOBAL 6h floor between notifications, including the first of a new
        // episode: an episode-scoped bypass let a threshold-hovering storm
        // (3 clean samples close the episode, the next hot run reopens it)
        // notify every ~14 minutes (Codex review). A recurrence within 6h is
        // the same ongoing problem — the cure (quit + gap + relaunch) hasn't
        // happened — so the floor costs nothing real.
        guard now.timeIntervalSince(lastNotifiedAt) >= Self.renotifyInterval else {
            return
        }
        let isFirstForEpisode = !didNotifyThisEpisode
        didNotifyThisEpisode = true
        lastNotifiedAt = now
        let burningHours = episodeStartedAt.map { now.timeIntervalSince($0) / 3600 } ?? 0
        LoggingService.shared.logError(
            "StormWatchdog: SUSTAINED idle burn ≥\(Self.burnThreshold * 100)% (storm ~\(String(format: "%.1f", burningHours))h old) — likely tracking-area/WindowServer storm; in-place remediation failed. The only known cure: quit, wait ~2 minutes off the bar, relaunch."
        )
        let content = UNMutableNotificationContent()
        content.title = "Claude Usage: high idle CPU"
        content.body = isFirstForEpisode
            ? "The widget has sustained background CPU burn and self-healing did not clear it. Quit it, wait ~2 minutes, then relaunch — an immediate relaunch re-inherits the OS-side wedge. Logs were captured for diagnosis."
            : "Still burning after ~\(Int(burningHours.rounded())) hours. Quit the widget, wait ~2 minutes, then relaunch — an immediate relaunch re-inherits the OS-side wedge."
        let request = UNNotificationRequest(
            identifier: "storm-watchdog",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DispatchQueue.main.async {
                    LoggingService.shared.logError(
                        "StormWatchdog: notification delivery failed (\(error.localizedDescription)) — storm alarm is log-only")
                }
            }
        }
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
