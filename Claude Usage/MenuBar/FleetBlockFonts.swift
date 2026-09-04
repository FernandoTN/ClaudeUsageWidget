//
//  FleetBlockFonts.swift
//  Claude Usage
//
//  The fonts the fleet-summary block draws with. They live beside the model
//  rather than inside the renderer because `FleetBlockGeometry`'s reserved
//  widths were MEASURED with exactly these, and
//  `FleetSummaryTests.testReservedWidthsCoverTheRealFonts` re-measures them
//  on every run: a font change here fails the test before it can clip the bar.
//

import AppKit

enum FleetBlockFonts {
    /// Provider mark (`Cl` / `Cx` / `Gk`) and the `+N` overflow mark.
    static let mark = NSFont.systemFont(ofSize: 6, weight: .semibold)
    /// The candidate row: `91→Ced✓`.
    static let affix = NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .semibold)
    /// The counts row: `●12 ◐3 ▲11 ×2`.
    static let counts = NSFont.monospacedDigitSystemFont(ofSize: 6, weight: .semibold)
}
