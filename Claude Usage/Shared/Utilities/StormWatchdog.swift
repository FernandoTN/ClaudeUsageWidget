//
//  StormWatchdog.swift
//  Claude Usage
//
//  Self-census guardrail from the 2026-07-29 storm investigation: the
//  WindowServer↔AppKit tracking-area feedback loop burned 15-25% CPU for
//  days across multiple "fixed" builds because nothing watched the app's own
//  idle cost. This watchdog samples the process's CPU time every 2 minutes;
//  sustained burn while the UI is nominally idle is logged loudly and
//  surfaced via a user notification — promptly at each new EPISODE (45-min
//  first-notify floor + 20-min cumulative suppressed-burn override), re-posted
//  on a 6h backoff while one already-notified episode persists (a 6.5-day
//  process once burned for hours after its single per-launch notification
//  was spent, silently; the GLOBAL 6h floor that replaced it then compressed
//  8 hot-burn runs/22h into 3 notifications on 2026-08-07, leaving the day's
//  worst episode silent for 2h52m at 8-11% burn).
//
//  2026-09-05: the alarm fired 270 times overnight on a burn that was the
//  app's OWN work (a 55 MB-per-sweep rollout read, PR #160), and told the
//  user to quit for a WindowServer storm that was not there. The decision
//  logic now lives in `StormWatchdogPolicy` (pure, tested), the threshold is
//  re-baselined against the measured idle cost, and the notification names
//  the measured value and prescribes quitting ONLY when the storm signature
//  — the window population growing during the episode — is actually seen.
//

import AppKit
import UserNotifications

// MARK: - Policy (pure)

/// The watchdog's decisions — threshold, strikes, episodes, the notification
/// gates — as a value the timer feeds one sample at a time, so the logic is
/// testable against a synthetic tick stream. `StormWatchdog` performs what
/// it decides (log, remediate, notify).
struct StormWatchdogPolicy {
    /// Fraction of one core considered pathological while idle.
    ///
    /// History, all 2026-07-29: 12% was arithmetically unreachable (the
    /// post-remap storm cost 8-11%) and the watchdog stayed silent through a
    /// full evening storm; 6% caught every storm observed with 14 per-profile
    /// tiles; composite provider-group tiles then cut the wedged-state cost to
    /// ~2% (42 scene windows → 9), so 1.5% was chosen above a 0.0% measured
    /// idle. That baseline was measured with no sweep cost visible; the app's
    /// legitimate steady state is a 30 s sweep of ~8 network fetches, the
    /// telemetry slices and a repaint, and at 1.5% the alarm fired 270 times
    /// overnight on 2026-09-04/05 against the app's own work. Re-baselined
    /// 2026-09-05 after PR #160: `measuredIdleBaseline` below is the measured
    /// idle average, and the threshold sits at 3× it.
    static let defaultBurnThreshold = 0.045
    /// The idle average the threshold was derived from (fraction of a core):
    /// 1.5% — 0.9 s of CPU per 60 s wall, measured 2026-09-05 10:22 on the
    /// deployed #160 build (pid 91164, 23 profiles, 30 s sweep, no
    /// interactive Codex daemon running). Named in the log line so the reader
    /// sees what "high" is relative to.
    static let measuredIdleBaseline = 0.015

    var burnThreshold = defaultBurnThreshold
    /// Consecutive hot samples before the episode opens (3 × interval = 6 min).
    var hotSamplesBeforeAlarm = 3
    var interval: TimeInterval = 120
    /// While ONE already-notified episode persists unremediated, re-post on
    /// this backoff (same identifier — replaces, never stacks). Since
    /// 2026-08-07 this gates ONLY intra-episode re-posts.
    var renotifyInterval: TimeInterval = 6 * 3600
    /// Global floor between ANY notification and the FIRST notification of a
    /// NEW episode. 45 min absorbs the worst REAL flap cadence ever measured
    /// (3 episode opens in 54 min) while restoring minutes-scale latency:
    /// simulated on the real 2026-08-07 tick stream this posts 7
    /// notifications (vs 3 under a global 6h floor) and alerts the worst
    /// episode six minutes into its burn (vs 2h52m).
    var firstNotifyFloor: TimeInterval = 45 * 60
    /// Cumulative suppressed-burn override: while the current episode is
    /// un-notified, every idle-attributed hot sample banks its wall interval
    /// (clamped to 2× the nominal interval — a clamshell sleep must not fill
    /// the bank from one tick); at ≥ 20 min of banked burn the first-of-episode
    /// notification fires regardless of the floor. Drained only by a post, so
    /// floor-blocked micro-episodes accumulate toward it.
    var cumulativeOverrideBurn: TimeInterval = 20 * 60
    /// Hot samples tolerated while the UI reports "open" before the pause is
    /// overridden (30 min): a stranded-visible window otherwise disarms the
    /// watchdog through an entire storm.
    var maxPausedHotSamples = 15

