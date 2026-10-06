//
//  DesignLegendTests.swift
//  Claude UsageTests
//
//  The owner's colour scheme (2026-09-04) gives each hue a bright and a
//  duller shade; since 2026-10-06 green and orange have three (brighter =
//  more weekly capacity left). The owner found the light red and the light
//  green alike, so the duller shades keep the hue saturated and drop the
//  lightness, and this test measures them in CIE Lab: light red vs every
//  green well apart (also under protan / deutan simulation), every shade
//  well apart from the others of its hue, and lightness strictly falling
//  bright → medium → dull — in both appearances.
//

import AppKit
import XCTest
@testable import Claude_Usage

@MainActor
final class DesignLegendTests: XCTestCase {
    private struct Lab { var l, a, b: Double }

    private func linear(_ c: CGFloat) -> Double {
        let v = Double(c)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// sRGB → CIE Lab (D65), optionally through a dichromat simulation
    /// (Viénot, Brettel & Mollon 1999 matrices in linear RGB).
    private func lab(_ color: NSColor, simulate: String? = nil) -> Lab {
        let c = color.usingColorSpace(.sRGB)!
        var r = linear(c.redComponent), g = linear(c.greenComponent), b = linear(c.blueComponent)
        switch simulate {
        case "protan":
            (r, g, b) = (0.152286 * r + 1.052583 * g - 0.204868 * b,
                         0.114503 * r + 0.786281 * g + 0.099216 * b,
                         -0.003882 * r - 0.048116 * g + 1.051998 * b)
        case "deutan":
            (r, g, b) = (0.367322 * r + 0.860646 * g - 0.227968 * b,
                         0.280085 * r + 0.672501 * g + 0.047413 * b,
                         -0.011820 * r + 0.042940 * g + 0.968881 * b)
        default: break
        }
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 1.0
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116.0 }
        return Lab(l: 116 * f(y) - 16, a: 500 * (f(x) - f(y)), b: 200 * (f(y) - f(z)))
    }

    private func deltaE(_ p: NSColor, _ q: NSColor, simulate: String? = nil) -> Double {
        let a = lab(p, simulate: simulate), b = lab(q, simulate: simulate)
        return sqrt(pow(a.l - b.l, 2) + pow(a.a - b.a, 2) + pow(a.b - b.b, 2))
    }

    private func inAppearance(_ name: NSAppearance.Name, _ body: () -> Void) {
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance(body)
    }

    /// Bright → medium → dull, per hue. Red keeps its two shades.
    private let greens: [DesignRole] = [.ready, .readyMedium, .readyDull]
    private let oranges: [DesignRole] = [.caution, .cautionMedium, .cautionDull]

    func testLightRedAndEveryGreenStayApartInBothAppearancesAndForDichromats() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            inAppearance(appearance) {
                let red = DesignRole.blockingLight.nsColor
                for green in greens {
                    for sim in [nil, "protan", "deutan"] {
                        XCTAssertGreaterThanOrEqual(deltaE(red, green.nsColor, simulate: sim), 20,
                                                    "light red vs \(green) (\(appearance.rawValue), \(sim ?? "normal"))")
                    }
                }
                for (orange, green) in zip(oranges, greens) {
                    XCTAssertGreaterThanOrEqual(deltaE(orange.nsColor, green.nsColor), 20, "\(orange) vs \(green) (\(appearance.rawValue))")
                }
            }
        }
    }

    /// Every shade of a hue is well apart from every other shade of it —
    /// for dichromats too, since the shades differ mostly in lightness.
    func testEveryShadeIsWellApartFromTheOthersOfItsHue() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            inAppearance(appearance) {
                for ramp in [greens, oranges] {
                    for (i, a) in ramp.enumerated() {
                        for b in ramp.dropFirst(i + 1) {
                            for sim in [nil, "protan", "deutan"] {
                                XCTAssertGreaterThanOrEqual(deltaE(a.nsColor, b.nsColor, simulate: sim), 10,
                                                            "\(a) vs \(b) (\(appearance.rawValue), \(sim ?? "normal"))")
                            }
                        }
                    }
                }
                XCTAssertGreaterThanOrEqual(deltaE(DesignRole.blocking.nsColor, DesignRole.blockingLight.nsColor), 10,
                                            "bright red vs light red (\(appearance.rawValue))")
            }
        }
    }

    /// Brightness means capacity (owner, 2026-10-06): within green and within
    /// orange, CIE L* steps DOWN bright → medium → dull in BOTH appearances.
    /// The regression guard for the Light-mode swap: the old palette's
    /// `adaptiveGreen` turned forest green (L* 40) in Light mode, darker than
    /// the old light shade (L* 62), so Settings and the popover painted the
    /// two greens inverted. This test failed on that palette.
    func testShadesStepDownInLightnessInBothAppearances() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            inAppearance(appearance) {
                for ramp in [greens, oranges] {
                    let lightness = ramp.map { lab($0.nsColor).l }
                    for (brighter, duller) in zip(lightness, lightness.dropFirst()) {
                        XCTAssertGreaterThan(brighter, duller, "\(ramp) L* \(lightness) (\(appearance.rawValue))")
                    }
                }
            }
        }
        // The top green on the dark bar is the one the owner already reads as
        // bright green, or brighter — never duller.
        inAppearance(.darkAqua) {
            XCTAssertGreaterThanOrEqual(lab(DesignRole.ready.nsColor).l, lab(NSColor.adaptiveGreen).l - 0.01)
        }
    }

    func testRolesAndGlyphsFollowTheOwnersScheme() {
        XCTAssertEqual(AccountReadiness.weeklyHitSoon.role, .blocking, "bright red = weekly hit with the reset within a day")
        XCTAssertEqual(AccountReadiness.weeklyHit.role, .blockingLight)
        XCTAssertEqual([AccountReadiness.sessionHit, .sessionHitUnderHalf, .sessionHitUnderQuarter].map(\.role), oranges)
        XCTAssertEqual([AccountReadiness.ready, .readyUnderHalf, .readyUnderQuarter].map(\.role), greens)
        XCTAssertEqual(AccountReadiness.legendOrder.count, AccountReadiness.allCases.count)
        XCTAssertEqual(Set(AccountReadiness.legendOrder), Set(AccountReadiness.allCases))
        XCTAssertTrue(DesignLegend.line.contains("ready, weekly under a quarter"), "the legend names every shade")
        XCTAssertTrue(DesignLegend.line.contains(DesignLegend.staleRing), "the legend explains the stale ring")
    }
}
