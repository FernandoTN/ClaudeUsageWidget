//
//  TelemetryWindowController.swift
//  Claude Usage
//
//  The token-usage window (spec §3.4): one controller, one window, reused
//  across opens — never recreated, so the sidebar selection and scroll
//  survive a close. Copies the Settings window's load-bearing shape: TITLED
//  with a hidden titlebar (a truly borderless window re-opened the
//  window-server storm), `isReleasedWhenClosed = false`, foregrounded through
//  `MenuBarManager.bringWindowToForeground` because `NSApp.activate()` is
//  cooperative from an accessory app, and never an activation-policy flip.
//  The observer is installed at launch: the entry points already post, and a
//  lazily created controller would drop the first click. The window itself
//  is created on first show so nothing hidden subscribes to anything.
//

import AppKit
import SwiftUI

final class TelemetryPanelWindow: NSWindow {
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: backing, defer: flag)
        minSize = TelemetryWindowController.minimumSize
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = true
        backgroundColor = .windowBackgroundColor
        hasShadow = true
        isMovableByWindowBackground = false
        isRestorable = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class TelemetryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TelemetryWindowController()
    static let defaultSize = NSSize(width: 1040, height: 680)
    static let minimumSize = NSSize(width: 880, height: 560)
    static let frameMetaKey = "windowFrame"

    let model = TelemetryWindowModel()
    private var observer: NSObjectProtocol?
    private var restoredFrame: NSRect?
    private var frameSaveScheduled = false

    private init() {
        super.init(window: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Called once at launch by `TelemetryService.start()`.
    func installObserver() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .telemetryWindowRequested, object: nil, queue: .main) { [weak self] notification in
            let scope = TelemetryWindowModel.scope(from: notification)
            Task { @MainActor in self?.show(scope: scope) }
        }
        TelemetryService.shared.meta(Self.frameMetaKey) { [weak self] value in
            guard let value, let self else { return }
            let frame = NSRectFromString(value)
            if frame.width >= Self.minimumSize.width, frame.height >= Self.minimumSize.height { self.restoredFrame = frame }
        }
    }

    /// Reuse-or-front: creates the window on first use, deminiaturizes,
    /// applies the requested scope, and brings it to the front.
    func show(scope: TelemetryScope?) {
        if window == nil { window = makeWindow() }
        guard let window else { return }
        if let scope { model.select(scope) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        MenuBarManager.bringWindowToForeground(window)
        model.setVisible(true)
        model.reload()
    }

    private func makeWindow() -> NSWindow {
        let window = TelemetryPanelWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                                          styleMask: [], backing: .buffered, defer: false)
        window.title = "telemetry.window_title".localized
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: TelemetryView(model: model))
        if let restoredFrame, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(restoredFrame) }) {
            window.setFrame(restoredFrame, display: false)
        } else {
            window.center()
        }
        return window
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // The window and its hosting graph are kept for reuse; only stop the
        // reloads an open window would keep running.
        model.setVisible(false)
    }

    func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
    func windowDidEndLiveResize(_ notification: Notification) { scheduleFrameSave() }

    private func scheduleFrameSave() {
        guard !frameSaveScheduled else { return }
        frameSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.frameSaveScheduled = false
            if let frame = self.window?.frame {
                TelemetryService.shared.setMeta(Self.frameMetaKey, NSStringFromRect(frame))
            }
        }
    }
}