    /// One tick: the process's CPU share over `wall`, whether the UI was
    /// nominally idle, and the window population — the storm signature's
    /// inputs.
    struct Sample: Equatable {
        var usage: Double
        var wall: TimeInterval
        var uiIdle: Bool
        var windows: Int
        var trackingAreas: Int
        var now: Date
    }

    /// The WindowServer-storm signature: the window population GREW while the
    /// episode ran idle. The 2026-07-29 storm accreted windows (9 → 11) and
    /// leaked tracking areas; the app's own work (a sweep, a scan, a decode)
    /// changes neither. Without it, "quit and relaunch" is a guess.
    struct Signature: Equatable {
        var windowsAtOpen: Int
        var windowsNow: Int
        var trackingAreasAtOpen: Int
        var trackingAreasNow: Int
        var detected: Bool { windowsNow > windowsAtOpen || trackingAreasNow > trackingAreasAtOpen }
    }

    struct Notice: Equatable {
        var isFirstForEpisode: Bool
        var gate: String
        /// Mean CPU share over the current run of hot samples.
        var measuredUsage: Double
        /// Wall time that mean covers.
        var measuredOver: TimeInterval
        var episodeAge: TimeInterval
        var signature: Signature
    }

    enum Verdict: Equatable {
        /// Below the threshold. `episodeEnded` on the third clean sample of
        /// an open episode: remediation and notification are re-armed.
        case clean(episodeEnded: Bool)
        /// Hot, but the UI is open: paused, not counted (until the override).
        case pausedHot(paused: Int)
        /// Hot and idle, strike `streak` of `hotSamplesBeforeAlarm`.
        case hot(streak: Int)
        /// The strike bar was reached and the episode is open: one in-place
        /// remediation is attempted, with one interval to prove itself.
        case remediate
        /// Remediation did not clear it and a notification gate is open.
        case notify(Notice)
        /// Still burning past the bar, every gate closed.
        case gated(String)
    }

    private(set) var consecutiveHotSamples = 0
    private(set) var consecutiveCleanSamples = 0
    private(set) var pausedHotSamples = 0
    /// True when the last sample's pause was overridden (stranded window).
    private(set) var didOverridePause = false
    private(set) var episodeStartedAt: Date?
    private(set) var didRemediateThisEpisode = false
    private(set) var didNotifyThisEpisode = false
    private(set) var lastNotifiedAt: Date = .distantPast
    private(set) var suppressedBurn: TimeInterval = 0
    private var runUsageSeconds: Double = 0
    private var runWall: TimeInterval = 0
    private var windowsAtEpisodeOpen = 0
    private var trackingAreasAtEpisodeOpen = 0

    init(burnThreshold: Double = StormWatchdogPolicy.defaultBurnThreshold) {
        self.burnThreshold = burnThreshold
    }

