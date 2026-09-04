import Cocoa
import SwiftUI
import Combine
import os.log

@MainActor
class MenuBarManager: NSObject, ObservableObject {
    private var statusBarUIManager: StatusBarUIManager?
    private var refreshTimer: Timer?
    @Published private(set) var usage: ClaudeUsage = .empty
    @Published private(set) var status: ClaudeStatus = .unknown
    @Published private(set) var isRefreshing: Bool = false

    // Error tracking for stale data / credential banners
    @Published private(set) var hasCredentialError: Bool = false
    // Profiles whose last fetch failed with a credential error (401 / expired
    // session key). The popover banner keys off the VIEWED profile's membership —
    // one account's dead login must not flag every account's popover.
    @Published private(set) var credentialErrorProfileIds: Set<UUID> = []
    @Published private(set) var consecutiveRefreshFailures: Int = 0
    @Published private(set) var lastRefreshError: String? = nil
    @Published private(set) var lastSuccessfulRefreshTime: Date? = nil

    // Multi-profile mode: track which profile's icon was clicked
    @Published private(set) var clickedProfileId: UUID?
    @Published private(set) var clickedProfileUsage: ClaudeUsage?

    /// What the last candidate preflight (or auto-switch walk) learned about
    /// each candidate's login, keyed by profile id. Before this existed the
    /// verdict was a log line only; the fleet-summary tile's `›Mem✓` affix
    /// and the dashboard read it (docs/specs/menubar-redesign.md §4).
    @Published private(set) var preflightVerdicts: [UUID: PreflightVerdict] = [:]

    // MARK: - ⇄ Active-account selector (UX revamp stage 1b)

    /// The per-provider ACTIVE selector (docs/specs/ux-revamp.md §2.1). Created
    /// once in `setup()` BEFORE the provider groups so it lands rightmost and
    /// survives their rebuilds; owned here, never by StatusBarUIManager; never
    /// torn down (`cleanup()` leaves it; the setting toggles `isVisible`).
    private var activeSelector: ActiveSelectorItem?

    /// The live manager, for Settings views that need the paint-time context
    /// (`buildActiveSelections`) — AppDelegate owns the instance; set in
    /// `setup()`. nil under XCTest / previews, where the inspector falls back
    /// to a context without candidate predictions.
    private(set) static weak var current: MenuBarManager?

    /// Read-only handle for the exposure probe (redesign stage C), so a hidden
    /// selector shows up in the same `Menu bar exposure` log line.
    var activeSelectorStatusItem: NSStatusItem? { activeSelector?.statusItem }

    /// Accounts the user activated by hand while over a threshold — the
    /// auto-switch will not leave them until they regain headroom. Read-only
    /// mirror of `autoSwitchedProfileIds` for the selector and the dashboard.
    var manuallyPinnedProfileIds: Set<UUID> { autoSwitchedProfileIds }

    /// The user un-pins a manually chosen active account (Settings › Active &
    /// Auto-switch, round-3 R7): the auto-switch may move it again on the next
    /// sweep. Nothing else changes — no switch, no pointer, no credentials.
    func clearManualPin(_ profileId: UUID) {
        guard autoSwitchedProfileIds.remove(profileId) != nil else { return }
        let name = profileManager.profiles.first { $0.id == profileId }?.name ?? profileId.uuidString
        LoggingService.shared.log("Pin cleared for '\(name)' by the user")
    }

    /// What the fleet dashboard observes: its snapshot — rebuilt ONCE per
    /// paint while a dashboard is showing (`rebuildDashboardSnapshot`), never
    /// row by row — and the provider group whose tile was clicked (the
    /// dashboard opens scrolled to it; independent of `clickedProfileId`,
    /// since a fleet tile has no per-account click target).
    let dashboardStore = DashboardStore()



    // Track when refresh was last triggered (for distinguishing user vs auto refresh)
    private var lastRefreshTriggerTime: Date = .distantPast

    // Popover for beautiful SwiftUI interface
    private var popover: NSPopover?

    // Event monitor for closing popover on outside click
    private var eventMonitor: Any?

    // Detached window reference (when popover is detached)
    private var detachedWindow: NSWindow?

    // Settings window reference
    private var settingsWindow: NSWindow?

    // Track which button is currently showing the popover. The dismiss
    // decision keys on the BUTTON only — any same-group click while open is
    // a dismiss; anchor rects are re-resolved from the clicked profile id at
    // show time, so no per-profile anchor state is kept here.
    private weak var currentPopoverButton: NSStatusBarButton?

    /// Re-open swallow stamp. The .semitransient popover auto-closes when a
    /// click lands on its own anchor button; the same click's action then
    /// arrives with the popover already closed and would re-open it, so a
    /// same-group click could never dismiss. Armed ONLY in popoverWillClose
    /// (close INITIATION, before the fade delivers didClose) and only when
    /// the pointer is on the anchor at that moment; consumed by the next
    /// same-button action within 0.5s.
    private weak var lastPopoverCloseButton: NSStatusBarButton?
    private var lastPopoverCloseTime: Date = .distantPast

    /// Storm-mode duplicate-delivery coalescing (forensics 2026-08-06).
    /// While a scene host is wedged (pointerLocalX == nil epochs) one
    /// physical click on a status button arrives as 2-5 independent action
    /// dispatches, 45-229ms apart (9 bursts mined; the 15:36:15 quintuple
    /// spans 517ms). The fastest DELIBERATE re-click in the mined window is
    /// 449ms, so a same-button action within 0.3s of the previous one is a
    /// re-delivery, not a click. The window SLIDES (re-arms on each
    /// suppression) — a fixed window can't work, since a burst's span (517ms)
    /// exceeds the genuine-click floor (449ms). `clickBurstStartUptime` caps
    /// continuous suppression at 1.5s so a pathological endless duplicate
    /// stream cannot eat deliberate clicks forever. Monotonic uptime, never
    /// Date() (wall-clock jumps must not open/close the window); weak button
    /// ref so composite rebuilds naturally invalidate the key. Distinct from
    /// the auto-close swallow stamp above: that consumes the dismiss-click's
    /// OWN action 9-43ms after willClose (previous ACTION is seconds
    /// earlier), this drops repeat deliveries of one action.
    /// Accepted residuals (wedge-state only, both theoretical — observed
    /// wedge re-clicks are seconds apart): (1) because the window slides
    /// from the LAST duplicate, a deliberate re-click up to ~830ms after a
    /// quintuple burst's physical click is coalesced; (2) after a
    /// swallow-consumed dismiss, a deliberate same-button reopen within
    /// 300ms is coalesced (previously it reopened).
    private weak var lastClickActionButton: NSStatusBarButton?
    private var lastClickActionUptime: TimeInterval = -.greatestFiniteMagnitude
    private var clickBurstStartUptime: TimeInterval = -.greatestFiniteMagnitude

    private let apiService = ClaudeAPIService()
    private let statusService = ClaudeStatusService()
    private let networkMonitor = NetworkMonitor.shared
    private let profileManager = ProfileManager.shared
    // Combine cancellables for profile observation
    private var cancellables = Set<AnyCancellable>()

    // Track if we've handled the first profile switch (to allow returning to initial profile)
    private var hasHandledFirstProfileSwitch = false

    // Track which profiles have already triggered auto-switch (prevents repeated firing)
    private var autoSwitchedProfileIds: Set<UUID> = []

    /// True while a candidate walk is running. Taken SYNCHRONOUSLY at the walk's
    /// entry — before the Task's first suspension — because the walk's own
    /// `isSwitchingProfile` re-check is only observed after an `await`, and the
    /// checks that start walks (mid-sweep for each provider-active account, again
    /// at sweep end, plus manual refresh) can fire while an earlier walk is parked
    /// in `fetchUsageForProfile`. Two live walks race into `activateProfile`, one
    /// of them is refused by the semaphore, and that refusal used to be recorded
    /// as dead credentials against a healthy candidate (audit H6).
    private var autoSwitchWalkInFlight = false

    /// When each background Claude profile last STARTED a usage fetch (in-memory;
    /// resets on relaunch). The scheduler ranks candidates by time since last
    /// attempt — not last success — so a profile whose fetch keeps failing cannot
    /// pin the top slot and starve the rest of the rotation.
    private var backgroundFetchAttempts: [UUID: Date] = [:]

    /// Last time `status.claude.com` was polled. Initialized to `.distantPast` so
    /// the first sweep after launch always fetches; subsequent polls wait for
    /// `statusPollInterval` (status is not usage-critical and need not ride every
    /// 30s sweep).
    private var lastStatusFetch: Date = .distantPast
    private let statusPollInterval: TimeInterval = 300

    /// One-shot log of the background-Claude staleness estimate for the current
    /// profile count (F4). Recomputed only at first multi-profile sweep of the run.
    private var hasLoggedBackgroundStalenessEstimate = false

    /// Coalesces the 2s retry scheduled while credential hydration is still
    /// `.loading` so overlapping timer/network triggers do not stack retries.
    private var credentialHydrationRetryScheduled = false

    // Observer for icon configuration changes
    private var iconConfigObserver: NSObjectProtocol?

    // Observer for credential changes (add, remove, update)
    private var credentialsObserver: NSObjectProtocol?
    private var manualActivationObserver: NSObjectProtocol?
    private var profileDeletedObserver: NSObjectProtocol?

    // Observer for display mode changes (single/multi profile) — legacy posters
    private var displayModeObserver: NSObjectProtocol?

    // Typed structural/cosmetic multi-profile display observers (Phase 1)
    private var displayStructureObserver: NSObjectProtocol?
    private var displayCosmeticsObserver: NSObjectProtocol?

    // Observer for screen/display changes (headless mode support)
    private var screenObserver: NSObjectProtocol?

    // Observer for wake-from-sleep
    private var wakeObserver: NSObjectProtocol?
    private var lastAutoRefreshTime: Date = .distantPast

    func setup() {
        // Idempotency: the headless screen-recovery path and AppDelegate's
        // delayed retry can call setup() again on a live manager. Without this
        // teardown, a second pass would orphan the whole status-item group
        // (leaking its scene CAContexts server-side) and duplicate every
        // timer/observer registered below (Codex consult 2026-07-29).
        if statusBarUIManager != nil {
            LoggingService.shared.logWarning("MenuBarManager: setup() re-entered — cleaning up prior state first")
            cleanup()
        }

        // The view-pinning predicate for automatic switches. ProfileManager
        // decides whether a sweep-driven switch may move the view; only this
        // class knows whether the user is working inside the Settings window,
        // so it supplies the answer rather than reaching for AppKit down there.
        profileManager.viewIsPinnedByOpenUI = { [weak self] in
            guard let self else { return false }
            if let settings = self.settingsWindow, settings.isKeyWindow || settings.attachedSheet != nil {
                return true
            }
            return NSApp.keyWindow?.attachedSheet != nil
        }

        // Owner decision 2026-09-04: an untouched config moves to the
        // redesigned default layout once, BEFORE the bar is set up so the
        // first paint already uses it.
        applyDefaultBarLayoutOnce()

        // Observe profile changes - CRITICAL: Set up before anything else
        observeProfileChanges()

        Self.current = self

        // Initialize status bar UI manager
        statusBarUIManager = StatusBarUIManager()
        statusBarUIManager?.delegate = self
        // The ⇄ selector shares the bar's fate: the exposure probe logs it
        // beside the provider groups (telemetry only).
        statusBarUIManager?.auxiliaryExposureItems = { [weak self] in
            self?.activeSelectorStatusItem.map { ["selector": $0] } ?? [:]
        }

        // Check if we should use multi-profile mode
        if profileManager.displayMode == .multi {
            // Multi-profile mode - setup with selected profiles
            setupMultiProfileMode()
        } else {
            // Single profile mode - setup with active profile's config
            let config = profileManager.activeProfile?.iconConfig ?? .default
            let hasUsageCredentials = profileManager.activeProfile?.hasUsageCredentials ?? false

            // If no usage credentials, create empty config to show default logo
            let displayConfig: MenuBarIconConfiguration
            if !hasUsageCredentials {
                displayConfig = MenuBarIconConfiguration(
                    colorMode: config.colorMode,
                    singleColorHex: config.singleColorHex,
                    showIconNames: config.showIconNames,
                    metrics: config.metrics.map { metric in
                        var updatedMetric = metric
                        updatedMetric.isEnabled = false
                        return updatedMetric
                    }
                )
            } else {
                displayConfig = config
            }

            statusBarUIManager?.setup(target: self, action: #selector(togglePopover), config: displayConfig)
        }

#if DEBUG
        startFrameRenderingIfRequested()
#endif

        // The ⇄ selector item is created AFTER the provider groups. Measured on
        // the deployed bar (2026-09-03, exposure probe): with the selector
        // created FIRST, the groups came up claude < grok < codex < ⇄ — the
        // opposite of the designed codex < grok < claude — and neither a
        // ≥ 2-minute quit nor fixed-length group items (#83) changed it, while
        // a fresh process with fixed-length items placed textbook. Creating it
        // last keeps the groups' order intact; the selector then sits at the
        // LEFT edge of the app's cluster and clips first on overflow — a
        // documented trade-off (spec §2.1). A later GROUP rebuild (a provider
        // appearing or disappearing — membership changes reuse the items) may
        // land new groups left of the selector; the probe's order= field is
        // the truth. Created once; setup() re-entry reuses it.
        installActiveSelectorIfNeeded()

        // The popover is created lazily on first click (ensurePopover) and
        // DESTROYED on close: a closed NSPopover keeps its borderless
        // _NSPopoverWindow alive off-screen forever, and every off-screen
        // window participates in AppKit's per-display-cycle tracking-area /
        // structural-region pass (the 2026-07-29 storm investigation found the
        // WindowServer↔AppKit feedback loop iterating exactly these windows).
        // The window population while idle should be status items only.

        // Load saved data from active profile first (provides immediate feedback)
        // BUT only if profile has usage credentials - CLI alone can't show usage
        if let profile = profileManager.activeProfile {
            if profile.hasUsageCredentials {
                // Profile has usage credentials - show saved usage data if available
                if let savedUsage = profile.claudeUsage {
                    usage = savedUsage
                }
            } else {
                // No usage credentials - clear any old usage data and show default logo
                usage = .empty
                LoggingService.shared.log("MenuBarManager: Profile has no usage credentials, showing default logo")
            }
            updateAllStatusBarIcons()
        }

        // Start network monitoring - fetch data when network is available
        networkMonitor.onNetworkAvailable = { [weak self] in
            // Only refresh if we haven't refreshed recently (avoid duplicate on startup)
            guard let self = self else { return }

            // The credential gate only applies to single-profile mode: in multi
            // mode refreshUsage() sweeps every selected profile, so the FOCUSED
            // profile's credentials are irrelevant (a credential-less focused
            // profile used to block the whole group's post-reconnect refresh).
            if self.profileManager.displayMode != .multi {
                // Skip if profile has no usage credentials (CLI alone can't be used)
                guard let profile = self.profileManager.activeProfile, profile.hasUsageCredentials else {
                    LoggingService.shared.log("Skipping network-available refresh (no usage credentials)")
                    return
                }
            }

            let timeSinceLastRefresh = Date().timeIntervalSince(self.lastRefreshTriggerTime)
            if timeSinceLastRefresh > 2.0 {  // At least 2 seconds since last refresh
                self.refreshUsage()
            } else {
                LoggingService.shared.log("Skipping network-available refresh (too soon after last refresh)")
            }
        }
        networkMonitor.startMonitoring()

        // Initial data fetch (with small delay for launch-at-login scenarios).
        // Single mode: only if the active profile has usage credentials (not
        // just CLI). Multi mode: always — the sweep covers every selected
        // profile regardless of the focused one's credentials.
        if profileManager.displayMode == .multi
            || (profileManager.activeProfile?.hasUsageCredentials ?? false) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.refreshUsage()
            }
        } else {
            LoggingService.shared.log("Skipping initial refresh (no usage credentials)")
        }

        // Start auto-refresh timer with active profile's interval
        startAutoRefresh()

        // Observe icon configuration changes
        observeIconConfigChanges()

        // Observe session key updates
        observeCredentialChanges()
        observeManualActivations()
        observeProfileDeletions()

        // Observe display mode changes (single/multi profile) + typed structure/cosmetics
        observeDisplayModeChanges()
        observeDisplayStructureChanges()
        observeDisplayCosmeticsChanges()

        // Setup headless mode observer if enabled (for Remote Desktop support)
        setupHeadlessModeObserver()

        // Setup wake-from-sleep observer for auto-refresh
        setupWakeObserver()

        // Setup global keyboard shortcuts
        setupShortcuts()

        #if DEBUG
        // Design-pass frame renders (docs/specs/ux-revamp.md §12): a Debug build
        // launched with CUW_RENDER_FRAMES=<dir> writes every surface as PNG.
        DesignFrameHarness.runIfRequested()
        #endif

        // Idle-burn guardrail: alarms (log + per-episode notification, re-posted
        // on a 6h backoff while the storm persists) when the app burns CPU with
        // no popover/settings open — the storm failure class. Stage 1 below is
        // reachable only from the manual trigger; the automatic path uses the
        // cheap repaint alone (the visibility cycle is falsified as a cure and
        // leaks CAContexts).
        StormWatchdog.shared.isNominallyIdle = {
            // Consult the ACTUAL window population, not tracked references —
            // a minimized settings window (no delegate callback ever fires),
            // a double-open orphan, or the Cmd-, SwiftUI Settings scene all
            // leave tracked refs lying (2026-07-29 evening: a stranded-open
            // settings window disarmed the watchdog through an entire storm).
            // Idle = no non-status-bar window visible on screen; miniaturized
            // windows count as idle (nobody is interacting with them).
            !NSApp.windows.contains { window in
                window.isVisible
                    && !window.isMiniaturized
                    && !NSStringFromClass(type(of: window)).contains("StatusBar")
            }
        }
        StormWatchdog.shared.remediate = { [weak self] stage in
            guard let self else { return }
            switch stage {
            case 0:
                // Cheap: drop render caches and repaint everything.
                self.statusBarUIManager?.clearOverflowParkedState()
                self.updateAllStatusBarIcons()
            default:
                self.statusBarUIManager?.cycleTileVisibility()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.updateAllStatusBarIcons()
                }
            }
        }
        StormWatchdog.shared.start()
    }

    private func setupShortcuts() {
        let shortcutManager = ShortcutManager.shared
        shortcutManager.onTogglePopover = { [weak self] in
            self?.togglePopover(nil)
        }
        shortcutManager.onRefresh = { [weak self] in
            self?.refreshUsage()
        }
        shortcutManager.onOpenSettings = { [weak self] in
            self?.preferencesClicked()
        }
        shortcutManager.onNextProfile = { [weak self] in
            self?.switchToNextProfile()
        }
        shortcutManager.startListening()
    }

    func cleanup() {
        ShortcutManager.shared.stopListening()
        refreshTimer?.invalidate()
        refreshTimer = nil
        networkMonitor.stopMonitoring()
        cancellables.removeAll()  // Clean up Combine subscriptions
        if let iconConfigObserver = iconConfigObserver {
            NotificationCenter.default.removeObserver(iconConfigObserver)
            self.iconConfigObserver = nil
        }
        if let credentialsObserver = credentialsObserver {
            NotificationCenter.default.removeObserver(credentialsObserver)
            self.credentialsObserver = nil
        }
        if let manualActivationObserver = manualActivationObserver {
            NotificationCenter.default.removeObserver(manualActivationObserver)
            self.manualActivationObserver = nil
        }
        if let profileDeletedObserver = profileDeletedObserver {
            NotificationCenter.default.removeObserver(profileDeletedObserver)
            self.profileDeletedObserver = nil
        }
        if let displayModeObserver = displayModeObserver {
            NotificationCenter.default.removeObserver(displayModeObserver)
            self.displayModeObserver = nil
        }
        if let displayStructureObserver = displayStructureObserver {
            NotificationCenter.default.removeObserver(displayStructureObserver)
            self.displayStructureObserver = nil
        }
        if let displayCosmeticsObserver = displayCosmeticsObserver {
            NotificationCenter.default.removeObserver(displayCosmeticsObserver)
            self.displayCosmeticsObserver = nil
        }
        if let screenObserver = screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let wakeObserver = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        detachedWindow?.close()
        detachedWindow = nil
        statusBarUIManager?.cleanup()
        statusBarUIManager = nil

    }

    /// Cleans up tracking data for a specific profile (called when profile is deleted)
    func cleanupProfile(_ profileId: UUID) {
        autoSwitchedProfileIds.remove(profileId)
        credentialErrorProfileIds.remove(profileId)
        burstBackoffs.removeValue(forKey: profileId)
        preflightedMilestones.removeValue(forKey: profileId)
        preflightSessionBoundary.removeValue(forKey: profileId)
        preflightRunning.remove(profileId)
        preflightInFlightCandidates.remove(profileId)
        // Persisted dead-login flags and refresh cooldowns are keyed by
        // profile id too — a deleted profile's UserDefaults entries otherwise
        // outlive it forever.
        GrokUsageService.shared.forgetProfile(profileId)
        CodexUsageService.shared.forgetProfile(profileId)
    }

    // MARK: - Profile Observation

    private func observeProfileChanges() {
        // Store the initial profile ID to skip only the very first startup update
        let initialProfileId = profileManager.activeProfile?.id

        // Observe active profile changes
        profileManager.$activeProfile
            .removeDuplicates { oldProfile, newProfile in
                // Only trigger if the profile ID actually changed
                let result = oldProfile?.id == newProfile?.id
                if !result {
                    LoggingService.shared.log("MenuBarManager: Profile ID changed from \(oldProfile?.id.uuidString ?? "nil") to \(newProfile?.id.uuidString ?? "nil")")
                }
                return result
            }
            .dropFirst()  // Skip the initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProfile in
                guard let self = self, let profile = newProfile else { return }

                // Skip ONLY if this is the startup profile AND we haven't switched yet
                if !self.hasHandledFirstProfileSwitch && profile.id == initialProfileId {
                    LoggingService.shared.log("MenuBarManager: Skipping initial startup profile update to: \(profile.name)")
                    self.hasHandledFirstProfileSwitch = true
                    return
                }

                // Mark that we've handled at least one profile switch
                self.hasHandledFirstProfileSwitch = true

                Task {
                    await self.handleProfileSwitch(to: profile)
                }
            }
            .store(in: &cancellables)

        LoggingService.shared.log("MenuBarManager: Observing profile changes (initial: \(initialProfileId?.uuidString ?? "nil"))")
    }

    private func handleProfileSwitch(to profile: Profile) async {
        LoggingService.shared.log("MenuBarManager: Handling profile switch to: \(profile.name)")

        // 1. Load saved data from new profile (for immediate display)
        if let savedUsage = profile.claudeUsage {
            self.usage = savedUsage
        } else {
            self.usage = .empty
        }

        // 2. Update refresh interval with profile's setting
        restartAutoRefreshWithInterval(profile.refreshInterval)

        // 3. Update menu bar based on current display mode
        // IMPORTANT: In multi-profile mode, we update all icons, not just switch config
        if profileManager.displayMode == .multi {
            // Repaint the existing items instead of tearing the group down: a
            // profile switch changes no item set, and updateMultiProfileButtons
            // rebuilds by itself in the rare case the ranking changed. The old
            // setupMultiProfileMode() here destroyed and recreated all status
            // items on EVERY switch (visible flicker) and kicked off a second
            // concurrent refresh sweep on top of step 5's.
            updateAllStatusBarIcons()
        } else {
            // Single profile mode - update menu bar configuration
            updateMenuBarDisplay(with: profile.iconConfig)
        }

        // 4. Point an OPEN click surface at the new focus, in place.
        refocusOpenSurface(on: profile)

        // 5. Trigger immediate refresh ONLY if profile has usage credentials
        if profile.hasUsageCredentials {
            self.lastRefreshTriggerTime = Date()
            refreshUsage()
        } else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh for profile without usage credentials")
        }
    }

    /// A focus change never drops the popover. Both surfaces re-render in
    /// place — `PopoverContentView` observes this manager and the dashboard
    /// observes its store — and the content is rebuilt from scratch on every
    /// show anyway (`togglePopover`), so a fresh popover bought nothing.
    /// What the old `recreatePopover()` cost: the dashboard's own
    /// "Make active…" confirmation ends in `activateProfileDetailed`, which
    /// moves the focus, which closed the popover one runloop later — the
    /// outcome note vanished with it — and every switch paid one more
    /// scene fence/entanglement cycle against a scene-hosted status window
    /// (the teardown once raced a CA commit into the permanent WindowServer
    /// echo storm; leak-hunter forensics, 2026-07-29).
    private func refocusOpenSurface(on profile: Profile) {
        guard popover?.isShown == true || detachedWindow != nil else { return }
        if usesDashboardSurface {
            rebuildDashboardSnapshot()
        } else {
            viewProfile(profile.id)
        }
        LoggingService.shared.log("MenuBarManager: open surface refocused on '\(profile.name)'")
    }

    private func updateMenuBarDisplay(with config: MenuBarIconConfiguration) {
        // Skip if in multi-profile mode - this method is for single profile mode only
        guard profileManager.displayMode == .single else {
            LoggingService.shared.log("MenuBarManager: Skipping updateMenuBarDisplay (in multi-profile mode)")
            return
        }

        // Check if active profile has usage credentials (not just CLI)
        let hasUsageCredentials = profileManager.activeProfile?.hasUsageCredentials ?? false

        // If no usage credentials, use an empty config (will show default logo)
        let displayConfig: MenuBarIconConfiguration
        if !hasUsageCredentials {
            // Create config with no enabled metrics (will trigger default logo)
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.updateConfiguration(
            target: self,
            action: #selector(togglePopover),
            config: displayConfig
        )

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }
    }

    private func restartAutoRefreshWithInterval(_ interval: TimeInterval) {
        refreshTimer?.invalidate()
        refreshTimer = nil

        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
        timer.tolerance = interval * 0.1  // 10% tolerance for energy efficiency
        RunLoop.main.add(timer, forMode: .common)  // keeps sweeping while an NSMenu is tracking
        refreshTimer = timer

        LoggingService.shared.log("Updated refresh interval to \(interval)s")
    }

    /// Returns the live popover, creating it if needed. Created WITHOUT content;
    /// every show-path installs a fresh contentViewController first.
    /// True when a click opens the fleet dashboard rather than the classic
    /// single-account popover: multi-profile mode with the dashboard surface
    /// chosen (or implied by a fleet layout).
    private var usesDashboardSurface: Bool {
        profileManager.displayMode == .multi
            && profileManager.multiProfileConfig.effectiveClickSurface == .dashboard
    }

    /// The popover / detached panel size for the surface in use.
    private var surfaceSize: NSSize {
        DashboardSurface.size(for: usesDashboardSurface ? .dashboard : .classic)
    }

    private func ensurePopover() -> NSPopover {
        if let popover { return popover }
        let popover = NSPopover()
        popover.contentSize = surfaceSize
        popover.behavior = .semitransient  // Allows detaching
        // NO show/close fade: the fade is a CA transaction against the anchor
        // tile's scene that outlives the user's action — both 2026-08-06
        // fence-race bursts ("Entangling fence requested after pre-commit")
        // landed in that post-close window, and with animates=true didClose is
        // delivered only after the fade, which provably let the cross-tile
        // re-show run against a mid-close popover (stranded-window class —
        // the old pid's 9→11 window accretion). With animates=false the whole
        // close (willClose → didClose) is synchronous inside performClose.
        // NOTE (2026-08-06 workflow verdict): this is exposure/defect removal,
        // NOT storm prevention — ignition was measured multi-host (ControlCenter
        // first) and OS-side; do not re-attribute storms to this flag.
        popover.animates = false
        popover.delegate = self
        self.popover = popover
        return popover
    }

    /// The content behind a click: the fleet dashboard or the classic
    /// single-account popover, by `MultiProfileDisplayConfig.clickSurface`.
    /// Type-erased so the popover and the detached panel share one factory.
    private func createContentViewController() -> NSViewController {
        if usesDashboardSurface {
            rebuildDashboardSnapshot()
            let actions = DashboardActions(
                refresh: { [weak self] in self?.refreshFromPopover() },
                openSettings: { [weak self] raw in
                    self?.closePopoverOrWindow()
                    self?.preferencesClicked(section: raw.flatMap(SettingsSection.init(rawValue:)))
                },
                makeActive: { [weak self] id in
                    guard let self else { return .profileNotFound }
                    // The one activation seam: dead-login gate, adoption,
                    // switch record, notifications — never a second path.
                    let outcome = await self.profileManager.activateProfileDetailed(id, userInitiated: true)
                    self.rebuildDashboardSnapshot()
                    return outcome
                },
                queueNext: { [weak self] id in
                    let rest = SharedDataStore.shared.loadAutoSwitchQueue().filter { $0 != id }
                    SharedDataStore.shared.saveAutoSwitchQueue([id] + rest)
                    self?.rebuildDashboardSnapshot()
                },
                removeFromQueue: { [weak self] id in
                    SharedDataStore.shared.saveAutoSwitchQueue(
                        SharedDataStore.shared.loadAutoSwitchQueue().filter { $0 != id })
                    self?.rebuildDashboardSnapshot()
                },
                openActiveSelector: { provider in
                    // The ⇄ selector item (UX revamp stage 1b) observes this
                    // and opens its menu scrolled to the provider's section.
                    NotificationCenter.default.post(name: .activeSelectorRequested, object: provider)
                },
                openTokenUsage: { [weak self] id, provider in
                    self?.closePopoverOrWindow()
                    Self.requestTokenUsageWindow(profileId: id, provider: provider)
                }
            )
            return NSHostingController(rootView: DashboardView(store: dashboardStore, actions: actions))
        }

        // Create SwiftUI content view
        let contentView = PopoverContentView(
            manager: self,
            onRefresh: { [weak self] in
                // Targeted: the viewed/active account, not a budget-rotated
                // sweep (see refreshFromPopover).
                self?.refreshFromPopover()
            },
            onPreferences: { [weak self] in
                self?.closePopoverOrWindow()
                self?.preferencesClicked()
            },
            onManageProfiles: { [weak self] in
                self?.closePopoverOrWindow()
                self?.preferencesClicked(section: .manageProfiles)
            },
            onTokenUsage: { [weak self] id, provider in
                self?.closePopoverOrWindow()
                Self.requestTokenUsageWindow(profileId: id, provider: provider)
            },
            onMakeActive: { [weak self] id in
                guard let self else { return .profileNotFound }
                // The one activation seam — dead-login gate, adoption, switch
                // record, notifications; the same call the dashboard makes.
                return await self.profileManager.activateProfileDetailed(id, userInitiated: true)
            }
        )

        return NSHostingController(rootView: contentView)
    }

    /// Ask the token-usage window (owned under `Telemetry/`) to open for one
    /// account, or the fleet when `profileId` is nil. Contract:
    /// object = the profile id, userInfo["provider"] = the provider kind.
