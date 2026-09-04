//
//  ActiveSelectorMenu.swift
//  Claude Usage
//
//  The ⇄ status item: the per-provider ACTIVE selector (docs/specs/ux-revamp.md
//  §2.1; frame-by-frame pass §12.1). One fixed 24 pt item created ONCE by
//  `MenuBarManager.setup()` before the provider groups (so it lands rightmost
//  and survives every group rebuild), owned here — never by
//  `StatusBarUIManager`, whose `cleanup()` removes every item it owns. Never
//  torn down (every recreate leaks a CAContext on macOS 26/27); the on/off
//  setting toggles `isVisible`.
//
//  The menu is a one-to-one rendering of `ActiveSelectorMenuModel.rows` built
//  in `menuNeedsUpdate` from a fresh `ProviderActiveSelection` snapshot — no
//  ranking, no Keychain, no roster walk of its own. Switching goes through the
//  ONE activation seam (`activateProfileDetailed(userInitiated: true)`) behind a
//  never-suppressible confirmation, and every alert re-activates the app first
//  (an accessory app's click grant has expired by the time an `await` returns).
//

import AppKit
import Combine

@MainActor
final class ActiveSelectorItem: NSObject, NSMenuDelegate {
    /// Everything the selector can READ or DO, supplied by `MenuBarManager` so
    /// this class never reaches into the sweep or the services.
    struct Actions {
        var selections: () -> [ProviderActiveSelection]
        var preferencesDegraded: () -> Bool
        var makeActive: (UUID) async -> ProfileManager.ActivationOutcome
        var queueNext: (UUID) -> Void
        /// View `profileId` (when given) and open Settings on `section`.
        var viewAndOpenSettings: (UUID?, SettingsSection?) -> Void
        var openDashboard: () -> Void
        var openTelemetry: () -> Void
        var setAutoSwitchEnabled: (Bool) -> Void
    }

    static let length: CGFloat = 24
    /// Not the circular-arrows glyph: that is the popover's REFRESH icon (I1).
    static let symbolName = "arrow.left.arrow.right"

    let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let actions: Actions
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    /// Owners that changed outside the app since the menu was last opened
    /// (frame 8) — one banner per episode, cleared when the menu is built.
    private var externalChanges: [Profile.ProviderKind: String] = [:]
    private var repaintScheduled = false
    private var lastBadge: ActiveSelectorMenuModel.Badge?
    private var lastTooltip = ""

    var isVisible: Bool {
        get { statusItem.isVisible }
        set { statusItem.isVisible = newValue }
    }

