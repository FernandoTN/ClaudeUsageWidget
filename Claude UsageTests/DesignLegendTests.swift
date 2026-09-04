//
//  DesignLegendTests.swift
//  Claude UsageTests
//
//  The owner's colour scheme (2026-09-04) pairs a bright and a light shade
//  per hue. He found the light red and the light green alike, so the light
//  shades keep the hue saturated and drop the lightness, and this test
//  measures the pairs in CIE Lab: light red vs light green well apart (also
//  under protan / deutan simulation), and each light shade well apart from
//  its bright one — in both appearances.
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

    func testLightRedAndLightGreenStayApartInBothAppearancesAndForDichromats() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            inAppearance(appearance) {
                let red = DesignRole.blockingLight.nsColor, green = DesignRole.readyLight.nsColor
                for sim in [nil, "protan", "deutan"] {
                    XCTAssertGreaterThanOrEqual(deltaE(red, green, simulate: sim), 20,
                                                "light red vs light green (\(appearance.rawValue), \(sim ?? "normal"))")
                }
                XCTAssertGreaterThanOrEqual(deltaE(DesignRole.cautionLight.nsColor, green), 20, "faded orange vs light green")
            }
        }
    }

    func testEachLightShadeIsWellApartFromItsBrightOne() {
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            inAppearance(appearance) {
                let pairs: [(DesignRole, DesignRole)] = [(.ready, .readyLight), (.caution, .cautionLight), (.blocking, .blockingLight)]
                for (bright, light) in pairs {
                    XCTAssertGreaterThanOrEqual(deltaE(bright.nsColor, light.nsColor), 10,
                                                "\(bright) vs \(light) (\(appearance.rawValue))")
                }
            }
        }
    }

    func testRolesAndGlyphsFollowTheOwnersScheme() {
        XCTAssertEqual(AccountReadiness.weeklyHitSoon.role, .blocking, "bright red = weekly hit with the reset within a day")
        XCTAssertEqual(AccountReadiness.weeklyHit.role, .blockingLight)
        XCTAssertEqual(AccountReadiness.sessionHit.role, .caution)
        XCTAssertEqual(AccountReadiness.sessionHitLight.role, .cautionLight)
        XCTAssertEqual(AccountReadiness.ready.role, .ready)
        XCTAssertEqual(AccountReadiness.readyLight.role, .readyLight)
        XCTAssertEqual(AccountReadiness.legendOrder.count, AccountReadiness.allCases.count)
        XCTAssertEqual(Set(AccountReadiness.legendOrder), Set(AccountReadiness.allCases))
    }
}