#if DEBUG
    // MARK: - Frame harness (DEBUG builds only)

    /// `CUW_RENDER_FRAMES=<dir>` at launch: every 20 s, write what the bar and
    /// both click surfaces show for the LIVE roster — each provider item's
    /// composite as painted (at the display's pixel scale), the classic
    /// popover content and the fleet dashboard, the last two in light and
    /// dark — as `<surface>-<state>-<light|dark>@2x.png` plus an `index.md`.
    /// For the owner's pixel pass over a menu-bar agent that has no window to
    /// screenshot; fixture-driven frames of every state live in the test
    /// target (`FrameRenderTests`). Never compiled into Release.
    private static var frameRenderTimer: Timer?

    private func startFrameRenderingIfRequested() {
        guard Self.frameRenderTimer == nil,
              let dir = ProcessInfo.processInfo.environment["CUW_RENDER_FRAMES"], !dir.isEmpty else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Self.frameRenderTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderLiveFrames(into: url) }
        }
        LoggingService.shared.log("Frame harness: writing live frames to \(dir) every 20 s")
    }

    private func renderLiveFrames(into dir: URL) {
        var index = ["# Live frames — \(Date())", "", "Rendered from the running roster; the bar images are the composites as painted.", ""]
        for entry in statusBarUIManager?.debugGroupImages() ?? [] {
            let name = "bar-\(entry.layout)-\(entry.provider)@2x.png"
            if let tiff = entry.image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               Self.writePNG(rep, to: dir.appendingPathComponent(name)) {
                index.append("- `\(name)` — \(entry.provider) group composite, layout family \(entry.layout)")
            }
        }
        rebuildDashboardSnapshot()
        let noActions = DashboardActions(refresh: {}, openSettings: { _ in }, makeActive: { _ in .profileNotFound },
                                         queueNext: { _ in }, removeFromQueue: { _ in })
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let popover = PopoverContentView(manager: self, onRefresh: {}, onPreferences: {}, onManageProfiles: {})
            if let rep = Self.snapshot(popover, size: DashboardSurface.size(for: .classic), dark: dark),
               Self.writePNG(rep, to: dir.appendingPathComponent("popover-live-\(mode)@2x.png")) {
                index.append("- `popover-live-\(mode)@2x.png` — classic popover for the viewed account (\(mode))")
            }
            let dashboard = DashboardView(store: dashboardStore, actions: noActions, height: 1400)
            if let rep = Self.snapshot(dashboard, size: NSSize(width: DashboardSurface.dashboardSize.width, height: 1400), dark: dark),
               Self.writePNG(rep, to: dir.appendingPathComponent("dashboard-live-\(mode)@2x.png")) {
                index.append("- `dashboard-live-\(mode)@2x.png` — fleet dashboard, full height (\(mode))")
            }
        }
        try? index.joined(separator: "\n").write(to: dir.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
    }

    static func snapshot<V: View>(_ view: V, size: NSSize, dark: Bool) -> NSBitmapImageRep? {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    static func writePNG(_ rep: NSBitmapImageRep, to url: URL) -> Bool {
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
#endif

    // MARK: - Default bar layout (owner decision 2026-09-04)

    /// The flag under which the one-time move to the redesigned default is
    /// remembered (registered in `SettingsKeyRegistry.miscKeys`).
    static let defaultLayoutMigrationKey = "menuBarLayoutDefault_v1"

    /// The redesigned default applied to a config the user never touched:
    /// still on the legacy per-account layout AND with no explicit click
    /// surface. nil when nothing should change — an explicit click surface
    /// means the user has been in the pickers, and any fleet layout is
    /// already the redesign.
    nonisolated static func migratedDefaultLayout(_ config: MultiProfileDisplayConfig) -> MultiProfileDisplayConfig? {
        guard config.barLayout == .everyAccount, config.clickSurface == nil else { return nil }
        var moved = config
        moved.barLayout = .fleetDots
        return moved
    }

    /// Once per install: move an untouched config to "Active + dots" (the
    /// click then opens the fleet dashboard). The flag is set whether or not
    /// anything moved, so a user who later picks "Every account" keeps it.
    private func applyDefaultBarLayoutOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.defaultLayoutMigrationKey) else { return }
        if let moved = Self.migratedDefaultLayout(profileManager.multiProfileConfig) {
            profileManager.updateMultiProfileConfig(moved)
            LoggingService.shared.log("MenuBarManager: default bar layout applied once — Active + dots, click opens the dashboard")
        }
        defaults.set(true, forKey: Self.defaultLayoutMigrationKey)
    }

    private static func requestTokenUsageWindow(profileId: UUID?, provider: Profile.ProviderKind?) {
        NotificationCenter.default.post(
            name: .telemetryWindowRequested,
            object: profileId,
            userInfo: provider.map { ["provider": $0] }
        )
    }

    /// Show a DIFFERENT account's usage in the already-open popover, without
    /// touching the popover itself.
    ///
    /// This backs the popover's group navigator (‹ ›, tile chips, arrow keys):
    /// with composite tiles a whole provider group lives inside ONE status item,
    /// so selecting a specific account by clicking its ~20pt segment is fiddly —
    /// the popover has to be able to walk the group on its own. Deliberately
    /// does NOT re-anchor or re-show the popover: re-anchoring destroys and
    /// rebuilds it against a scene-hosted status window, which is exactly the
    /// CA fence/entanglement exposure the storm work exists to minimize. Only
    /// the published selection changes, so SwiftUI re-renders in place.
    func viewProfile(_ profileId: UUID) {
        guard let profile = profileManager.profiles.first(where: { $0.id == profileId }) else { return }
        clickedProfileId = profileId
        clickedProfileUsage = profile.claudeUsage ?? .empty
        // The popover's ANCHOR deliberately stays where it is: the dismiss
        // decision keys on currentPopoverButton, so a second click on the
        // anchoring tile stays a dismiss. Re-anchoring here would turn that
        // click into a "tile switch" — a close plus a fresh popover, i.e. one
        // more scene fence/entanglement cycle per dismiss.
        LoggingService.shared.log("Popover: now viewing '\(profile.name)' (group navigator)")
    }

    /// The menu bar's PAINTED left-to-right order for one provider group, or
    /// empty when nothing has been painted yet. The popover's navigator reads
    /// this instead of recomputing the ranking, so the chips, the ‹ › walk and
    /// the tiles can never disagree about which account is "next" (audit M10).
    func paintedGroupMembers(for provider: Profile.ProviderKind) -> [UUID] {
        statusBarUIManager?.paintedGroupMembers(for: provider, among: profileManager.profiles) ?? []
    }

    /// Re-read the viewed account's usage so an OPEN popover shows fresh numbers
    /// after a refresh sweep. `clickedProfileUsage` is a snapshot taken at click
    /// time; without this the displayed percentages stayed frozen for as long as
    /// the popover remained open.
    private func refreshViewedProfileUsage() {
        // Only while something is actually displaying it — no publishes into a
        // closed popover (a switch sweep's publishes are what made Settings
        // feel frozen once before).
        guard popover?.isShown == true || detachedWindow != nil else { return }
        // The dashboard reads ONE snapshot per paint, rebuilt here from the
        // same fresh data the tiles are painted from.
        if usesDashboardSurface { rebuildDashboardSnapshot() }
        guard clickedProfileUsage != nil, let id = clickedProfileId,
              let usage = profileManager.profiles.first(where: { $0.id == id })?.claudeUsage,
              usage != clickedProfileUsage else { return }
        clickedProfileUsage = usage
    }

    /// Compact identity of the in-flight NSEvent for click-forensics log
    /// lines. `eventNumber` is only legal on mouse/tracking events (AppKit
    /// raises on anything else), and the type of a scene-synthesized action
    /// event is exactly what this instrumentation is meant to learn — so the
    /// type gates the eventNumber read. If duplicates turn out to share an
    /// eventNumber, it becomes a precise dedup key (currently unproven: no
    /// probe ever captured it).
    private func currentEventIdentity() -> String {
        guard let event = NSApp.currentEvent else { return "event=nil" }
        let mouseTypes: Set<NSEvent.EventType> = [
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged,
            .rightMouseDragged, .otherMouseDragged, .mouseMoved,
            .mouseEntered, .mouseExited]
        let number = mouseTypes.contains(event.type)
            ? String(event.eventNumber) : "n/a"
        let ts = String(format: "%.3f", event.timestamp)
        return "event type=\(event.type.rawValue) no=\(number) ts=\(ts)"
            + " buttons=\(NSEvent.pressedMouseButtons)"
    }

    @objc private func togglePopover(_ sender: Any?) {
        // Determine which button was clicked
        let clickedButton: NSStatusBarButton?
        // The account a NON-click invocation (keyboard shortcut) means: the
        // focused profile. Composite groups host many tiles per button, so
        // without this the x-less resolution below would fall back to the
        // group's rightmost tile and the shortcut would open the popover on
        // whichever account happens to reset soonest (Codex finding 2).
        var intendedProfileId: UUID?
        if let button = sender as? NSStatusBarButton {
            clickedButton = button
        } else if statusBarUIManager?.isInMultiProfileMode == true,
                  let activeId = profileManager.activeProfile?.id,
                  let activeButton = statusBarUIManager?.button(for: activeId) {
            // Multi-profile mode: use the active profile's button
            clickedButton = activeButton
            intendedProfileId = activeId
        } else {
            // Single profile mode: fallback to primary button
            clickedButton = statusBarUIManager?.primaryButton
        }

        guard let button = clickedButton else { return }

        // Coalesce storm-mode duplicate deliveries (see the state docs at
        // lastClickActionButton). Status-button sends only — a keyboard
        // shortcut (sender == nil) is never a re-delivery and is never
        // coalesced. Runs BEFORE clickX resolution so suppressed duplicates
        // skip pointer reads and the popover state machine entirely;
        // first-delivery-wins turns a wedged burst's open/dismiss flap into
        // one clean open.
        if sender is NSStatusBarButton {
            let now = ProcessInfo.processInfo.systemUptime
            let delta = now - lastClickActionUptime
            if lastClickActionButton === button, delta < 0.3 {
                if now - clickBurstStartUptime < 1.5 {
                    lastClickActionUptime = now  // sliding window: re-arm
                    LoggingService.shared.log(
                        "Composite click: duplicate within \(Int(delta * 1000))ms"
                        + " — coalesced (\(currentEventIdentity()))")
                    return
                }
                // Burst cap expired: accept, but say so — otherwise a
                // pathological >1.5s duplicate stream is indistinguishable
                // from a fresh click in a post-mortem trace.
                LoggingService.shared.log(
                    "Composite click: burst cap (1.5s) expired — accepting delivery \(Int(delta * 1000))ms after previous (\(currentEventIdentity()))")
            }
            lastClickActionButton = button
            lastClickActionUptime = now
            clickBurstStartUptime = now
        }

        // Composite tiles: the click's x-offset within the group button
        // identifies WHICH tile was clicked. Only meaningful when the sender
        // is the clicked button itself (shortcut-invoked toggles pass nil).
        //
        // COORDINATE TRAP (scene-hosted status items, macOS 26/27): the
        // action's NSEvent does NOT carry the click location. Clicks arrive
        // as FrontBoard NSMenuBarNavigateActions and AppKit re-dispatches
        // them with a SYNTHESIZED event at the button's CENTER — 14
        // production clicks all logged rawX == width/2, resolving every
        // click to the center tile ("always opens Commits", owner report
        // 2026-07-30). The physical pointer position is the click location;
        // read it from the window server, never from the event.
        let clickX: CGFloat? = {
            guard sender is NSStatusBarButton else { return nil }
            let x = StatusBarUIManager.pointerLocalX(in: button)
            if x == nil {
                LoggingService.shared.log(
                    "Composite click: pointer off-button → ambiguous (active-account fallback)"
                    + " (\(currentEventIdentity()))")
            }
            return x
        }()

        // In multi-profile mode, determine which profile was clicked. Written
        // with an explicit flatMap so there is no nested-optional `??` to
        // reason about: `manager?.profileId(...)` is a UUID??, and `nil ?? that`
        // would resolve to .some(nil) rather than falling through.
        let resolvedProfileId: UUID? = intendedProfileId
            ?? statusBarUIManager.flatMap { $0.profileId(for: button, atX: clickX) }

        if statusBarUIManager?.isInMultiProfileMode == true,
           let profileId = resolvedProfileId,
           let profile = profileManager.profiles.first(where: { $0.id == profileId }) {
            // Set the clicked profile data
            clickedProfileId = profileId
            clickedProfileUsage = profile.claudeUsage ?? .empty
            dashboardStore.clickedProvider = profile.providerKind
            LoggingService.shared.log("Multi-profile popover: showing data for '\(profile.name)'")
        } else {
            // Single profile mode - use active profile
            clickedProfileId = profileManager.activeProfile?.id
            clickedProfileUsage = nil  // Will use manager.usage
            dashboardStore.clickedProvider = profileManager.activeProfile?.providerKind
        }

        // Popover anchor: the clicked tile's segment within a composite group
        // button, or the whole button otherwise.
        let anchorRect = clickedProfileId
            .flatMap { statusBarUIManager?.anchorRect(for: $0, in: button) }
            ?? button.bounds

        // If there's a detached window, close it
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
            currentPopoverButton = nil
            return
        }

        // Otherwise toggle the popover. "Same" = same BUTTON: a click
        // anywhere on a group whose popover is already open is a DISMISS
        // (owner spec 2026-07-30), never a tile switch — switching accounts
        // with the popover open is the group navigator's job. Keying on
        // (button, profile) here made the dismiss depend on the re-click
        // resolving to the exact anchor tile, which a few points of click
        // scatter (or an ambiguous→active open) defeats: the "dismiss"
        // turned into a close + fresh popover.
        let sameButton = currentPopoverButton === button
        if let popover, popover.isShown {
            if sameButton {
                // Same group - close the popover
                LoggingService.shared.log("Popover: same-group re-click → dismiss")
                closePopover()
            } else {
                // Different tile/button: close now, re-show on the NEXT
                // runloop turn with a FRESH popover. With animates=false,
                // performClose delivers didClose SYNCHRONOUSLY here, which
                // queues the deferred destroy BEFORE the re-show block below —
                // so the destroy provably runs first and ensurePopover()
                // builds a genuinely fresh popover. (With animates=true this
                // ordering was inverted — didClose arrived after the fade,
                // the re-show reused the mid-close popover, and a collided
                // close/re-show could strand an invisible _NSPopoverWindow
                // forever. Do not re-enable animation without re-sequencing.)
                popover.performClose(nil)
                stopMonitoringForOutsideClicks()
                let targetProfileId = clickedProfileId
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let fresh = self.ensurePopover()
                    fresh.contentSize = self.surfaceSize
                    fresh.contentViewController = self.createContentViewController()
                    // Re-resolve the anchor NOW: a repaint between the two
                    // runloop turns can re-lay out the composite, and a stale
                    // segment rect would anchor the popover under the wrong
                    // tile.
                    let freshAnchor = targetProfileId
                        .flatMap { self.statusBarUIManager?.anchorRect(for: $0, in: button) }
                        ?? anchorRect
                    fresh.show(relativeTo: freshAnchor, of: button, preferredEdge: .minY)
                    self.currentPopoverButton = button
                    self.startMonitoringForOutsideClicks()
                }
            }
        } else {
            // Popover not shown. If it JUST closed anchored to this same
            // group button, this click is the semitransient auto-close's own
            // mouse-up — the user meant "dismiss", so swallow the re-open.
            if let lastButton = lastPopoverCloseButton, lastButton === button,
               Date().timeIntervalSince(lastPopoverCloseTime) < 0.5 {
                lastPopoverCloseButton = nil
                stopMonitoringForOutsideClicks()
                LoggingService.shared.log("Popover: re-click after auto-close swallowed → dismissed")
                return
            }
            // Stop any existing monitor first
            stopMonitoringForOutsideClicks()
            let popover = ensurePopover()
            popover.contentSize = surfaceSize
            popover.contentViewController = createContentViewController()
            popover.show(relativeTo: anchorRect, of: button, preferredEdge: .minY)
            currentPopoverButton = button
            startMonitoringForOutsideClicks()
        }
    }

    private func closePopover() {
        // performClose delivers popoverWillClose synchronously, which stamps
        // the swallow anchor while currentPopoverButton is still set — so the
        // nilling below must come AFTER it.
        popover?.performClose(nil)
        stopMonitoringForOutsideClicks()
        currentPopoverButton = nil
    }

    private func startMonitoringForOutsideClicks() {
        // Idempotent: a second install without an intervening stop would
        // overwrite eventMonitor and leak the first monitor forever.
        stopMonitoringForOutsideClicks()
        // Only monitor when popover is shown (not detached)
        // Stop monitoring if popover gets detached
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self,
                  let popover = self.popover,
                  popover.isShown,
                  self.detachedWindow == nil else { return }
            self.closePopover()
        }
    }

    private func stopMonitoringForOutsideClicks() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func closePopoverOrWindow() {
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
        } else {
            popover?.performClose(nil)
        }
    }

    // MARK: - Status Bar Icon Updates

    /// Updates all enabled status bar icons
    private func updateAllStatusBarIcons() {
        // An open popover shows a snapshot of ONE account's usage — refresh it
        // from the same fresh data the tiles are about to be painted from.
        refreshViewedProfileUsage()

        // Check if in multi-profile mode
        if profileManager.displayMode == .multi {
            // Update multi-profile icons using profiles from profileManager
            let config = profileManager.multiProfileConfig
            statusBarUIManager?.updateMultiProfileButtons(
                profiles: profileManager.profiles,
                config: config,
                context: fleetSummaryContext(for: config)
            )
        } else {
            // Single profile mode - use the standard update
            statusBarUIManager?.updateAllButtons(usage: usage)
        }
    }

    private func startAutoRefresh() {
        let interval = profileManager.activeProfile?.refreshInterval ?? 30.0
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.lastAutoRefreshTime = Date()
            self?.refreshUsage()
        }
        timer.tolerance = interval * 0.1  // 10% tolerance for energy efficiency
        RunLoop.main.add(timer, forMode: .common)  // keeps sweeping while an NSMenu is tracking
        refreshTimer = timer
        LoggingService.shared.log("Started auto-refresh with interval: \(interval)s")
    }

    private func setupWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // Debounce: only refresh if at least 10 seconds since last auto-refresh
            let timeSinceLastRefresh = Date().timeIntervalSince(self.lastAutoRefreshTime)
            guard timeSinceLastRefresh > 10 else {
                LoggingService.shared.log("MenuBarManager: Skipping wake refresh (debounce)")
                return
            }
            LoggingService.shared.log("MenuBarManager: Wake from sleep detected, refreshing after delay")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.lastAutoRefreshTime = Date()
                self?.refreshUsage()
            }
        }
    }

