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

    /// True inside the XCTest host, which launches the real app around the
    /// tests. Starting the menu bar there gives every test a live 30s sweep
    /// that adopts the machine's real Claude Code login into whatever profile
    /// the test just made active, silently overwriting a seeded credential
    /// mid-assertion (three CredentialHydrationTests, 2026-09-03). Until now
    /// the suite was protected only by an accident — the focused test profile
    /// happened to look credential-less, so the wizard branch ran instead —
    /// which any correct broadening of the setup predicate removes. Tests that
    /// need a MenuBarManager build their own.
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
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

        // Phase 0 lab path: synthetic tiles only. Skips migration, profile load,
        // credential sync, notifications, network, and MenuBarManager so lab
        // runs never touch real profiles / Keychain / UserDefaults / network.
        // Single-instance guard above is kept (lab builds use a distinct bundle id).
        if LabMode.isEnabled {
            NSApp.setActivationPolicy(.accessory)
            LabController.shared.start()
            RenderInstrumentation.startIfNeeded()
            LoggingService.shared.log("AppDelegate: lab mode active (CUW_LAB=1) — normal startup skipped")
            return
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
        if Self.isRunningUnderXCTest {
            LoggingService.shared.log(
                "AppDelegate: XCTest host — skipping menu bar and setup wizard")
        } else if !shouldShowSetupWizard() {
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

        // Phase 0 render instrumentation (normal mode; lab path starts it above).
        RenderInstrumentation.startIfNeeded()
    }

    private func requestNotificationPermissions() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            // Silently request permissions
        }
    }


    /// Setup is complete when the INSTALL has a usable login, not when the
    /// focused profile does. PURE, so the predicate is testable without a
    /// Keychain or an app launch.
    ///
    /// The old rule read the focused profile only, which made a Codex-only
    /// install permanently unfinished: the auto-import lands "Codex (email)"
    /// as an extra profile while focus stays on the empty "Account 1", so
    /// "Claude Code login required" reopened on every launch until the user
    /// activated the Codex profile by hand. Any credentialed profile of any
    /// provider counts, and so does a live provider CLI login on disk (the
    /// auto-import turns those into profiles, but it runs once and may not
    /// have run yet).
    ///
    /// `carries*Account` is deliberately part of the profile test: the wizard
    /// gate runs at launch, when the background Keychain hydration may not
    /// have filled in the credential fields yet, and a profile that looks
    /// credential-less for that reason must not reopen the wizard.
    /// The three CLI probes are `@autoclosure` so the profile test
    /// short-circuits them. `hasValidSystemCLICredentials()` reads the system
    /// Keychain on the calling (main) thread, and this gate runs at launch —
    /// evaluating it eagerly on every launch would put a blocking Keychain
    /// read in front of the UI for no reason.
    static func isSetupComplete(
        profiles: [Profile],
        hasClaudeCLILogin: @autoclosure () -> Bool,
        hasCodexCLILogin: @autoclosure () -> Bool,
        hasGrokCLILogin: @autoclosure () -> Bool
    ) -> Bool {
        if profiles.contains(where: {
            $0.hasAnyCredentials || $0.carriesClaudeAccount || $0.carriesCodexAccount || $0.carriesGrokAccount
        }) {
            return true
        }
        return hasClaudeCLILogin() || hasCodexCLILogin() || hasGrokCLILogin()
    }

    private func shouldShowSetupWizard() -> Bool {
        // FORCE SHOW wizard on very first app launch (one-time)
        // This ensures users see the migration option if they have old data
        if !SharedDataStore.shared.hasShownWizardOnce() {
            LoggingService.shared.log("AppDelegate: First launch - forcing wizard to show migration option")
            return true
        }

        // After first launch, use normal checks:
        let profiles = ProfileManager.shared.profiles
        guard !profiles.isEmpty else {
            return true  // Safety fallback, should never happen after loadProfiles()
        }

        if Self.isSetupComplete(
            profiles: profiles,
            hasClaudeCLILogin: hasValidSystemCLICredentials(),
            hasCodexCLILogin: Self.hasValidCodexCLILogin(),
            hasGrokCLILogin: Self.hasValidGrokCLILogin()
        ) {
            return false
        }

        // No credentials found - show wizard
        return true
    }

    /// A live `~/.codex/auth.json` login. File read only — no Keychain, so it
    /// is safe on the main thread at launch.
    static func hasValidCodexCLILogin() -> Bool {
        guard let json = CodexUsageService.shared.readAuthFile() else { return false }
        return CodexUsageService.shared.extractAccessToken(from: json) != nil
    }

    /// A live `~/.grok/auth.json` login. Same file-only read as the Codex twin.
    static func hasValidGrokCLILogin() -> Bool {
        guard let json = GrokUsageService.shared.readAuthFile() else { return false }
        return GrokUsageService.shared.extractAccessToken(from: json) != nil
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

        // Re-entry guard: a second invocation would mint a second window,
        // orphan the first one, and overwrite (leak) its close observer —
        // cross-wiring which window restores the accessory activation policy.
        if let existing = setupWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

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
        // Persist any deferred usage patches before teardown so a quit mid-sweep
        // does not drop the last fetched percentages.
        ProfileManager.shared.flushPendingUsage()
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
