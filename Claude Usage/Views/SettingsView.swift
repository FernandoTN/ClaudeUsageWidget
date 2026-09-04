import SwiftUI
import UserNotifications

// MARK: - Visual Effect Backgrounds

/// Full-window vibrancy background — same approach as the popover's VisualEffectBackground.
/// Using NSViewRepresentable inside SwiftUI means the entire view tree is SwiftUI-managed,
/// so there is no opaque flash on deminiaturize or appearance change.
struct SettingsBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effectView)

        let tintView = NSView()
        tintView.wantsLayer = true
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        } else {
            tintView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
        }
        tintView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tintView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: container.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op unless the resolved appearance actually changed: this runs on
        // EVERY re-evaluation of the owning SwiftUI tree, and unconditionally
        // assigning a full-window layer color scheduled a whole-window
        // recomposite per publish (Codex-validated). Keyed on the VIEW's
        // effective appearance, not NSApp's.
        guard let tintView = nsView.subviews.last else { return }
        let isDark = nsView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let desired = isDark
            ? NSColor.black.withAlphaComponent(0.35).cgColor
            : NSColor.white.withAlphaComponent(0.4).cgColor
        if tintView.layer?.backgroundColor != desired {
            tintView.wantsLayer = true
            tintView.layer?.backgroundColor = desired
        }
    }
}

struct SidebarVisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.isEmphasized = true
        effectView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effectView)

        let tintView = NSView()
        tintView.wantsLayer = true
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            tintView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        } else {
            tintView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        }
        tintView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tintView)

        NSLayoutConstraint.activate([
            effectView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effectView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            effectView.topAnchor.constraint(equalTo: container.topAnchor),
            effectView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            tintView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: container.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Same guard as SettingsBackground: only touch the layer when the
        // resolved appearance actually changed.
        guard let tintView = nsView.subviews.last else { return }
        let isDark = nsView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let desired = isDark
            ? NSColor.black.withAlphaComponent(0.55).cgColor
            : NSColor.white.withAlphaComponent(0.5).cgColor
        if tintView.layer?.backgroundColor != desired {
            tintView.wantsLayer = true
            tintView.layer?.backgroundColor = desired
        }
    }
}

/// Borderless window that keeps rounded corners, shadow, and drag-to-move.
final class BorderlessSettingsWindow: NSWindow {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask,
                  backing: NSWindow.BackingStoreType, defer flag: Bool) {
        // TITLED (with the titlebar hidden), NOT .borderless — this was the root
        // of the window-server storm family plaguing the app since profiling
        // began. A transparent borderless window's event shape is derived from
        // its content's ALPHA and recomputed continuously ("Window event shape
        // became non empty" storms, thousands/min), and every tracking-area
        // change forces a synchronous structural-region re-registration with
        // the window server — sampled repeatedly as the main-thread mach_msg
        // storm behind the settings freezes (scrolling a hover-dense view
        // re-registers regions per frame). A titled+fullSizeContentView window
        // looks the same, has a fixed rectangular event shape, native rounded
        // corners/shadow, and real traffic lights.
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: backing, defer: flag)
        // Resizable since the Accounts inspector (a roster + a detail pane do
        // not fit a fixed 720); the minimum keeps every page's 520 pt content
        // and the Codex sheets fitting.
        minSize = Constants.WindowSizes.settingsMinimum
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        isMovableByWindowBackground = true
        isRestorable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Builds the settings window — titled with a hidden/transparent titlebar
/// (see BorderlessSettingsWindow's init comment for why it must NOT be
/// borderless). The styleMask argument is fixed by the initializer; pass the
/// truthful mask so the call site doesn't mislead.
enum SettingsWindowBuilder {
    static func makeWindow(size: CGSize, initialSection: SettingsSection? = nil) -> NSWindow {
        let window = BorderlessSettingsWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // Install via contentViewController — NOT as a bare subview. The
        // close path (MenuBarManager.windowWillClose) releases the SwiftUI
        // graph by nilling contentViewController; with the previous
        // subview-install that line was a proven no-op (the graph survived
        // close, kept observing ProfileManager, and re-rendered on every
        // publish — 2026-07-29 evening investigation, empirical probe).
        window.contentViewController = NSHostingController(rootView:
            SettingsView(initialSection: initialSection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )

        return window
    }
}

/// Professional, native macOS Settings interface with multi-profile support
struct SettingsView: View {
    @State private var selectedSection: SettingsSection
    /// The Accounts inspector's detail tab (docs/specs/ux-revamp.md §2.2).
    @State private var accountTab: AccountTab = .overview
    /// The section to return to from the Accounts roster sidebar.
    @State private var sectionBeforeAccounts: SettingsSection = .manageProfiles
    @StateObject private var accountsStore = AccountsInspectorStore()
    @Environment(\.colorScheme) private var colorScheme