private func observeCredentialChanges() {
        // Observe credential changes (add, remove, or update)
        credentialsObserver = NotificationCenter.default.addObserver(
            forName: .credentialsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                // Check if active profile has usage credentials
                guard let profile = self.profileManager.activeProfile, profile.hasUsageCredentials else {
                    LoggingService.shared.logInfo("Credentials changed but no usage credentials - showing default logo")

                    // Reconfigure menu bar to show default logo
                    let config = self.profileManager.activeProfile?.iconConfig ?? .default
                    self.updateMenuBarDisplay(with: config)
                    return
                }

                LoggingService.shared.logInfo("Credentials changed - triggering immediate refresh")

                // Reconfigure menu bar to show metrics (in case we were showing default logo)
                let config = profile.iconConfig
                self.updateMenuBarDisplay(with: config)

                // Mark this as user-triggered
                self.lastRefreshTriggerTime = Date()

                self.refreshUsage()
            }
        }
    }

    private func observeManualActivations() {
        manualActivationObserver = NotificationCenter.default.addObserver(
            forName: .profileManuallyActivated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let profileId = notification.object as? UUID else { return }
            Task { @MainActor in
                // Respect the explicit choice: marking the profile as already-
                // switched keeps the sweep from rotating away from it while it
                // sits above a switch threshold. The existing re-arm (usage back
                // below every threshold) clears the mark, so a profile the user
                // picked with real headroom behaves exactly as before.
                self.autoSwitchedProfileIds.insert(profileId)
                LoggingService.shared.log("MenuBarManager: user manually activated profile \(profileId) — auto-switch-away suppressed until it regains headroom")
            }
        }
    }

    private func observeProfileDeletions() {
        // Prune long-lived per-profile tracking on deletion; cleanupProfile was
        // previously never called from anywhere, so deleted profiles' backoff
        // and milestone entries lived for the rest of the process.
        profileDeletedObserver = NotificationCenter.default.addObserver(
            forName: .profileDeleted,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self, let profileId = notification.object as? UUID else { return }
            Task { @MainActor in
                self.cleanupProfile(profileId)
            }
        }
    }

    private func observeIconConfigChanges() {
        // Observe configuration changes (metrics enabled/disabled, order changes, etc.)
        iconConfigObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconConfigChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            // Reload configuration from active profile (already on main queue)
            Task { @MainActor in
                // Handle differently based on display mode
                if self.profileManager.displayMode == .multi {
                    // Multi-profile mode - refresh all profile icons
                    self.setupMultiProfileMode()
                } else {
                    // Single profile mode
                    let newConfig = self.profileManager.activeProfile?.iconConfig ?? .default
                    self.updateMenuBarDisplay(with: newConfig)
                }
            }
        }
    }

    private func observeDisplayModeChanges() {
        // Legacy `.displayModeChanged` posters (if any remain) route to structural setup.
        displayModeObserver = NotificationCenter.default.addObserver(
            forName: .displayModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                self.handleDisplayModeChange()
            }
        }
    }

    private func observeDisplayStructureChanges() {
        displayStructureObserver = NotificationCenter.default.addObserver(
            forName: .profileDisplayStructureChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleDisplayStructureChange(userInfo: notification.userInfo)
            }
        }
    }

    private func observeDisplayCosmeticsChanges() {
        displayCosmeticsObserver = NotificationCenter.default.addObserver(
            forName: .profileDisplayCosmeticsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                self.handleDisplayCosmeticsChange()
            }
        }
    }

    private func handleDisplayModeChange() {
        // Legacy `.displayModeChanged` posters route to the same structural path
        // (rebuild items, no full network sweep).
        LoggingService.shared.log("MenuBarManager: Display mode changed (legacy notification)")
        handleDisplayStructureChange(userInfo: nil)
    }

    /// Structural change: rebuild status items, but do NOT full-network-sweep.
    /// If selection grew, fetch only newly-added profiles that lack cached usage.
    private func handleDisplayStructureChange(userInfo: [AnyHashable: Any]?) {
        let displayMode = profileManager.displayMode
        LoggingService.shared.log("MenuBarManager: Display structure changed (mode=\(displayMode.rawValue))")

        if displayMode == .multi {
            setupMultiProfileMode(refreshAll: false)
            let addedIds = (userInfo?["addedProfileIds"] as? [String])?
                .compactMap { UUID(uuidString: $0) } ?? []
            if !addedIds.isEmpty {
                fetchUsageForAddedProfilesLackingCache(addedIds)
            }
        } else {
            setupSingleProfileMode()
        }
    }

    /// Cosmetic change: repaint existing tiles only — no teardown, no network.
    private func handleDisplayCosmeticsChange() {
        guard profileManager.displayMode == .multi else { return }
        LoggingService.shared.log("MenuBarManager: Display cosmetics changed — repainting tiles")
        updateAllStatusBarIcons()
    }

    // MARK: - Headless Mode (Remote Desktop Support)

    private func setupHeadlessModeObserver() {
        // Always observe screen changes to support headless Mac setups (Remote Desktop)
        LoggingService.shared.log("MenuBarManager: Setting up screen change observer for headless support")

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
    }

    private func handleScreenChange() {
        // Only proceed if we have screens now
        guard !NSScreen.screens.isEmpty else { return }

        // Check if status bar needs retry (button is nil means it failed on headless startup)
        guard let uiManager = statusBarUIManager else { return }

        if !uiManager.hasValidStatusBar {
            LoggingService.shared.log("MenuBarManager: Headless mode - display connected, retrying status bar setup (screens: \(NSScreen.screens.count))")
            setup()
        } else {
            // Screen geometry changed: clear parked-tile skip state and force one
            // full repaint so un-parked tiles refresh within one cycle.
            uiManager.clearOverflowParkedState()
            updateAllStatusBarIcons()
        }
    }

    /// Returns whether the status bar has at least one valid button
    func hasValidStatusBar() -> Bool {
        return statusBarUIManager?.hasValidStatusBar ?? false
    }

    private func setupMultiProfileMode(refreshAll: Bool = true) {
        let selectedProfiles = profileManager.getSelectedProfiles()
        let config = profileManager.multiProfileConfig

        statusBarUIManager?.setupMultiProfile(
            profiles: selectedProfiles,
            target: self,
            action: #selector(togglePopover)
        )

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.statusBarUIManager?.updateMultiProfileButtons(
                profiles: self.profileManager.profiles,
                config: config,
                context: self.fleetSummaryContext(for: config)
            )
        }

        LoggingService.shared.log("MenuBarManager: Multi-profile mode enabled with \(selectedProfiles.count) profiles, style=\(config.iconStyle.rawValue)")

        // Full network sweep only when requested (startup / icon-config multi path).
        // Structural selection changes fetch only newly-added profiles lacking cache.
        if refreshAll {
            refreshAllSelectedProfiles()
        }
    }

    /// Fetch usage for profiles newly added to the multi-profile selection that
    /// have no cached `claudeUsage` yet — avoids a full sweep on every toggle.
    private func fetchUsageForAddedProfilesLackingCache(_ ids: [UUID]) {
        let toFetch = ids.compactMap { id -> Profile? in
            guard let profile = profileManager.profiles.first(where: { $0.id == id }),
                  profile.hasUsageCredentials,
                  profile.claudeUsage == nil else { return nil }
            return profile
        }
        guard !toFetch.isEmpty else { return }

        Task { @MainActor in
            for profile in toFetch {
                do {
                    let newUsage = try await self.fetchUsageForProfile(profile)
                    self.profileManager.saveClaudeUsage(newUsage, for: profile.id)
                    LoggingService.shared.log(
                        "MenuBarManager: Fetched usage for newly-selected profile '\(profile.name)'"
                    )
                } catch {
                    LoggingService.shared.logError(
                        "Failed to fetch usage for newly-selected profile '\(profile.name)': \(error.localizedDescription)"
                    )
                }
            }
            self.profileManager.flushPendingUsage()
            self.updateAllStatusBarIcons()
        }
    }

    /// Returns true when credential hydration is still `.loading`, in which case
    /// the caller should skip credential-dependent work. Schedules at most ONE
    /// 2s retry that re-invokes `retry` (stacking prevented by the boolean).
    /// `.ready` and `.failed` both return false so work proceeds.
    @discardableResult
    private func deferIfCredentialHydrationLoading(retry: @escaping () -> Void) -> Bool {
        guard profileManager.credentialHydrationState == .loading else { return false }
        if !credentialHydrationRetryScheduled {
            credentialHydrationRetryScheduled = true
            LoggingService.shared.log(
                "MenuBarManager: credential hydration still loading — deferring refresh, retry in 2s"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self else { return }
                self.credentialHydrationRetryScheduled = false
                retry()
            }
        }
        return true
    }

    /// Refreshes usage data for all profiles selected for multi-profile display
    private func refreshAllSelectedProfiles() {
        // Gate on credential hydration: nil credentials while `.loading` mean
        // "not loaded yet", not "has no credentials" — sweeping now would skip
        // every profile and mis-route provider kind.
        if deferIfCredentialHydrationLoading(retry: { [weak self] in
            self?.refreshAllSelectedProfiles()
        }) {
            return
        }

        // Reentrancy guard: a sweep does per-profile Keychain healing plus one
        // network fetch per profile, so it can outlast the 30s timer — and profile
        // switches used to fire it twice. Overlapping sweeps interleave half-fresh
        // usage into the end-of-sweep ranking check, causing menu bar rebuild
        // ping-pong, and double every API call (the 429s in the log).
        guard !isRefreshing else {
            LoggingService.shared.log("MenuBarManager: refresh sweep already in progress, skipping")
            return
        }

        // Never sweep mid-switch: activateProfile rewrites the shared logins and
        // pointers across several suspension points, and a sweep's Keychain
        // adoption interleaved into that window can copy the incoming account's
        // login into the outgoing profile (cross-account contamination).
        guard !profileManager.isSwitchingProfile else {
            LoggingService.shared.log("MenuBarManager: profile switch in progress, skipping sweep")
            return
        }

        let allSelected = profileManager.profiles.filter { $0.isSelectedForDisplay && $0.hasUsageCredentials }

        guard !allSelected.isEmpty else {
            LoggingService.shared.log("MenuBarManager: No selected profiles with usage credentials to refresh")
            updateAllStatusBarIcons()
            return
        }

        // api.anthropic.com/api/oauth/usage sustains only ~2 requests per 30s
        // window per IP (3/sweep still drew one 429 per sweep in measurement).
        // Fetch the provider-active/focused Claude profiles every sweep and give
        // the remaining budget (max(1, 2 - priorityClaudeCount)) to the
        // background Claude profiles that need it most: candidates that would
        // only burn the slot (throttle-stamped, burst-backed-off, dead login)
        // are excluded up front, and the rest are ranked by time since their
        // last fetch ATTEMPT, weighted so accounts already near a limit sample
        // ~3x as often as idle ones — those are the accounts parallel CLI
        // sessions are actively burning, and the ones the auto-switch needs
        // fresh numbers for. This replaced a blind round-robin cursor under
        // which a dead login consumed a full slot every cycle and an account
        // cached at 70% session waited behind half a dozen idle accounts —
        // observed 2026-08-11: 'Memori' sat 33 min stale while its real
        // session usage hit 100%. Codex/Grok hit different hosts and refresh
        // every sweep (never counted against the Claude budget).
        // DISPLAY + OWNER priority, deliberately: the account on screen is the
        // one whose number the user is reading, and the Claude OWNER is the one
        // the CLI is burning. This is a FETCH-BUDGET ranking, never an
        // "is this the active account" test — nothing downstream of it applies
        // a credential or fires a switch, so including the focus is safe here
        // and only here.
        let priorityIds = Set([
            profileManager.activeProfile?.id,
            profileManager.providerOwnerId(for: .claude)
        ].compactMap { $0 })
        let priorityClaudeCount = allSelected.filter { $0.providerKind == .claude && priorityIds.contains($0.id) }.count
        let rotationBudget = max(1, 2 - priorityClaudeCount)
        let backgroundClaude = allSelected.filter { $0.providerKind == .claude && !priorityIds.contains($0.id) }
        let scheduleNow = Date()
        let candidates = backgroundClaude.map { profile in
            BackgroundFetchCandidate(
                id: profile.id,
                lastAttempt: backgroundFetchAttempts[profile.id] ?? profile.claudeUsage?.lastUpdated,
                isHot: Self.isNearLimit(profile.claudeUsage),
                isEligible: !isBackgroundFetchIneligible(profile)
            )
        }
        let rotatingIds = Set(Self.selectBackgroundFetchIds(
            candidates: candidates, budget: rotationBudget, now: scheduleNow
        ))
        // Codex and Grok profiles hit their own hosts (never the throttled
        // oauth/usage endpoint), so they refresh every sweep.
        // Order: priority Claude first (freshest data for the accounts being
        // burned right now, and a sweep that ends early on a mid-sweep switch
        // has already covered them), then the scheduled background Claude,
        // then Codex/Grok.
        let fetchRank: (Profile) -> Int = { profile in
            if priorityIds.contains(profile.id) && profile.providerKind == .claude { return 0 }
            if rotatingIds.contains(profile.id) { return 1 }
            return 2
        }
        let selectedProfiles = allSelected
            .filter { $0.providerKind != .claude || priorityIds.contains($0.id) || rotatingIds.contains($0.id) }
            .enumerated()
            .sorted { (fetchRank($0.element), $0.offset) < (fetchRank($1.element), $1.offset) }
            .map(\.element)

        // Log the scheduling shape once per app run (F4): how many background
        // accounts compete for the budget, how many are hot (3x sampling) and
        // how many are excluded as unfetchable. Cold-account staleness ≈
        // (nHot × hotWeight + nCold) / budget sweeps × 30s; hot ≈ 1/hotWeight
        // of that.
        if !hasLoggedBackgroundStalenessEstimate {
            hasLoggedBackgroundStalenessEstimate = true
            let eligible = candidates.filter(\.isEligible)
            let nHot = eligible.filter(\.isHot).count
            let nCold = eligible.count - nHot
            let excluded = candidates.count - eligible.count
            let coldSweeps = ceil((Double(nHot) * Self.hotFetchWeight + Double(nCold)) / Double(rotationBudget))
            let coldMinutes = coldSweeps * 30.0 / 60.0
            LoggingService.shared.log(
                "MenuBarManager: \(candidates.count) background Claude profiles (\(nHot) hot, \(excluded) excluded) on budget \(rotationBudget) -> cold-account staleness ~\(String(format: "%.1f", coldMinutes))min, hot ~\(String(format: "%.1f", coldMinutes / Self.hotFetchWeight))min"
            )
        }

        LoggingService.shared.log("MenuBarManager: Refreshing \(selectedProfiles.count) of \(allSelected.count) selected profiles for multi-profile mode")

        isRefreshing = true
        Task {
            // Flush deferred usage once when the sweep ends — covers normal completion,
            // early break on mid-sweep switch, and thrown/cancelled paths.
            defer {
                // ONE publish for all staged usage (idempotent), then one disk
                // flush. Order matters: in-memory state first so any exit-path
                // repaint sees fresh values.
                self.profileManager.publishStagedUsage()
                self.profileManager.flushPendingUsage()
                self.isRefreshing = false
            }

            // Local ground truth first (zero network): transcript rate-limit
            // tripwire + the CLI's own cached bars. These land before any
            // fetch so the sweep's skip logic and the auto-switch see them.
            await self.harvestLocalLimitSignals()

            // Per-sweep outcome tracking — the error banners must reflect reality:
            // resetting the failure counters unconditionally at sweep end used to
            // mask a sweep where EVERY profile failed (dead network, revoked
            // logins) as a success, so the "stale data" banner never appeared.
            var sweepSuccesses = 0
            var sweepFailures = 0
            var sweepCredentialError = false
            var sweepLastErrorMessage: String?

            // status.claude.com rides its own 5-min cadence (F2) — not every
            // 30s sweep. First sweep after launch always fetches (distantPast).
            if Date().timeIntervalSince(self.lastStatusFetch) >= self.statusPollInterval {
                self.lastStatusFetch = Date()
                do {
                    let newStatus = try await statusService.fetchStatus()
                    self.status = newStatus
                } catch {
                    let appError = AppError.wrap(error)
                    LoggingService.shared.log("MenuBarManager: Failed to fetch status - [\(appError.code.rawValue)] \(appError.message)")
                }
            }

            // Claude-only monotonic spacing clock for this sweep (F1). Codex/Grok
            // hit different hosts and must not inherit Claude's 2s pacing — and
            // must not reset the Claude clock when interleaved between Claude
            // fetches. Aggregate Claude request rate stays unchanged.
            var lastClaudeFetchStart: Date? = nil
            let claudeFetchSpacing: TimeInterval = 2.0

            // Fetch usage for each selected profile
            for var profile in selectedProfiles {
                // The mid-sweep auto-switch below may have started rewriting the
                // shared logins. Stop the sweep rather than run Keychain healing
                // beside it — same cross-account-contamination hazard the
                // sweep-start guard exists for. Priority (provider-active/focused)
                // profiles re-fetch next sweep; a skipped background profile has
                // no attempt stamped, so the scheduler re-picks it next sweep.
                if self.profileManager.isSwitchingProfile {
                    LoggingService.shared.log("MenuBarManager: profile switch started mid-sweep — ending sweep early")
                    break
                }


                // While a SERVER-AFFIRMED account throttle is in force the
                // endpoint told us when to come back — don't burn the budget.
                // An INFERRED (suspected) stamp is the opposite: keep fetching,
                // because the next fetch IS the confirmation — a 200 replaces
                // the usage wholesale and clears the suspicion instantly
                // (skipping suspects for the stamp's 5 min was what made the
                // false "100%" sticky — consult verdict, 2026-08-12).
                let usageThrottled = (profile.claudeUsage?.rateLimitedUntil.map { $0 > Date() } ?? false)
                    && profile.claudeUsage?.rateLimitedInferred != true
                let burstBackoffUntil = burstBackoffs[profile.id]?.until
                let usageBackedOff = burstBackoffUntil.map { $0 > Date() } ?? false
                // A dead-flagged login that cannot fetch burns a rotation slot
                // plus an error log every cycle (profile 'Ai' did so for six
                // days; the Codex twin drew 1,009 401s in nine hours). The
                // per-provider rule lives in shouldSkipFetchForDeadLogin —
                // Claude pairs the flag with an expired access token, Codex and
                // Grok pair it with the 401 backoff window, and each provider's
                // active account is exempt. The API-console fetch below is
                // untouched.
                let cliLoginDead = self.shouldSkipFetchForDeadLogin(profile)
                let authBackoffUntil = self.authBackoffs[profile.id]?.until
                let authBackedOff = authBackoffUntil.map { $0 > Date() } ?? false
                if usageThrottled {
                    LoggingService.shared.log("MenuBarManager: skipping usage fetch for '\(profile.name)' — endpoint throttled until \(profile.claudeUsage?.rateLimitedUntil ?? Date())", type: .info)
                } else if usageBackedOff {
                    LoggingService.shared.log("MenuBarManager: skipping usage fetch for '\(profile.name)' — backing off burst 429s until \(burstBackoffUntil ?? Date())", type: .info)
                } else if cliLoginDead {
                    // Default level deliberately (not .info): .info never
                    // persists to `log show`, and this line is the only
                    // post-hoc evidence that a profile's staleness is a dead
                    // login rather than a fetch bug. With selection-time
                    // eligibility filtering, a dead BACKGROUND profile is
                    // normally never picked, so this fires mainly for a dead
                    // PRIORITY (provider-active/focused) profile, or in the
                    // race where the flag landed after selection.
                    LoggingService.shared.log("MenuBarManager: skipping usage fetch for '\(profile.name)' — provider login is dead (revoked refresh token); log in again + re-sync to resume")
                } else if authBackedOff {
                    LoggingService.shared.log("MenuBarManager: skipping usage fetch for '\(profile.name)' — backing off 401s until \(authBackoffUntil ?? Date())", type: .info)
                } else {
                    // Space Claude-bound fetches only: oauth/usage is the sole
                    // reason for pacing. Sleep the remainder so Claude starts are
                    // never < 2s apart even when Codex/Grok sit between them.
                    if profile.providerKind == .claude {
                        if let lastStart = lastClaudeFetchStart {
                            let elapsed = Date().timeIntervalSince(lastStart)
                            if elapsed < claudeFetchSpacing {
                                let remainderNs = UInt64((claudeFetchSpacing - elapsed) * 1_000_000_000)
                                try? await Task.sleep(nanoseconds: remainderNs)
                            }
                        }
                        lastClaudeFetchStart = Date()
                        // Stamp the ATTEMPT (not the outcome) — the scheduler
                        // ranks by this, so a profile whose fetch fails without
                        // registering a backoff still yields the slot next sweep
                        // instead of pinning the top score and starving the rest.
                        self.backgroundFetchAttempts[profile.id] = Date()
                    }

                    // Self-heal a stale CLI OAuth token before fetching
                    await self.ensureFreshCLICredentialsIfNeeded(for: profile)
                    if let updated = self.profileManager.profiles.first(where: { $0.id == profile.id }) {
                        profile = updated
                    }

                    // Per-sweep steady-state chatter stays at .info (memory
                    // buffer, visible to `log stream`/recent `log show --info`)
                    // — persisted .default is reserved for state changes,
                    // warnings, and errors.
                    LoggingService.shared.log("MenuBarManager: Fetching usage for profile '\(profile.name)'", type: .info)

                    do {
                        let newUsage = try await fetchUsageForProfile(profile)

                        // Save to profile
                        self.profileManager.stageClaudeUsage(newUsage, for: profile.id)
                        LoggingService.shared.log("MenuBarManager: Saved usage for profile '\(profile.name)' - session: \(newUsage.sessionPercentage)%", type: .info)

                        // DISPLAY ONLY: `usage` is the headline number the
                        // popover and single-profile mode show, so it follows the
                        // profile being VIEWED. No credential and no switch hangs
                        // off it, which is why the focus is the right test here.
                        if profile.id == self.profileManager.activeProfile?.id {
                            self.usage = newUsage
                        }
                        sweepSuccesses += 1
                        self.credentialErrorProfileIds.remove(profile.id)
                        self.burstBackoffs.removeValue(forKey: profile.id)
                        self.authBackoffs.removeValue(forKey: profile.id)
                        self.recordClaudeUsageSuccess(profile, usage: newUsage)

                        // Threshold notifications for EVERY swept profile,
                        // honouring that profile's own toggles. Until
                        // 2026-09-03 they were fired only from the
                        // single-profile refresh path, so in multi-profile
                        // mode (with more than one account selected) no
                        // account of any provider ever got one and the
                        // per-profile switches in Settings → General did
                        // nothing. NotificationManager de-dupes per
                        // (profile, type, threshold) until the window rolls
                        // over, so the 30s cadence does not spam.
                        NotificationManager.shared.checkAndNotify(
                            usage: newUsage,
                            profileName: profile.name,
                            settings: profile.effectiveNotificationSettings(fleet: SharedDataStore.shared.loadFleetAlertDefaults())
                        )

                        // Check auto-switch NOW for the accounts actually in use
                        // instead of waiting for the end of the sweep: rate-limit
                        // spacing makes a full sweep take ~2s per profile, and near
                        // the threshold those seconds are when parallel sessions hit
                        // the hard limit. Idempotent with the end-of-sweep check
                        // (autoSwitchedProfileIds de-dupes the trigger).
                        // OWNERS ONLY (see `mayTriggerAutoSwitch`): a
                        // merely-viewed account at 96 % must not rotate the CLI
                        // away from the owner that still has headroom.
                        if self.mayTriggerAutoSwitch(profile.id) {
                            self.checkAutoSwitchIfNeeded(usage: newUsage, currentProfile: profile)
                        }
                    } catch {
                        let appError = AppError.wrap(error)

                        // The usage endpoint refused, but the account is the
                        // one being burned right now — read its live counters
                        // off the Messages API headers (different rate-limit
                        // bucket, the one the fleet's own requests ride) rather
                        // than going blind. This is a real measurement: it
                        // takes the whole success path.
                        if appError.code == .apiRateLimited,
                           let rescued = await self.probeUsageViaMessageHeaders(for: profile) {
                            self.profileManager.stageClaudeUsage(rescued, for: profile.id)
                            // DISPLAY ONLY — the headline number follows the
                            // VIEWED profile (see the sibling assignment above).
                            if profile.id == self.profileManager.activeProfile?.id {
                                self.usage = rescued
                            }
                            sweepSuccesses += 1
                            self.credentialErrorProfileIds.remove(profile.id)
                            self.burstBackoffs.removeValue(forKey: profile.id)
                            // Not endpoint control evidence: this success came
                            // from a DIFFERENT host bucket, so it says nothing
                            // about whether oauth/usage is answering for other
                            // accounts (shouldInferAccountThrottle reads that).
                            self.recordClaudeUsageSuccess(profile, usage: rescued, countsAsEndpointControl: false)
                            self.checkAutoSwitchIfNeeded(usage: rescued, currentProfile: profile)
                            continue
                        }

                        sweepFailures += 1
                        sweepLastErrorMessage = appError.message
                        if appError.code == .apiUnauthorized || appError.code == .sessionKeyExpired {
                            sweepCredentialError = true
                            self.credentialErrorProfileIds.insert(profile.id)
                            // Unlike a 429, a 401 carries no Retry-After and
                            // nothing used to slow it down: one dead-flagged
                            // Codex profile drew 1,009 401s in nine hours
                            // (audit H2). Back off instead — and keep it short
                            // enough that the retry IS the confirmation, since
                            // a 200 clears the dead flag.
                            self.registerAuthBackoff(for: profile)
                        }
                        // An account-level 429 IS usage information: the account is
                        // out of capacity and its cached percentages are frozen at
                        // pre-throttle values. Stamp it so the tiles and auto-switch
                        // see 100% instead of trusting the stale cache — and check
                        // the switch NOW if this account is one actually in use.
                        if let stamped = self.stampAccountThrottleIfNeeded(appError, profile: profile) {
                            if self.mayTriggerAutoSwitch(profile.id) {
                                self.checkAutoSwitchIfNeeded(usage: stamped, currentProfile: profile)
                            }
                        } else if appError.code == .apiRateLimited {
                            // Burst-class 429 (no account-level Retry-After):
                            // exhaustion is unproven by the header, so back the
                            // fetch off — and once the streak plus a recent
                            // other-account success prove the refusal follows
                            // the ACCOUNT, stamp it as exhausted anyway (the
                            // retry-after:0 incident — see the inferred-throttle
                            // section).
                            self.registerBurstBackoff(for: profile, retryAfter: appError.retryAfterSeconds)
                            let isActiveAccount = self.profileManager.isProviderOwner(profile.id)
                            if profile.providerKind == .claude,
                               let streak = self.burstBackoffs[profile.id]?.streak,
                               Self.shouldInferAccountThrottle(
                                   streak: streak,
                                   profileId: profile.id,
                                   isActiveAccount: isActiveAccount,
                                   cachedUsage: profile.claudeUsage,
                                   lastClaudeSuccess: self.lastClaudeUsageSuccess,
                                   now: Date()
                               ) {
                                // Never a switch trigger (autoSwitchTriggerUsage
                                // strips it) — an active account gets a one-shot
                                // notification so the user makes the call.
                                self.stampInferredAccountThrottle(profile, streak: streak)
                                self.notifyInferredThrottleIfNeeded(profile)
                            }
                            // Whether the stamp is new or carried over, another
                            // failed read means the display estimate should
                            // advance along the measured burn rate.
                            self.updateSuspectedProjection(for: profile.id)
                        }
                        LoggingService.shared.logError("Failed to refresh profile '\(profile.name)': \(error.localizedDescription)")
                    }
                }
            }

            // Publish everything staged this sweep in ONE objectWillChange,
            // then repaint the tiles from the fresh array.
            self.profileManager.publishStagedUsage()

            // An open popover is showing one account's snapshot — re-read it
            // from this sweep's fresh data.
            self.refreshViewedProfileUsage()

            // Update all icons once after all profiles are refreshed
            let config = self.profileManager.multiProfileConfig
            self.statusBarUIManager?.updateMultiProfileButtons(
                profiles: self.profileManager.profiles,
                config: config,
                context: self.fleetSummaryContext(for: config)
            )

            // Reflect the sweep's real outcome in the error-tracking state.
            if sweepSuccesses > 0 {
                self.consecutiveRefreshFailures = 0
                self.lastRefreshError = sweepFailures > 0 ? sweepLastErrorMessage : nil
                self.lastSuccessfulRefreshTime = Date()
            } else if sweepFailures > 0 {
                self.consecutiveRefreshFailures += 1
                self.lastRefreshError = sweepLastErrorMessage
            }
            self.hasCredentialError = sweepCredentialError

            // Check auto-switch for each provider's OWNER — the accounts that
            // are "in use" at any time: the Claude account the CLI is logged
            // into, the Codex account owning auth.json, and now the Grok one
            // too. Each hitting its limit rotates within its own provider
            // group. The FOCUSED profile is deliberately not in this set: it is
            // whatever the user is looking at, and looking at an exhausted
            // account must not switch a CLI off the account it is signed into.
            let idsToCheck = self.profileManager.activeAccountIds(among: self.profileManager.profiles)

            for profileId in idsToCheck {
                if let candidate = self.profileManager.profiles.first(where: { $0.id == profileId }),
                   let candidateUsage = candidate.claudeUsage {
                    self.checkAutoSwitchIfNeeded(usage: candidateUsage, currentProfile: candidate)
                }
            }

            // Route the shared CLI login to whichever profile its live identity
            // says owns it — this is how a plain `/login` in the terminal revives
            // a dead profile without switching to it (the gate refuses that) or
            // relaunching the app. Identity is cached per token, so this only
            // touches the network when the CLI's login actually changes.
            await self.profileManager.adoptSystemLoginByIdentity()

            // The Codex twin, and the reason a CLI-side `codex login` can revive
            // a dead Codex profile: re-derive auth.json's owner from its
            // account_id and adopt a fresher login into it. File read + JSON
            // parse, no network (audit H4).
            await self.profileManager.adoptCodexLoginByAccountId()

            // A CLI-side /login only writes the Keychain; keep the credentials
            // FILE in step so headless sessions that read the file aren't left
            // presenting the previous (possibly exhausted) account's token.
            await ClaudeCodeSyncService.shared.healCredentialsFileFromKeychainOffMain()

            // Learn WHOSE account each stored Claude login belongs to, one
            // profile per sweep, oldest unstamped first. Until a profile is
            // stamped, every account-keyed check (adoption matching, the
            // duplicate detector, the auto-switch's same-account skip) reads
            // nil and concludes nothing — which is how two profiles holding
            // ONE Anthropic account were displayed as two independent quotas.
            // A stamped profile is never a candidate again, so this costs one
            // request per newly-synced login and nothing in steady state.
            if !self.profileManager.isSwitchingProfile,
               await ClaudeCodeSyncService.shared.stampNextUnstampedIdentity() != nil {
                self.profileManager.loadProfiles()
            }
        }
    }

    /// Fetches usage data for a specific profile using its credentials
    private func fetchUsageForProfile(_ profile: Profile) async throws -> ClaudeUsage {
        var usage = try await fetchRawUsageForProfile(profile)
        // A window with no resets_at (rolled over while idle) parses as a
        // sentinel — replace it with this profile's last known boundary before
        // anything displays or persists the result.
        usage.healMissingResetStamps(previous: profile.claudeUsage)
        return usage
    }

    private func fetchRawUsageForProfile(_ profile: Profile) async throws -> ClaudeUsage {
        // Codex-only profiles fetch from the ChatGPT backend instead
        if profile.isCodexOnlyProfile {
            return try await CodexUsageService.shared.fetchUsage(for: profile.id)
        }

        // Grok-only profiles fetch from the Grok billing endpoint
        if profile.isGrokOnlyProfile {
            return try await GrokUsageService.shared.fetchUsage(for: profile.id)
        }

        // Priority 1: Saved CLI OAuth token from profile
        if let cliJSON = profile.cliCredentialsJSON,
           !ClaudeCodeSyncService.shared.isTokenExpired(cliJSON),
           let accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: cliJSON) {
            return try await apiService.fetchUsageData(oauthAccessToken: accessToken)
        }

        // Priority 2: System Keychain CLI OAuth token — the shared Keychain item always
        // holds the active CLAUDE account's login, so this fallback is only correct
        // for that profile. Using it for another profile would display the active
        // account's usage under that profile's name.
        if profileManager.isProviderOwner(profile.id, of: .claude),
           let systemCredentials = try? await ClaudeCodeSyncService.shared.readSystemCredentialsOffMain(),
           !ClaudeCodeSyncService.shared.isTokenExpired(systemCredentials),
           let accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: systemCredentials) {
            return try await apiService.fetchUsageData(oauthAccessToken: accessToken)
        }

        // Distinguish "credentials exist but are unusable" (expired access
        // token whose heal failed — dead/revoked refresh token) from "no
        // credentials at all": the old blanket "Missing credentials" hid
        // dead logins behind a message suggesting none were ever synced, and
        // .sessionKeyNotFound is not counted as a credential error by the
        // sweep's banner accounting (dead logins never surfaced in the UI).
        if profile.cliCredentialsJSON != nil {
            throw AppError(
                code: .sessionKeyExpired,
                message: "CLI login for '\(profile.name)' is expired and could not be refreshed — run /login with that account, then re-sync in Settings",
                isRecoverable: false
            )
        }
        throw AppError(
            code: .sessionKeyNotFound,
            message: "Missing credentials for profile '\(profile.name)'",
            isRecoverable: false
        )
    }

    private func setupSingleProfileMode() {
        guard let profile = profileManager.activeProfile else { return }

        let hasUsageCredentials = profile.hasUsageCredentials
        let config = profile.iconConfig

        // If no usage credentials, create empty config to show default logo
        let displayConfig: MenuBarIconConfiguration
        if !hasUsageCredentials {
            displayConfig = MenuBarIconConfiguration(
                colorMode: config.colorMode,
                singleColorHex: config.singleColorHex,
                showIconNames: config.showIconNames,
                metrics: config.metrics.map { metric in
                    var updatedMetric = metric
                    updatedMetric.isEnabled = false
                    return updatedMetric
                }
            )
        } else {
            displayConfig = config
        }

        statusBarUIManager?.setup(target: self, action: #selector(togglePopover), config: displayConfig)

        // Defer icon update to next run loop iteration to let NSStatusBar finalize layout
        DispatchQueue.main.async { [weak self] in
            self?.updateAllStatusBarIcons()
        }

        LoggingService.shared.log("MenuBarManager: Single profile mode enabled")
    }

    func refreshUsage() {
        // cfprefsd can accept a write in-process and never persist it — every
        // in-process read-back reports success, so only the disk disagrees
        // (audit C3, live 2026-09-03: five single-shot keys stranded for an
        // hour). Rewrite anything still missing at the top of every sweep,
        // before either mode's fetch path. A no-op with nothing pending.
        ProfileStore.shared.reassertPendingWrites()
        SharedDataStore.shared.reassertPendingWrites()

        // In multi-profile mode, refresh ALL selected profiles
        if profileManager.displayMode == .multi {
            refreshAllSelectedProfiles()
            return
        }

        // Gate the single-profile fetch path the same way as the multi sweep:
        // unhydrated credentials must not be treated as missing.
        if deferIfCredentialHydrationLoading(retry: { [weak self] in
            self?.refreshUsage()
        }) {
            return
        }

        // Single profile mode - refresh only active profile
        guard let profile = profileManager.activeProfile else {
            LoggingService.shared.log("MenuBarManager.refreshUsage: No active profile")
            return
        }

        // Detailed logging (steady-state chatter — .info, not persisted)
        LoggingService.shared.log(
            "MenuBarManager.refreshUsage called: profile '\(profile.name)', hasUsageCredentials: \(profile.hasUsageCredentials)",
            type: .info)

        // Check for usage credentials (Claude.ai or API Console, not just CLI)
        guard profile.hasUsageCredentials else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh - no usage credentials")
            // Update icons to show default logo if needed
            updateAllStatusBarIcons()
            return
        }

        // Reentrancy guard (same rationale as refreshAllSelectedProfiles): the
        // timer, the network-available callback, and manual refresh can all
        // fire this — overlapping Tasks double API load and race token
        // redemptions. Claim the flag synchronously, before the Task starts.
        guard !isRefreshing else {
            LoggingService.shared.log("MenuBarManager: refresh already in flight — skipping overlap")
            return
        }
        isRefreshing = true

        LoggingService.shared.log("MenuBarManager: Proceeding with refresh")
        Task {
            // One deferred usage write for this single-profile refresh — covers
            // Claude/API saves, throttle-stamp saves, and cancelled/error exits.
            defer {
                self.profileManager.flushPendingUsage()
                self.isRefreshing = false
            }

            // Self-heal a stale CLI OAuth token before fetching (this is what used to
            // require a manual Settings → CLI → Resync)
            await self.ensureFreshCLICredentialsIfNeeded(for: profile)

            // status.claude.com on its own 5-min cadence (F2). Start in parallel
            // with the usage fetch when due; when skipped, leave `status` untouched.
            let shouldFetchStatus = Date().timeIntervalSince(self.lastStatusFetch) >= self.statusPollInterval
            if shouldFetchStatus {
                self.lastStatusFetch = Date()
            }
            // Nested async helper so `async let` stays a single expression both
            // when a poll is due and when it is a no-op nil.
            func maybeFetchStatus() async throws -> ClaudeStatus? {
                guard shouldFetchStatus else { return nil }
                return try await statusService.fetchStatus()
            }
            async let statusResult = maybeFetchStatus()

            var usageSuccess = false

            // Fetch usage with proper error handling
            do {
                // Codex-only profiles fetch from the ChatGPT backend (the service
                // self-heals its own token); everything else uses the Claude flow.
                var newUsage: ClaudeUsage
                if profile.isCodexOnlyProfile {
                    newUsage = try await CodexUsageService.shared.fetchUsage(for: profile.id)
                } else if profile.isGrokOnlyProfile {
                    newUsage = try await GrokUsageService.shared.fetchUsage(for: profile.id)
                } else {
                    newUsage = try await apiService.fetchUsageData()
                }
                // Carry forward last known reset boundaries for windows the API
                // reported without a resets_at stamp (idle rollover — sentinel).
                newUsage.healMissingResetStamps(previous: profile.claudeUsage)

                // Stale-completion guard (Codex review): this fetch ran for the
                // profile captured at trigger time. If the user switched
                // mid-fetch, applying the result would save profile A's usage
                // under the NEW active profile — while the new profile's own
                // refresh was rejected by the reentrancy guard. Discard and
                // re-run once the deferred cleanup has released the guard.
                guard self.profileManager.activeProfile?.id == profile.id else {
                    LoggingService.shared.log(
                        "MenuBarManager: discarding refresh result for '\(profile.name)' — active profile changed mid-fetch; re-refreshing")
                    DispatchQueue.main.async { [weak self] in self?.refreshUsage() }
                    return
                }

                // Check for resets before updating usage
                self.usage = newUsage

                // Save against the CAPTURED profile id (== active, per the
                // guard above), never "whoever is active at completion".
                self.profileManager.saveClaudeUsage(newUsage, for: profile.id)

                // Update all menu bar icons
                self.updateAllStatusBarIcons()

                // Check if we should send notifications (using active profile's settings)
                if let profile = self.profileManager.activeProfile {
                    NotificationManager.shared.checkAndNotify(
                        usage: newUsage,
                        profileName: profile.name,
                        settings: profile.effectiveNotificationSettings(fleet: SharedDataStore.shared.loadFleetAlertDefaults())
                    )

                    // Check if auto-switch should trigger. This path FETCHES for
                    // the VIEWED profile — that is what single-profile mode
                    // displays, and it stays keyed on the view — but the trigger
                    // is owner-only, so a merely-viewed account cannot rotate
                    // somebody else's login. (`checkAutoSwitchIfNeeded` guards
                    // the same way; this one keeps the rule visible where the
                    // call is made.)
                    if self.mayTriggerAutoSwitch(profile.id) {
                        self.checkAutoSwitchIfNeeded(usage: newUsage, currentProfile: profile)
                    }
                }

                // Record success for circuit breaker
                ErrorRecovery.shared.recordSuccess(for: .api)
                usageSuccess = true

                self.consecutiveRefreshFailures = 0
                self.lastRefreshError = nil
                self.hasCredentialError = false
                if let profileId = self.profileManager.activeProfile?.id {
                    self.credentialErrorProfileIds.remove(profileId)
                }
                self.lastSuccessfulRefreshTime = Date()
                self.recordClaudeUsageSuccess(profile, usage: newUsage)

            } catch {
                // Same stale-completion guard as the success path: error state
                // (banners, credential flags, throttle stamps) must not be
                // attributed to a profile the failure didn't belong to.
                guard self.profileManager.activeProfile?.id == profile.id else {
                    LoggingService.shared.log(
                        "MenuBarManager: discarding refresh failure for '\(profile.name)' — active profile changed mid-fetch; re-refreshing")
                    DispatchQueue.main.async { [weak self] in self?.refreshUsage() }
                    return
                }

                // Convert to AppError and log
                let appError = AppError.wrap(error)
                ErrorLogger.shared.log(appError, severity: .error)

                // Record failure for circuit breaker
                ErrorRecovery.shared.recordFailure(for: .api)

                // Track error state for UI banners
                self.consecutiveRefreshFailures += 1
                self.lastRefreshError = appError.message

                // Track credential errors specifically
                if appError.code == .apiUnauthorized || appError.code == .sessionKeyExpired {
                    self.hasCredentialError = true
                    if let profileId = self.profileManager.activeProfile?.id {
                        self.credentialErrorProfileIds.insert(profileId)
                    }
                }

                // Account-level throttle: reflect it instead of keeping a
                // frozen pre-throttle percentage on screen (see the sweep-path
                // twin of this call for the full rationale).
                if let stamped = self.stampAccountThrottleIfNeeded(appError, profile: profile) {
                    self.usage = stamped
                    self.updateAllStatusBarIcons()
                    self.checkAutoSwitchIfNeeded(usage: stamped, currentProfile: profile)
                }

                // Check if this refresh was triggered within last 5 seconds
                // (indicates user-initiated action like saving session key)
                if abs(self.lastRefreshTriggerTime.timeIntervalSinceNow) < 5 {
                    ErrorPresenter.shared.showAlert(for: appError)
                } else {
                    // Background refresh - just log
                    LoggingService.shared.logError("MenuBarManager: Failed to fetch usage - [\(appError.code.rawValue)] \(appError.message)")
                }
            }

            // Apply status only when a poll returned a value (don't fail if usage
            // works). When skipped, statusResult is nil and `status` is untouched.
            do {
                if let newStatus = try await statusResult {
                    self.status = newStatus
                }
            } catch {
                // Convert to AppError and log
                let appError = AppError.wrap(error)
                ErrorLogger.shared.log(appError, severity: .info)

                // Don't show error for status - it's not critical
                LoggingService.shared.log("MenuBarManager: Failed to fetch status - [\(appError.code.rawValue)] \(appError.message)")
            }

            // Show success notification if this was user-triggered and successful
            if usageSuccess && abs(self.lastRefreshTriggerTime.timeIntervalSinceNow) < 5 {
                self.showSuccessNotification()
            }
        }
    }

    /// Shows a brief success notification for user-triggered refreshes
    private func showSuccessNotification() {
        NotificationManager.shared.sendSuccessNotification()
    }

    // MARK: - Manual Popover Refresh

    /// The popover's bottom-bar refresh button. Single-profile mode already
    /// refreshes exactly the active profile via `refreshUsage()`. In
    /// multi-profile mode the old routing kicked a full sweep, which spends
    /// its rate-limit budget on the ROTATION's pick — not necessarily the
    /// account on screen — and skips a burst-backed-off profile outright
    /// (observed 2026-08-11: the active account at 97% sat inside a 120s
    /// backoff; a click refreshed everything except the number the user was
    /// looking at). A deliberate click means "THIS account, now": fetch just
    /// the viewed (else active) profile.
    func refreshFromPopover() {
        if profileManager.displayMode == .multi {
            refreshViewedOrActiveProfile()
        } else {
            refreshUsage()
        }
    }

    /// The account a manual popover refresh targets: the profile the popover
    /// is viewing when it still exists, else the focused profile. A viewed id
    /// whose profile was deleted mid-popover falls back instead of no-op'ing.
    nonisolated static func resolveManualRefreshTarget(
        viewedId: UUID?,
        profiles: [Profile],
        activeProfile: Profile?
    ) -> Profile? {
        viewedId.flatMap { id in profiles.first(where: { $0.id == id }) } ?? activeProfile
    }

    /// Multi-profile manual refresh: fetch exactly the profile the popover is
    /// viewing (`clickedProfileId` — set on every popover open, tile click,
    /// and group-navigator step), falling back to the focused profile. The
    /// single extra request is user-initiated and rare, so it clears any
    /// burst backoff on the target; an account-level throttle stamp is
    /// honored (the endpoint told us when to come back, and the tiles
    /// already report 100% while it lives).
    private func refreshViewedOrActiveProfile() {
        if deferIfCredentialHydrationLoading(retry: { [weak self] in
            self?.refreshViewedOrActiveProfile()
        }) {
            return
        }
        // Same hazards as the sweep: never fetch mid-switch (Keychain
        // adoption contamination), never overlap an in-flight refresh (the
        // running sweep now fetches the priority profiles FIRST, so the
        // number on screen is at most one sweep away).
        guard !profileManager.isSwitchingProfile else {
            LoggingService.shared.log("MenuBarManager: manual refresh skipped — profile switch in progress")
            return
        }
        let target = Self.resolveManualRefreshTarget(
            viewedId: clickedProfileId,
            profiles: profileManager.profiles,
            activeProfile: profileManager.activeProfile
        )
        guard let target, target.hasUsageCredentials else {
            LoggingService.shared.log("MenuBarManager: manual refresh skipped — no refreshable target profile")
            return
        }
        // Only a SERVER-AFFIRMED throttle blocks a manual refresh; a suspected
        // (inferred) stamp must let the click through — the user's fetch is
        // exactly the confirmation/clearing probe.
        if (target.claudeUsage?.rateLimitedUntil.map({ $0 > Date() }) ?? false)
            && target.claudeUsage?.rateLimitedInferred != true {
            LoggingService.shared.log("MenuBarManager: manual refresh for '\(target.name)' skipped — account-level throttle until \(target.claudeUsage?.rateLimitedUntil ?? Date())")
            return
        }
        guard !isRefreshing else {
            LoggingService.shared.log("MenuBarManager: manual refresh skipped — refresh already in flight")
            return
        }
        isRefreshing = true
        // User-initiated: a burst backoff must not eat the click — expire the
        // wait but KEEP the streak, so repeated clicks against a persistently
        // 429ing account still accumulate the evidence the inferred-throttle
        // stamp needs (removeValue here would reset the streak to 0 and make
        // manual retries unable to ever prove account-level exhaustion).
        if var backoff = burstBackoffs[target.id] {
            backoff.until = Date()
            burstBackoffs[target.id] = backoff
        }
        LoggingService.shared.log("MenuBarManager: manual refresh for '\(target.name)' (popover)")

        Task {
            defer {
                self.profileManager.publishStagedUsage()
                self.profileManager.flushPendingUsage()
                self.isRefreshing = false
            }

            // Self-heal a stale CLI OAuth token, then re-read the profile so
            // the fetch sees the repaired credentials.
            await self.ensureFreshCLICredentialsIfNeeded(for: target)
            var profile = target
            if let updated = self.profileManager.profiles.first(where: { $0.id == target.id }) {
                profile = updated
            }
            // Stamp the scheduler's attempt clock so the next sweep's budget
            // is not spent re-fetching what the user just refreshed.
            if profile.providerKind == .claude {
                self.backgroundFetchAttempts[profile.id] = Date()
            }

            // Gates the auto-switch below, so it is an OWNER test: a manual
            // refresh on the account the user is merely viewing must report its
            // numbers, not rotate a CLI login.
            let isActiveAccount = self.mayTriggerAutoSwitch(profile.id)

            do {
                let newUsage = try await self.fetchUsageForProfile(profile)
                self.profileManager.stageClaudeUsage(newUsage, for: profile.id)
                // DISPLAY ONLY: the headline number belongs to the profile being
                // VIEWED, which is exactly what the focus names.
                if profile.id == self.profileManager.activeProfile?.id {
                    self.usage = newUsage
                }
                self.credentialErrorProfileIds.remove(profile.id)
                self.burstBackoffs.removeValue(forKey: profile.id)
                self.recordClaudeUsageSuccess(profile, usage: newUsage)
                self.consecutiveRefreshFailures = 0
                self.lastRefreshError = nil
                self.lastSuccessfulRefreshTime = Date()
                if isActiveAccount {
                    self.checkAutoSwitchIfNeeded(usage: newUsage, currentProfile: profile)
                }
                LoggingService.shared.log("MenuBarManager: manual refresh saved usage for '\(profile.name)' - session: \(newUsage.sessionPercentage)%", type: .info)
            } catch {
                let appError = AppError.wrap(error)

                // Same rescue as the sweep: the user clicked refresh on the
                // account being burned and the usage endpoint refused — read
                // the live counters off the Messages API headers instead of
                // showing them a stale number.
                if appError.code == .apiRateLimited,
                   let rescued = await self.probeUsageViaMessageHeaders(for: profile) {
                    self.profileManager.stageClaudeUsage(rescued, for: profile.id)
                    if profile.id == self.profileManager.activeProfile?.id {
                        self.usage = rescued
                    }
                    self.credentialErrorProfileIds.remove(profile.id)
                    self.burstBackoffs.removeValue(forKey: profile.id)
                    self.recordClaudeUsageSuccess(profile, usage: rescued, countsAsEndpointControl: false)
                    self.consecutiveRefreshFailures = 0
                    self.lastRefreshError = nil
                    self.lastSuccessfulRefreshTime = Date()
                    if isActiveAccount {
                        self.checkAutoSwitchIfNeeded(usage: rescued, currentProfile: profile)
                    }
                    self.profileManager.publishStagedUsage()
                    self.refreshViewedProfileUsage()
                    self.statusBarUIManager?.updateMultiProfileButtons(
                        profiles: self.profileManager.profiles,
                        config: self.profileManager.multiProfileConfig,
                        context: self.fleetSummaryContext(for: self.profileManager.multiProfileConfig)
                    )
                    return
                }

                self.lastRefreshError = appError.message
                if appError.code == .apiUnauthorized || appError.code == .sessionKeyExpired {
                    self.credentialErrorProfileIds.insert(profile.id)
                }
                // Mirror the sweep's 429 taxonomy: a long account-level
                // Retry-After stamps exhaustion; a burst-class 429 re-arms
                // the backoff this click just cleared.
                if let stamped = self.stampAccountThrottleIfNeeded(appError, profile: profile) {
                    if isActiveAccount {
                        self.checkAutoSwitchIfNeeded(usage: stamped, currentProfile: profile)
                    }
                } else if appError.code == .apiRateLimited {
                    self.registerBurstBackoff(for: profile, retryAfter: appError.retryAfterSeconds)
                    if profile.providerKind == .claude,
                       let streak = self.burstBackoffs[profile.id]?.streak,
                       Self.shouldInferAccountThrottle(
                           streak: streak,
                           profileId: profile.id,
                           isActiveAccount: isActiveAccount,
                           cachedUsage: profile.claudeUsage,
                           lastClaudeSuccess: self.lastClaudeUsageSuccess,
                           now: Date()
                       ) {
                        // Never a switch trigger (autoSwitchTriggerUsage strips
                        // it) — an active account gets a one-shot notification.
                        self.stampInferredAccountThrottle(profile, streak: streak)
                        self.notifyInferredThrottleIfNeeded(profile)
                    }
                    self.updateSuspectedProjection(for: profile.id)
                }
                LoggingService.shared.logError("Manual refresh failed for '\(profile.name)': \(appError.message)")
            }

            // Publish the staged result, then repaint from the fresh array —
            // the open popover's snapshot and this profile's tile.
            self.profileManager.publishStagedUsage()
            self.refreshViewedProfileUsage()
            self.statusBarUIManager?.updateMultiProfileButtons(
                profiles: self.profileManager.profiles,
                config: self.profileManager.multiProfileConfig,
                context: self.fleetSummaryContext(for: self.profileManager.multiProfileConfig)
            )
        }
    }

    // MARK: - CLI Token Self-Healing

    /// If the profile's stored CLI OAuth token is stale, repair it before the fetch:
    /// adopt the CLI's silently-refreshed token from the system Keychain (active
    /// profile only — that item always holds the ACTIVE account's login) or redeem
    /// the refresh token, then reload profiles so the fetch sees the new token.
    /// Without this, an expired stored token froze the displayed usage until the
    /// user manually resynced in Settings → CLI.
    private func ensureFreshCLICredentialsIfNeeded(for profile: Profile) async {
        guard let cliJSON = profile.cliCredentialsJSON else { return }

        let syncService = ClaudeCodeSyncService.shared
        if let expiry = syncService.extractTokenExpiry(from: cliJSON),
           expiry > Date().addingTimeInterval(300) {
            return  // token still comfortably valid — skip the Keychain subprocess
        }

        // "Active" here means: this profile owns the Claude Code CLI Keychain login
        // (tracked separately from the focused profile — the focus may be on a
        // Codex profile while this Claude account is still the CLI's login).
        let isActiveClaude = profileManager.isProviderOwner(profile.id, of: .claude)
        let changed = await syncService.ensureFreshCredentials(
            for: profile.id,
            adoptSystemKeychain: isActiveClaude,
            syncToSystem: isActiveClaude
        )
        if changed {
            profileManager.loadProfiles()
            LoggingService.shared.log("MenuBarManager: CLI credentials self-healed for '\(profile.name)'")
        }
    }

    // MARK: - Background Fetch Scheduling

    /// One background Claude profile as the sweep scheduler sees it.
    struct BackgroundFetchCandidate {
        let id: UUID
        /// Last fetch ATTEMPT if one happened this run, else the cached usage's
        /// `lastUpdated`, else nil (never fetched — highest urgency).
        let lastAttempt: Date?
        /// Cached usage is already near a limit (see `isNearLimit`).
        let isHot: Bool
        /// False when a fetch would only burn the slot: throttle-stamped,
        /// burst-backed-off, or dead CLI login.
        let isEligible: Bool
    }

    /// A cached session percentage at/above this marks the account as "hot":
    /// some CLI session is actively burning it, and it can hit the hard limit
    /// within a couple of rotation cycles. (Idle accounts read 0% — the 5h
    /// window expires — so any substantial session usage means recent activity.)
    nonisolated static let hotSessionThreshold: Double = 50
    /// Weekly (or Fable-weekly) percentage at/above this marks the account hot:
    /// weekly limits move slowly but are unrecoverable until the weekly reset,
    /// so near-cap accounts deserve fresh numbers too.
    nonisolated static let hotWeeklyThreshold: Double = 80
    /// Hot accounts sample this many times as often as cold ones (their
    /// staleness score grows this much faster). Budget-neutral: it reallocates
    /// the same ~1 request per sweep, it never adds requests.
    nonisolated static let hotFetchWeight: Double = 3

    /// True when the cached usage says the account is close enough to a limit
    /// that stale numbers are dangerous (auto-switch decisions, the user
    /// picking an account for a new session).
    nonisolated static func isNearLimit(_ usage: ClaudeUsage?) -> Bool {
        guard let usage else { return false }
        if usage.effectiveSessionPercentage >= hotSessionThreshold { return true }
        return max(usage.weeklyPercentage, usage.fableWeeklyPercentage ?? 0) >= hotWeeklyThreshold
    }

    /// Picks which background Claude profiles this sweep's rotation budget goes
    /// to: the ELIGIBLE candidates with the highest staleness score, where
    /// score = seconds since last attempt × (hot ? hotFetchWeight : 1).
    /// Properties that make this safe:
    /// - never-attempted candidates (nil lastAttempt) always win first;
    /// - starvation-free — an unpicked candidate's score only grows, so it
    ///   eventually beats every hot account (steady state: hot accounts
    ///   refresh ~hotFetchWeight× as often, cold accounts still cycle);
    /// - ineligible candidates cost nothing — the budget always goes to
    ///   profiles that can actually produce fresh usage (under the old
    ///   round-robin cursor, a dead login burned a slot every cycle);
    /// - stateless between sweeps apart from the attempt stamps — profile
    ///   membership can churn (switches add/remove priority accounts) without
    ///   aliasing, which the positional cursor could not guarantee.
    nonisolated static func selectBackgroundFetchIds(
        candidates: [BackgroundFetchCandidate],
        budget: Int,
        now: Date
    ) -> [UUID] {
        guard budget > 0 else { return [] }
        return candidates
            .filter(\.isEligible)
            .map { candidate -> (id: UUID, score: Double) in
                let age = now.timeIntervalSince(candidate.lastAttempt ?? .distantPast)
                return (candidate.id, age * (candidate.isHot ? hotFetchWeight : 1))
            }
            .sorted { $0.score > $1.score }
            .prefix(budget)
            .map(\.id)
    }

    /// Selection-time mirror of the in-loop skip checks (throttled /
    /// burst-backed-off / dead login) so an unfetchable background profile
    /// never receives a rotation slot in the first place. The in-loop checks
    /// stay as the race-safety belt — a throttle stamp or dead flag can land
    /// between selection and the profile's turn — and they alone cover the
    /// PRIORITY profiles, which bypass this scheduler.
    private func isBackgroundFetchIneligible(_ profile: Profile) -> Bool {
        // Server-affirmed throttles only: a SUSPECTED (inferred) profile stays
        // eligible — its stamp also reads as hot to the scheduler, so it gets
        // re-probed at priority and one 200 clears the suspicion.
        if (profile.claudeUsage?.rateLimitedUntil.map({ $0 > Date() }) ?? false)
            && profile.claudeUsage?.rateLimitedInferred != true { return true }
        if burstBackoffs[profile.id].map({ $0.until > Date() }) ?? false { return true }
        if authBackoffs[profile.id].map({ $0.until > Date() }) ?? false { return true }
        // Background candidates are never a provider-active profile, so unlike
        // the in-loop check no active-profile exemption is needed here.
        return shouldSkipFetchForDeadLogin(profile, exemptProviderActive: false)
    }

    // MARK: - Dead-Login Fetch Skip (per provider)

    /// Whether this sweep should skip fetching a profile whose provider login is
    /// flagged dead.
    ///
    /// Claude and Codex/Grok need different rules because their tokens have
    /// different lifetimes. A Claude access token lives hours, so "flagged AND
    /// expired" is reached quickly and the skip can be permanent until a
    /// re-login. A Codex access token lives ~10 DAYS: the same rule would almost
    /// never fire (the live incident: 1,009 401s against an unexpired token),
    /// while skipping on the flag ALONE would remove the only thing that can
    /// clear it — a 200. So the Codex/Grok arm pairs the flag with the 401
    /// backoff window: skipped while the window stands, one confirming fetch
    /// when it expires, and a success clears flag and backoff together.
    private func shouldSkipFetchForDeadLogin(_ profile: Profile, exemptProviderActive: Bool = true) -> Bool {
        switch profile.providerKind {
        case .claude:
            let exempt = exemptProviderActive && profileManager.isProviderOwner(profile.id, of: .claude)
            return ClaudeCodeSyncService.shared.isLoginMarkedDead(profile.id)
                && !profile.hasValidCLIOAuth
                && !exempt
        case .codex:
            guard CodexUsageService.shared.isLoginMarkedDead(profile.id) else { return false }
            let exempt = exemptProviderActive && profileManager.isProviderOwner(profile.id, of: .codex)
            return !exempt && (authBackoffs[profile.id]?.until).map { $0 > Date() } ?? false
        case .grok:
            guard GrokUsageService.shared.isLoginMarkedDead(profile.id) else { return false }
            // Grok has a pointer of its own now, so the exemption is the same
            // owner test as the other two. It used to read the FOCUS, which
            // exempted whichever Grok account the user happened to be looking at
            // and left the real owner's dead login skipped.
            let exempt = exemptProviderActive && profileManager.isProviderOwner(profile.id, of: .grok)
            return !exempt && (authBackoffs[profile.id]?.until).map { $0 > Date() } ?? false
        }
    }

    // MARK: - 401 Fetch Backoff

    /// Auth failures have no Retry-After to honour, so the schedule is fixed:
    /// 5 minutes, doubling to a 60-minute cap. A provider-active account is
    /// capped at the first step — its number gates the auto-switch, and its
    /// login can be revived out-of-band by a CLI-side login at any moment.
    /// Reset by the first successful fetch (which also clears the dead flag).
    nonisolated static func authBackoffInterval(streak: Int, isActiveAccount: Bool) -> TimeInterval {
        min(300 * pow(2, Double(max(0, streak - 1))), isActiveAccount ? 300 : 3600)
    }

    private var authBackoffs: [UUID: BurstBackoff] = [:]

    private func registerAuthBackoff(for profile: Profile) {
        let streak = (authBackoffs[profile.id]?.streak ?? 0) + 1
        let isActiveAccount = profileManager.isProviderOwner(profile.id)
        let interval = Self.authBackoffInterval(streak: streak, isActiveAccount: isActiveAccount)
        authBackoffs[profile.id] = BurstBackoff(until: Date().addingTimeInterval(interval), streak: streak)
        LoggingService.shared.log("MenuBarManager: '\(profile.name)' usage fetch was rejected (401/expired, active: \(isActiveAccount)) — backing off for \(clampedInt(interval))s (streak \(streak))")
    }

    // MARK: - Burst-429 Fetch Backoff

    /// A 429 WITHOUT an account-level Retry-After (header absent or
    /// seconds-scale) never stamps `rateLimitedUntil`, so nothing stopped the
    /// sweep from re-fetching — and re-429ing — the same profile every 30s
    /// forever (a real profile drew 90 identical 429s in one hour, flipping
    /// its tile's error state on every sweep). Back that profile's usage
    /// fetch off exponentially instead: 2min, 4, 8, … capped at 30min, reset
    /// by the first successful fetch. In-memory only — retrying immediately
    /// after a relaunch is fine.
    private struct BurstBackoff {
        var until: Date
        var streak: Int
    }
    private var burstBackoffs: [UUID: BurstBackoff] = [:]

    /// The most recent SUCCESSFUL Claude usage fetch (any profile). This is the
    /// control evidence behind `shouldInferAccountThrottle`: a success seconds
    /// ago proves the shared IP is not being burst-limited, so a profile that
    /// keeps 429ing anyway is being refused at the ACCOUNT level.
    private var lastClaudeUsageSuccess: (profileId: UUID, at: Date)?

    /// Recent MEASURED session percentages per profile (newest last, max
    /// `measuredHistoryCapacity`), PERSISTED via SharedDataStore. Feeds the
    /// burn-rate projection that keeps a suspected profile's display honest
    /// while reads fail — only real fetch results are recorded, never stamps
    /// or projections. Persisted because an in-memory basis died at every
    /// relaunch: the 2026-08-12 deploy wiped it mid-incident and 'Commits'
    /// fell back to a frozen 67% (real 100%) with nothing to project from.
    private lazy var measuredSessionHistory: [UUID: [(at: Date, pct: Double)]] =
        SharedDataStore.shared.loadMeasuredSessionHistory()
    private static let measuredHistoryCapacity = 4

    private func recordMeasuredSession(_ usage: ClaudeUsage, for profileId: UUID) {
        guard usage.providesSessionWindow else { return }
        var history = measuredSessionHistory[profileId] ?? []
        history.append((Date(), usage.sessionPercentage))
        if history.count > Self.measuredHistoryCapacity {
            history.removeFirst(history.count - Self.measuredHistoryCapacity)
        }
        measuredSessionHistory[profileId] = history
        SharedDataStore.shared.saveMeasuredSessionHistory(measuredSessionHistory)
    }

    /// Best-estimate session percentage while reads fail: the last measured
    /// value projected forward at the recent measured burn rate. Returns nil
    /// when there is nothing defensible to project: fewer than two samples,
    /// a flat/declining trend (idle accounts must not creep upward on noise),
    /// a burn window shorter than a sweep, or a session boundary crossed
    /// since the last sample (the window rolled — the projection basis died).
    /// Clamped to 100. The 0.2pp/min floor rejects measurement jitter.
    nonisolated static func projectSessionPercentage(
        history: [(at: Date, pct: Double)],
        sessionResetTime: Date,
        now: Date
    ) -> Double? {
        guard sessionResetTime > now else { return nil }
        // Persisted samples can predate the CURRENT 5h window (history now
        // survives relaunches) — a rate measured across a window rollover
        // projects garbage. Every sample must belong to the window that
        // ends at sessionResetTime.
        let windowStart = sessionResetTime.addingTimeInterval(-Constants.sessionWindow)
        let history = history.filter { $0.at >= windowStart }
        guard let last = history.last, let first = history.first, history.count >= 2 else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= 25 else { return nil }
        let ratePerSecond = (last.pct - first.pct) / span
        guard ratePerSecond * 60 >= 0.2 else { return nil }
        let projected = last.pct + ratePerSecond * now.timeIntervalSince(last.at)
        return min(max(projected, last.pct), 100)
    }

    /// Refresh a suspected profile's displayed estimate after another failed
    /// read, and — when the ACTIVE account's estimate crosses the auto-switch
    /// threshold — tell the user once per episode: the trigger itself stays
    /// measured-only (a projection must never spend the ~10-15%-per-session
    /// cost of a switch), but the user must not be left watching a frozen
    /// 67% while their sessions hit the hard limit (2026-08-12 incident).
    private func updateSuspectedProjection(for profileId: UUID) {
        // Re-read: the caller's copy predates any stamp applied this cycle.
        guard let profile = profileManager.profiles.first(where: { $0.id == profileId }) else { return }
        guard var usage = profile.claudeUsage, usage.isSuspectedRateLimited else { return }
        guard let projected = Self.projectSessionPercentage(
            history: measuredSessionHistory[profile.id] ?? [],
            sessionResetTime: usage.sessionResetTime,
            now: Date()
        ) else { return }
        usage.projectedSessionPercentage = projected
        profileManager.saveClaudeUsage(usage, for: profile.id)

        let isActiveClaude = profileManager.isProviderOwner(profile.id, of: .claude)
        if isActiveClaude,
           projected >= SharedDataStore.shared.loadAutoSwitchThreshold(),
           !projectionNotifiedIds.contains(profile.id) {
            projectionNotifiedIds.insert(profile.id)
            NotificationManager.shared.sendProjectedExhaustionNotification(
                profileName: profile.name,
                projectedPercentage: projected
            )
        }
    }

    /// Profiles already notified that their projection crossed the switch
    /// threshold this episode — cleared by the next successful fetch.
    private var projectionNotifiedIds: Set<UUID> = []

    // MARK: - Local Ground-Truth Signals (CLI transcripts + cache)

    /// Scan cursor for the transcript tripwire; events at/before
    /// `lastTripwireEventAt` are already handled.
    private var lastTripwireScan: Date = Date().addingTimeInterval(-600)
    private var lastTripwireEventAt: Date = .distantPast

    /// Harvests Claude Code's own on-disk limit signals at the top of every
    /// sweep — zero network cost, and immune to the 429 blindness that hits
    /// the usage endpoint exactly when an account burns hardest:
    /// - a transcript `error: "rate_limit"` event means a session DIED on the
    ///   API's own 429 — server-affirmed exhaustion of whichever account
    ///   owned the shared CLI login at that moment ('Commits' displayed 67%
    ///   for 35 min while this exact event sat on disk, 2026-08-12);
    /// - `~/.claude.json`'s cachedUsageUtilization is the CLI's own last
    ///   usage fetch — adopted as a free measurement when fresher than ours.
    private func harvestLocalLimitSignals() async {
        let since = min(lastTripwireScan, Date().addingTimeInterval(-90))
        lastTripwireScan = Date()
        let signals = await Task.detached(priority: .utility) {
            (events: LocalLimitSignalService.scanRateLimitEvents(since: since),
             cliCache: LocalLimitSignalService.readCLICachedUsage())
        }.value

        if let event = signals.events.last, event.at > lastTripwireEventAt {
            lastTripwireEventAt = event.at
            applyTranscriptRateLimitEvent(event)
        }
        if let cache = signals.cliCache {
            adoptCLICachedUsage(cache)
        }
    }

    /// The account that owned the shared CLI login when the event fired: the
    /// switch history's first switch AFTER the event names who it was taken
    /// from; no later switch means the current owner. (The event may be
    /// minutes old — attributing it to the CURRENT owner after the user
    /// already switched away would exhaust-stamp the wrong account.)
    private func attributeRateLimitEvent(at eventTime: Date) -> Profile? {
        let history = SharedDataStore.shared.loadSwitchHistory()
        let claudeNames = Set(
            profileManager.profiles
                .filter { !$0.isCodexOnlyProfile && !$0.isGrokOnlyProfile }
                .map(\.name)
        )
        if let ownerName = Self.rateLimitEventOwnerName(
            history: history, eventTime: eventTime, claudeProfileNames: claudeNames
        ) {
            return profileManager.profiles.first(where: { $0.name == ownerName })
        }
        let activeId = profileManager.providerOwnerId(for: .claude)
        return profileManager.profiles.first(where: { $0.id == activeId })
    }

    /// Name of the CLAUDE account that owned the shared CLI login when a
    /// transcript rate-limit event fired: the first switch AFTER the event
    /// whose outgoing profile is a Claude one. Codex and Grok switches share
    /// the same history ring, and skipping past them matters — the owner
    /// switches Codex accounts between Claude ones, and treating a Codex
    /// switch as "not attributable" dropped the Claude exhaustion event
    /// entirely. Returns nil when no Claude switch follows the event: the
    /// caller then attributes it to the current Claude owner.
    nonisolated static func rateLimitEventOwnerName(
        history: [SwitchEvent],
        eventTime: Date,
        claudeProfileNames: Set<String>
    ) -> String? {
        history
            .filter { $0.at >= eventTime }
            .sorted { $0.at < $1.at }
            .first(where: { claudeProfileNames.contains($0.from) })?
            .from
    }

    private func applyTranscriptRateLimitEvent(_ event: LocalLimitSignalService.RateLimitEvent) {
        guard let profile = attributeRateLimitEvent(at: event.at) else { return }
        var usage = profile.claudeUsage ?? .empty
        // Server-affirmed (a real session died on the API's 429): display
        // reads 100 through the affirmed-stamp seam, sweeps skip until the
        // window resets, the auto-switch may act on it.
        usage.rateLimitedUntil = event.resetsAt ?? event.at.addingTimeInterval(1800)
        usage.rateLimitedInferred = nil
        usage.projectedSessionPercentage = nil
        if let resetsAt = event.resetsAt {
            usage.sessionResetTime = resetsAt
        }
        usage.lastUpdated = event.at
        profileManager.saveClaudeUsage(usage, for: profile.id)
        LoggingService.shared.log("MenuBarManager: transcript rate-limit event — '\(profile.name)' hit its session limit at \(event.at), resets \(event.resetsAt.map(String.init(describing:)) ?? "unknown (30min stamp)")")
        // Filed at the EVENT's time, not now: the tripwire routinely reads a
        // transcript minutes old, and the dashboard's 24 h window must age it
        // from when the session actually died.
        incidentRing.record(FleetInsights.Incident(
            at: event.at, profileId: profile.id, name: profile.name, provider: .claude, kind: .tripwire,
            detail: "session limit, resets \(event.resetsAt.map(String.init(describing:)) ?? "unknown (30min stamp)")"))
        if mayTriggerAutoSwitch(profile.id) {
            checkAutoSwitchIfNeeded(usage: usage, currentProfile: profile)
        }
    }

    /// Adopts the CLI's cached bars for the profile whose persisted account
    /// uuid matches — a real measurement (the CLI paid for the fetch), so it
    /// feeds the projection history and clears suspicion like any 200.
    private func adoptCLICachedUsage(_ cache: LocalLimitSignalService.CLICachedUsage) {
        guard let profile = profileManager.profiles.first(where: { $0.claudeAccountUUID == cache.accountUuid }),
              let sessionPercent = cache.sessionPercent else { return }
        let currentUpdated = profile.claudeUsage?.lastUpdated ?? .distantPast
        guard cache.fetchedAt > currentUpdated.addingTimeInterval(5) else { return }

        var usage = profile.claudeUsage ?? .empty
        usage.sessionPercentage = sessionPercent
        if let resets = cache.sessionResetsAt { usage.sessionResetTime = resets }
        if let weekly = cache.weeklyPercent { usage.weeklyPercentage = weekly }
        if let weeklyResets = cache.weeklyResetsAt { usage.weeklyResetTime = weeklyResets }
        if let fable = cache.fablePercent { usage.fableWeeklyPercentage = fable }
        if let fableResets = cache.fableResetsAt { usage.fableWeeklyResetTime = fableResets }
        // A fresh real measurement supersedes suspicion — same semantics as
        // a successful fetch of our own.
        usage.rateLimitedUntil = nil
        usage.rateLimitedInferred = nil
        usage.projectedSessionPercentage = nil
        usage.lastUpdated = cache.fetchedAt
        // Attributed to this account by identity, not read with its own
        // credentials — the dashboard labels it and never shows it as the
        // active card's headline measurement.
        usage.provenance = .cliCache
        profileManager.saveClaudeUsage(usage, for: profile.id)
        recordMeasuredSession(usage, for: profile.id)
        burstBackoffs.removeValue(forKey: profile.id)
        inferredThrottleNotifiedIds.remove(profile.id)
        projectionNotifiedIds.remove(profile.id)
        LoggingService.shared.log("MenuBarManager: adopted CLI cached usage for '\(profile.name)' — session \(Int(sessionPercent))% fetched \(Int(-cache.fetchedAt.timeIntervalSinceNow))s ago (zero-cost)", type: .info)
        if mayTriggerAutoSwitch(profile.id) {
            checkAutoSwitchIfNeeded(usage: usage, currentProfile: profile)
        }
    }

    // MARK: - Blind Active Account: Messages-API header rescue

    /// Minimum spacing between header probes for one profile. The probe costs a
    /// `max_tokens: 1` Haiku request; one per minute for ONE account is noise
    /// against a 5-hour window, and it only runs while `oauth/usage` refuses.
    nonisolated static let headerProbeMinInterval: TimeInterval = 60

    /// Last Messages-API header probe per profile (in-memory: after a relaunch
    /// the first blind sweep may probe immediately, which is what we want).
    private var lastHeaderProbeAt: [UUID: Date] = [:]

    /// Whether a refused `oauth/usage` read may be rescued by reading the
    /// account's live counters from the Messages API headers.
    ///
    /// Deliberately narrow — this is the only path in the app that SPENDS
    /// quota to measure it:
    /// - provider-active Claude account only: it is the one whose number gates
    ///   the switch-away decision, and the one the fleet is burning;
    /// - its session window must already be OPEN AND NON-EMPTY. A request
    ///   against an idle account would START its 5-hour window (windows begin
    ///   at the first request), stealing headroom from an account we are
    ///   holding in reserve as a switch target;
    /// - at most one probe per `headerProbeMinInterval` per profile.
    nonisolated static func shouldProbeMessageHeaders(
        isActiveClaudeAccount: Bool,
        cached: ClaudeUsage?,
        lastProbe: Date?,
        now: Date = Date()
    ) -> Bool {
        guard isActiveClaudeAccount, let cached else { return false }
        guard cached.providesSessionWindow else { return false }
        // Window already open and already burning — the probe cannot be what
        // opens it. (A fabricated/healed boundary always pairs with 0%.)
        guard cached.sessionResetTime > now, cached.sessionPercentage > 0 else { return false }
        guard let lastProbe else { return true }
        return now.timeIntervalSince(lastProbe) >= headerProbeMinInterval
    }

    /// Reads the active account's live 5h/7d counters from the Messages API
    /// headers after `oauth/usage` refused, and folds them onto its cached
    /// usage. Returns nil when the probe is not allowed, has no token, or
    /// fails — callers then fall through to the existing 429 handling.
    ///
    /// The 2026-08-13 incident this closes: 'BBR' (06:36→06:59) and 'Outlook'
    /// (12:41→13:40) were burned 0→100% by ~30 parallel sessions while their
    /// own usage endpoint refused most reads, so the widget's number never
    /// even reached the 25% preflight milestone and the 95% switch never fired.
    private func probeUsageViaMessageHeaders(for profile: Profile) async -> ClaudeUsage? {
        let isActiveClaudeAccount = profile.providerKind == .claude
            && profileManager.isProviderOwner(profile.id, of: .claude)
        guard Self.shouldProbeMessageHeaders(
            isActiveClaudeAccount: isActiveClaudeAccount,
            cached: profile.claudeUsage,
            lastProbe: lastHeaderProbeAt[profile.id]
        ) else { return nil }

        var accessToken: String?
        if let cliJSON = profile.cliCredentialsJSON,
           !ClaudeCodeSyncService.shared.isTokenExpired(cliJSON) {
            accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: cliJSON)
        }
        if accessToken == nil,
           let systemCredentials = try? await ClaudeCodeSyncService.shared.readSystemCredentialsOffMain(),
           !ClaudeCodeSyncService.shared.isTokenExpired(systemCredentials) {
            accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: systemCredentials)
        }
        guard let accessToken else { return nil }

        lastHeaderProbeAt[profile.id] = Date()
        do {
            let headerUsage = try await apiService.fetchUsageFromMessageHeaders(oauthAccessToken: accessToken)
            var merged = (profile.claudeUsage ?? .empty).mergingHeaderMeasurement(headerUsage)
            merged.healMissingResetStamps(previous: profile.claudeUsage)
            LoggingService.shared.log(
                "MenuBarManager: '\(profile.name)' usage endpoint refused — read live counters from the Messages API headers instead: session \(Int(merged.sessionPercentage))%, weekly \(Int(merged.weeklyPercentage))%\(merged.rateLimitedUntil != nil ? " (5h window REJECTED — sessions are blocked)" : "")"
            )
            incidentRing.record(FleetInsights.Incident(
                at: Date(), profileId: profile.id, name: profile.name, provider: .claude, kind: .headerRescue,
                detail: "session \(Int(merged.sessionPercentage))%, weekly \(Int(merged.weeklyPercentage))%"))
            return merged
        } catch {
            let refusal = AppError.wrap(error)
            LoggingService.shared.log("MenuBarManager: header rescue probe for '\(profile.name)' failed — \(refusal.message)")
            incidentRing.record(FleetInsights.Incident(
                at: Date(), profileId: profile.id, name: profile.name, provider: .claude, kind: .headerProbe429,
                detail: "\(refusal.code.rawValue)\(refusal.retryAfterSeconds.map { ", retry-after \(clampedInt($0))s" } ?? "")"))
            return nil
        }
    }

    /// Exponential cap is 8 min, not the original 30: the 30-min cap defended
    /// against the pre-refactor sweep re-fetching a 429ing profile every 30s
    /// (90 429s/hour measured). Per-account fetches are now spaced ~5 min by
    /// the rotation budget + Claude-only pacing, so the residual retry volume
    /// is tiny — while a 30-min blind window on a HEAVILY-USED account (the
    /// ones most likely to 429) let its displayed session % drift 15-20pp
    /// behind reality and fed the auto-switch stale candidate data (observed
    /// live 2026-07-29 on a profile stuck at 51% vs ~70% real).
    nonisolated static func burstBackoffInterval(streak: Int) -> TimeInterval {
        min(120 * pow(2, Double(max(0, streak - 1))), 480)
    }

    /// Backoff ceiling by role. The ACTIVE account retries EVERY SWEEP (30s):
    /// its number gates the auto-switch and its usage moves fastest exactly
    /// when the shared IP is busiest — the old 120s cap, re-armed by each
    /// failed retry, left 'Commits' blind for 22 minutes while parallel
    /// sessions burned it 67%→100% (2026-08-12). A SUSPECTED profile retries
    /// within ~2 sweeps (60s) even in the background: persistent 429s follow
    /// an account whose own sessions saturate its per-org request bucket —
    /// i.e. the accounts whose numbers are moving — and after the user
    /// switches away from one it must not go 8-min-blind while still
    /// burning (the post-switch 'Commits' sat 35 min stale). One retry per
    /// 30-60s per such account stays within the measured budget. Exhausted
    /// accounts answer their usage endpoint once their sessions idle
    /// ('Memori' returned 200 at a real 100%), so reading through the noise
    /// is safe. Idle background profiles keep the 8-min cap.
    nonisolated static func burstBackoffCap(isActiveAccount: Bool, isSuspected: Bool) -> TimeInterval {
        if isActiveAccount { return 30 }
        if isSuspected { return 60 }
        return 480
    }

    private func registerBurstBackoff(for profile: Profile, retryAfter: TimeInterval? = nil) {
        let streak = (burstBackoffs[profile.id]?.streak ?? 0) + 1
        let isActiveAccount = profileManager.isProviderOwner(profile.id)
        let cap = Self.burstBackoffCap(
            isActiveAccount: isActiveAccount,
            isSuspected: profile.claudeUsage?.isSuspectedRateLimited ?? false
        )
        let interval: TimeInterval
        if let retryAfter, retryAfter > 0 {
            // The endpoint SAID when to come back (a seconds-scale, sub-account-
            // floor Retry-After). Honor it instead of an exponential guess —
            // discarding it was how a busy account went blind for minutes at a
            // time. Small floor so a "1s" header can't turn into hammering.
            // Clamped: an unbounded header (a legitimate 86400, or a buggy
            // upstream number) would park this profile's usage fetch for its
            // full span and the tile would go blind silently (audit H2). The
            // account-level path above already handled anything at or over
            // `accountThrottleRetryAfterFloor`, so the burst cap is the right
            // ceiling here.
            interval = min(max(retryAfter, 30), cap)
        } else {
            interval = min(Self.burstBackoffInterval(streak: streak), cap)
        }
        burstBackoffs[profile.id] = BurstBackoff(until: Date().addingTimeInterval(interval), streak: streak)
        LoggingService.shared.log("MenuBarManager: '\(profile.name)' drew a burst 429 (retry-after: \(retryAfter.map { "\(clampedInt($0))s" } ?? "none"), active: \(isActiveAccount)) — backing usage fetch off for \(clampedInt(interval))s (streak \(streak))")
        incidentRing.record(FleetInsights.Incident(
            at: Date(), profileId: profile.id, name: profile.name, provider: profile.providerKind,
            kind: .burst429(streak: streak), detail: "backed usage fetch off for \(clampedInt(interval))s"))
    }

    // MARK: - Account-Level Throttle Stamping

    /// Floor separating an ACCOUNT-level usage-endpoint throttle from the
    /// endpoint's ordinary per-IP burst limiting. Burst 429s carry a
    /// seconds-scale (or no) Retry-After; an exhausted/heavily-used account
    /// refuses its own usage reads with a Retry-After of MINUTES (a real
    /// incident measured 2918s).
    nonisolated static let accountThrottleRetryAfterFloor: TimeInterval = 60

    // MARK: - Inferred Account Throttle (429 with useless Retry-After)

    /// The Retry-After floor above cannot catch every account-level refusal:
    /// 2026-08-11 incident — an exhausted account ('Ass-FerminAssistant')
    /// refused its own usage reads with HTTP 429 `retry-after: 0`, so no
    /// stamp fired, the burst backoff ate every retry, and the tile froze at
    /// a stale 74% while the account had zero capacity. Retry-After alone no
    /// longer separates account exhaustion from per-IP burst noise; the
    /// sweep's own cross-account evidence does: consecutive 429s for ONE
    /// profile spanning backoff cycles (minutes), while OTHER Claude accounts
    /// fetch fine from the same IP seconds around it, mean the refusal
    /// follows the account — treat it as exhausted for a short, self-healing
    /// TTL. A false positive (unlucky profile mislabeled 100%) lasts at most
    /// the TTL: the stamp's expiry re-probes at hot priority and one success
    /// clears everything.
    nonisolated static let inferredThrottleMinStreak = 2
    /// The ACTIVE profile is fetched every sweep, so its 429 streaks accumulate
    /// fastest and it is the most exposed to per-IP collisions — it needs one
    /// more consecutive refusal before suspicion (consult verdict, 2026-08-12).
    nonisolated static let inferredThrottleActiveMinStreak = 3
    nonisolated static let inferredThrottleControlWindow: TimeInterval = 90
    nonisolated static let inferredThrottleTTL: TimeInterval = 300
    /// Precision gate on the cached usage: exhaustion minutes after a FRESH
    /// low reading is implausible (a 5h window does not jump 45pp in one
    /// backoff interval — the 'BBR' false positive was cached at 8-55%). A
    /// fresh cache must already read near a limit before suspicion; a cache
    /// older than `inferredThrottleStaleCacheAge` proves nothing either way
    /// (the frozen-74% case) and does not block.
    nonisolated static let inferredThrottleFreshCacheFloor: Double = 85
    nonisolated static let inferredThrottleStaleCacheAge: TimeInterval = 15 * 60

    /// True when a burst-class 429 (no usable Retry-After) marks this profile
    /// SUSPECTED rate-limited: the consecutive-429 streak reached the floor
    /// (attempts are backoff-spaced, so streaks span minutes of persistent
    /// refusal; the active profile needs one more), a DIFFERENT Claude profile
    /// fetched successfully within `inferredThrottleControlWindow` (the shared
    /// IP is not fully saturated), AND the cached usage is consistent with
    /// exhaustion (near a limit, or too stale to say). This is deliberately
    /// EVIDENCE OF SUSPICION, not proof: a live probe measured 89% on an
    /// account DURING its own inferred stamp (2026-08-12) — the endpoint
    /// flaps per-request under ambient IP load, so a suspect is displayed
    /// with its real number + a distinct color, kept out of switch-target
    /// candidacy, and re-fetched (never fetch-skipped) until a 200 clears it.
    nonisolated static func shouldInferAccountThrottle(
        streak: Int,
        profileId: UUID,
        isActiveAccount: Bool,
        cachedUsage: ClaudeUsage?,
        lastClaudeSuccess: (profileId: UUID, at: Date)?,
        now: Date
    ) -> Bool {
        let minStreak = isActiveAccount ? inferredThrottleActiveMinStreak : inferredThrottleMinStreak
        guard streak >= minStreak else { return false }
        guard let success = lastClaudeSuccess, success.profileId != profileId else { return false }
        guard now.timeIntervalSince(success.at) <= inferredThrottleControlWindow else { return false }
        // Fresh cache far from every limit → refusal is IP noise, not exhaustion.
        if let cached = cachedUsage,
           now.timeIntervalSince(cached.lastUpdated) < inferredThrottleStaleCacheAge {
            let nearSession = cached.effectiveSessionPercentage >= inferredThrottleFreshCacheFloor
            let nearWeekly = max(cached.weeklyPercentage, cached.fableWeeklyPercentage ?? 0)
                >= inferredThrottleFreshCacheFloor
            guard nearSession || nearWeekly else { return false }
        }
        return true
    }

    /// Apply a synthetic account-throttle stamp (no server Retry-After to
    /// honor, so a short fixed TTL): same seam as the header-based stamp —
    /// `effectiveSessionPercentage` reports 100% until expiry, sweeps skip
    /// the profile, and the scheduler excludes it instead of burning budget.
    @discardableResult
    private func stampInferredAccountThrottle(_ profile: Profile, streak: Int) -> ClaudeUsage {
        var usage = profile.claudeUsage ?? .empty
        usage.rateLimitedUntil = Date().addingTimeInterval(Self.inferredThrottleTTL)
        usage.rateLimitedInferred = true
        // Deliberately NOT touching lastUpdated: no measurement happened, and
        // bumping it made a stale reading look fresh (masking the staleness
        // from the pre-switch verification and the popover's age display).
        profileManager.saveClaudeUsage(usage, for: profile.id)
        LoggingService.shared.log("MenuBarManager: '\(profile.name)' SUSPECTED rate-limited — \(streak) consecutive 429s while other accounts fetch fine; displaying last measured %, excluded as a switch target, re-probing until a fetch succeeds")
        incidentRing.record(FleetInsights.Incident(
            at: Date(), profileId: profile.id, name: profile.name, provider: profile.providerKind,
            kind: .inferredStamp, detail: "\(streak) consecutive 429s while other accounts fetch fine"))
        return usage
    }

    /// Profiles already notified about an inferred throttle this episode —
    /// one notification per outage, not one per 5-min re-stamp. Cleared by
    /// the profile's next successful fetch (recordClaudeUsageSuccess).
    private var inferredThrottleNotifiedIds: Set<UUID> = []

    /// An inferred stamp on an ACTIVE account does NOT auto-switch (see
    /// `autoSwitchTriggerUsage`) — the user decides whether displacing every
    /// running session's prompt cache is worth it. Tell them once per episode.
    private func notifyInferredThrottleIfNeeded(_ profile: Profile) {
        let isActiveAccount = profileManager.isProviderOwner(profile.id)
        guard isActiveAccount, !inferredThrottleNotifiedIds.contains(profile.id) else { return }
        inferredThrottleNotifiedIds.insert(profile.id)
        NotificationManager.shared.sendInferredThrottleNotification(profileName: profile.name)
    }

    /// The usage a switch-away decision is allowed to see. An INFERRED
    /// throttle stamp is display/scheduling truth, but switching the shared
    /// CLI login invalidates every concurrent session's prompt cache
    /// (~10-15% of quota burned re-reading context), so displacing the
    /// ACTIVE account requires server-affirmed evidence: a MEASURED
    /// percentage over threshold, or an explicit long Retry-After. Stripping
    /// the inferred stamp here makes the trigger evaluate the real cached
    /// numbers; candidate-side headroom checks keep seeing the stamp, so a
    /// suspect account is still never switched INTO (no ping-pong).
    nonisolated static func autoSwitchTriggerUsage(_ usage: ClaudeUsage) -> ClaudeUsage {
        guard usage.rateLimitedInferred == true else { return usage }
        var stripped = usage
        stripped.rateLimitedUntil = nil
        stripped.rateLimitedInferred = nil
        return stripped
    }

    /// Success bookkeeping for the inference above. Claude-flow fetches only —
    /// Codex/Grok hit different hosts and prove nothing about the Claude IP.
    /// A success also ends the profile's inferred-throttle episode (re-arming
    /// its one-shot notifications) and feeds the measured burn-rate history
    /// the suspected-state projection draws from.
    ///
    /// `countsAsEndpointControl` is false for a Messages-API header rescue: the
    /// measurement is real (it feeds history and clears suspicion) but it came
    /// from a different host bucket, so it must not stand as proof that
    /// `oauth/usage` is answering for OTHER accounts from this IP.
    private func recordClaudeUsageSuccess(
        _ profile: Profile,
        usage: ClaudeUsage,
        countsAsEndpointControl: Bool = true
    ) {
        inferredThrottleNotifiedIds.remove(profile.id)
        projectionNotifiedIds.remove(profile.id)
        guard profile.providerKind == .claude else { return }
        if countsAsEndpointControl {
            lastClaudeUsageSuccess = (profile.id, Date())
        }
        recordMeasuredSession(usage, for: profile.id)
    }

    // MARK: - Account-Level Throttle Stamping (header-based)

    /// When a usage fetch is refused with a long account-level Retry-After,
    /// record the throttle on the profile's cached usage. From then on
    /// `effectiveSessionPercentage` reports 100% until the stamp expires, so
    /// the frozen pre-throttle cache can no longer masquerade as headroom —
    /// in the tiles, the popover, the auto-switch trigger, or candidate
    /// selection. Returns the stamped usage, or nil if the error isn't an
    /// account-level throttle.
    @discardableResult
    private func stampAccountThrottleIfNeeded(_ error: AppError, profile: Profile) -> ClaudeUsage? {
        guard error.code == .apiRateLimited,
              let retryAfter = error.retryAfterSeconds,
              retryAfter.isFinite,
              retryAfter >= Self.accountThrottleRetryAfterFloor else { return nil }

        var usage = profile.claudeUsage ?? .empty
        let until = Date().addingTimeInterval(min(retryAfter, retryAfterMaximum))
        usage.rateLimitedUntil = until
        // Server-affirmed: clears any inferred provenance a prior stamp left.
        usage.rateLimitedInferred = nil
        usage.lastUpdated = Date()
        profileManager.saveClaudeUsage(usage, for: profile.id)
        LoggingService.shared.log("MenuBarManager: '\(profile.name)' usage endpoint throttled for \(clampedInt(retryAfter))s — treating account as exhausted until the throttle lifts")
        incidentRing.record(FleetInsights.Incident(
            at: Date(), profileId: profile.id, name: profile.name, provider: profile.providerKind,
            kind: .affirmedStamp(until: until), detail: "retry-after \(clampedInt(retryAfter))s"))
        return usage
    }

    // MARK: - Auto-Switch Profile on Session Limit

    /// Whether a usage reading for `profileId` is allowed to trigger a switch
    /// AWAY from that account.
    ///
    /// Only a PROVIDER OWNER may: a switch rewrites a shared CLI login, and an
    /// account no CLI is signed into has no session to rescue. The account the
    /// user happens to be VIEWING is not that test — with viewing free to land
    /// anywhere, a glance at a non-owner sitting at 96 % session would rotate
    /// the CLI off the owner that still has headroom, burning every running
    /// session's prompt cache (~10-15 % of quota) to solve a problem nobody had.
    ///
    /// One predicate, read by every call site AND by the trigger's own guard,
    /// so a new caller that forgets the filter is still refused.
    func mayTriggerAutoSwitch(_ profileId: UUID) -> Bool {
        Self.mayTriggerAutoSwitch(profileId, in: profileManager)
    }

    /// The rule itself, reachable without a live menu bar.
    static func mayTriggerAutoSwitch(_ profileId: UUID, in profileManager: ProfileManager) -> Bool {
        profileManager.isProviderOwner(profileId)
    }

    /// Checks if the current profile crossed an auto-switch threshold (session
    /// default 95%, weekly/Fable default 99% — Settings → Profiles →
    /// Auto-Switch) and switches to the next available one. Firing BELOW 100%
    /// is deliberate: it forfeits the remaining headroom so running sessions
    /// never hit the hard limit while the sweep-based detection (~30s cadence)
    /// catches up. The weekly threshold is tighter because forfeited weekly
    /// quota does not come back until the weekly reset.
    private func checkAutoSwitchIfNeeded(usage: ClaudeUsage, currentProfile: Profile) {
        // GUARD: only a PROVIDER OWNER may trigger a switch away from itself.
        //
        // This is the backstop for the whole "focus is never authority" rule.
        // Every caller above filters on ownership, but the filter is the kind of
        // thing a new call site forgets — and the cost of forgetting is not a
        // cosmetic one: a profile the user is merely LOOKING at, sitting at 96 %
        // session because its own sessions burned it days ago, would rotate the
        // shared CLI login off the account that is actually signed in and still
        // has headroom, invalidating every running session's prompt cache
        // (~10-15 % of quota) to solve a problem nobody had. An account whose
        // exhaustion nothing is currently spending is not a reason to switch.
        guard mayTriggerAutoSwitch(currentProfile.id) else {
            LoggingService.shared.log("AutoSwitch: '\(currentProfile.name)' is not a provider owner — no CLI is signed into it, so its usage cannot trigger a switch", type: .info)
            return
        }

        // Switch-away decisions never see an inferred throttle stamp — only
        // measured percentages or a server-affirmed (long Retry-After) stamp
        // may displace the active account (see autoSwitchTriggerUsage; the
        // 2026-08-11 'BBR' switch at a real ~40% session is the incident).
        let usage = Self.autoSwitchTriggerUsage(usage)

        // Guard: feature must be enabled
        guard SharedDataStore.shared.loadAutoSwitchProfileEnabled() else { return }

        // Guard: credential cache still hydrating — candidates may look
        // credential-less only because Keychain warm has not finished. A switch
        // decision on unhydrated profiles could pick (or skip) the wrong one.
        guard profileManager.credentialHydrationState != .loading else { return }

        // Guard: a switch is already rewriting the shared logins (other provider's
        // rotation, or a user-initiated switch). Don't stack a second one —
        // activateProfile would refuse via its semaphore and the candidate walk
        // below would misread that refusal as dead credentials and skip a
        // perfectly good candidate. The next sweep re-checks.
        guard !profileManager.isSwitchingProfile else { return }

        // Auto-switch never crosses providers: a Codex profile at the limit switches to
        // another CODEX account, a Claude profile to another CLAUDE account
        // (candidate filtering below enforces the same-provider rule).

        // Guard: need more than 1 profile
        let profiles = profileManager.profiles
        guard profiles.count > 1 else { return }

        // Guard: the trigger only ever rotates WITHIN a provider group
        // (candidates are same-providerKind by construction), so a provider
        // with no other account — Grok today — must not arm the machinery at
        // all: there is nothing to switch to, and another provider's limits
        // must never reach for this account.
        guard profiles.contains(where: {
            $0.id != currentProfile.id
                && $0.providerKind == currentProfile.providerKind
                && $0.hasUsageCredentials
        }) else { return }

        // Proactive: as usage climbs toward the limit, validate the predicted next
        // candidate's login so the eventual switch is seamless (or the user learns
        // about a dead account while there is still headroom to re-login).
        preflightNextCandidateIfNeeded(usage: usage, currentProfile: currentProfile)

        let profileId = currentProfile.id
        let sessionThreshold = SharedDataStore.shared.loadAutoSwitchThreshold()
        let weeklyThreshold = SharedDataStore.shared.loadAutoSwitchWeeklyThreshold()

        // If every quota window regained headroom (session reset, weekly rollover),
        // re-arm the trigger for this profile.
        if !Self.isQuotaExhausted(usage, sessionThreshold: sessionThreshold, weeklyThreshold: weeklyThreshold) {
            autoSwitchedProfileIds.remove(profileId)
            return
        }

        // Guard: don't re-trigger for this profile
        guard !autoSwitchedProfileIds.contains(profileId) else { return }

        // Guard: a candidate walk is already running. This flag is read and set
        // here, in synchronous main-actor code with no suspension in between, so
        // a second entrant cannot slip past it the way the post-`await`
        // isSwitchingProfile re-check below can be slipped past.
        guard !autoSwitchWalkInFlight else {
            LoggingService.shared.log("AutoSwitch: a candidate walk is already in flight — skipping this trigger")
            return
        }

        // Mark as triggered
        autoSwitchedProfileIds.insert(profileId)
        autoSwitchWalkInFlight = true

        // Try candidates in ranking order. A candidate whose stored login turns out
        // to be dead is NOT applied by activateProfile (it returns false and the
        // shared login stays on the outgoing account) — move on to the next one
        // instead of silently staying on an exhausted account.
        let fromName = currentProfile.name
        Task {
            // Every exit from the walk — switched, deferred, exhausted, or a
            // thrown cancellation — releases the entry mark.
            defer { self.autoSwitchWalkInFlight = false }
            var excluded: Set<UUID> = []
            while true {
                let queuedTarget = self.peekQueuedSwitchTarget(
                    provider: currentProfile.providerKind,
                    excluding: excluded,
                    sessionThreshold: sessionThreshold,
                    weeklyThreshold: weeklyThreshold
                )
                guard let nextProfile = queuedTarget
                    ?? self.findNextAvailableProfile(after: currentProfile, excluding: excluded) else { break }
                let cameFromQueue = queuedTarget?.id == nextProfile.id
                // Re-check at every iteration: a switch that started after the
                // guard above (other provider, user click) must not be stacked —
                // retry cleanly on the next sweep instead of walking candidates
                // on semaphore refusals.
                guard !self.profileManager.isSwitchingProfile else {
                    self.autoSwitchedProfileIds.remove(profileId)
                    LoggingService.shared.log("AutoSwitch: another switch is in flight, deferring to next sweep")
                    return
                }

                // Verify a STALE Claude candidate's real usage before taking the
                // switch: rotation + burst-429 backoff can leave a candidate's
                // cached percentages minutes old, and a heavily-used account (the
                // kind that 429s its own usage endpoint) can climb 15-20pp in that
                // window — landing the switch on an account that is about to hit
                // the very limit we are escaping (observed live 2026-07-29:
                // cached 51% vs ~70% real). One probe per candidate per switch;
                // Codex/Grok candidates refresh every sweep and never need it.
                if nextProfile.providerKind == .claude,
                   let cached = nextProfile.claudeUsage,
                   Date().timeIntervalSince(cached.lastUpdated) > 180 {
                    do {
                        let fresh = try await self.fetchUsageForProfile(nextProfile)
                        self.profileManager.saveClaudeUsage(fresh, for: nextProfile.id)
                        self.burstBackoffs.removeValue(forKey: nextProfile.id)
                        var verified = nextProfile
                        verified.claudeUsage = fresh
                        guard self.hasSessionHeadroom(verified, threshold: sessionThreshold),
                              self.hasWeeklyHeadroom(verified, threshold: weeklyThreshold, now: Date()),
                              self.hasFableWeeklyHeadroom(verified, threshold: weeklyThreshold, now: Date()) else {
                            excluded.insert(nextProfile.id)
                            LoggingService.shared.log("AutoSwitch: '\(nextProfile.name)' cached headroom was stale — fresh fetch shows none, trying next candidate")
                            continue
                        }
                    } catch {
                        let appError = AppError.wrap(error)
                        if let stamped = self.stampAccountThrottleIfNeeded(appError, profile: nextProfile) {
                            // Account-level throttle = exhausted: never switch onto it.
                            _ = stamped
                            excluded.insert(nextProfile.id)
                            LoggingService.shared.log("AutoSwitch: '\(nextProfile.name)' usage endpoint is account-throttled — treating as exhausted, trying next candidate")
                            continue
                        }
                        if appError.code == .apiRateLimited {
                            self.registerBurstBackoff(for: nextProfile, retryAfter: appError.retryAfterSeconds)
                        }
                        // Burst 429 / transient error: exhaustion unknown — proceed
                        // on the cached estimate rather than refusing to switch at
                        // all (the outgoing account is definitively at its limit).
                        LoggingService.shared.log("AutoSwitch: could not verify '\(nextProfile.name)' usage (\(appError.code.rawValue)) — proceeding on cached estimate")
                    }
                }
                LoggingService.shared.log("AutoSwitch: Switching from '\(fromName)' to '\(nextProfile.name)' (thresholds session \(Int(sessionThreshold))% / weekly \(Int(weeklyThreshold))%)")

                let outcome = await self.profileManager.activateProfileDetailed(nextProfile.id)
                switch Self.walkReaction(to: outcome) {
                case .switched:
                    self.preflightVerdicts[nextProfile.id] = PreflightVerdict(isLive: true, at: Date(), kind: .switched)
                    // Consume the queue entry only now — the switch landed.
                    if cameFromQueue {
                        self.consumeQueuedSwitchTarget(nextProfile.id)
                    }
                    // activateProfile just recorded the switch; enrich it with
                    // what only this walk knows (queued attribution + trigger
                    // measurements).
                    SharedDataStore.shared.amendLastSwitchEvent(
                        trigger: cameFromQueue ? .queued : .auto,
                        reason: "session \(Int(usage.effectiveSessionPercentage))% / weekly \(Int(usage.weeklyPercentage))% crossed threshold"
                    )
                    // Send notification
                    NotificationManager.shared.sendAutoSwitchNotification(fromProfile: fromName, toProfile: nextProfile.name)
                    return

                case .deferToNextSweep:
                    // The semaphore, not the candidate. Its credentials were
                    // never even examined, so it must NOT be excluded or
                    // recorded as a dead login — un-mark and let the next sweep
                    // re-run the whole trigger.
                    self.autoSwitchedProfileIds.remove(profileId)
                    LoggingService.shared.log("AutoSwitch: '\(nextProfile.name)' activation was refused by an in-flight switch (candidate NOT excluded) — deferring to next sweep")
                    return

                case .excludeCandidate:
                    excluded.insert(nextProfile.id)
                    // The switch itself is the strongest liveness probe there
                    // is — record it so the bar stops advertising this account.
                    self.preflightVerdicts[nextProfile.id] = PreflightVerdict(isLive: false, at: Date(), kind: .switched)
                    LoggingService.shared.log("AutoSwitch: could not take over '\(nextProfile.name)' login (dead credentials?), trying next candidate")
                }
            }
            // No candidate had headroom (or their logins were dead). Un-mark so the
            // next sweep retries — a candidate's session window resetting must not
            // strand us on an exhausted account for the rest of its weekly window.
            self.autoSwitchedProfileIds.remove(profileId)
            LoggingService.shared.log("AutoSwitch: no usable candidate right now, staying on '\(fromName)' (will retry)")
        }
    }

    /// What the candidate walk does with an activation result.
    enum CandidateWalkReaction {
        /// The switch landed — consume the queue entry and stop walking.
        case switched
        /// Nothing was attempted because another switch holds the semaphore.
        /// Stop walking and let the next sweep retry, WITHOUT excluding the
        /// candidate: its credentials were never examined.
        case deferToNextSweep
        /// The candidate itself is unusable — exclude it and try the next one.
        case excludeCandidate
    }

    /// Maps an activation outcome onto the walk's reaction. Split out so the
    /// one rule that matters is directly testable: a semaphore refusal
    /// (`switchInFlight`) must never be recorded as a dead login. Collapsing
    /// both into `false` is what let a healthy candidate be excluded — and a
    /// usage fetch burned per candidate — whenever a second walk or a manual
    /// switch was in flight (audit H6).
    nonisolated static func walkReaction(
        to outcome: ProfileManager.ActivationOutcome
    ) -> CandidateWalkReaction {
        switch outcome {
        case .activated, .alreadyActive:
            return .switched
        case .switchInFlight:
            return .deferToNextSweep
        case .profileNotFound, .credentialsRefused, .focusedWithoutApplying:
            // `focusedWithoutApplying` is a USER-initiated outcome and the walk
            // never sets `userInitiated`, so it cannot arrive here today. It is
            // mapped anyway, and to exactly what `.credentialsRefused` maps to:
            // no login changed hands, so the queue entry must not be consumed,
            // and the candidate is unusable for this walk.
            return .excludeCandidate
        }
    }

    /// True when ANY of the profile's quota windows has crossed its threshold:
    /// the 5-hour session vs `sessionThreshold`, the all-models weekly and the
    /// Fable weekly vs `weeklyThreshold`. The thresholds differ deliberately —
    /// forfeited session headroom regenerates within 5h (default 95%), while
    /// forfeited weekly headroom is gone for the rest of the week (default
    /// 99%). Mirrors the candidate headroom checks below — an account the
    /// auto-switch would never pick as a target should not be kept as the
    /// active one either (a weekly limit can run out while the session window
    /// sits far below the threshold). The per-window threshold shared with
    /// BOTH sides is what prevents ping-pong: an account switched away from at
    /// ≥threshold can never be re-picked as a target until one of its windows
    /// resets. Static + injectable so the mirror is unit-testable.
    nonisolated static func isQuotaExhausted(
        _ usage: ClaudeUsage,
        sessionThreshold: Double = 100,
        weeklyThreshold: Double = 100,
        now: Date = Date()
    ) -> Bool {
        if usage.effectiveSessionPercentage >= sessionThreshold { return true }
        if usage.weeklyResetTime >= now && usage.weeklyPercentage >= weeklyThreshold { return true }
        if let fablePercentage = usage.fableWeeklyPercentage, fablePercentage >= weeklyThreshold,
           usage.fableWeeklyResetTime.map({ $0 >= now }) ?? true {
            return true
        }
        return false
    }

    // MARK: - Candidate Preflight (seamless auto-switch)

    /// Usage milestones at which the NEXT auto-switch candidate's stored
    /// login is validated ahead of the threshold switch.
    private static let preflightMilestones: [Double] = [25, 50, 75, 90]

    /// The percentage the milestones are keyed off. A weekly-only provider
    /// (Codex since OpenAI collapsed its two windows into one 7-day window,
    /// Grok always) reports `sessionPercentage` 0 forever, so keying on the
    /// session window alone meant preflight NEVER armed for that provider's
    /// owner — the whole "re-login while you still have headroom" feature was
    /// dead for Codex accounts. Take the window that is actually filling up:
    /// weekly alone when there is no session window, else the higher of the
    /// two (a Claude account can exhaust its week at low session usage).
    nonisolated static func preflightMilestonePercentage(_ usage: ClaudeUsage) -> Double {
        guard usage.providesSessionWindow else { return usage.weeklyPercentage }
        return max(usage.effectiveSessionPercentage, usage.weeklyPercentage)
    }

    /// The window boundary the milestone re-arm anchors on — the session
    /// window when the provider has one, else the weekly boundary. Anchoring
    /// a weekly-only provider on `sessionResetTime` happens to work today
    /// (both services report the weekly boundary there) but is not a contract.
    nonisolated static func preflightMilestoneBoundary(_ usage: ClaudeUsage) -> Date {
        usage.providesSessionWindow ? usage.sessionResetTime : usage.weeklyResetTime
    }

    /// Milestones already preflighted per current profile — cleared when its
    /// usage drops back below the first milestone or when the keyed window
    /// itself rolls over (a busy account can be above 25% again by the
    /// first post-reset sweep and would otherwise never re-arm all window).
    private var preflightedMilestones: [UUID: Set<Double>] = [:]
    /// Anchored milestone-window boundary per profile; compared with a ±2min
    /// tolerance (the API reports the same boundary with ±1s jitter).
    private var preflightSessionBoundary: [UUID: Date] = [:]
    private var preflightRunning: Set<UUID> = []

    /// CANDIDATES currently being validated by any watcher. Both provider-active
    /// accounts (and the focused profile) are milestone-watched, and two watchers
    /// of the same provider can rank the SAME candidate next — the per-profile
    /// refresh mutex already prevents a double token redemption, but this keeps
    /// the second watcher from walking (and double-notifying about) a candidate
    /// another watcher is validating right now.
    private var preflightInFlightCandidates: Set<UUID> = []

    /// Fires once per crossed milestone (25/50/75/90% of the current account's
    /// keyed window — session where one exists, weekly for a weekly-only
    /// provider) and validates the auto-switch's predicted target in the
    /// background. Validation = the same refresh the switch itself would perform,
    /// done EARLY: a live-but-stale token is refreshed now (proving the refresh
    /// token works and banking a fresh access token), and a dead one triggers the
    /// re-login notification while the current account still has headroom — so the
    /// eventual switch lands on a login that is known to work.
    private func preflightNextCandidateIfNeeded(usage: ClaudeUsage, currentProfile: Profile) {
        let percentage = Self.preflightMilestonePercentage(usage)
        // Tolerance comparison, not minute-quantization: a boundary reported
        // near :30s alternates between adjacent rounded minutes under the
        // API's ±1s jitter (Codex review). Anything within 2 minutes is the
        // SAME window; the stored anchor only moves on a real rollover.
        let boundary = Self.preflightMilestoneBoundary(usage)
        if let anchored = preflightSessionBoundary[currentProfile.id] {
            if abs(anchored.timeIntervalSince(boundary)) > 120 {
                preflightedMilestones[currentProfile.id] = nil  // new window — re-arm
                preflightSessionBoundary[currentProfile.id] = boundary
            }
        } else {
            preflightSessionBoundary[currentProfile.id] = boundary
        }
        if percentage < Self.preflightMilestones[0] {
            preflightedMilestones[currentProfile.id] = nil  // window reset — re-arm
            return
        }
        guard let milestone = Self.preflightMilestones.last(where: { percentage >= $0 }),
              !(preflightedMilestones[currentProfile.id]?.contains(milestone) ?? false),
              !preflightRunning.contains(currentProfile.id) else { return }

        preflightedMilestones[currentProfile.id, default: []].insert(milestone)
        preflightRunning.insert(currentProfile.id)

        let currentId = currentProfile.id
        Task {
            await self.preflightCandidates(after: currentProfile, milestone: milestone)
            self.preflightRunning.remove(currentId)
        }
    }

    /// Walks the ranked same-provider candidates until one holds a LIVE login,
    /// notifying (via the services) about every dead one found on the way.
    private func preflightCandidates(after currentProfile: Profile, milestone: Double) async {
        // Unhydrated candidates look credential-less — never refresh/rotate on
        // that false signal. Ready/failed both proceed (partial cache on failed).
        guard profileManager.credentialHydrationState != .loading else { return }

        var excluded: Set<UUID> = []
        while let candidate = findNextAvailableProfile(after: currentProfile, excluding: excluded) {
            // A candidate that already owns its provider's shared login is being
            // kept fresh by the CLI itself. Do NOT refresh it here — rotating its
            // refresh token without syncing the shared login would leave the CLI
            // holding a consumed token (the exact failure this preflight prevents).
            if profileManager.isProviderOwner(candidate.id) {
                LoggingService.shared.log("Preflight[\(Int(milestone))%]: next candidate '\(candidate.name)' already owns its provider login — OK")
                preflightVerdicts[candidate.id] = PreflightVerdict(isLive: true, at: Date(), kind: .ownsLogin)
                return
            }

            // Another watcher is validating this exact candidate — let it finish.
            guard !preflightInFlightCandidates.contains(candidate.id) else {
                LoggingService.shared.log("Preflight[\(Int(milestone))%]: '\(candidate.name)' is already being validated by another watcher — skipping")
                return
            }
            preflightInFlightCandidates.insert(candidate.id)
            defer { preflightInFlightCandidates.remove(candidate.id) }

            var alive = true
            // How the verdict was reached — a ✓ on the bar is earned only by a
            // check that PROVES the login (probe / refresh); an expiry check on
            // an externally revoked token proves nothing (consult, 2026-09-03).
            var verdictKind: PreflightVerdict.Kind = .expiryOnly
            if candidate.isCodexOnlyProfile {
                _ = await CodexUsageService.shared.ensureFreshCredentials(for: candidate.id, freshFor: 24 * 3600)
                // Expiry is not evidence for a 10-day Codex token — ask the
                // account's own usage endpoint, exactly as the switch gate does,
                // so preflight and the switch cannot disagree (audit C2). Same
                // decision as `isSafeToApplyLogin`, unrolled so an INCONCLUSIVE
                // probe (429/5xx/transport) is recorded as expiry-only evidence
                // rather than as a proven-live login.
                let codex = CodexUsageService.shared
                let expired = ProfileStore.shared.loadProfiles()
                    .first(where: { $0.id == candidate.id })?.codexCredentialsJSON
                    .map { codex.isTokenExpired($0) } ?? true
                let liveness: CodexUsageService.LoginLiveness = expired
                    ? .unknown
                    : await codex.confirmLoginLiveness(for: candidate.id)
                alive = !expired && CodexUsageService.applyDecision(
                    isExpired: false,
                    markedDead: codex.isLoginMarkedDead(candidate.id),
                    verdict: liveness
                )
                verdictKind = liveness == .unknown ? .expiryOnly : .probed
                // The refresh path notifies only when the REFRESH grant is
                // refused. A login whose refresh works but whose account still
                // rejects it (the externally-invalidated case) is just as dead
                // for the CLI, and telling the user now — while the current
                // account still has headroom — is the entire point of preflight.
                if !alive { CodexUsageService.shared.notifyReloginNeeded(for: candidate.id) }
            } else if candidate.isGrokOnlyProfile {
                // Structurally dead today (a grok CURRENT never crosses a session
                // milestone — grok session% is always 0 — and candidates are
                // same-provider), but kept correct for a future multi-account
                // grok group rather than falling into the claude branches.
                if await GrokUsageService.shared.ensureFreshCredentials(for: candidate.id, freshFor: 24 * 3600) {
                    verdictKind = .refreshed
                }
                if let json = ProfileStore.shared.loadProfiles().first(where: { $0.id == candidate.id })?.grokCredentialsJSON {
                    alive = !GrokUsageService.shared.isTokenExpired(json)
                }
            } else if candidate.cliCredentialsJSON != nil {
                let refreshed = await ClaudeCodeSyncService.shared.ensureFreshCredentials(
                    for: candidate.id,
                    adoptSystemKeychain: false,
                    syncToSystem: false,
                    freshFor: 3600
                )
                if refreshed { verdictKind = .refreshed }
                if let json = ProfileStore.shared.loadProfiles().first(where: { $0.id == candidate.id })?.cliCredentialsJSON {
                    alive = !ClaudeCodeSyncService.shared.isTokenExpired(json)
                }
            }
            // claude.ai-session-only candidates carry no OAuth tokens to validate.

            preflightVerdicts[candidate.id] = PreflightVerdict(isLive: alive, at: Date(), kind: verdictKind)
            if alive {
                LoggingService.shared.log("Preflight[\(Int(milestone))%]: next candidate '\(candidate.name)' login is live and fresh")
                return
            }

            // Dead login — ensureFreshCredentials already sent the re-login
            // notification. Validate the next candidate so a working fallback is
            // confirmed before the switch fires.
            LoggingService.shared.log("Preflight[\(Int(milestone))%]: '\(candidate.name)' login is DEAD — user notified, checking next candidate")
            excluded.insert(candidate.id)
        }
        LoggingService.shared.log("Preflight[\(Int(milestone))%]: no live candidate available after '\(currentProfile.name)'")
    }

    /// Picks the profile to switch to when the switch threshold is crossed.
    ///
    /// Selection: among the other profiles OF THE SAME PROVIDER (Codex accounts
    /// switch among Codex accounts, Claude among Claude — the same policy applies
    /// to both groups), prefer the one whose WEEKLY limit resets soonest — its
    /// remaining weekly quota expires first, so it should be burned before quota
    /// that lasts longer ("use it or lose it"). A candidate is only eligible while
    /// it still has session, all-models weekly AND Fable weekly headroom; otherwise
    /// the next-soonest weekly reset is tried. Claude CLI accounts without a paid
    /// subscription are skipped.
    private func findNextAvailableProfile(after currentProfile: Profile, excluding: Set<UUID> = []) -> Profile? {
        findNextAvailableProfile(
            provider: currentProfile.providerKind,
            excluding: excluding.union([currentProfile.id]),
            alsoBlockingAccountOf: currentProfile
        )
    }

    /// The Anthropic accounts a Claude switch can gain nothing by moving to:
    /// whatever account the provider-active login already belongs to, plus the
    /// outgoing profile's when the walk names one. Two profiles stamped with
    /// the same `claudeAccountUUID` share ONE quota — switching between them
    /// changes the label and nothing else, while costing every running session
    /// a full context re-read. Empty unless the roster actually holds a
    /// duplicate, and empty for Codex/Grok (their duplicate guard runs at sync
    /// time, on `account_id`).
    private func blockedClaudeAccountUUIDs(alsoBlockingAccountOf current: Profile?) -> Set<String> {
        let activeId = profileManager.providerOwnerId(for: .claude)
        let active = profileManager.profiles.first(where: { $0.id == activeId })
        return Set([active?.claudeAccountUUID, current?.claudeAccountUUID]
            .compactMap { $0 }
            .filter { !$0.isEmpty })
    }

    /// Drops candidates whose stored login belongs to an account already in
    /// use. Pure so the walk's same-account rule is testable without a live
    /// profile manager; an unstamped candidate (nil uuid) is never dropped —
    /// no stamp is no evidence, not a match.
    nonisolated static func excludingBlockedClaudeAccounts(
        _ candidates: [Profile], blocked: Set<String>
    ) -> [Profile] {
        guard !blocked.isEmpty else { return candidates }
        return candidates.filter { candidate in
            guard let uuid = candidate.claudeAccountUUID, !uuid.isEmpty else { return true }
            return !blocked.contains(uuid)
        }
    }

    /// The same ranking keyed by PROVIDER rather than by an outgoing profile,
    /// so the fleet-summary tile can predict a next candidate for a provider
    /// with no active login at all. `quiet` suppresses the per-candidate log
    /// lines — this runs on every paint, not just at a threshold crossing.
    private func findNextAvailableProfile(
        provider switchingProvider: Profile.ProviderKind,
        excluding: Set<UUID>,
        quiet: Bool = false,
        alsoBlockingAccountOf currentProfile: Profile? = nil
    ) -> Profile? {
        let now = Date()
        // Candidates are held to the SAME per-window thresholds the trigger
        // fires at: a profile at ≥threshold is exactly what the switch is
        // escaping, so landing on one (and ping-ponging between two
        // nearly-full accounts) must be impossible by construction.
        let sessionThreshold = SharedDataStore.shared.loadAutoSwitchThreshold()
        let weeklyThreshold = SharedDataStore.shared.loadAutoSwitchWeeklyThreshold()

        let candidates = profileManager.profiles.filter { candidate in
            guard candidate.hasUsageCredentials,
                  !excluding.contains(candidate.id) else { return false }

            // Same-provider rule: never cross between Claude, Codex, and Grok accounts
            guard candidate.providerKind == switchingProvider else { return false }

            // Respect the per-profile eligibility toggle (Settings → Profiles → Auto-Switch)
            guard candidate.isAutoSwitchEnabled else {
                if !quiet {
                    LoggingService.shared.log("AutoSwitch: Skipping '\(candidate.name)' (excluded by per-profile toggle)")
                }
                return false
            }

            // Skip Claude CLI-only accounts on a free plan — no paid quota to take over
            if switchingProvider == .claude,
               !candidate.hasClaudeAI,
               let cliJSON = candidate.cliCredentialsJSON,
               let info = ClaudeCodeSyncService.shared.extractSubscriptionInfo(from: cliJSON),
               info.type.lowercased() == "free" {
                if !quiet {
                    LoggingService.shared.log("AutoSwitch: Skipping '\(candidate.name)' (free subscription)")
                }
                return false
            }
            return true
        }

        // Same-account rule: a candidate holding a login for the account that
        // is ALREADY active shares its quota, so switching to it buys no
        // headroom (see `blockedClaudeAccountUUIDs`). Applied after the filter
        // above so the log line names the profile once, by the same walk that
        // would otherwise have picked it.
        let blocked = switchingProvider == .claude
            ? blockedClaudeAccountUUIDs(alsoBlockingAccountOf: currentProfile)
            : []
        let distinctAccounts = Self.excludingBlockedClaudeAccounts(candidates, blocked: blocked)
        if !quiet {
            for dropped in candidates where !distinctAccounts.contains(where: { $0.id == dropped.id }) {
                LoggingService.shared.log("AutoSwitch: Skipping '\(dropped.name)' (same Anthropic account as the active login — one quota, no headroom to gain)")
            }
        }

        // Default ranking only — the consumable switch QUEUE is handled one
        // level up in the candidate walk (popQueuedSwitchTarget), so an empty
        // queue falls through to this ranking untouched.
        let ranked = Self.rankAutoSwitchCandidates(distinctAccounts, customOrder: nil, now: now)

        for candidate in ranked {
            if hasSessionHeadroom(candidate, threshold: sessionThreshold)
                && hasWeeklyHeadroom(candidate, threshold: weeklyThreshold, now: now)
                && hasFableWeeklyHeadroom(candidate, threshold: weeklyThreshold, now: now) {
                return candidate
            }
            if !quiet {
                LoggingService.shared.log("AutoSwitch: '\(candidate.name)' resets soonest but has no session, weekly or Fable headroom, trying next")
            }
        }
        return nil
    }

    // MARK: - Fleet summary (menu-bar redesign, stage A)

    /// The account the auto-switch would pick next for `provider` — the head
    /// of the user's queue when one is eligible, else the ranked candidate —
    /// or nil when nobody has headroom. Exactly the walk's selection, minus
    /// the side effects (no queue cleanup, no log lines): this is read on
    /// every paint by the fleet-summary tile.
    func predictedNextCandidate(for provider: Profile.ProviderKind) -> PredictedCandidate? {
        let profiles = profileManager.profiles
        let activeIds = profileManager.activeAccountIds(among: profiles)
        let excluded = Set(profiles.filter { $0.providerKind == provider && activeIds.contains($0.id) }.map(\.id))
        let sessionThreshold = SharedDataStore.shared.loadAutoSwitchThreshold()
        let weeklyThreshold = SharedDataStore.shared.loadAutoSwitchWeeklyThreshold()
        let now = Date()

        let queue = SharedDataStore.shared.loadAutoSwitchQueue()
        // A queue entry for THIS provider that is not executable right now is
        // a blocked head: the ranked fallback must say so, or the bar would
        // misrepresent the user's hand-off plan (consult, 2026-09-03).
        var queueHeadBlocked = false
        if !queue.isEmpty {
            let (queued, _) = Self.selectQueuedSwitchTarget(
                queue: queue,
                profiles: profiles,
                provider: provider,
                excluding: excluded,
                isEligible: { profile in
                    profile.hasUsageCredentials
                        && hasSessionHeadroom(profile, threshold: sessionThreshold)
                        && hasWeeklyHeadroom(profile, threshold: weeklyThreshold, now: now)
                        && hasFableWeeklyHeadroom(profile, threshold: weeklyThreshold, now: now)
                }
            )
            if let queued {
                return PredictedCandidate(
                    id: queued.id, label: queued.menuBarDisplayName, queued: true, queueHeadBlocked: false
                )
            }
            queueHeadBlocked = queue.contains { id in
                profiles.first(where: { $0.id == id })?.providerKind == provider && !excluded.contains(id)
            }
        }
        guard let ranked = findNextAvailableProfile(provider: provider, excluding: excluded, quiet: true) else {
            return nil
        }
        return PredictedCandidate(
            id: ranked.id, label: ranked.menuBarDisplayName, queued: false, queueHeadBlocked: queueHeadBlocked
        )
    }

    /// Everything the fleet-summary layouts need beyond profiles + config.
    /// Nil for the per-account layout so none of this work happens for it.
    /// The per-provider selection the ⇄ menu and its badge render: the same
    /// readiness / candidate / verdict context the tiles and the dashboard use,
    /// built once per call and handed down — never cached across sweeps.
    // MARK: - Fleet insights (docs/specs/ux-revamp.md §4, stage 4a)

    /// Rate-limit incidents for the dashboard's last-24-h view. The stamp
    /// sites (affirmed / inferred stamps, header-probe 429s and rescues, the
    /// transcript tripwire, burst backoffs) record into it.
    let incidentRing = IncidentRing()
    /// Every "changed outside the app" episode of this process.
    let driftLog = DriftLog()

    /// Read-only view of the per-profile burst backoffs for the insights model.
    var backoffStates: [UUID: FleetInsights.Backoff] {
        burstBackoffs.mapValues { FleetInsights.Backoff(until: $0.until, streak: $0.streak) }
    }

    /// The dashboard's insights, derived from what the app already keeps. The
    /// build itself is pure; this gathers its inputs, as the snapshot does.
    func makeFleetInsights(now: Date = Date()) -> FleetInsights {
        let selections = buildActiveSelections()
        return FleetInsights.build(FleetInsights.Inputs(
            selections: selections, profiles: profileManager.profiles,
            switchHistory: SharedDataStore.shared.loadSwitchHistory(),
            measured: SharedDataStore.shared.loadMeasuredSessionHistory(),
            incidents: incidentRing.recent(now: now), drift: driftLog.episodes, backoffs: backoffStates,
            counts: selections.map(\.counts), staleAfter: makeFleetSummaryContext().thresholds.staleAfter, now: now))
    }

    func buildActiveSelections() -> [ProviderActiveSelection] {
        let profiles = profileManager.profiles
        var painted: [Profile.ProviderKind: [UUID]] = [:]
        for provider in Profile.ProviderKind.allCases {
            let order = statusBarUIManager?.paintedGroupMembers(for: provider, among: profiles) ?? []
            if !order.isEmpty { painted[provider] = order }
        }
        return ProviderActiveSelection.build(ProviderActiveSelection.Inputs(
            profiles: profiles,
            activeIds: profileManager.activeAccountIds(among: profiles),
            focusedId: profileManager.activeProfile?.id,
            paintedOrder: painted,
            context: makeFleetSummaryContext(),
            queue: SharedDataStore.shared.loadAutoSwitchQueue(),
            duplicateGroups: FleetCounts.duplicateGroups(
                in: profiles, published: profileManager.duplicateClaudeAccountGroups),
            manuallyPinned: autoSwitchedProfileIds,
            cachedResets: Dictionary(uniqueKeysWithValues: profiles.filter { $0.providerKind == .codex }.compactMap { profile in
                CodexUsageService.shared.cachedResetCredits(for: profile.id).map { (profile.id, $0) }
            }),
            needsRelogin: profileManager.profilesNeedingAccountRelogin,
            autoSwitchEnabled: SharedDataStore.shared.loadAutoSwitchProfileEnabled()
        ))
    }

    /// Opens the click surface (dashboard or classic popover) on the viewed
    /// account — the inspector's "Open in dashboard" button.
    func openDashboard() {
        togglePopover(nil)
    }

    /// Creates the ⇄ item exactly once; `setup()` re-entry reuses it.
    private func installActiveSelectorIfNeeded() {
        guard activeSelector == nil else { return }
        activeSelector = ActiveSelectorItem(actions: ActiveSelectorItem.Actions(
            selections: { [weak self] in self?.buildActiveSelections() ?? [] },
            preferencesDegraded: { [weak self] in self?.profileManager.preferencesDegraded ?? false },
            makeActive: { [weak self] id in
                guard let self else { return .profileNotFound }
                // The one activation seam: dead-login gate, adoption, switch
                // record, notifications — never a second path.
                let outcome = await self.profileManager.activateProfileDetailed(id, userInitiated: true)
                self.rebuildDashboardSnapshot()
                return outcome
            },
            queueNext: { [weak self] id in
                let rest = SharedDataStore.shared.loadAutoSwitchQueue().filter { $0 != id }
                SharedDataStore.shared.saveAutoSwitchQueue([id] + rest)
                self?.rebuildDashboardSnapshot()
            },
            viewAndOpenSettings: { [weak self] id, section in
                guard let self else { return }
                if let id { self.profileManager.viewProfile(id) }
                self.preferencesClicked(section: section)
            },
            openDashboard: { [weak self] in self?.togglePopover(nil) },
            openTelemetry: { NotificationCenter.default.post(name: .telemetryWindowRequested, object: nil) },
            setAutoSwitchEnabled: { enabled in SharedDataStore.shared.saveAutoSwitchProfileEnabled(enabled) }
        ))
        LoggingService.shared.log("MenuBarManager: ⇄ active-account selector installed (visible: \(activeSelector?.isVisible == true))")
    }

    private func fleetSummaryContext(for config: MultiProfileDisplayConfig) -> FleetSummaryContext? {
        guard config.barLayout.isFleetSummary else { return nil }
        return makeFleetSummaryContext()
    }

    /// Rebuilds the dashboard's snapshot from the current profiles, provider
    /// owners, painted order, switch queue and history. Called on open and
    /// once per paint while a dashboard is showing.
    func rebuildDashboardSnapshot() {
        let profiles = profileManager.profiles
        var painted: [Profile.ProviderKind: [UUID]] = [:]
        for provider in Profile.ProviderKind.allCases {
            let order = statusBarUIManager?.paintedGroupMembers(for: provider, among: profiles) ?? []
            if !order.isEmpty { painted[provider] = order }
        }
        dashboardStore.snapshot = DashboardSnapshot.build(DashboardSnapshot.Inputs(
            profiles: profiles,
            activeIds: profileManager.activeAccountIds(among: profiles),
            focusedId: profileManager.activeProfile?.id,
            paintedOrder: painted,
            context: makeFleetSummaryContext(),
            queue: SharedDataStore.shared.loadAutoSwitchQueue(),
            history: SharedDataStore.shared.loadSwitchHistory(),
            hiddenProviders: statusBarUIManager?.hiddenProviders ?? [],
            // Same account behind several profiles (#60): the dashboard shows
            // them as one quota with the member names. Claude groups come from
            // the manager's published rule, Codex groups from `codexAccountId`.
            duplicateGroups: FleetCounts.duplicateGroups(in: profiles, published: profileManager.duplicateClaudeAccountGroups),
            manuallyPinned: autoSwitchedProfileIds,
            needsRelogin: profileManager.profilesNeedingAccountRelogin
        ))
        // Same paint, same inputs shape: the insights ride inside the
        // snapshot so the view observes one value and the frame harness
        // renders them from a fixture like everything else.
        dashboardStore.snapshot?.insights = makeFleetInsights()
    }

    /// The readiness / candidate / verdict context both the fleet tiles and
    /// the dashboard read.
    func makeFleetSummaryContext() -> FleetSummaryContext {
        var next: [Profile.ProviderKind: PredictedCandidate] = [:]
        for provider in Profile.ProviderKind.allCases {
            if let candidate = predictedNextCandidate(for: provider) {
                next[provider] = candidate
            }
        }
        return FleetSummaryContext(
            thresholds: ReadinessThresholds(
                session: SharedDataStore.shared.loadAutoSwitchThreshold(),
                weekly: SharedDataStore.shared.loadAutoSwitchWeeklyThreshold()
            ),
            isLoginDead: { profile in
                // Same definition the profile switcher menu uses (flag, or
                // expired with no refresh token) plus the Grok flag.
                ProfileCredentialStatusCache.hasDeadLogin(profile)
                    || (profile.isGrokOnlyProfile && GrokUsageService.shared.isLoginMarkedDead(profile.id))
            },
            isExcluded: { profile in
                // The walk's own eligibility rules (findNextAvailableProfile),
                // so a green dot means exactly "the auto-switch would take it".
                if !profile.isAutoSwitchEnabled { return true }
                if profile.providerKind == .claude, !profile.hasClaudeAI,
                   let cliJSON = profile.cliCredentialsJSON,
                   let info = ClaudeCodeSyncService.shared.extractSubscriptionInfo(from: cliJSON),
                   info.type.lowercased() == "free" {
                    return true
                }
                return false
            },
            nextCandidates: next,
            preflightVerdicts: preflightVerdicts,
            preferencesDegraded: profileManager.preferencesDegraded,
            isSwitching: profileManager.isSwitchingProfile,
            now: Date()
        )
    }

    /// Selects the next queued auto-switch target for this provider WITHOUT
    /// consuming it. The queue is consumed ONLY on successful activation
    /// (`consumeQueuedSwitchTarget`) — the original consume-on-try semantics
    /// silently emptied a user's queued handoff plan: an entry was popped
    /// before the `isSwitchingProfile` abort, and a queued target wearing a
    /// FALSE inferred "100%" looked headroom-less and was eaten (both paths
    /// confirmed by the 2026-08-12 consult; the owner's queued account
    /// vanished without ever being activated). Deleted profiles are the only
    /// entries dropped here. An entry that is ineligible RIGHT NOW (excluded
    /// this walk, dead, no headroom) is skipped but stays queued for the next
    /// walk. Returns the selected profile and the cleaned queue to persist.
    nonisolated static func selectQueuedSwitchTarget(
        queue: [UUID],
        profiles: [Profile],
        provider: Profile.ProviderKind,
        excluding: Set<UUID>,
        isEligible: (Profile) -> Bool
    ) -> (target: Profile?, cleanedQueue: [UUID]) {
        var cleaned: [UUID] = []
        var target: Profile? = nil
        for id in queue {
            guard let profile = profiles.first(where: { $0.id == id }) else {
                continue  // profile was deleted — drop the entry
            }
            cleaned.append(id)
            guard target == nil,
                  profile.providerKind == provider,
                  !excluding.contains(profile.id),
                  isEligible(profile) else { continue }
            target = profile
        }
        return (target, cleaned)
    }

    private func peekQueuedSwitchTarget(
        provider: Profile.ProviderKind,
        excluding: Set<UUID>,
        sessionThreshold: Double,
        weeklyThreshold: Double
    ) -> Profile? {
        let queue = SharedDataStore.shared.loadAutoSwitchQueue()
        guard !queue.isEmpty else { return nil }
        let now = Date()
        let (target, cleaned) = Self.selectQueuedSwitchTarget(
            queue: queue,
            profiles: profileManager.profiles,
            provider: provider,
            excluding: excluding,
            isEligible: { profile in
                profile.hasUsageCredentials
                    && hasSessionHeadroom(profile, threshold: sessionThreshold)
                    && hasWeeklyHeadroom(profile, threshold: weeklyThreshold, now: now)
                    && hasFableWeeklyHeadroom(profile, threshold: weeklyThreshold, now: now)
            }
        )
        if cleaned != queue {
            SharedDataStore.shared.saveAutoSwitchQueue(cleaned)
        }
        if let target {
            LoggingService.shared.log("AutoSwitch: queued target '\(target.name)' selected (consumed only if the switch lands)")
        }
        return target
    }

    /// Removes a queue entry AFTER its activation succeeded — the only
    /// consumption path.
    private func consumeQueuedSwitchTarget(_ id: UUID) {
        var queue = SharedDataStore.shared.loadAutoSwitchQueue()
        guard let index = queue.firstIndex(of: id) else { return }
        queue.remove(at: index)
        SharedDataStore.shared.saveAutoSwitchQueue(queue)
        LoggingService.shared.log("AutoSwitch: queued target consumed after successful switch (\(queue.count) left in queue)")
    }

    /// True when the account's WEEKLY quota is at/over the auto-switch weekly
    /// threshold — all-models weekly or the Fable weekly for Claude; the single
    /// weekly window for Codex/Grok. The 5h session window is deliberately NOT
    /// consulted (owner spec 2026-07-29: session exhaustion regenerates within
    /// hours and must not mark a tile as maxed). A weekly/Fable reset already in
    /// the past means the window rolled over since the data was cached — full
    /// quota again, not maxed. No cached usage -> not maxed. Static +
    /// injectable so the tile-color rule is unit-testable.
    nonisolated static func isWeeklyMaxed(
        _ usage: ClaudeUsage?,
        weeklyThreshold: Double,
        now: Date = Date()
    ) -> Bool {
        guard let usage else { return false }
        if usage.weeklyResetTime >= now, usage.weeklyPercentage >= weeklyThreshold {
            return true
        }
        if let fable = usage.fableWeeklyPercentage,
           usage.fableWeeklyResetTime.map({ $0 >= now }) ?? true,
           fable >= weeklyThreshold {
            return true
        }
        return false
    }

    /// Ranks auto-switch candidates. Default: soonest weekly reset first
    /// (profiles with no cached usage sort last — their reset time is unknown,
    /// so they serve as the fallback). With a user-defined custom order
    /// (Settings → Profiles → Auto-Switch → Custom switch order): queue
    /// position wins; profiles NOT in the queue rank after every queued one,
    /// in default order. Headroom/eligibility checks are unaffected — the
    /// queue only decides who gets tried FIRST. Static + injectable for tests.
    nonisolated static func rankAutoSwitchCandidates(
        _ candidates: [Profile],
        customOrder: [UUID]?,
        now: Date
    ) -> [Profile] {
        let byReset = candidates.sorted {
            $0.nextWeeklyReset(after: now) < $1.nextWeeklyReset(after: now)
        }
        guard let customOrder, !customOrder.isEmpty else { return byReset }
        let position = Dictionary(uniqueKeysWithValues: customOrder.enumerated().map { ($1, $0) })
        // Stable partition: queued candidates in queue order, then the rest in
        // default order.
        let queued = byReset
            .filter { position[$0.id] != nil }
            .sorted { position[$0.id]! < position[$1.id]! }
        let unqueued = byReset.filter { position[$0.id] == nil }
        return queued + unqueued
    }

    /// True while the candidate's session usage is below the SESSION switch
    /// threshold. A profile with no cached usage is assumed available; an
    /// expired session window counts as 0%.
    private func hasSessionHeadroom(_ profile: Profile, threshold: Double) -> Bool {
        guard let usage = profile.claudeUsage else { return true }
        return usage.effectiveSessionPercentage < threshold
    }

    /// True while the candidate's weekly usage is below the WEEKLY switch
    /// threshold. A weekly reset already in the past means the window rolled
    /// over since the data was cached — full quota.
    private func hasWeeklyHeadroom(_ profile: Profile, threshold: Double, now: Date) -> Bool {
        guard let usage = profile.claudeUsage else { return true }
        if usage.weeklyResetTime < now { return true }
        return usage.weeklyPercentage < threshold
    }

    /// True while the candidate's Fable weekly usage is below the WEEKLY switch
    /// threshold. Accounts that don't report a Fable limit (Codex profiles,
    /// plans without a Fable window) are treated as available; a Fable reset
    /// already in the past means full quota again.
    private func hasFableWeeklyHeadroom(_ profile: Profile, threshold: Double, now: Date) -> Bool {
        guard let usage = profile.claudeUsage,
              let fablePercentage = usage.fableWeeklyPercentage else { return true }
        if let fableReset = usage.fableWeeklyResetTime, fableReset < now { return true }
        return fablePercentage < threshold
    }

    private func preferencesClicked(section: SettingsSection? = nil) {
        // Close the popover or detached window first
        closePopoverOrWindow()

        // If a settings window exists AT ALL, reuse it — visible, minimized,
        // or parked on another Space. The old `isVisible` condition skipped
        // MINIATURIZED windows (isVisible is false while in the Dock, and
        // miniaturize never notifies the delegate), so a second window was
        // built and the first one orphaned: retained by AppKit forever,
        // subscribed to ProfileManager, re-rendering on every publish
        // (2026-07-29 evening investigation, orphan path O1).
        if let existingWindow = settingsWindow {
            if existingWindow.isMiniaturized {
                existingWindow.deminiaturize(nil)
            }
            Self.bringWindowToForeground(existingWindow)
            if let section {
                NotificationCenter.default.post(name: .settingsSectionRequested, object: section.rawValue)
            }
            return
        }

        // Double-open guard: two triggers within the 150ms delay below would
        // build two windows and orphan the first (orphan path O2).
        guard !settingsOpenPending else { return }
        settingsOpenPending = true

        // Small delay to ensure smooth transition
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Deliberately NO setActivationPolicy(.regular) here: flipping an
            // accessory app's activation policy forces EVERY window — including
            // all 14 status-item windows — to re-register its remote context and
            // tracking-area structural regions with the window server. Sampled
            // live 2026-07-29 while the settings window was "frozen" (20s+
            // responses): the main thread sat in a remote_context_notify →
            // _NSTrackingAreaAKManager → add_structural_region storm of
            // synchronous mach_msg round-trips. A settings window needs no Dock
            // icon; bringWindowToForeground() handles focus without the flip.

            // Create and show the settings window
            let window = SettingsWindowBuilder.makeWindow(size: Constants.WindowSizes.settingsWindow, initialSection: section)
            window.title = "Claude Usage - Settings"
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self

            self.settingsWindow = window
            self.settingsOpenPending = false

            Self.bringWindowToForeground(window)
        }
    }

    /// Guards the 150ms deferred settings-window creation against double-open.
    private var settingsOpenPending = false

    /// Foreground a window from this ACCESSORY app assertively. Since macOS 14,
    /// `NSApp.activate()` is cooperative — called from a menu-bar app after a
    /// dispatch delay, the click's interaction grant has expired and the system
    /// DENIES the activation, so the window opens BEHIND the frontmost app and
    /// looks like nothing happened (real report 2026-07-29: settings "frozen",
    /// actually open in the background).
    static func bringWindowToForeground(_ window: NSWindow) {
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// The "next account" hotkey VIEWS the next account of the viewed
    /// provider group, in the bar's painted order (left → right, wrapping) —
    /// it never switches a CLI (docs/specs/ux-revamp.md D7). The old version
    /// ACTIVATED the next profile in array order across providers, so a
    /// keypress could hand a Claude session a Codex login (audit M7).
    private func switchToNextProfile() {
        guard let current = profileManager.activeProfile else { return }
        let provider = current.providerKind
        // Painted order when the group is on the bar and includes the viewed
        // account; otherwise the same ranking the bar would paint, over every
        // account of the provider (selected or not), so an unselected viewed
        // account still has a "next".
        var order = paintedGroupMembers(for: provider)
        if !order.contains(current.id) {
            order = StatusBarUIManager.compositePaintOrder(
                StatusBarUIManager.multiProfileCreationOrder(
                    for: profileManager.profiles, now: Date(), includeUnselected: true)
                    .filter { $0.providerKind == provider }
                    .map(\.id)
            )
        }
        guard let next = ViewingNavigation.next(after: current.id, in: order) else { return }
        profileManager.viewProfile(next)
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }

}

