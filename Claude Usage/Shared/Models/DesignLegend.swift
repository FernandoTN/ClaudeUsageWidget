//
//  DesignLegend.swift
//  Claude Usage
//
//  ONE colour-role table and ONE glyph legend for every surface — the bar's
//  fleet blocks and tooltips, the fleet dashboard, the classic popover, the
//  ⇄ active-account selector (design round 1, 2026-09-03, items G1/G2).
//  Before this, orange carried five meanings across the surfaces and each
//  surface kept its own glyph mapping. Owned by the menu-bar redesign; the
//  UX-revamp surfaces consume it and keep no mapping of their own.
//

import AppKit
import SwiftUI

/// What a colour MEANS. Surfaces pick a role, never a colour.
enum DesignRole: Hashable {
    /// Measured with headroom; the auto-switch would accept it.
    case ready
    /// Ready, but a weekly window has half or less left (light green).
    case readyLight
    /// Session hit while a weekly window has half or less left (faded orange).
    case cautionLight
    /// Weekly or Fable hit with the reset more than a day away (light red).
    case blockingLight
    /// Near a limit, exhausted for now, or attributed (not measured with the
    /// account's own credentials): worth attention, not blocking.
    case caution
    /// Dead login, hard limit hit, or the app cannot persist: blocking.
    case blocking
    /// Inferred throttle — a data-quality caveat, never a fact.
    case suspected
    /// Unmeasured, excluded, informational, or off.
    case informational
    /// The provider-active account (the tiles' cyan label).
    case active
    /// Links and actions.
    case action

    var nsColor: NSColor {
        switch self {
        case .ready: return .adaptiveGreen
        case .readyLight: return NSColor(calibratedRed: 0.60, green: 0.86, blue: 0.60, alpha: 1.0)
        case .caution: return .systemOrange
        case .cautionLight: return NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.48, alpha: 1.0)
        case .blocking: return .systemRed
        case .blockingLight: return NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.45, alpha: 1.0)
        case .suspected: return .systemPurple
        case .informational: return .secondaryLabelColor
        case .active: return .systemCyan
        // The system LINK colour, not the accent: the accent is the user's
        // choice and on an orange accent it collides with caution (round 2,
        // R2-5). Links read as links on every accent.
        case .action: return .linkColor
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// The glyph alphabet shared by every surface.
enum DesignGlyph {
    static let ready = "●"
    /// Session hit (the session half is gone).
    static let sessionHit = "◐"
    static let low = sessionHit
    static let unmeasured = "○"
    /// Weekly or Fable hit.
    static let weeklyHit = "▲"
    static let exhausted = weeklyHit
    static let suspected = "◆"
    static let excluded = "–"
    static let dead = "×"
    static let duplicate = "⧉"
    static let next = "→"
    static let verified = "✓"
    static let queued = "»"
}

extension AccountReadiness {
    /// The owner's colour scheme (2026-09-04, amended the same morning):
    /// bright always means more relief available. Red = a weekly / Fable
    /// limit hit (bright: the reset is within a day; light: more than a day
    /// away); orange = the session limit hit (bright: weekly and Fable have
    /// more than half left; faded: half or less); green = session available
    /// (bright / light by the same halves); purple suspected; grey
    /// unmeasured or excluded; × dead.
    var role: DesignRole {
        switch self {
        case .ready: return .ready
        case .readyLight: return .readyLight
        case .sessionHit: return .caution
        case .sessionHitLight: return .cautionLight
        case .weeklyHitSoon, .dead: return .blocking
        case .weeklyHit: return .blockingLight
        case .suspected: return .suspected
        case .unknown, .excluded: return .informational
        }
    }

    var legendGlyph: String {
        switch self {
        case .ready, .readyLight: return DesignGlyph.ready
        case .sessionHit, .sessionHitLight: return DesignGlyph.sessionHit
        case .weeklyHit, .weeklyHitSoon: return DesignGlyph.weeklyHit
        case .unknown: return DesignGlyph.unmeasured
        case .suspected: return DesignGlyph.suspected
        case .excluded: return DesignGlyph.excluded
        case .dead: return DesignGlyph.dead
        }
    }

    var legendWord: String {
        switch self {
        case .ready: return "ready"
        case .readyLight: return "ready, weekly under half"
        case .sessionHit: return "session limit hit"
        case .sessionHitLight: return "session hit, weekly under half"
        case .weeklyHitSoon: return "weekly limit hit, resets within a day"
        case .weeklyHit: return "weekly limit hit, reset more than a day away"
        case .unknown: return "unmeasured"
        case .suspected: return "suspected"
        case .excluded: return "excluded"
        case .dead: return "dead"
        }
    }

    /// Legend / counts order: greens, oranges, reds, then the rest.
    static let legendOrder: [AccountReadiness] = [
        .ready, .readyLight, .sessionHit, .sessionHitLight, .weeklyHitSoon, .weeklyHit,
        .suspected, .unknown, .excluded, .dead,
    ]
}

enum DesignLegend {
    /// The legend, in precedence order, for tooltips and hover help.
    static var line: String {
        let states = AccountReadiness.legendOrder.map { "\($0.legendGlyph) \($0.legendWord)" }
        return (states + ["\(DesignGlyph.duplicate) duplicate", "\(DesignGlyph.next) next", "\(DesignGlyph.verified) verified"])
            .joined(separator: " · ")
    }
}
