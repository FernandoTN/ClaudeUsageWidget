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
    /// Measured with headroom; the auto-switch would accept it. The
    /// brightest green: weekly and Fable both have more than half left.
    case ready
    /// Ready, but a weekly window has half or less left (medium green).
    case readyMedium
    /// Ready, but a weekly window has a quarter or less left (dullest green).
    case readyDull
    /// Session hit while a weekly window has half or less left (medium orange).
    case cautionMedium
    /// Session hit while a weekly window has a quarter or less left
    /// (dullest orange).
    case cautionDull
    /// Weekly or Fable hit with the reset more than a day away (light red).
    case blockingLight
    /// Near a limit, exhausted for now, or attributed (not measured with the
    /// account's own credentials): worth attention, not blocking. The
    /// brightest orange.
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
        // A duller shade of a hue keeps the hue SATURATED and drops the
        // lightness (owner, 2026-09-04: grey-washed tints of red and green
        // looked alike). Brightness means capacity (owner, 2026-10-06), so
        // green and orange step DOWN in CIE L* bright → medium → dull in
        // BOTH appearances: the greens are one fixed ladder (L* 71 / 60 /
        // 49) rather than `adaptiveGreen`, whose Light variant is a forest
        // green (L* 40) darker than the shade below it used to be — Settings
        // and the popover painted the two shades inverted in Light mode. The
        // dullest green stops at L* 49 so that, for protan and deutan
        // vision, it stays clear of the light red (L* 35). `DesignLegendTests`
        // measures all of it in CIE Lab, also under protan / deutan
        // simulation.
        switch self {
        case .ready: return NSColor(srgbRed: 60 / 255, green: 199 / 255, blue: 95 / 255, alpha: 1.0)
        case .readyMedium: return NSColor(srgbRed: 40 / 255, green: 165 / 255, blue: 82 / 255, alpha: 1.0)
        case .readyDull: return NSColor(srgbRed: 33 / 255, green: 133 / 255, blue: 71 / 255, alpha: 1.0)
        case .caution: return .systemOrange
        case .cautionMedium: return NSColor(srgbRed: 216 / 255, green: 111 / 255, blue: 18 / 255, alpha: 1.0)
        case .cautionDull: return NSColor(srgbRed: 173 / 255, green: 84 / 255, blue: 11 / 255, alpha: 1.0)
        case .blocking: return .systemRed
        case .blockingLight: return NSColor(calibratedHue: 0.0, saturation: 0.88, brightness: 0.55, alpha: 1.0)
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
    /// The owner's colour scheme (2026-09-04, amended the same morning;
    /// three shades 2026-10-06): bright always means more relief available.
    /// Red = a weekly / Fable limit hit (bright: the reset is within a day;
    /// light: more than a day away); orange = the session limit hit
    /// (brightest: weekly and Fable have more than half left; medium: half or
    /// less; dullest: a quarter or less); green = session available (the
    /// same three shades); purple suspected; grey unmeasured or excluded;
    /// × dead.
    var role: DesignRole {
        switch self {
        case .ready: return .ready
        case .readyUnderHalf: return .readyMedium
        case .readyUnderQuarter: return .readyDull
        case .sessionHit: return .caution
        case .sessionHitUnderHalf: return .cautionMedium
        case .sessionHitUnderQuarter: return .cautionDull
        case .weeklyHitSoon, .dead: return .blocking
        case .weeklyHit: return .blockingLight
        case .suspected: return .suspected
        case .unknown, .excluded: return .informational
        }
    }

    /// Drawn as a FILLED dot on the bar — a measured capacity state (or a
    /// suspicion about one). Only these carry the stale ring; the hollow
    /// ring, the dash and the × state no capacity.
    var drawsFilledDot: Bool {
        switch self {
        case .unknown, .excluded, .dead: return false
        case .ready, .readyUnderHalf, .readyUnderQuarter, .sessionHit, .sessionHitUnderHalf, .sessionHitUnderQuarter,
             .weeklyHitSoon, .weeklyHit, .suspected:
            return true
        }
    }

    var legendGlyph: String {
        switch self {
        case .ready, .readyUnderHalf, .readyUnderQuarter: return DesignGlyph.ready
        case .sessionHit, .sessionHitUnderHalf, .sessionHitUnderQuarter: return DesignGlyph.sessionHit
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
        case .readyUnderHalf: return "ready, weekly under half"
        case .readyUnderQuarter: return "ready, weekly under a quarter"
        case .sessionHit: return "session limit hit"
        case .sessionHitUnderHalf: return "session hit, weekly under half"
        case .sessionHitUnderQuarter: return "session hit, weekly under a quarter"
        case .weeklyHitSoon: return "weekly limit hit, resets within a day"
        case .weeklyHit: return "weekly limit hit, reset more than a day away"
        case .unknown: return "unmeasured"
        case .suspected: return "suspected"
        case .excluded: return "excluded"
        case .dead: return "dead"
        }
    }

    /// Legend / counts order: greens, oranges, reds (each brightest first),
    /// then the rest.
    static let legendOrder: [AccountReadiness] = [
        .ready, .readyUnderHalf, .readyUnderQuarter, .sessionHit, .sessionHitUnderHalf, .sessionHitUnderQuarter,
        .weeklyHitSoon, .weeklyHit, .suspected, .unknown, .excluded, .dead,
    ]
}

enum DesignLegend {
    /// What the ring around a filled dot means — the stale cue on the bar
    /// and in Settings → Accounts (`ProviderSummary.displayStaleAfter`).
    static let staleRing = "ringed dot: not re-measured for over an hour"

    /// The legend, in precedence order, for tooltips and hover help. Green
    /// and orange each have three shades — brighter means more weekly
    /// capacity left — and the words name every shade.
    static var line: String {
        let states = AccountReadiness.legendOrder.map { "\($0.legendGlyph) \($0.legendWord)" }
        return (states + [staleRing, "\(DesignGlyph.duplicate) duplicate", "\(DesignGlyph.next) next", "\(DesignGlyph.verified) verified"])
            .joined(separator: " · ")
    }
}