    mutating func observe(_ sample: Sample) -> Verdict {
        didOverridePause = false
        guard sample.usage >= burnThreshold else {
            consecutiveHotSamples = 0
            pausedHotSamples = 0
            runUsageSeconds = 0
            runWall = 0
            consecutiveCleanSamples += 1
            if consecutiveCleanSamples >= 3,
               episodeStartedAt != nil || didRemediateThisEpisode || didNotifyThisEpisode {
                episodeStartedAt = nil
                didRemediateThisEpisode = false
                didNotifyThisEpisode = false
                return .clean(episodeEnded: true)
            }
            return .clean(episodeEnded: false)
        }
        consecutiveCleanSamples = 0

        if !sample.uiIdle {
            pausedHotSamples += 1
            if pausedHotSamples < maxPausedHotSamples {
                // Hot but the user has UI open: PAUSE rather than reset — brief
                // foreground activity must not erase the hot history of a
                // storm that keeps burning underneath it.
                return .pausedHot(paused: pausedHotSamples)
            }
            // A window has been "open" through 30 minutes of continuous burn —
            // that is the stranded-window failure mode, not a user session.
            didOverridePause = true
        } else {
            pausedHotSamples = 0
        }

        if !didNotifyThisEpisode {
            suppressedBurn += min(sample.wall, 2 * interval)
        }
        consecutiveHotSamples += 1
        runUsageSeconds += sample.usage * sample.wall
        runWall += sample.wall
        guard consecutiveHotSamples >= hotSamplesBeforeAlarm else {
            return .hot(streak: consecutiveHotSamples)
        }

        if episodeStartedAt == nil {
            episodeStartedAt = sample.now.addingTimeInterval(-TimeInterval(hotSamplesBeforeAlarm) * interval)
            windowsAtEpisodeOpen = sample.windows
            trackingAreasAtEpisodeOpen = sample.trackingAreas
        }

        // One cheap self-heal attempt per episode (render-cache repaint), with
        // a single sample interval to prove itself before alarming.
        if !didRemediateThisEpisode {
            didRemediateThisEpisode = true
            consecutiveHotSamples = hotSamplesBeforeAlarm - 1
            return .remediate
        }

        // Hybrid gate (2026-08-07 policy analysis): first-of-episode passes
        // the 45-min global floor or the 20-min cumulative override; a
        // re-post inside an already-notified episode waits the 6h backoff.
        let sinceLast = sample.now.timeIntervalSince(lastNotifiedAt)
        let gate: String
        if didNotifyThisEpisode {
            guard sinceLast >= renotifyInterval else {
                return .gated("6h intra-episode re-post backoff (\(Int(sinceLast / 60)) min since the last post)")
            }
            gate = "6h intra-episode re-post backoff elapsed"
        } else if sinceLast >= firstNotifyFloor {
            gate = "first-of-episode, 45-min floor clear"
        } else if suppressedBurn >= cumulativeOverrideBurn {
            gate = "first-of-episode, cumulative override (\(Int(suppressedBurn / 60)) min suppressed burn)"
        } else {
            return .gated("first-of-episode floor (\(Int(sinceLast / 60)) min since the last post, \(Int(suppressedBurn / 60)) min banked)")
        }
        let notice = Notice(
            isFirstForEpisode: !didNotifyThisEpisode,
            gate: gate,
            measuredUsage: runWall > 0 ? runUsageSeconds / runWall : sample.usage,
            measuredOver: runWall,
            episodeAge: episodeStartedAt.map { sample.now.timeIntervalSince($0) } ?? 0,
            signature: Signature(
                windowsAtOpen: windowsAtEpisodeOpen, windowsNow: sample.windows,
                trackingAreasAtOpen: trackingAreasAtEpisodeOpen, trackingAreasNow: sample.trackingAreas
            )
        )
        didNotifyThisEpisode = true
        lastNotifiedAt = sample.now
        suppressedBurn = 0
        return .notify(notice)
    }

    // MARK: Alarm text

    /// The user-facing body: the measured value first, the threshold it is
    /// judged against, and quit advice ONLY behind the storm signature.
    static func alarmBody(for notice: Notice, threshold: Double) -> String {
        let measured = String(format: "%.1f", notice.measuredUsage * 100)
        let over = max(1, Int((notice.measuredOver / 60).rounded()))
        let limit = String(format: "%.1f", threshold * 100)
        let lead = notice.isFirstForEpisode
            ? "The widget averaged \(measured)% of a core over the last \(over) min while idle (alarm threshold \(limit)%)."
            : "Still averaging \(measured)% of a core after ~\(Int((notice.episodeAge / 3600).rounded())) h (alarm threshold \(limit)%)."
        let s = notice.signature
        if s.detected {
            return lead + " The window population grew during this episode (\(s.windowsAtOpen) → \(s.windowsNow) windows, \(s.trackingAreasAtOpen) → \(s.trackingAreasNow) tracking areas): the WindowServer storm signature. Quit the widget, wait ~2 minutes, then relaunch — an immediate relaunch re-inherits the OS-side wedge."
        }
        return lead + " No WindowServer storm signature (\(s.windowsNow) windows, unchanged), so the cost is inside the app's own work: nothing to quit for. Logs were captured for diagnosis."
    }
}