    init(initialSection: SettingsSection? = nil) {
        _selectedSection = State(initialValue: initialSection ?? .accounts)
    }

    var body: some View {
        HStack(spacing: 0) {
            if selectedSection == .accounts {
                // Accounts mode: the sidebar IS the roster (spec §12.2 frame 0).
                AccountsSidebar(store: accountsStore) {
                    selectedSection = sectionBeforeAccounts
                }
                .background(SidebarVisualEffect())
                .frame(width: 250)
            } else {
            // Sidebar with Profile Switcher
            VStack(spacing: 0) {
                // Native traffic lights live in the (transparent) titlebar now —
                // reserve their space instead of drawing SwiftUI lookalikes.
                Spacer()
                    .frame(height: 28)

                // Profile Section (Switcher + Credentials + Settings)
                ProfileSectionContainer(selectedSection: $selectedSection)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                Spacer()

                // App Settings Section
                AppSettingsSection(selectedSection: $selectedSection)
                    .padding(.horizontal, 12)

                // Bottom bar: About, Debug, Support, Updates
                BottomBarSection(selectedSection: $selectedSection)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .padding(.top, 4)
            }
            .background(SidebarVisualEffect())
            .frame(width: 190)
            }

            // Content
            Group {
                switch selectedSection {
                case .accounts:
                    AccountsDetailView(store: accountsStore, tab: $accountTab)
                case .activeAccounts:
                    ActiveSwitchView()
                // Credentials
                case .cliAccount:
                    CLIAccountView()
                case .codexAccount:
                    CodexAccountView()

                // Profile Settings
                case .appearance:
                    AppearanceSettingsView()
                case .general:
                    GeneralSettingsView()

                // Shared Settings
                case .appSettings:
                    AppSettingsView()
                case .manageProfiles:
                    ManageProfilesView()
                case .shortcuts:
                    ShortcutsSettingsView()
                case .popover:
                    PopoverSettingsView()
                case .about:
                    AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                colorScheme == .dark
                    ? Color.black.opacity(0.15)
                    : Color.white.opacity(0.3)
            )
        }
        .frame(minWidth: Constants.WindowSizes.settingsMinimum.width, maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsBackground())
        .onReceive(NotificationCenter.default.publisher(for: .settingsSectionRequested)) { notification in
            // Both payloads decode: the legacy section string every existing
            // poster sends, and the typed route that names its profile + tab.
            guard let route = SettingsRoute(deepLink: notification.object) else { return }
            if let id = route.profileId { ProfileManager.shared.viewProfile(id) }
            if let tab = route.tab { accountTab = tab }
            select(route.section)
        }
    }

    private func select(_ section: SettingsSection) {
        if section == .accounts, selectedSection != .accounts { sectionBeforeAccounts = selectedSection }
        selectedSection = section
    }
}

// MARK: - Profile Section Container

struct ProfileSectionContainer: View {
    @Binding var selectedSection: SettingsSection
    @StateObject private var profileManager = ProfileManager.shared

