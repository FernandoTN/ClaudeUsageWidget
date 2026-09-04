//
//  GroupExposure.swift
//  Claude Usage
//
//  Stage C0 of the menu-bar redesign (docs/specs/menubar-redesign.md §5):
//  is a provider's composite status item actually VISIBLE on the menu bar,
//  or has macOS hidden it because the bar overflowed? A fixed-length item
//  that does not fit is parked off the bar with no callback, no log and no
//  change to `NSStatusItem.isVisible` (Apple documents that it stays true).
//  The legacy per-tile detector never ran for composite items (audit
//  2026-09-03 H7), so an overflowed provider vanished silently.
//
//  Evidence, in order of trust (field data 2026-09-03, macOS 27, builds
//  ead8c54 and 96c9aa5): `NSWindow.occlusionState` first — `.visible` means
//  the WindowServer composites some pixel of the window, and it read
//  visible for every painted tile. Frame-shape rules second: parked items
//  were measured at y = −33, and a stub narrower than half the item length
//  is the legacy parking signature. Two legs are ADVISORY only, each after a
//  false positive on every group while the owner was clicking the tiles:
//  a SCREEN-POINT HIT TEST (`NSWindow.windowNumber(at:)`) — a hit on the
//  item's own window is proof, a miss proves nothing, because the menu-bar
//  host owns the event surface above third-party items (`hits=000`); and
//  the on-screen window list (`CGWindowListCopyWindowInfo(.optionOnScreenOnly)`)
//  — status-item windows are hosted out of process on macOS 27 and never
//  appear in it for this app (`on=0` with `occ=0`), so absence proves
//  nothing and presence is merely supporting. A frame with no height has
//  not been laid out yet (the first paint after launch), which is unknown,
//  not hidden. Absent windows are unknown, never hidden. Verdicts are pure;
//  the tracker applies hysteresis so one odd sample (a menu open over the
//  bar, a display mid-change) cannot flip the state. Observe-only: this
//  stage logs and feeds the dashboard banner.
//

import CoreGraphics
import Foundation

enum GroupExposure {
    /// One sample of a provider item, in screen coordinates (y up; the menu
    /// bar sits at `screenFrame.maxY`).
    struct Observation: Hashable {
        var frame: CGRect?
        var screenFrame: CGRect?
        var isVisible: Bool
        /// `!occlusionState.contains(.visible)`: the WindowServer says no
        /// pixel of the window is on screen.
        var occluded: Bool
        /// Whether the window number is in the WindowServer's on-screen
        /// list; nil when the list was not sampled. Telemetry: on macOS 27
        /// the list never carries this app's status-item windows.
        var onScreen: Bool?
        /// `NSStatusItem.length` (the composite's fixed width).
        var length: CGFloat
        /// Per probe point: did the hit test resolve to the item's own window?
        var hits: [Bool]

        init(frame: CGRect?, screenFrame: CGRect?, isVisible: Bool, occluded: Bool,
             onScreen: Bool? = nil, length: CGFloat, hits: [Bool]) {
            self.frame = frame
            self.screenFrame = screenFrame
            self.isVisible = isVisible
            self.occluded = occluded
            self.onScreen = onScreen
            self.length = length
            self.hits = hits
        }
    }

    enum Verdict: Hashable {
        case exposed
        case hidden
        case unknown
    }

    /// Probe positions along the button width.
    static let probeFractions: [CGFloat] = [0.25, 0.5, 0.75]
    /// A window whose top edge is further than this below the screen's top
    /// edge is not on the menu bar (parked items were measured at y = -33).
    static let barBand: CGFloat = 100

    nonisolated static func verdict(_ o: Observation) -> Verdict {
        guard let frame = o.frame, let screen = o.screenFrame else { return .unknown }
        // A hit test that resolves to our own window is proof: pixels of
        // this item are on screen where we expect them. A miss proves nothing.
        if o.hits.contains(true) { return .exposed }
        // Not laid out yet (the first paint after launch reports h = 0).
        if frame.height < 2 { return .unknown }
        // Off either edge of the screen, or parked below the bar band.
        if frame.maxX > screen.maxX + 4 || frame.minX < screen.minX - 4 { return .hidden }
        if frame.maxY < screen.maxY - barBand { return .hidden }
        // A stub: the window is far narrower than the item's fixed length.
        if o.length > 0, frame.width + 1 < o.length * 0.5 { return .hidden }
        if !o.isVisible { return .hidden }
        // The WindowServer composites some pixel of it: exposed. (The
        // on-screen list is not consulted here — see the header.)
        if !o.occluded { return .exposed }
        // A plausible frame that the WindowServer reports fully occluded (a
        // full-screen app hiding the bar, a covering window, or an overflow
        // that keeps the frame): not confirmed either way until a real
        // overflow sample says occlusion flips for a parked status window.
        return .unknown
    }
}

/// Hysteresis over successive verdicts: a provider is CONFIRMED hidden after
/// `hideAfter` consecutive hidden samples and cleared after `clearAfter`
/// consecutive exposed ones; unknown samples leave the state untouched.
struct GroupExposureTracker: Hashable {
    static let hideAfter = 2
    static let clearAfter = 3

    private var hiddenStreak: [Profile.ProviderKind: Int] = [:]
    private var exposedStreak: [Profile.ProviderKind: Int] = [:]
    private(set) var confirmedHidden: Set<Profile.ProviderKind> = []

    init() {}

    /// Records one round of verdicts and returns the confirmed-hidden set.
    @discardableResult
    nonisolated mutating func record(_ verdicts: [Profile.ProviderKind: GroupExposure.Verdict]) -> Set<Profile.ProviderKind> {
        for (provider, verdict) in verdicts {
            switch verdict {
            case .hidden:
                hiddenStreak[provider, default: 0] += 1
                exposedStreak[provider] = 0
                if hiddenStreak[provider, default: 0] >= Self.hideAfter { confirmedHidden.insert(provider) }
            case .exposed:
                exposedStreak[provider, default: 0] += 1
                hiddenStreak[provider] = 0
                if exposedStreak[provider, default: 0] >= Self.clearAfter { confirmedHidden.remove(provider) }
            case .unknown:
                break
            }
        }
        // A provider that no longer has an item is neither hidden nor exposed.
        confirmedHidden = confirmedHidden.filter { verdicts[$0] != nil }
        return confirmedHidden
    }
}