// MARK: - Watchdog (timer + effects)

final class StormWatchdog {
    static let shared = StormWatchdog()

    private static let interval: TimeInterval = 120

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

    private var policy = StormWatchdogPolicy()
    private var timer: Timer?
    private var observerToken: NSObjectProtocol?
    private var lastCPUTime: TimeInterval = 0
    private var lastSampleAt: Date?
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
        let sample = StormWatchdogPolicy.Sample(
            usage: (cpu - lastCPUTime) / wall,
            wall: wall,
            uiIdle: isNominallyIdle(),
            windows: NSApp.windows.count,
            trackingAreas: Self.trackingAreaCount(),
            now: now
        )
        let verdict = policy.observe(sample)
        let percent = String(format: "%.1f", sample.usage * 100)
        if policy.didOverridePause {
            LoggingService.shared.logWarning(
                "StormWatchdog: pause override — hot for \(policy.pausedHotSamples) samples with UI reported open (stranded window?); treating as idle burn")
        }

        switch verdict {
        case .clean(let ended):
            if ended {
                manualStage = 0
                LoggingService.shared.log(
                    "StormWatchdog: storm episode ended (3 clean samples) — remediation and notification re-armed"
                        + (policy.suppressedBurn > 0 ? "; \(Int(policy.suppressedBurn / 60)) min suppressed burn carries toward the cumulative override" : ""))
            }
        case .pausedHot(let paused):
            LoggingService.shared.log(
                "StormWatchdog: hot sample (\(percent)%) while UI open — pausing (\(paused)/\(policy.maxPausedHotSamples) before override; hot streak \(policy.consecutiveHotSamples)/\(policy.hotSamplesBeforeAlarm))")
        case .hot(let streak):
            logHot(sample, percent: percent, streak: streak)
        case .remediate:
            logHot(sample, percent: percent, streak: policy.hotSamplesBeforeAlarm)
            LoggingService.shared.logWarning("StormWatchdog: episode opened — attempting the one in-place remediation (render-cache repaint) before alarming")
            remediate(0)
        case .gated(let reason):
            logHot(sample, percent: percent, streak: policy.hotSamplesBeforeAlarm)
            LoggingService.shared.log("StormWatchdog: alarm gated — \(reason)")
        case .notify(let notice):
            logHot(sample, percent: percent, streak: policy.hotSamplesBeforeAlarm)
            post(notice)
        }
    }

    private func logHot(_ sample: StormWatchdogPolicy.Sample, percent: String, streak: Int) {
        LoggingService.shared.logWarning(
            "StormWatchdog: idle CPU \(percent)% of a core over \(Int(sample.wall))s (\(streak)/\(policy.hotSamplesBeforeAlarm); threshold \(String(format: "%.1f", policy.burnThreshold * 100))%); windows=\(sample.windows) trackingAreas=\(sample.trackingAreas) [\(Self.windowCensus())]"
        )
    }

    private func post(_ notice: StormWatchdogPolicy.Notice) {
        let s = notice.signature
        LoggingService.shared.logError(
            "StormWatchdog: SUSTAINED idle burn — \(String(format: "%.1f", notice.measuredUsage * 100))% of a core over \(Int(notice.measuredOver / 60)) min (threshold \(String(format: "%.1f", policy.burnThreshold * 100))%, measured baseline \(String(format: "%.1f", StormWatchdogPolicy.measuredIdleBaseline * 100))%; episode ~\(String(format: "%.1f", notice.episodeAge / 3600))h old; \(notice.gate)) — storm signature \(s.detected ? "DETECTED" : "absent") (windows \(s.windowsAtOpen)→\(s.windowsNow), tracking areas \(s.trackingAreasAtOpen)→\(s.trackingAreasNow)); in-place remediation did not clear it"
        )
        NotificationManager.shared.sendStormWatchdogNotification(
            body: StormWatchdogPolicy.alarmBody(for: notice, threshold: policy.burnThreshold)
        )
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

    /// Tracking areas across every window's view tree — the other half of the
    /// storm signature (the 2026-07-29 loop churned them).
    private static func trackingAreaCount() -> Int {
        func count(_ view: NSView) -> Int {
            view.trackingAreas.count + view.subviews.reduce(0) { $0 + count($1) }
        }
        return NSApp.windows.reduce(0) { $0 + ($1.contentView.map(count) ?? 0) }
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