    var profileSections: [SettingsSection] {
        SettingsSection.allCases.filter { $0.isProfileSetting && !$0.isCredential }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Viewing picker — which account these pages SHOW. Picking a name
            // here only views it (`viewProfile`): it never applies a login,
            // never records a switch, never runs the dead-login gate. Switching
            // what a CLI uses is a separate, confirmed action ("Make active for
            // <provider>…", docs/specs/ux-revamp.md §1). Until the UX revamp
            // this picker activated — every profile you looked at became the
            // CLI's account, which is the confusion the model change ends.
            VStack(alignment: .leading, spacing: 4) {
                Text(ActiveVocabulary.viewing)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .help("section.viewing_desc".localized)

                Picker("", selection: Binding(
                    // Stable sentinel fallback: minting `UUID()` per body
                    // evaluation gave the Picker a never-matching, always-new
                    // selection — an invalidation on every render.
                    get: { profileManager.activeProfile?.id ?? UUID(uuid: UUID_NULL) },
                    set: { newId in
                        profileManager.viewProfile(newId)
                    }
                )) {
                    ForEach(profileManager.profiles) { profile in
                        HStack {
                            Text(profile.name)
                            if profile.hasCliAccount {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 9))
                                    .foregroundColor(.green)
                            }
                        }
                        .tag(profile.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .padding(8)

            Divider()
                .padding(.horizontal, 8)

            // Credentials
            VStack(alignment: .leading, spacing: 4) {
                Text("section.credentials".localized)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                ProfileCredentialCardsRow(selectedSection: $selectedSection)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
            }

            Divider()
                .padding(.horizontal, 8)

            // Profile Settings
            VStack(alignment: .leading, spacing: 4) {
                Text("section.settings".localized)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)

                VStack(spacing: 4) {
                    ForEach(profileSections, id: \.self) { section in
                        Button {
                            selectedSection = section
                        } label: {
                            SettingMiniButton(
                                icon: section.icon,
                                title: section.title,
                                isSelected: selectedSection == section
                            )
                        }
                        .buttonStyle(.plain)
                        .help(section.description)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - App Settings Section

struct AppSettingsSection: View {
    @Binding var selectedSection: SettingsSection

    var sharedSections: [SettingsSection] {
        SettingsSection.allCases.filter { !$0.isProfileSetting && !$0.isCredential && !$0.isBottomBarItem }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("section.app".localized)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 4)

            ForEach(sharedSections, id: \.self) { section in
                SidebarItem(
                    icon: section.icon,
                    title: section.title,
                    description: section.description,
                    isSelected: selectedSection == section
                ) {
                    selectedSection = section
                }
            }
        }
    }
}

struct BottomBarSection: View {
    @Binding var selectedSection: SettingsSection
    @State private var hoveredItem: String?

    var items: [SettingsSection] {
        SettingsSection.allCases.filter { $0.isBottomBarItem }
    }

    var body: some View {
        VStack(spacing: 6) {
            Divider()

            HStack(spacing: 0) {
                ForEach(items, id: \.self) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        bottomBarLabel(
                            icon: section.icon,
                            label: section.shortLabel,
                            isSelected: selectedSection == section,
                            isHovered: hoveredItem == section.rawValue
                        )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredItem = hovering ? section.rawValue : nil
                    }
                    .help(section.title)
                }

                // Quit button
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    bottomBarLabel(
                        icon: "power",
                        label: "common.quit".localized,
                        isSelected: false,
                        isHovered: hoveredItem == "quit",
                        hoverColor: Color.red.opacity(0.1)
                    )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredItem = hovering ? "quit" : nil
                }
                .help("common.quit".localized)
            }
        }
    }

    private func bottomBarLabel(icon: String, label: String, isSelected: Bool, isHovered: Bool, hoverColor: Color? = nil) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(height: 14)

            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? DesignTokens.Colors.accent : (isHovered ? (hoverColor ?? Color.primary.opacity(0.06)) : Color.clear))
        )
        .contentShape(Rectangle())
    }
}

enum SettingsSection: String, CaseIterable {
    // Credentials (not shown in sidebar)
    case cliAccount
    case codexAccount

    // Profile Settings
    case appearance
    case general

    // Shared Settings
    case accounts
    case activeAccounts
    case appSettings
    case manageProfiles
    case shortcuts
    case popover
    case about

    var title: String {
        switch self {
        case .accounts: return "section.accounts_title".localized
        case .activeAccounts: return "section.active_title".localized
        case .cliAccount: return "section.cli_account_title".localized
        case .codexAccount: return "section.codex_account_title".localized
        case .appearance: return "section.appearance_title".localized
        case .general: return "section.general_title".localized
        case .appSettings: return "section.app_settings_title".localized
        case .manageProfiles: return "section.manage_profiles_title".localized
        case .shortcuts: return "section.shortcuts_title".localized
        case .popover: return "section.popover_title".localized
        case .about: return "settings.about".localized
        }
    }

    var icon: String {
        switch self {
        case .accounts: return "person.crop.rectangle.stack.fill"
        case .activeAccounts: return "arrow.left.arrow.right"
        case .cliAccount: return "terminal.fill"
        case .codexAccount: return "chevron.left.forwardslash.chevron.right"
        case .appearance: return "paintbrush.fill"
        case .general: return "gearshape.fill"
        case .appSettings: return "gearshape.2.fill"
        case .manageProfiles: return "person.2.fill"
        case .shortcuts: return "keyboard"
        case .popover: return "rectangle.topthird.inset.filled"
        case .about: return "info.circle.fill"
        }
    }

