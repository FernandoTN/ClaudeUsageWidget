import SwiftUI

@main
struct ClaudeUsageTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Menu-bar-only app: deliberately NO SwiftUI Settings scene. The real
        // settings window is hand-built (SettingsWindowBuilder) and tracked by
        // MenuBarManager.settingsWindow; a Settings scene here would let Cmd-,
        // open a SECOND, untracked SettingsView graph that subscribes to
        // ProfileManager forever and blinds the StormWatchdog idle gate
        // (2026-07-29 evening investigation, orphan path O3). An App needs at
        // least one Scene — an empty, never-shown WindowGroup-free placeholder
        // is not expressible, so use Settings with an EmptyView (instantiates
        // nothing observable).
        Settings {
            EmptyView()
        }
    }
}
