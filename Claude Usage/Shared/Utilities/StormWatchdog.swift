//
//  StormWatchdog.swift
//  Claude Usage
//
//  Self-census guardrail from the 2026-07-29 storm investigation: the
//  WindowServer↔AppKit tracking-area feedback loop burned 15-25% CPU for
//  days across multiple "fixed" builds because nothing watched the app's own
//  idle cost. This watchdog samples the process's CPU time every 2 minutes;
//  sustained burn while the UI is nominally idle is logged loudly and
//  surfaced via a user notification — promptly at each new storm EPISODE
//  (45-min first-notify floor + 20-min cumulative suppressed-burn override),
//  re-posted on a 6h backoff while one already-notified episode persists (a
//  6.5-day process once burned for hours after its single per-launch
//  notification was spent, silently; the GLOBAL 6h floor that replaced it
//  then compressed 8 hot-burn runs/22h into 3 notifications on 2026-08-07,
//  leaving the day's worst episode silent for 2h52m at 8-11% burn).
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
    /// While ONE already-notified episode persists unremediated, re-post on
    /// this backoff (same identifier — replaces, never stacks). The
    /// 2026-08-06 storm burned all night behind a spent once-per-launch
    /// notification. Since 2026-08-07 this interval gates ONLY intra-episode
    /// re-posts — the FIRST notification of a new episode is gated by
    /// `firstNotifyFloor` / `cumulativeOverrideBurn` below.
    private static let renotifyInterval: TimeInterval = 6 * 3600
    /// Global floor between ANY notification and the FIRST notification of a
    /// NEW episode. History: a floor-free per-episode bypass could flap
    /// every ~14 min under threshold hover (Codex review); the GLOBAL 6h
    /// floor that replaced it degraded per-episode alerting to once-per-6h
    /// under real storm weather (2026-08-07: 8 hot-burn runs in 22h → 3
    /// notifications; ep7 burned 8-11% for 2h52m before its floor-release
    /// alert at exactly lastNotified+6h). 45 min absorbs the worst REAL flap
    /// cadence ever measured (3 episode opens in 54 min, 8-min minimum
    /// end-to-reopen gap ≈ 20-min cycles) while restoring minutes-scale
    /// latency: simulated on the real 22h tick stream this policy posts 7
    /// notifications (vs 3) and alerts ep7 six minutes into its burn (vs
    /// 2h52m). True pathological ceiling (judge-corrected): minimum
    /// first-of-episode post spacing is 26 min (6-min episode close + 20-min
    /// bank refill) ≈ 55 posts/day ≈ 2.2/h — and each such post is backed by
    /// 20 min of banked ≥1.5% burn, i.e. it is signal, not flap; the classic
    /// 14-min hover shape (6-min hot cycles) actually produces ~0 posts,
    /// because 3-hot-sample runs never reach the notify gate at all.
    /// Replace-don't-stack keeps at most one banner pending. A 30-min floor
    /// was rejected: zero latency gain on the real day.
    private static let firstNotifyFloor: TimeInterval = 45 * 60
    /// Cumulative suppressed-burn override: while the current episode is
    /// un-notified, every idle-attributed hot sample banks its wall
    /// interval; at ≥20 min of banked burn the first-of-episode notification
    /// fires REGARDLESS of `firstNotifyFloor`. The accumulator carries
    /// across episode close (drained only by an actual post): on the real
    /// 2026-08-07 ledger ep5's eligible tick cleared the 45-min floor
    /// anyway — the override is the counterfactual guard for a follow-on
    /// episode opening INSIDE the floor, which would otherwise wait it out.
    /// The ~20-min bound holds for episodes that REACH the notify gate
    /// (≥4 hot samples ≈ ≥8-min runs); shorter runs (≤3 hot samples — the
    /// remediation tick consumes the 3rd) never reach notifyIfDue and bank
    /// without firing — a pre-existing reach limitation, unchanged here.
    /// (~2.4 banked core-minutes at the measured 8-11% burn,
    /// vs ~19.5 silent core-minutes under the 6h floor). Because only a
    /// posted notification drains it and accumulation stops once the episode
    /// is notified, it cannot drum through a continuous storm the way a
    /// cumulative-only policy would (~16 posts/day simulated at N=20): after
    /// the first post, the 6h `renotifyInterval` owns the episode.
    private static let cumulativeOverrideBurn: TimeInterval = 20 * 60
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
    /// Wall time banked by idle-attributed hot samples while the current
    /// episode is un-notified (pre-open streak-1/2 samples included — burn
    /// is burn). Drained ONLY by a posted notification; deliberately NOT
    /// reset on episode close, so floor-blocked micro-episodes accumulate
    /// toward `cumulativeOverrideBurn`. UI-open (paused) hot samples do not
    /// bank — they may be legitimate foreground work.
    private var suppressedBurn: TimeInterval = 0
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
                    "StormWatchdog: storm episode ended (3 clean samples) — remediation and notification re-armed"
                        + (suppressedBurn > 0 ? "; \(Int(suppressedBurn / 60)) min suppressed burn carries toward the cumulative override" : ""))
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

        if !didNotifyThisEpisode {
            // Clamp per-sample banking to 2× the nominal interval: a timer
            // suspension (ep5's 37-min clamshell sleep bridged one sample
            // across a 42-min wall gap) must not fill the 20-min bank from a
            // single tick — the bank means "minutes of observed hot samples",
            // not "wall time spanned by them".
            suppressedBurn += min(wall, 2 * Self.interval)
        }
        consecutiveHotSamples += 1
        LoggingService.shared.logWarning(
            "StormWatchdog: idle CPU \(Int(usage * 100))% of a core over \(Int(wall))s (\(consecutiveHotSamples)/\(Self.hotSamplesBeforeAlarm)); windows=\(NSApp.windows.count) [\(Self.windowCensus())]"
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
        // Hybrid gate (2026-08-07 policy analysis, simulated tick-by-tick
        // against the real 22h episode ledger):
        //  - FIRST notification of a NEW episode: 45-min global floor since
        //    ANY notification, overridden by ≥20 min cumulative suppressed
        //    burn. The previous GLOBAL 6h floor here — added because a
        //    floor-free bypass could flap every ~14 min under threshold
        //    hover — compressed 8 hot-burn runs/22h into 3 notifications and
        //    let ep7 burn 8-11% for 2h52m silently. This gate on the same
        //    day: 7 notifications, 6-min worst first-alert latency, ~20-min
        //    bound on suppressed burn for episodes that reach this gate,
        //    ~2.2/h true pathological ceiling (26-min min post spacing, each
        //    post backed by 20 min of banked burn; same-identifier
        //    replacement keeps at most one banner pending).
        //  - Re-post within an already-notified episode: unchanged 6h
        //    backoff — a recurrence there is "same storm, already reported";
        //    the cure (quit + ~2-min gap + relaunch) hasn't happened.
        let sinceLast = now.timeIntervalSince(lastNotifiedAt)
        let gate: String
        if didNotifyThisEpisode {
            guard sinceLast >= Self.renotifyInterval else { return }
            gate = "6h intra-episode re-post backoff elapsed"
        } else if sinceLast >= Self.firstNotifyFloor {
            gate = "first-of-episode, 45-min floor clear"
        } else if suppressedBurn >= Self.cumulativeOverrideBurn {
            gate = "first-of-episode, cumulative override (\(Int(suppressedBurn / 60)) min suppressed burn)"
        } else {
            return
        }
        let isFirstForEpisode = !didNotifyThisEpisode
        didNotifyThisEpisode = true
        lastNotifiedAt = now
        suppressedBurn = 0
        let burningHours = episodeStartedAt.map { now.timeIntervalSince($0) / 3600 } ?? 0
        LoggingService.shared.logError(
            "StormWatchdog: SUSTAINED idle burn ≥\(Self.burnThreshold * 100)% (storm ~\(String(format: "%.1f", burningHours))h old; \(gate)) — likely tracking-area/WindowServer storm; in-place remediation failed. The only known cure: quit, wait ~2 minutes off the bar, relaunch."
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

    /// Compact per-class window census for the hot-sample log line, e.g.
    /// "NSStatusBarWindow×9, _NSPopoverWindow·hidden×1". The old 6.5-day
    /// process accreted 9→11 windows and the bare count made the extras
    /// unidentifiable post-mortem — a stranded invisible _NSPopoverWindow is
    /// exactly the class this exposes in the moment.
    private static func windowCensus() -> String {
        var counts: [String: Int] = [:]
        for window in NSApp.windows {
            var name = NSStringFromClass(type(of: window))
            if !window.isVisible { name += "·hidden" }
            counts[name, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }
            .map { "\($0.key)×\($0.value)" }
            .joined(separator: ", ")
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