    var description: String {
        switch self {
        case .accounts: return "section.accounts_desc".localized
        case .activeAccounts: return "section.active_desc".localized
        case .cliAccount: return "section.cli_account_desc".localized
        case .codexAccount: return "section.codex_account_desc".localized
        case .appearance: return "section.appearance_desc".localized
        case .general: return "section.general_desc".localized
        case .appSettings: return "section.app_settings_desc".localized
        case .manageProfiles: return "section.manage_profiles_desc".localized
        case .shortcuts: return "section.shortcuts_desc".localized
        case .popover: return "section.popover_desc".localized
        case .about: return "settings.about.description".localized
        }
    }

    var shortLabel: String {
        switch self {
        case .about: return "About"
        default: return title
        }
    }

    var isCredential: Bool {
        switch self {
        case .cliAccount, .codexAccount:
            return true
        default:
            return false
        }
    }

    var isProfileSetting: Bool {
        switch self {
        case .appearance, .general:
            return true
        default:
            return false
        }
    }

    var isBottomBarItem: Bool {
        switch self {
        case .about:
            return true
        default:
            return false
        }
    }
}

// MARK: - Sidebar Item

struct SidebarItem: View {
    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? .white : .secondary)
                    .frame(width: 12)

                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .white : .primary)

                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? DesignTokens.Colors.accent : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .help(description)
    }
}

// MARK: - Profile Credential Cards Row

struct ProfileCredentialCardsRow: View {
    @Binding var selectedSection: SettingsSection
    @StateObject private var profileManager = ProfileManager.shared

    // Provider exclusivity: a Codex profile never offers the Claude credential
    // sections and vice versa. A profile with no credentials yet offers both.
    private var showsClaudeSections: Bool {
        !(profileManager.activeProfile?.carriesCodexAccount ?? false)
    }

    private var showsCodexSection: Bool {
        !(profileManager.activeProfile?.carriesClaudeAccount ?? false)
    }

    var body: some View {
        VStack(spacing: 4) {
            if showsClaudeSections {
                // CLI Account Card
                Button {
                    selectedSection = .cliAccount
                } label: {
                    CredentialMiniCard(
                        icon: "terminal.fill",
                        title: "CLI Account",
                        isConnected: profileManager.activeProfile?.hasCliAccount ?? false,
                        isSelected: selectedSection == .cliAccount
                    )
                }
                .buttonStyle(.plain)
            }

            if showsCodexSection {
                // Codex Account Card
                Button {
                    selectedSection = .codexAccount
                } label: {
                    CredentialMiniCard(
                        icon: "chevron.left.forwardslash.chevron.right",
                        title: "Codex Account",
                        isConnected: profileManager.activeProfile?.hasCodexAccount ?? false,
                        isSelected: selectedSection == .codexAccount
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            normalizeSelection()
        }
        .onChange(of: activeAvailabilitySignature) { _, _ in
            normalizeSelection()
        }
    }

    /// What `normalizeSelection` actually depends on: WHO is focused and which
    /// credential kinds they carry. Observing the full 14-profile array ran a
    /// deep ~30-field Equatable compare per publish; observing ids alone missed
    /// same-id credential-kind transitions (Codex-caught).
    private var activeAvailabilitySignature: String {
        let p = profileManager.activeProfile
        return "\(p?.id.uuidString ?? "-")|\(p?.hasCliAccount == true)|\(p?.hasCodexAccount == true)"
    }

    /// Moves the selection off a credential section the focused profile doesn't
    /// offer (e.g. the Codex page was open and the user switched to a Claude
    /// profile) — otherwise the content pane would show a page with no sidebar card.
    private func normalizeSelection() {
        if !showsCodexSection, selectedSection == .codexAccount {
            selectedSection = .cliAccount
        } else if !showsClaudeSections, selectedSection == .cliAccount {
            selectedSection = .codexAccount
        }
    }
}

struct CredentialMiniCard: View {
    let icon: String
    let title: String
    let isConnected: Bool
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? .white : (isConnected ? .green : .gray))
                .frame(width: 12)

            // Title
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .white : .primary)

            Spacer()

            // Status indicator
            Circle()
                .fill(isSelected ? Color.white.opacity(0.9) : (isConnected ? Color.green : Color.gray.opacity(0.3)))
                .frame(width: 5, height: 5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? DesignTokens.Colors.accent : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

struct SettingMiniButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Icon
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 12)

            // Title
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .white : .primary)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? DesignTokens.Colors.accent : (isHovered ? Color.primary.opacity(0.06) : Color.clear))
        )
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