// MARK: - NSPopoverDelegate
extension MenuBarManager: NSPopoverDelegate {
    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        // Allow popover to be detached by dragging
        return true
    }

    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        // Stop monitoring for outside clicks when detaching
        stopMonitoringForOutsideClicks()

        // Create a new window with NEW content view controller
        // This prevents the popover from losing its content
        let newContentViewController = createContentViewController()

        let size = surfaceSize
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = newContentViewController
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isRestorable = false
        window.delegate = self
        window.backgroundColor = .clear

        // Store reference to the detached window
        detachedWindow = window

        return window
    }

    func popoverWillClose(_ notification: Notification) {
        // Arm the re-open swallow when this close is the semitransient
        // auto-close of a click on the anchoring button: that click's own
        // action will arrive with isShown == false and must read as
        // "dismiss", not "open". It must happen HERE, at close initiation —
        // an invariant that is timing-independent: with animates=false (the
        // current config) didClose follows synchronously, but arming at
        // initiation also survives any future animated config, where didClose
        // is delivered only after the fade-out, typically AFTER that action
        // already ran and found no stamp (the close/re-open pairs in the
        // 2026-07-30 click trace).
        //
        // The ONLY gate is "pointer on the anchor": that alone distinguishes
        // an anchor-click auto-close (arm) from a desktop/elsewhere click or
        // programmatic close (don't arm — a legitimate open within 0.5s must
        // not be swallowed). Do NOT gate on NSEvent.pressedMouseButtons: the
        // scene-routed click is processed by the app AFTER the physical
        // release, so "mouse currently pressed" is never true here — that
        // condition disarmed the swallow entirely and every same-tile
        // re-click closed and re-opened (owner report + live trace,
        // 2026-07-30 13:06). A press that closes the popover but never
        // produces an action (right-click, drag-off) arms a stamp nothing
        // consumes — accepted residual: it self-expires in 0.5s and at worst
        // swallows one click, which the next click recovers.
        guard let button = currentPopoverButton else { return }
        guard StatusBarUIManager.pointerLocalX(in: button) != nil else {
            LoggingService.shared.log("Popover: willClose — pointer off anchor, swallow not armed")
            return
        }
        LoggingService.shared.log("Popover: willClose — swallow armed (pointer on anchor)")
        lastPopoverCloseButton = button
        lastPopoverCloseTime = Date()
    }

    func popoverDidClose(_ notification: Notification) {
        // Only touch anchor state when the CURRENT popover really finished
        // closing. The guards are ordering-independent (they key on object
        // identity + isShown, not delivery timing): with animates=false this
        // runs synchronously inside performClose; under an animated config a
        // group switch could show a fresh popover before the old didClose
        // arrived, and clearing currentPopoverButton then would orphan the
        // shown popover — its next same-group click reads as "different
        // button" and re-opens instead of dismissing.
        // No swallow-stamp writes here: willClose already armed it under the
        // precise condition, and re-arming after the mouse-up consumed it
        // would swallow the NEXT legitimate click (Codex review 2026-07-30,
        // finding 2).
        if let closed = notification.object as? NSPopover, !closed.isShown,
           closed === popover || popover == nil {
            currentPopoverButton = nil
            // Every close path funnels through here — including semitransient
            // auto-closes, Esc, and the Settings/Manage buttons, none of which
            // go through closePopover(). Without this the global outside-click
            // monitor stayed installed (one leaked monitor per such close,
            // each one a callout on every click system-wide).
            stopMonitoringForOutsideClicks()
        }

        // DESTROY the popover once closed: dropping only the hosting
        // controller (the previous fix) still leaves the borderless
        // _NSPopoverWindow alive off-screen forever, where it joins AppKit's
        // per-display-cycle tracking-area/structural-region pass — the window
        // population implicated in the 2026-07-29 WindowServer feedback-loop
        // storm. ensurePopover() rebuilds it on the next click (~1ms).
        // Defer one turn so a same-runloop re-show (e.g. switching tiles)
        // can re-show this popover first; only tear down if still closed.
        guard let closed = notification.object as? NSPopover else { return }
        DispatchQueue.main.async { [weak self, weak closed] in
            guard let closed, !closed.isShown else { return }
            closed.contentViewController = nil
            if let self, self.popover === closed {
                self.popover = nil
            }
        }
    }
}

// MARK: - StatusBarUIManagerDelegate
extension MenuBarManager: StatusBarUIManagerDelegate {
    func statusBarAppearanceDidChange() {
        // Safe from infinite loops: StatusBarUIManager's observer deduplicates by
        // appearance name, and setButtonImage() only assigns button.image when the
        // rendered TIFF data actually changes — so even if setting button.image
        // triggers effectiveAppearance KVO, the cycle stops immediately.
        updateAllStatusBarIcons()
        activeSelector?.statusBarAppearanceDidChange()
    }
}

// MARK: - NSWindowDelegate
extension MenuBarManager: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window == settingsWindow {
                // No policy restore needed — settings no longer flips the
                // activation policy (see preferencesClicked). Release the SwiftUI
                // hosting graph like the popover/detached paths do.
                window.contentViewController = nil
                settingsWindow = nil
            } else if window == detachedWindow {
                // Release SwiftUI hosting graph (same rationale as popoverDidClose)
                window.contentViewController = nil
                // Clear detached window reference when closed
                detachedWindow = nil
            }
        }
    }
}
