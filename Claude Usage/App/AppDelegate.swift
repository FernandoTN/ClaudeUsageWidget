import Cocoa
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var menuBarManager: MenuBarManager?
    private var setupWindow: NSWindow?
    private var setupWindowCloseObserver: NSObjectProtocol?

    /// True when another live instance of this app should win and this one must
    /// exit. Oldest `launchDate` wins — PID comparison is NOT a launch-order
    /// tiebreak (PID wraparound handed a freshly launched duplicate a lower PID
    /// than the long-running original, a real incident); identical launch dates
    /// fall back to PID so simultaneous copies still collapse deterministically
    /// to exactly one instead of all quitting (and being resurrected) together.
    /// Never true inside a test run: the guard would terminate the XCTest host
    /// whenever the real app is running on the same machine.
    private static func isDuplicateInstance() -> Bool {
        let isTestRun = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        guard !isTestRun else { return false }

        let me = NSRunningApplication.current
        let siblings = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { !$0.isTerminated && $0.processIdentifier != me.processIdentifier }

        let myDate = me.launchDate ?? .distantPast
        let olderSiblingExists = siblings.contains { sib in
            let sibDate = sib.launchDate ?? .distantPast
            if sibDate != myDate { return sibDate < myDate }
            return sib.processIdentifier < me.processIdentifier
        }
        if olderSiblingExists {
            LoggingService.shared.log("AppDelegate: an older instance of this app is already running — exiting duplicate pid \(me.processIdentifier)")
        }
        return olderSiblingExists
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard, BEFORE any side effects: duplicate instances
        // double every API sweep (feeding oauth/usage 429s), double Keychain
        // writes, and duplicate the menu-bar icons. macOS resurrects killed
        // login-item agents, and a resurrection racing a manual relaunch has
        // produced two live copies (2026-07-16). exit(0), not
        // NSApp.terminate — terminate can be swallowed mid-didFinishLaunching.
        if Self.isDuplicateInstance() {
            exit(0)
        }
        // Simultaneous launches can each miss the other before LaunchServices
        // registers them (observed: resurrection racing a manual `open`) —
        // re-check once after the window has safely passed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if Self.isDuplicateInstance() {
                exit(0)
            }
        }

        // FIRST: one-time preferences migration for the bundle-id rename — must
        // run before anything reads (or writes) UserDefaults.standard.
        MigrationService.shared.migrateLegacyBundleDefaultsIfNeeded()

        // Disable window restoration for menu bar app
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")

        // Set app icon early for Stage Manager and windows
        if let appIcon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }

        // Hide dock icon (menu bar app only)
        NSApp.setActivationPolicy(.accessory)

        // Load profiles into ProfileManager (synchronously)
        ProfileManager.shared.loadProfiles()

        // Request notification permissions
        requestNotificationPermissions()

        // Listen for manual wizard trigger (for testing)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShowSetupWizard),
            name: .showSetupWizard,
            object: nil
        )

        // Check if setup has been completed
        if !shouldShowSetupWizard() {
            // Initialize menu bar with active profile
            menuBarManager = MenuBarManager()
            menuBarManager?.setup()
        } else {
            showSetupWizardManually()
            // Mark that wizard has been shown once
            SharedDataStore.shared.markWizardShown()
        }

        // Headless support: delayed retry for Remote Desktop scenarios
        // If status bar failed to initialize (headless Mac), retry after a delay when displays connect
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }

            // Only retry if we have screens now but status bar failed
            if !NSScreen.screens.isEmpty && self.menuBarManager?.hasValidStatusBar() == false {
                LoggingService.shared.log("AppDelegate: Delayed retry of status bar setup (headless support)")
                self.menuBarManager?.setup()
            }
        }
    }

    private func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            // Silently request permissions
        }
    }


    private func shouldShowSetupWizard() -> Bool {
        // FORCE SHOW wizard on very first app launch (one-time)
        // This ensures users see the migration option if they have old data
        if !SharedDataStore.shared.hasShownWizardOnce() {
            LoggingService.shared.log("AppDelegate: First launch - forcing wizard to show migration option")
            return true
        }

        // After first launch, use normal checks:

        // activeProfile will always exist after loadProfiles() is called
        // (ProfileManager creates a default profile if none exist)
        guard let activeProfile = ProfileManager.shared.activeProfile else {
            return true  // Safety fallback, should never happen
        }

        // If profile already has any credentials, skip wizard
        if activeProfile.hasAnyCredentials {
            return false
        }

        // Check if valid CLI credentials exist in system Keychain
        if hasValidSystemCLICredentials() {
            LoggingService.shared.log("AppDelegate: Found valid CLI credentials, skipping wizard")
            return false
        }

        // No credentials found - show wizard
        return true
    }

    /// Checks if valid Claude Code CLI credentials exist in system Keychain
    private func hasValidSystemCLICredentials() -> Bool {
        do {
            // Attempt to read credentials from system Keychain
            guard let jsonData = try ClaudeCodeSyncService.shared.readSystemCredentials() else {
                LoggingService.shared.log("AppDelegate: No CLI credentials found in system Keychain")
                return false
            }

            // Validate: not expired
            if ClaudeCodeSyncService.shared.isTokenExpired(jsonData) {
                LoggingService.shared.log("AppDelegate: CLI credentials found but expired")
                return false
            }

            // Validate: has valid access token
            guard ClaudeCodeSyncService.shared.extractAccessToken(from: jsonData) != nil else {
                LoggingService.shared.log("AppDelegate: CLI credentials found but missing access token")
                return false
            }

            LoggingService.shared.log("AppDelegate: Valid CLI credentials found in system Keychain")
            return true

        } catch {
            LoggingService.shared.logError("AppDelegate: Failed to check CLI credentials", error: error)
            return false
        }
    }

    /// Handles notification to show setup wizard
    @objc private func handleShowSetupWizard() {
        LoggingService.shared.log("AppDelegate: Received showSetupWizard notification")
        showSetupWizardManually()
    }

    /// Shows the setup wizard window (can be called manually for testing)
    func showSetupWizardManually() {
        LoggingService.shared.log("AppDelegate: showSetupWizardManually called")

        // Temporarily show dock icon for the setup window
        NSApp.setActivationPolicy(.regular)
        LoggingService.shared.log("AppDelegate: Set activation policy to regular")

        let setupView = SetupWizardView()
        let hostingController = NSHostingController(rootView: setupView)
        LoggingService.shared.log("AppDelegate: Created hosting controller")

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Claude Usage Widget Setup"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        LoggingService.shared.log("AppDelegate: Window created and made key")

        // Hide dock icon again when setup window closes
        setupWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            NSApp.setActivationPolicy(.accessory)
            self?.setupWindow = nil

            // Remove observer to prevent leak
            if let observer = self?.setupWindowCloseObserver {
                NotificationCenter.default.removeObserver(observer)
                self?.setupWindowCloseObserver = nil
            }

            // Initialize menu bar after setup completes
            if self?.menuBarManager == nil {
                self?.menuBarManager = MenuBarManager()
                self?.menuBarManager?.setup()
            }
        }

        setupWindow = window
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup
        menuBarManager?.cleanup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running even if all windows are closed
        return false
    }

    func application(_ application: NSApplication, willEncodeRestorableState coder: NSCoder) {
        // Prevent window restoration state from being saved
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        // Disable state restoration for menu bar app
        return false
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notifications even when app is in foreground (menu bar apps are always foreground)
        completionHandler([.banner, .sound])
    }
}
