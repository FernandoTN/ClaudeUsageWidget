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
        case .caution: return .systemOrange
        case .blocking: return .systemRed
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
    static let low = "◐"
    static let unmeasured = "○"
    static let exhausted = "▲"
    static let suspected = "◆"
    static let excluded = "–"
    static let dead = "×"
    static let duplicate = "⧉"
    static let next = "→"
    static let verified = "✓"
    static let queued = "»"
}

extension AccountReadiness {
    /// Owner ruling 2026-09-04: any window AT its limit — session, weekly
    /// or Fable weekly — is RED; amber is only for approaching one.
    var role: DesignRole {
        switch self {
        case .ready: return .ready
        case .low: return .caution
        case .exhausted, .dead: return .blocking
        case .suspected: return .suspected
        case .unknown, .excluded: return .informational
        }
    }

    var legendGlyph: String {
        switch self {
        case .ready: return DesignGlyph.ready
        case .low: return DesignGlyph.low
        case .unknown: return DesignGlyph.unmeasured
        case .suspected: return DesignGlyph.suspected
        case .exhausted: return DesignGlyph.exhausted
        case .excluded: return DesignGlyph.excluded
        case .dead: return DesignGlyph.dead
        }
    }

    var legendWord: String {
        switch self {
        case .ready: return "ready"
        case .low: return "near limit"
        case .unknown: return "unmeasured"
        case .suspected: return "suspected"
        case .exhausted: return "at a limit"
        case .excluded: return "excluded"
        case .dead: return "dead"
        }
    }
}

enum DesignLegend {
    /// The legend, in precedence order, for tooltips and hover help.
    static var line: String {
        let states = [AccountReadiness.ready, .low, .exhausted, .suspected, .unknown, .excluded, .dead]
            .map { "\($0.legendGlyph) \($0.legendWord)" }
        return (states + ["\(DesignGlyph.duplicate) duplicate", "\(DesignGlyph.next) next", "\(DesignGlyph.verified) verified"])
            .joined(separator: " · ")
    }
}