    init(actions: Actions) {
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: Self.length)
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.behavior = []
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("selector.accessibility".localized)
        }
        isVisible = SharedDataStore.shared.loadActiveSelectorItemEnabled()

        observers.append(NotificationCenter.default.addObserver(
            forName: .activeSelectorRequested, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.open() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .providerOwnerChangedExternally, object: nil, queue: .main
        ) { [weak self] note in
            let provider = (note.userInfo?["provider"] as? String).flatMap(Self.provider(named:))
            let name = note.userInfo?["ownerName"] as? String
            MainActor.assumeIsolated { self?.noteExternalChange(provider: provider, ownerName: name) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .activeSelectorVisibilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isVisible = SharedDataStore.shared.loadActiveSelectorItemEnabled() }
        })

        // Badge + tooltip follow the roster and the owners; coalesced so a
        // sweep that publishes twenty times repaints once.
        let manager = ProfileManager.shared
        let triggers: [AnyPublisher<Void, Never>] = [
            manager.$profiles.map { _ in () }.eraseToAnyPublisher(),
            manager.$activeClaudeProfileId.map { _ in () }.eraseToAnyPublisher(),
            manager.$activeCodexProfileId.map { _ in () }.eraseToAnyPublisher(),
            manager.$activeGrokProfileId.map { _ in () }.eraseToAnyPublisher(),
            manager.$isSwitchingProfile.map { _ in () }.eraseToAnyPublisher(),
            manager.$preferencesDegraded.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRepaint() }
            .store(in: &cancellables)

        repaint()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Item (frame 0)

    func statusBarAppearanceDidChange() {
        lastBadge = nil  // force a redraw in the new appearance
        repaint()
    }

    private func scheduleRepaint() {
        guard !repaintScheduled else { return }
        repaintScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.repaintScheduled = false
            self.repaint()
        }
    }

    func repaint() {
        guard let button = statusItem.button else { return }
        let selections = actions.selections()
        let badge = ActiveSelectorMenuModel.badge(selections: selections, preferencesDegraded: actions.preferencesDegraded())
        if badge != lastBadge || button.image == nil {
            button.image = Self.image(badge: badge, appearance: button.effectiveAppearance)
            lastBadge = badge
        }
        let tooltip = ActiveSelectorMenuModel.tooltip(selections: selections, badge: badge)
        if tooltip != lastTooltip {
            button.toolTip = tooltip
            button.setAccessibilityLabel(tooltip)
            lastTooltip = tooltip
        }
    }

    /// The glyph as a template image at rest (the bar tints it); with a badge,
    /// a composed non-template image: glyph in the bar's label colour plus a
    /// 5 pt dot at the bottom-right in the badge's colour.
    static func image(badge: ActiveSelectorMenuModel.Badge?, appearance: NSAppearance) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) ?? NSImage(size: NSSize(width: 16, height: 16))
        guard let badge else {
            symbol.isTemplate = true
            return symbol
        }
        let size = NSSize(width: length, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            appearance.performAsCurrentDrawingAppearance {
                let glyphRect = NSRect(
                    x: ((size.width - symbol.size.width) / 2).rounded(),
                    y: ((size.height - symbol.size.height) / 2).rounded(),
                    width: symbol.size.width, height: symbol.size.height)
                symbol.draw(in: glyphRect)
                NSColor.labelColor.set()
                glyphRect.fill(using: .sourceAtop)
                badgeColor(badge).setFill()
                NSBezierPath(ovalIn: NSRect(x: size.width - 6, y: 1, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func badgeColor(_ badge: ActiveSelectorMenuModel.Badge) -> NSColor {
        switch badge {
        case .red: return DesignRole.blocking.nsColor
        case .purple: return DesignRole.suspected.nsColor
        case .amber: return DesignRole.caution.nsColor
        }
    }

    // MARK: - Menu

    func open() {
        statusItem.button?.performClick(nil)
    }

    private func noteExternalChange(provider: Profile.ProviderKind?, ownerName: String?) {
        guard let provider, let ownerName else { return }
        externalChanges[provider] = ownerName
        scheduleRepaint()
    }

    private static func provider(named name: String) -> Profile.ProviderKind? {
        switch name.lowercased() {
        case "claude": return .claude
        case "codex": return .codex
        case "grok": return .grok
        default: return nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        let rows = ActiveSelectorMenuModel.rows(
            selections: actions.selections(),
            preferencesDegraded: actions.preferencesDegraded(),
            externalChanges: externalChanges,
            switching: nil,
            now: Date()
        )
        externalChanges.removeAll()
        fill(menu, with: rows)
    }

    private func fill(_ menu: NSMenu, with rows: [ActiveSelectorMenuModel.Row]) {
        menu.removeAllItems()
        for row in rows {
            switch row.kind {
            case .separator:
                menu.addItem(.separator())
            case .header:
                menu.addItem(NSMenuItem.sectionHeader(title: row.title))
            case .banner, .info, .action:
                let item = makeItem(row)
                menu.addItem(item)
                if let alternate = row.alternate {
                    let alt = makeItem(alternate)
                    alt.isAlternate = true
                    alt.keyEquivalentModifierMask = .option
                    menu.addItem(alt)
                }
                if !row.submenu.isEmpty {
                    let submenu = NSMenu(title: row.title)
                    submenu.autoenablesItems = false
                    fill(submenu, with: row.submenu)
                    item.submenu = submenu
                }
            }
        }
    }

    private func makeItem(_ row: ActiveSelectorMenuModel.Row) -> NSMenuItem {
        let item = NSMenuItem(title: row.title, action: row.action == nil ? nil : #selector(rowSelected(_:)), keyEquivalent: "")
        item.target = row.action == nil ? nil : self
        item.isEnabled = row.enabled && row.action != nil
        item.representedObject = row.action
        item.state = row.checked ? .on : .off
        item.attributedTitle = Self.attributedTitle(for: row)
        return item
    }

    /// Typography per §12.1: glyph in its tint, title 13 pt (semibold for
    /// accounts), detail 12 pt monospaced-digit secondary; banners tinted whole.
    static func attributedTitle(for row: ActiveSelectorMenuModel.Row) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let titleColor: NSColor = row.titleTint.map(color) ?? (row.enabled ? .labelColor : (row.kind == .info || row.kind == .banner ? .labelColor : .disabledControlTextColor))
        if let glyph = row.glyph {
            out.append(NSAttributedString(string: glyph + "  ", attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: row.glyphTint.map(color) ?? NSColor.secondaryLabelColor,
            ]))
        }
        let isAccount = row.kind == .info && row.detail != nil && row.glyph != nil && row.glyph != "→"
        out.append(NSAttributedString(string: row.title, attributes: [
            .font: isAccount || row.isPrimary ? NSFont.systemFont(ofSize: 13, weight: .semibold) : NSFont.menuFont(ofSize: 13),
            .foregroundColor: titleColor,
        ]))
        if let detail = row.detail, !detail.isEmpty {
            out.append(NSAttributedString(string: "   " + detail, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: row.titleTint == .purple ? color(.purple) : NSColor.secondaryLabelColor,
            ]))
        }
        return out
    }

    static func color(_ tint: ActiveSelectorMenuModel.Tint) -> NSColor {
        switch tint {
        case .cyan: return DesignRole.active.nsColor
        case .green: return DesignRole.ready.nsColor
        case .orange: return DesignRole.caution.nsColor
        case .red: return DesignRole.blocking.nsColor
        case .purple: return DesignRole.suspected.nsColor
        case .secondary: return DesignRole.informational.nsColor
        }
    }

    // MARK: - Actions

    @objc private func rowSelected(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ActiveSelectorMenuModel.Action else { return }
        switch action {
        case .switchTo(let id, let provider):
            confirmAndSwitch(to: id, provider: provider)
        case .queueNext(let id):
            actions.queueNext(id)
            scheduleRepaint()
        case .editQueue:
            actions.viewAndOpenSettings(nil, .manageProfiles)
        case .repairDead(let id, let provider):
            actions.viewAndOpenSettings(id, provider == .codex ? .codexAccount : .cliAccount)
        case .openActiveSettings:
            actions.viewAndOpenSettings(nil, .manageProfiles)
        case .openAccounts:
            actions.viewAndOpenSettings(nil, .manageProfiles)
        case .openDashboard:
            actions.openDashboard()
        case .openTelemetry:
            actions.openTelemetry()
        case .toggleAutoSwitch(let enabled):
            actions.setAutoSwitchEnabled(enabled)
            scheduleRepaint()
        }
    }

    /// Frame 9 + 10: the never-suppressible confirmation, then the one
    /// activation seam, then the outcome shown in place.
    private func confirmAndSwitch(to id: UUID, provider: Profile.ProviderKind) {
        let selections = actions.selections()
        guard let selection = selections.first(where: { $0.provider == provider }),
              let candidate = selection.candidates.first(where: { $0.id == id }) else { return }
        let name = candidate.name
        Task { [weak self] in
            guard let self else { return }
            // The shared confirmation (also the inspector's): both sides named,
            // Cancel the default, "Log in first" for a dead login.
            let outcome = await SwitchConfirmation.confirmAndSwitch(
                provider: provider, candidate: candidate, owner: selection.owner,
                makeActive: { id in await self.actions.makeActive(id) })
            if let outcome { self.report(outcome, name: name, profileId: id, provider: provider) }
            self.repaint()
        }
    }

    private func report(_ outcome: ProfileManager.ActivationOutcome, name: String, profileId: UUID, provider: Profile.ProviderKind) {
        switch outcome {
        case .activated, .alreadyActive:
            return  // the tile label moves; the next menu open shows the new owner
        case .switchInFlight, .profileNotFound:
            Self.activateApp()
            let alert = NSAlert()
            alert.messageText = "selector.not_switched".localized
            alert.informativeText = DashboardFormatting.outcome(outcome, name: name)
            alert.addButton(withTitle: "common.ok".localized)
            alert.runModal()
        case .credentialsRefused, .focusedWithoutApplying:
            Self.activateApp()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "selector.not_switched".localized
            alert.informativeText = DashboardFormatting.outcome(outcome, name: name)
            alert.addButton(withTitle: "selector.repair_in_accounts".localized)
            alert.addButton(withTitle: "common.ok".localized)
            if alert.runModal() == .alertFirstButtonReturn {
                actions.viewAndOpenSettings(profileId, provider == .codex ? .codexAccount : .cliAccount)
            }
        }
    }

    /// An accessory app must foreground itself before a panel, or the panel
    /// opens behind the frontmost app (`MenuBarManager.bringWindowToForeground`).
    /// Never flips the activation policy.
    static func activateApp() {
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
    }
}
