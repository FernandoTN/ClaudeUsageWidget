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
//  The primary evidence is a SCREEN-POINT HIT TEST: the window under three
//  points inside the item's button is asked for (`NSWindow.windowNumber(at:)`);
//  an exposed item answers with its own window number. The composite's
//  opaque event shape makes interior points resolve across the tile gaps.
//  Frame-shape rules are secondary evidence; absent windows are "unknown",
//  never "hidden". Verdicts are pure; the tracker applies hysteresis so one
//  odd sample (a menu open over the bar, a display mid-change) cannot flip
//  the state. Observe-only: this stage logs and feeds the dashboard banner.
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
        var occluded: Bool
        /// `NSStatusItem.length` (the composite's fixed width).
        var length: CGFloat
        /// Per probe point: did the hit test resolve to the item's own window?
        var hits: [Bool]
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
        // Positive proof first: a hit test that resolves to our own window
        // means pixels of this item are on screen where we expect them.
        if o.hits.contains(true) { return .exposed }
        // Never laid out.
        if frame.height < 2 { return .hidden }
        // Off either edge of the screen, or parked below the bar band.
        if frame.maxX > screen.maxX + 4 || frame.minX < screen.minX - 4 { return .hidden }
        if frame.maxY < screen.maxY - barBand { return .hidden }
        // A stub: the window is far narrower than the item's fixed length.
        if o.length > 0, frame.width + 1 < o.length * 0.5 { return .hidden }
        if !o.isVisible { return .hidden }
        // Plausible frame, but no probe ran (no screen at probe time).
        if o.hits.isEmpty { return .unknown }
        // Every probe resolved to some other window while the frame looks
        // right: covered or overflow-hidden. The tracker's hysteresis
        // absorbs a menu tracking session or a display mid-change.
        return .hidden
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
