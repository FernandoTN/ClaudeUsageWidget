//
//  TelemetryFormatting.swift
//  Claude Usage
//
//  Strings and colours for the token-usage window. Numbers are compact
//  ("78.3 B", "120 M", "219 k", "$58.7 k"); every headline carries its age
//  through `DashboardFormatting.age`. Series colours are the ONLY literal
//  colours in the module — the validated data-viz palette (CVD-checked
//  adjacent pairs, separate light/dark steps); everything else is semantic.
//

import AppKit
import SwiftUI

nonisolated enum TelemetryFormatting {

    /// 1,234 → "1.2 k"; 78,300,000,000 → "78.3 B". Thin space before the unit.
    static func compact(_ value: Int) -> String {
        let magnitude = abs(value)
        let sign = value < 0 ? "−" : ""
        func scaled(_ divisor: Double, _ unit: String) -> String {
            let scaled = Double(magnitude) / divisor
            let digits = scaled < 10 ? 2 : (scaled < 100 ? 1 : 0)
            var text = String(format: "%.\(digits)f", scaled)
            // "50.0 B" reads as false precision; "50 B" is the number.
            if text.contains(".") {
                while text.hasSuffix("0") { text.removeLast() }
                if text.hasSuffix(".") { text.removeLast() }
            }
            return sign + text + "\u{2009}" + unit
        }
        switch magnitude {
        case ..<1_000: return sign + String(magnitude)
        case ..<1_000_000: return scaled(1_000, "k")
        case ..<1_000_000_000: return scaled(1_000_000, "M")
        default: return scaled(1_000_000_000, "B")
        }
    }

    /// Nano-USD → "$0.09", "$214", "$58.7 k", "$1.2 M".
    static func usd(nanoUSD: Int) -> String {
        let dollars = Double(nanoUSD) / 1_000_000_000
        switch dollars {
        case ..<0.995: return String(format: "$%.2f", dollars)
        case ..<999.5: return String(format: "$%.0f", dollars)
        case ..<999_500: return String(format: "$%.1f\u{2009}k", dollars / 1_000)
        default: return String(format: "$%.1f\u{2009}M", dollars / 1_000_000)
        }
    }

    /// 0.968 → "97 %"; 0.0031 → "0.3 %".
    static func percent(_ share: Double) -> String {
        let value = share * 100
        if value > 0 && value < 1 { return String(format: "%.1f\u{2009}%%", value) }
        return String(format: "%.0f\u{2009}%%", value)
    }

    /// Signed, uncoloured delta versus the previous period: "▲ 48 %", "▼ 4 %".
    /// A percentage against a tiny base is noise ("▲ 1551 %"), so when the
    /// previous value is under 5 % of the current one the delta says what it
    /// grew from ("from 2.3 B"), and "new" when there was nothing at all.
    static func delta(current: Int, previous: Int, format: (Int) -> String = compact) -> String {
        guard previous > 0 else { return current > 0 ? "new" : "—" }
        // Ten times the base or more is not a percentage anyone reads
        // ("▲ 1574 %"): name the base instead.
        if Double(current) >= Double(previous) * 10 { return "from \(format(previous))" }
        let change = (Double(current) - Double(previous)) / Double(previous) * 100
        if abs(change) < 0.5 { return "▬ 0 %" }
        return (change > 0 ? "▲ " : "▼ ") + String(format: "%.0f\u{2009}%%", abs(change))
    }

    /// "4 d 12 h" / "6 h 20 m" / "45 m" — the length of an ownership span.
    static func span(_ interval: TimeInterval) -> String {
        let minutes = Int((max(0, interval) / 60).rounded())
        if minutes < 60 { return "\(minutes) m" }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 48 { return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m" }
        let days = hours / 24, hoursRest = hours % 24
        return hoursRest == 0 ? "\(days) d" : "\(days) d \(hoursRest) h"
    }

    /// "7-day mean" / "7-hour mean" / "7-week mean" / "7-month mean".
    static func meanLabel(_ granularity: BucketGranularity, window: Int = 7) -> String {
        "\(window)-\(granularity.rawValue) mean"
    }

    /// What the KPI deltas compare against, once, under the tile row.
    static func comparisonLabel(for window: TelemetryWindow) -> String? {
        switch window {
        case .today: return "vs yesterday to this hour"
        case .days7: return "vs the prior 7 days, to the same hour"
        case .days30: return "vs the prior 30 days, to the same hour"
        case .allIndexed: return nil
        }
    }

    static func bucketLabel(_ start: Date, granularity: BucketGranularity, calendar: Calendar, first: Bool) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        switch granularity {
        case .hour: formatter.dateFormat = "HH"
        case .day: formatter.dateFormat = first || calendar.component(.day, from: start) == 1 ? "MMM d" : "d"
        case .week: formatter.dateFormat = "MMM d"
        case .month: formatter.dateFormat = "MMM"
        }
        return formatter.string(from: start)
    }

    static func timeOfDay(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func mediumDate(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

/// The data-viz palette: eight categorical slots with separate light and dark
/// steps. Providers take slots 1–3 (the three-slot all-pairs cap is exactly
/// the provider count); models take slots by family; the tail folds to Other.
@MainActor
enum TelemetryPalette {
    private static func dynamic(light: String, dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return paletteColor(hex: isDark ? dark : light)
        })
    }

    private static func paletteColor(hex: String) -> NSColor {
        var value: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
        return NSColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static let slots: [Color] = [
        dynamic(light: "#2a78d6", dark: "#3987e5"),  // blue
        dynamic(light: "#eb6834", dark: "#d95926"),  // orange
        dynamic(light: "#1baf7a", dark: "#199e70"),  // aqua
        dynamic(light: "#eda100", dark: "#c98500"),  // yellow
        dynamic(light: "#e87ba4", dark: "#d55181"),  // magenta
        dynamic(light: "#008300", dark: "#008300"),  // green
        dynamic(light: "#4a3aa7", dark: "#9085e9"),  // violet
        dynamic(light: "#e34948", dark: "#e66767"),  // red
    ]
    static let other = dynamic(light: "#b8b7b2", dark: "#5c5b57")
    /// Cache reads are the light step of the series hue when stacking by kind.
    static let kindSteps: [Color] = [
        // One hue, three lightness steps in cost order (uncached is the
        // expensive part, cache reads the cheap bulk). Validated: every
        // adjacent pair ≥ 16.6 ΔE in normal, deutan, protan and tritan vision.
        dynamic(light: "#1a5db8", dark: "#9ccaff"),  // uncached input
        dynamic(light: "#6ba3e8", dark: "#3f82d4"),  // cache writes
        dynamic(light: "#bfd8f4", dark: "#27528a"),  // cache reads
    ]

    static func color(for provider: TelemetryProvider) -> Color {
        switch provider {
        case .claude: return slots[0]
        case .codex: return slots[1]
        case .grok: return slots[2]
        }
    }

    /// A model wears its PROVIDER's hue at a lightness step — never another
    /// provider's colour (a green Sonnet under a green Grok legend read as the
    /// same thing). Steps are fixed per model, so a filter never repaints.
    static func modelColorStep(_ model: String) -> (provider: TelemetryProvider?, step: Double) {
        let lower = model.lowercased()
        if lower.contains("opus") { return (.claude, 1.0) }
        if lower.contains("fable") || lower.contains("mythos") { return (.claude, 0.72) }
        if lower.contains("sonnet") { return (.claude, 0.5) }
        if lower.contains("haiku") { return (.claude, 0.34) }
        if lower.hasPrefix("claude") { return (.claude, 0.6) }
        if lower.hasPrefix("gpt-5.6-sol") { return (.codex, 1.0) }
        if lower.hasPrefix("gpt-5.6-terra") { return (.codex, 0.72) }
        if lower.hasPrefix("gpt-5.6-luna") { return (.codex, 0.5) }
        if lower.hasPrefix("gpt-5.5") { return (.codex, 0.6) }
        if lower.hasPrefix("gpt") { return (.codex, 0.4) }
        if lower.contains("codex") { return (.codex, 0.3) }
        if lower.hasPrefix("grok-4.6") { return (.grok, 1.0) }
        if lower.hasPrefix("grok-4.5") { return (.grok, 0.7) }
        if lower.contains("grok") { return (.grok, 0.5) }
        return (nil, 1.0)
    }

    static func color(forModel model: String) -> Color {
        let (provider, step) = modelColorStep(model)
        guard let provider else { return other }
        return color(for: provider).opacity(step)
    }

    static func color(for key: SeriesKey, stack: TelemetryStack, index: Int) -> Color {
        if key == .other { return other }
        switch stack {
        case .provider: return key.provider.map(color(for:)) ?? other
        case .model: return color(forModel: key.id)
        case .kind: return kindSteps[min(index, kindSteps.count - 1)]
        case .account, .originator: return slots[index % slots.count]
        }
    }
}
