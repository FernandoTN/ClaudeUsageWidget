import Cocoa
import SwiftUI
import Combine

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

    // Track which button is currently showing the popover
    private weak var currentPopoverButton: NSStatusBarButton?

    /// Where/when the popover last closed. The .semitransient popover auto-closes
    /// on the mouse-DOWN of a click on its own anchor button; without this stamp
    /// the mouse-UP action re-opens it, so a same-tile click can never dismiss.
    private weak var lastPopoverCloseButton: NSStatusBarButton?
    private var lastPopoverCloseTime: Date = .distantPast

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

    /// Round-robin cursor over the non-active Claude profiles: the usage endpoint
    /// sustains ~2 requests per 30s window per IP, so each sweep fetches only a
    /// budgeted slice of them (plus the provider-active/focused ones).
    private var claudeFetchCursor: Int = 0

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

        // Observe profile changes - CRITICAL: Set up before anything else
        observeProfileChanges()

        // Initialize status bar UI manager
        statusBarUIManager = StatusBarUIManager()
        statusBarUIManager?.delegate = self

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

            // Skip if profile has no usage credentials (CLI alone can't be used)
            guard let profile = self.profileManager.activeProfile, profile.hasUsageCredentials else {
                LoggingService.shared.log("Skipping network-available refresh (no usage credentials)")
                return
            }

            let timeSinceLastRefresh = Date().timeIntervalSince(self.lastRefreshTriggerTime)
            if timeSinceLastRefresh > 2.0 {  // At least 2 seconds since last refresh
                self.refreshUsage()
            } else {
                LoggingService.shared.log("Skipping network-available refresh (too soon after last refresh)")
            }
        }
        networkMonitor.startMonitoring()

        // Initial data fetch (with small delay for launch-at-login scenarios)
        // Only if profile has usage credentials (not just CLI)
        if let profile = profileManager.activeProfile, profile.hasUsageCredentials {
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

        // Idle-burn guardrail: alarms (log + one notification) when the app
        // burns CPU with no popover/settings open — the storm failure class.
        StormWatchdog.shared.isNominallyIdle = { [weak self] in
            guard let self else { return true }
            return self.popover == nil
                && self.settingsWindow == nil
                && self.detachedWindow == nil
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

        // 4. Recreate popover with new profile data
        recreatePopover()

        // 5. Trigger immediate refresh ONLY if profile has usage credentials
        if profile.hasUsageCredentials {
            self.lastRefreshTriggerTime = Date()
            refreshUsage()
        } else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh for profile without usage credentials")
        }
    }

    private func recreatePopover() {
        // Close (and thereby destroy) any open popover; the next click builds
        // a fresh one with fresh content via ensurePopover().
        //
        // Deferred one runloop turn: this runs inside handleProfileSwitch,
        // which the user can trigger from a button INSIDE the popover — i.e.
        // while the popover's own action is on the stack, mid CA commit.
        // Tearing the popover down synchronously there raced the fence
        // protocol ("cannot add handler to 2 from 2 - dropping", followed once
        // by a fence-tx timeout that wedged all 42 status-item scenes into the
        // permanent WindowServer echo storm — leak-hunter forensics,
        // 2026-07-29). Outside any in-flight commit the same teardown is safe.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.popover?.isShown == true {
                self.closePopover()
            }
            self.popover = nil
            LoggingService.shared.log("MenuBarManager: Popover dropped for profile switch")
        }
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

        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshUsage()
        }
        refreshTimer?.tolerance = interval * 0.1  // 10% tolerance for energy efficiency

        LoggingService.shared.log("Updated refresh interval to \(interval)s")
    }

    /// Returns the live popover, creating it if needed. Created WITHOUT content;
    /// every show-path installs a fresh contentViewController first.
    private func ensurePopover() -> NSPopover {
        if let popover { return popover }
        let popover = NSPopover()
        popover.contentSize = Constants.WindowSizes.popoverSize
        popover.behavior = .semitransient  // Allows detaching
        popover.animates = true
        popover.delegate = self
        self.popover = popover
        return popover
    }

    private func createContentViewController() -> NSHostingController<PopoverContentView> {
        // Create SwiftUI content view
        let contentView = PopoverContentView(
            manager: self,
            onRefresh: { [weak self] in
                self?.refreshUsage()
            },
            onPreferences: { [weak self] in
                self?.closePopoverOrWindow()
                self?.preferencesClicked()
            },
            onManageProfiles: { [weak self] in
                self?.closePopoverOrWindow()
                self?.preferencesClicked(section: .manageProfiles)
            }
        )

        return NSHostingController(rootView: contentView)
    }

    @objc private func togglePopover(_ sender: Any?) {
        // Determine which button was clicked
        let clickedButton: NSStatusBarButton?
        if let button = sender as? NSStatusBarButton {
            clickedButton = button
        } else if statusBarUIManager?.isInMultiProfileMode == true,
                  let activeId = profileManager.activeProfile?.id,
                  let activeButton = statusBarUIManager?.button(for: activeId) {
            // Multi-profile mode: use the active profile's button
            clickedButton = activeButton
        } else {
            // Single profile mode: fallback to primary button
            clickedButton = statusBarUIManager?.primaryButton
        }

        guard let button = clickedButton else { return }

        // In multi-profile mode, determine which profile was clicked
        if statusBarUIManager?.isInMultiProfileMode == true,
           let profileId = statusBarUIManager?.profileId(for: button),
           let profile = profileManager.profiles.first(where: { $0.id == profileId }) {
            // Set the clicked profile data
            clickedProfileId = profileId
            clickedProfileUsage = profile.claudeUsage ?? .empty
            LoggingService.shared.log("Multi-profile popover: showing data for '\(profile.name)'")
        } else {
            // Single profile mode - use active profile
            clickedProfileId = profileManager.activeProfile?.id
            clickedProfileUsage = nil  // Will use manager.usage
        }

        // If there's a detached window, close it
        if let window = detachedWindow {
            window.close()
            detachedWindow = nil
            currentPopoverButton = nil
            return
        }

        // Otherwise toggle the popover
        if let popover, popover.isShown {
            // Check if clicking the same button or a different one
            if currentPopoverButton === button {
                // Same button - close the popover
                closePopover()
            } else {
                // Different button: close now, re-show on the NEXT runloop
                // turn with a FRESH popover. Closing and re-anchoring the same
                // popover against a different scene-hosted status button in a
                // single turn is one of the suspected storm igniters (Codex
                // consult 2026-07-29); the deferred destroy in popoverDidClose
                // runs first, so the re-show always builds a clean popover.
                popover.performClose(nil)
                stopMonitoringForOutsideClicks()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let fresh = self.ensurePopover()
                    fresh.contentViewController = self.createContentViewController()
                    fresh.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                    self.currentPopoverButton = button
                    self.startMonitoringForOutsideClicks()
                }
            }
        } else {
            // Popover not shown. If it JUST closed anchored to this same
            // button, this click is the semitransient auto-close's own
            // mouse-up — the user meant "dismiss", so swallow the re-open.
            if let lastButton = lastPopoverCloseButton, lastButton === button,
               Date().timeIntervalSince(lastPopoverCloseTime) < 0.3 {
                lastPopoverCloseButton = nil
                stopMonitoringForOutsideClicks()
                return
            }
            // Stop any existing monitor first
            stopMonitoringForOutsideClicks()
            let popover = ensurePopover()
            popover.contentViewController = createContentViewController()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            currentPopoverButton = button
            startMonitoringForOutsideClicks()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        stopMonitoringForOutsideClicks()
        currentPopoverButton = nil
    }

    private func startMonitoringForOutsideClicks() {
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
        // Check if in multi-profile mode
        if profileManager.displayMode == .multi {
            // Update multi-profile icons using profiles from profileManager
            let config = profileManager.multiProfileConfig
            statusBarUIManager?.updateMultiProfileButtons(
                profiles: profileManager.profiles,
                config: config
            )
        } else {
            // Single profile mode - use the standard update
            statusBarUIManager?.updateAllButtons(usage: usage)
        }
    }

    private func startAutoRefresh() {
        let interval = profileManager.activeProfile?.refreshInterval ?? 30.0
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.lastAutoRefreshTime = Date()
            self?.refreshUsage()
        }
        refreshTimer?.tolerance = interval * 0.1  // 10% tolerance for energy efficiency
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
            self.statusBarUIManager?.updateMultiProfileButtons(profiles: self.profileManager.profiles, config: config)
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
        // Fetch the provider-active/focused Claude profiles every sweep and
        // round-robin the remaining ones with whatever budget is left:
        //   rotationBudget = max(1, 2 - priorityClaudeCount)
        //   background staleness ≈ ceil(N_background / rotationBudget) sweeps
        //                         × refresh interval (30s) → minutes
        // e.g. 10 background Claude @ budget 1 → ~5 min; 3 background @ budget 1
        // → ~1.5 min. The ~2.5-min figure in older comments assumed 6 profiles and
        // is wrong at higher N. Codex/Grok hit different hosts and refresh every
        // sweep (never counted against the Claude budget).
        let priorityIds = Set([profileManager.activeProfile?.id, profileManager.activeClaudeProfileId].compactMap { $0 })
        let priorityClaudeCount = allSelected.filter { $0.providerKind == .claude && priorityIds.contains($0.id) }.count
        let rotationBudget = max(1, 2 - priorityClaudeCount)
        let backgroundClaude = allSelected.filter { $0.providerKind == .claude && !priorityIds.contains($0.id) }
        var rotating: [Profile] = []
        if !backgroundClaude.isEmpty {
            for offset in 0..<min(rotationBudget, backgroundClaude.count) {
                rotating.append(backgroundClaude[(claudeFetchCursor + offset) % backgroundClaude.count])
            }
            claudeFetchCursor = (claudeFetchCursor + rotating.count) % backgroundClaude.count
        }
        let rotatingIds = Set(rotating.map(\.id))
        // Codex and Grok profiles hit their own hosts (never the throttled
        // oauth/usage endpoint), so they refresh every sweep.
        let selectedProfiles = allSelected.filter {
            $0.providerKind != .claude || priorityIds.contains($0.id) || rotatingIds.contains($0.id)
        }

        // Log the achievable background-staleness SLO once per app run (F4).
        if !hasLoggedBackgroundStalenessEstimate {
            hasLoggedBackgroundStalenessEstimate = true
            let nBackground = backgroundClaude.count
            let sweepsToCover = nBackground == 0
                ? 0
                : Int(ceil(Double(nBackground) / Double(rotationBudget)))
            // Refresh timer is 30s; report minutes (rounded up to nearest 0.5 for readability).
            let minutes = sweepsToCover == 0 ? 0.0 : Double(sweepsToCover) * 30.0 / 60.0
            let minutesLabel = minutes == floor(minutes)
                ? String(format: "%.0f", minutes)
                : String(format: "%.1f", minutes)
            LoggingService.shared.log(
                "MenuBarManager: \(nBackground) background Claude profiles on rotation budget \(rotationBudget) -> ~\(minutesLabel)min staleness"
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
                // profiles re-fetch next sweep; a skipped background profile waits
                // for its next round-robin turn (the fetch cursor already moved).
                if self.profileManager.isSwitchingProfile {
                    LoggingService.shared.log("MenuBarManager: profile switch started mid-sweep — ending sweep early")
                    break
                }

                // While an account-level throttle is in force the usage endpoint
                // keeps 429ing — don't burn the sweep's rate-limit budget on it.
                // The stamp keeps the account reported as exhausted; fetching
                // resumes automatically once the Retry-After expires (and a
                // still-throttled account just gets a fresh stamp). Only the
                // CLAUDE usage fetch is skipped — the API-console fetch below
                // hits a different, unthrottled endpoint and must keep flowing.
                let usageThrottled = profile.claudeUsage?.rateLimitedUntil.map { $0 > Date() } ?? false
                let burstBackoffUntil = burstBackoffs[profile.id]?.until
                let usageBackedOff = burstBackoffUntil.map { $0 > Date() } ?? false
                if usageThrottled {
                    LoggingService.shared.log("MenuBarManager: skipping usage fetch for '\(profile.name)' — endpoint throttled until \(profile.claudeUsage?.rateLimitedUntil ?? Date())")
                } else if usageBackedOff {
                    LoggingService.shared.log("MenuBarManager: skipping usage fetch for '\(profile.name)' — backing off burst 429s until \(burstBackoffUntil ?? Date())")
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
                    }

                    // Self-heal a stale CLI OAuth token before fetching
                    await self.ensureFreshCLICredentialsIfNeeded(for: profile)
                    if let updated = self.profileManager.profiles.first(where: { $0.id == profile.id }) {
                        profile = updated
                    }

                    LoggingService.shared.log("MenuBarManager: Fetching usage for profile '\(profile.name)'")

                    do {
                        let newUsage = try await fetchUsageForProfile(profile)

                        // Save to profile
                        self.profileManager.stageClaudeUsage(newUsage, for: profile.id)
                        LoggingService.shared.log("MenuBarManager: Saved usage for profile '\(profile.name)' - session: \(newUsage.sessionPercentage)%")

                        // If this is the active profile, also update the manager's usage
                        if profile.id == self.profileManager.activeProfile?.id {
                            self.usage = newUsage
                        }
                        sweepSuccesses += 1
                        self.credentialErrorProfileIds.remove(profile.id)
                        self.burstBackoffs.removeValue(forKey: profile.id)

                        // Check auto-switch NOW for the accounts actually in use
                        // instead of waiting for the end of the sweep: rate-limit
                        // spacing makes a full sweep take ~2s per profile, and near
                        // the threshold those seconds are when parallel sessions hit
                        // the hard limit. Idempotent with the end-of-sweep check
                        // (autoSwitchedProfileIds de-dupes the trigger).
                        if profile.id == self.profileManager.activeProfile?.id
                            || profile.id == self.profileManager.activeClaudeProfileId
                            || profile.id == self.profileManager.activeCodexProfileId {
                            self.checkAutoSwitchIfNeeded(usage: newUsage, currentProfile: profile)
                        }
                    } catch {
                        let appError = AppError.wrap(error)
                        sweepFailures += 1
                        sweepLastErrorMessage = appError.message
                        if appError.code == .apiUnauthorized || appError.code == .sessionKeyExpired {
                            sweepCredentialError = true
                            self.credentialErrorProfileIds.insert(profile.id)
                        }
                        // An account-level 429 IS usage information: the account is
                        // out of capacity and its cached percentages are frozen at
                        // pre-throttle values. Stamp it so the tiles and auto-switch
                        // see 100% instead of trusting the stale cache — and check
                        // the switch NOW if this account is one actually in use.
                        if let stamped = self.stampAccountThrottleIfNeeded(appError, profile: profile) {
                            if profile.id == self.profileManager.activeProfile?.id
                                || profile.id == self.profileManager.activeClaudeProfileId
                                || profile.id == self.profileManager.activeCodexProfileId {
                                self.checkAutoSwitchIfNeeded(usage: stamped, currentProfile: profile)
                            }
                        } else if appError.code == .apiRateLimited {
                            // Burst-class 429 (no account-level Retry-After):
                            // exhaustion is unknown, so don't stamp — but stop
                            // re-fetching every sweep. Pass the server's own
                            // (sub-floor) Retry-After when present.
                            self.registerBurstBackoff(for: profile, retryAfter: appError.retryAfterSeconds)
                        }
                        LoggingService.shared.logError("Failed to refresh profile '\(profile.name)': \(error.localizedDescription)")
                    }
                }
            }

            // Publish everything staged this sweep in ONE objectWillChange,
            // then repaint the tiles from the fresh array.
            self.profileManager.publishStagedUsage()

            // Update all icons once after all profiles are refreshed
            let config = self.profileManager.multiProfileConfig
            self.statusBarUIManager?.updateMultiProfileButtons(
                profiles: self.profileManager.profiles,
                config: config
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

            // Check auto-switch for each provider's active account (both are "in
            // use" at any time: the Claude account the CLI is logged into and the
            // Codex account owning auth.json — either hitting its limit should
            // rotate within its own provider group).
            var checkedIds = Set<UUID>()
            let idsToCheck = [
                self.profileManager.activeProfile?.id,
                self.profileManager.activeClaudeProfileId,
                self.profileManager.activeCodexProfileId
            ].compactMap { $0 }

            for profileId in idsToCheck where !checkedIds.contains(profileId) {
                checkedIds.insert(profileId)
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

            // A CLI-side /login only writes the Keychain; keep the credentials
            // FILE in step so headless sessions that read the file aren't left
            // presenting the previous (possibly exhausted) account's token.
            await ClaudeCodeSyncService.shared.healCredentialsFileFromKeychainOffMain()
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
        if profile.id == (profileManager.activeClaudeProfileId ?? profileManager.activeProfile?.id),
           let systemCredentials = try? await ClaudeCodeSyncService.shared.readSystemCredentialsOffMain(),
           !ClaudeCodeSyncService.shared.isTokenExpired(systemCredentials),
           let accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: systemCredentials) {
            return try await apiService.fetchUsageData(oauthAccessToken: accessToken)
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

        // Detailed logging
        LoggingService.shared.log("MenuBarManager.refreshUsage called:")
        LoggingService.shared.log("  - Profile: '\(profile.name)'")
        LoggingService.shared.log("  - hasUsageCredentials: \(profile.hasUsageCredentials)")

        // Check for usage credentials (Claude.ai or API Console, not just CLI)
        guard profile.hasUsageCredentials else {
            LoggingService.shared.log("MenuBarManager: Skipping refresh - no usage credentials")
            // Update icons to show default logo if needed
            updateAllStatusBarIcons()
            return
        }

        LoggingService.shared.log("MenuBarManager: Proceeding with refresh")
        Task {
            // Set loading state (keep existing data visible during refresh)
            self.isRefreshing = true
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

                // Check for resets before updating usage
                self.usage = newUsage

                // Save to active profile instead of global DataStore
                if let profileId = self.profileManager.activeProfile?.id {
                    self.profileManager.saveClaudeUsage(newUsage, for: profileId)
                }

                // Update all menu bar icons
                self.updateAllStatusBarIcons()

                // Check if we should send notifications (using active profile's settings)
                if let profile = self.profileManager.activeProfile {
                    NotificationManager.shared.checkAndNotify(
                        usage: newUsage,
                        profileName: profile.name,
                        settings: profile.notificationSettings
                    )

                    // Check if auto-switch should trigger
                    self.checkAutoSwitchIfNeeded(usage: newUsage, currentProfile: profile)
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

            } catch {
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
        let isActiveClaude = profile.id == (profileManager.activeClaudeProfileId ?? profileManager.activeProfile?.id)
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

    private func registerBurstBackoff(for profile: Profile, retryAfter: TimeInterval? = nil) {
        let streak = (burstBackoffs[profile.id]?.streak ?? 0) + 1
        // The ACTIVE accounts (focused + provider-active) are the ones whose
        // usage is actually moving — they own the CLI logins being burned right
        // now, and their percentages gate the auto-switch trigger. Cap their
        // backoff at 120s (≈ retry every other sweep) so a burst-429ing active
        // account is never more than ~2.5 min stale; only one account per
        // provider can be active, so the extra retry volume is one request per
        // ~2 sweeps at worst. Background rotation profiles keep the 8-min cap.
        let isActiveAccount = profile.id == profileManager.activeProfile?.id
            || profile.id == profileManager.activeClaudeProfileId
            || profile.id == profileManager.activeCodexProfileId
        let cap: TimeInterval = isActiveAccount ? 120 : 480
        let interval: TimeInterval
        if let retryAfter, retryAfter > 0 {
            // The endpoint SAID when to come back (a seconds-scale, sub-account-
            // floor Retry-After). Honor it instead of an exponential guess —
            // discarding it was how a busy account went blind for minutes at a
            // time. Small floor so a "1s" header can't turn into hammering.
            interval = max(retryAfter, 30)
        } else {
            interval = min(Self.burstBackoffInterval(streak: streak), cap)
        }
        burstBackoffs[profile.id] = BurstBackoff(until: Date().addingTimeInterval(interval), streak: streak)
        LoggingService.shared.log("MenuBarManager: '\(profile.name)' drew a burst 429 (retry-after: \(retryAfter.map { "\(Int($0))s" } ?? "none"), active: \(isActiveAccount)) — backing usage fetch off for \(Int(interval))s (streak \(streak))")
    }

    // MARK: - Account-Level Throttle Stamping

    /// Floor separating an ACCOUNT-level usage-endpoint throttle from the
    /// endpoint's ordinary per-IP burst limiting. Burst 429s carry a
    /// seconds-scale (or no) Retry-After; an exhausted/heavily-used account
    /// refuses its own usage reads with a Retry-After of MINUTES (a real
    /// incident measured 2918s).
    nonisolated static let accountThrottleRetryAfterFloor: TimeInterval = 60

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
              retryAfter >= Self.accountThrottleRetryAfterFloor else { return nil }

        var usage = profile.claudeUsage ?? .empty
        usage.rateLimitedUntil = Date().addingTimeInterval(retryAfter)
        usage.lastUpdated = Date()
        profileManager.saveClaudeUsage(usage, for: profile.id)
        LoggingService.shared.log("MenuBarManager: '\(profile.name)' usage endpoint throttled for \(Int(retryAfter))s — treating account as exhausted until the throttle lifts")
        return usage
    }

    // MARK: - Auto-Switch Profile on Session Limit

    /// Checks if the current profile crossed an auto-switch threshold (session
    /// default 95%, weekly/Fable default 99% — Settings → Profiles →
    /// Auto-Switch) and switches to the next available one. Firing BELOW 100%
    /// is deliberate: it forfeits the remaining headroom so running sessions
    /// never hit the hard limit while the sweep-based detection (~30s cadence)
    /// catches up. The weekly threshold is tighter because forfeited weekly
    /// quota does not come back until the weekly reset.
    private func checkAutoSwitchIfNeeded(usage: ClaudeUsage, currentProfile: Profile) {
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

        // Mark as triggered
        autoSwitchedProfileIds.insert(profileId)

        // Try candidates in ranking order. A candidate whose stored login turns out
        // to be dead is NOT applied by activateProfile (it returns false and the
        // shared login stays on the outgoing account) — move on to the next one
        // instead of silently staying on an exhausted account.
        let fromName = currentProfile.name
        Task {
            var excluded: Set<UUID> = []
            while let nextProfile = self.popQueuedSwitchTarget(
                provider: currentProfile.providerKind,
                excluding: excluded,
                sessionThreshold: sessionThreshold,
                weeklyThreshold: weeklyThreshold
            ) ?? self.findNextAvailableProfile(after: currentProfile, excluding: excluded) {
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

                if await self.profileManager.activateProfile(nextProfile.id) {
                    // Send notification
                    NotificationManager.shared.sendAutoSwitchNotification(fromProfile: fromName, toProfile: nextProfile.name)
                    return
                }

                excluded.insert(nextProfile.id)
                LoggingService.shared.log("AutoSwitch: could not take over '\(nextProfile.name)' login (dead credentials?), trying next candidate")
            }
            // No candidate had headroom (or their logins were dead). Un-mark so the
            // next sweep retries — a candidate's session window resetting must not
            // strand us on an exhausted account for the rest of its weekly window.
            self.autoSwitchedProfileIds.remove(profileId)
            LoggingService.shared.log("AutoSwitch: no usable candidate right now, staying on '\(fromName)' (will retry)")
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

    /// Session-usage milestones at which the NEXT auto-switch candidate's stored
    /// login is validated ahead of the threshold switch.
    private static let preflightMilestones: [Double] = [25, 50, 75, 90]

    /// Milestones already preflighted per current profile — cleared when its
    /// session usage drops back below the first milestone (window reset).
    private var preflightedMilestones: [UUID: Set<Double>] = [:]
    private var preflightRunning: Set<UUID> = []

    /// CANDIDATES currently being validated by any watcher. Both provider-active
    /// accounts (and the focused profile) are milestone-watched, and two watchers
    /// of the same provider can rank the SAME candidate next — the per-profile
    /// refresh mutex already prevents a double token redemption, but this keeps
    /// the second watcher from walking (and double-notifying about) a candidate
    /// another watcher is validating right now.
    private var preflightInFlightCandidates: Set<UUID> = []

    /// Fires once per crossed milestone (25/50/75/90% of the current account's
    /// session window) and validates the auto-switch's predicted target in the
    /// background. Validation = the same refresh the switch itself would perform,
    /// done EARLY: a live-but-stale token is refreshed now (proving the refresh
    /// token works and banking a fresh access token), and a dead one triggers the
    /// re-login notification while the current account still has headroom — so the
    /// eventual switch lands on a login that is known to work.
    private func preflightNextCandidateIfNeeded(usage: ClaudeUsage, currentProfile: Profile) {
        let percentage = usage.effectiveSessionPercentage
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
            if candidate.id == profileManager.activeClaudeProfileId
                || candidate.id == profileManager.activeCodexProfileId {
                LoggingService.shared.log("Preflight[\(Int(milestone))%]: next candidate '\(candidate.name)' already owns its provider login — OK")
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
            if candidate.isCodexOnlyProfile {
                _ = await CodexUsageService.shared.ensureFreshCredentials(for: candidate.id, freshFor: 24 * 3600)
                if let json = ProfileStore.shared.loadProfiles().first(where: { $0.id == candidate.id })?.codexCredentialsJSON {
                    alive = !CodexUsageService.shared.isTokenExpired(json)
                }
            } else if candidate.isGrokOnlyProfile {
                // Structurally dead today (a grok CURRENT never crosses a session
                // milestone — grok session% is always 0 — and candidates are
                // same-provider), but kept correct for a future multi-account
                // grok group rather than falling into the claude branches.
                _ = await GrokUsageService.shared.ensureFreshCredentials(for: candidate.id, freshFor: 24 * 3600)
                if let json = ProfileStore.shared.loadProfiles().first(where: { $0.id == candidate.id })?.grokCredentialsJSON {
                    alive = !GrokUsageService.shared.isTokenExpired(json)
                }
            } else if candidate.cliCredentialsJSON != nil {
                _ = await ClaudeCodeSyncService.shared.ensureFreshCredentials(
                    for: candidate.id,
                    adoptSystemKeychain: false,
                    syncToSystem: false,
                    freshFor: 3600
                )
                if let json = ProfileStore.shared.loadProfiles().first(where: { $0.id == candidate.id })?.cliCredentialsJSON {
                    alive = !ClaudeCodeSyncService.shared.isTokenExpired(json)
                }
            }
            // claude.ai-session-only candidates carry no OAuth tokens to validate.

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
        let now = Date()
        let switchingProvider = currentProfile.providerKind
        // Candidates are held to the SAME per-window thresholds the trigger
        // fires at: a profile at ≥threshold is exactly what the switch is
        // escaping, so landing on one (and ping-ponging between two
        // nearly-full accounts) must be impossible by construction.
        let sessionThreshold = SharedDataStore.shared.loadAutoSwitchThreshold()
        let weeklyThreshold = SharedDataStore.shared.loadAutoSwitchWeeklyThreshold()

        let candidates = profileManager.profiles.filter { candidate in
            guard candidate.id != currentProfile.id, candidate.hasUsageCredentials,
                  !excluding.contains(candidate.id) else { return false }

            // Same-provider rule: never cross between Claude, Codex, and Grok accounts
            guard candidate.providerKind == switchingProvider else { return false }

            // Respect the per-profile eligibility toggle (Settings → Profiles → Auto-Switch)
            guard candidate.isAutoSwitchEnabled else {
                LoggingService.shared.log("AutoSwitch: Skipping '\(candidate.name)' (excluded by per-profile toggle)")
                return false
            }

            // Skip Claude CLI-only accounts on a free plan — no paid quota to take over
            if switchingProvider == .claude,
               !candidate.hasClaudeAI,
               let cliJSON = candidate.cliCredentialsJSON,
               let info = ClaudeCodeSyncService.shared.extractSubscriptionInfo(from: cliJSON),
               info.type.lowercased() == "free" {
                LoggingService.shared.log("AutoSwitch: Skipping '\(candidate.name)' (free subscription)")
                return false
            }
            return true
        }

        // Default ranking only — the consumable switch QUEUE is handled one
        // level up in the candidate walk (popQueuedSwitchTarget), so an empty
        // queue falls through to this ranking untouched.
        let ranked = Self.rankAutoSwitchCandidates(candidates, customOrder: nil, now: now)

        for candidate in ranked {
            if hasSessionHeadroom(candidate, threshold: sessionThreshold)
                && hasWeeklyHeadroom(candidate, threshold: weeklyThreshold, now: now)
                && hasFableWeeklyHeadroom(candidate, threshold: weeklyThreshold, now: now) {
                return candidate
            }
            LoggingService.shared.log("AutoSwitch: '\(candidate.name)' resets soonest but has no session, weekly or Fable headroom, trying next")
        }
        return nil
    }

    /// Pops the next queued auto-switch target for this provider. The queue is
    /// CONSUMABLE: entry #1 is the immediate next switch target, and every entry
    /// is spent when tried — a queued account that turns out ineligible
    /// (deleted, excluded this walk, dead, or already over a threshold) is
    /// consumed and skipped, never retried forever. Entries for OTHER providers
    /// stay queued for their own provider's switch. Empty queue → nil → the
    /// caller falls back to the default soonest-weekly-reset walk.
    private func popQueuedSwitchTarget(
        provider: Profile.ProviderKind,
        excluding: Set<UUID>,
        sessionThreshold: Double,
        weeklyThreshold: Double
    ) -> Profile? {
        var queue = SharedDataStore.shared.loadAutoSwitchQueue()
        guard !queue.isEmpty else { return nil }
        defer { SharedDataStore.shared.saveAutoSwitchQueue(queue) }

        var index = 0
        while index < queue.count {
            let id = queue[index]
            guard let profile = profileManager.profiles.first(where: { $0.id == id }) else {
                queue.remove(at: index)  // profile was deleted — drop the entry
                continue
            }
            guard profile.providerKind == provider else {
                index += 1  // another provider's turn will consume it
                continue
            }
            // This provider's head entry: consume it now, whatever happens next.
            queue.remove(at: index)
            let now = Date()
            guard !excluding.contains(profile.id),
                  profile.hasUsageCredentials,
                  hasSessionHeadroom(profile, threshold: sessionThreshold),
                  hasWeeklyHeadroom(profile, threshold: weeklyThreshold, now: now),
                  hasFableWeeklyHeadroom(profile, threshold: weeklyThreshold, now: now) else {
                LoggingService.shared.log("AutoSwitch: queued '\(profile.name)' is not usable right now (dead, excluded, or no headroom) — consumed, trying next")
                continue
            }
            LoggingService.shared.log("AutoSwitch: taking queued target '\(profile.name)' (\(queue.count) left in queue)")
            return profile
        }
        return nil
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

        // If settings window already exists, bring it to front (and jump it to the
        // requested section — its SwiftUI state can't be re-seeded from here)
        if let existingWindow = settingsWindow, existingWindow.isVisible {
            Self.bringWindowToForeground(existingWindow)
            if let section {
                NotificationCenter.default.post(name: .settingsSectionRequested, object: section.rawValue)
            }
            return
        }

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

            Self.bringWindowToForeground(window)
        }
    }

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

    private func switchToNextProfile() {
        let profiles = profileManager.profiles
        guard profiles.count > 1,
              let currentId = profileManager.activeProfile?.id,
              let currentIndex = profiles.firstIndex(where: { $0.id == currentId }) else {
            return
        }

        let nextIndex = (profiles.index(after: currentIndex)) % profiles.count
        let nextProfile = profiles[nextIndex]

        Task {
            await profileManager.activateProfile(nextProfile.id, userInitiated: true)
        }
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

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = newContentViewController
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 320, height: 600))
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isRestorable = false
        window.delegate = self
        window.backgroundColor = .clear

        // Store reference to the detached window
        detachedWindow = window

        return window
    }

    func popoverDidClose(_ notification: Notification) {
        // Record WHERE and WHEN the popover closed. The .semitransient popover
        // auto-closes on the mouse-DOWN of a click on the anchoring status
        // button; the button's action then fires on mouse-UP with isShown ==
        // false and would re-open it — making "click the same tile to dismiss"
        // impossible. togglePopover consults this stamp to swallow that re-open.
        lastPopoverCloseButton = currentPopoverButton
        lastPopoverCloseTime = Date()
        currentPopoverButton = nil

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
