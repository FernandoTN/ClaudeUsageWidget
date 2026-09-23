//
//  FleetCapacityCard.swift
//  Claude Usage
//
//  The Claude section's weekly-capacity card: the full picture behind the
//  bar's `609·31h` (docs/specs/fleet-capacity-forecast.md) — the pool out of
//  its maximum, the burn against the sustainable ceiling and their ratio,
//  the runway with its date, and the weekday renewal profile so the Saturday
//  cluster is visible. Pure rendering of a `FleetCapacityForecast`.
//

import SwiftUI

struct FleetCapacityCard: View {
    let forecast: FleetCapacityForecast
    var calendar: Calendar = .current

    /// The card's one colour: what the runway says.
    private var role: DesignRole {
        switch forecast.runway {
        case .zero(let at, _):
            let left = at.timeIntervalSince(forecast.now)
            return left <= CapacityAffix.imminent ? .blocking : .caution
        case .survives, .sustainable, .notDraining: return .ready
        case .insufficientHistory: return .informational
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("WEEKLY CAPACITY").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                Spacer()
                Text(scopeText)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            poolLine
            Text(burnText)
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundColor(forecast.burnRatio.map { $0 > 1 } == true ? DesignRole.caution.color : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(runwayText)
                .font(.system(size: 9, weight: forecast.zeroAt == nil ? .regular : .semibold))
                .foregroundColor(forecast.zeroAt == nil ? .secondary : role.color)
                .fixedSize(horizontal: false, vertical: true)
            renewalProfile
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .help("One point is one percent of one account's weekly window. Every account renews its 100 points once a week, "
              + "so \(forecast.accounts) accounts sustain at most \(FleetCapacityFormatting.rate(forecast.ceiling)) points an hour; "
              + "a faster burn drains the pool, a slower one refills it.")
    }

    /// Which accounts the pool is made of.
    private var scopeText: String {
        let unmeasured = forecast.unmeasured > 0 ? " + \(forecast.unmeasured) unmeasured" : ""
        return "auto-switch accounts · \(forecast.accounts)" + unmeasured
    }

    // MARK: Pool

    private var poolLine: some View {
        HStack(spacing: 8) {
            Text(FleetCapacityFormatting.points(forecast.pool))
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
            Text("of \(FleetCapacityFormatting.points(forecast.maximum)) pts")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize()
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(role.color)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 4)
            Text("\(Int((fraction * 100).rounded(.down))) %")
                .font(.system(size: 9.5, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var fraction: Double {
        forecast.maximum > 0 ? min(1, max(0, forecast.pool / forecast.maximum)) : 0
    }

    // MARK: Burn and runway

    private var burnText: String {
        let ceiling = "ceiling \(FleetCapacityFormatting.rate(forecast.ceiling)) pt/h"
        guard let burn = forecast.burn else {
            return "Burn: measuring, \(forecast.fitSamples) of \(FleetCapacity.minSamples) samples over "
                + "\(Int(forecast.fitSpan / 60)) of \(Int(FleetCapacity.minSpan / 60)) min · \(ceiling)"
        }
        guard burn > 0, let ratio = forecast.burnRatio else {
            return "Burn \(FleetCapacityFormatting.rate(burn)) pt/h · \(ceiling) · the pool is refilling"
        }
        let verdict = ratio > 1 ? "draining" : "sustainable"
        return "Burn \(FleetCapacityFormatting.rate(burn)) pt/h · \(ceiling) · "
            + String(format: "%.1f×", ratio) + " · \(verdict)"
    }

    private var runwayText: String {
        switch forecast.runway {
        case .zero(let at, let next):
            var text = "Pool empty \(FleetCapacityFormatting.weekdayTime(at)) (in \(FleetCapacityFormatting.hours(at.timeIntervalSince(forecast.now))))"
            if let next {
                text += " — before \(next.name) renews \(FleetCapacityFormatting.weekdayTime(next.at))"
            }
            return text
        case .survives: return "The pool survives every renewal this week."
        case .sustainable: return "No runway: at this burn the renewals keep up."
        case .notDraining: return "No runway: the pool is not draining."
        case .insufficientHistory: return "No runway yet: it needs an hour of history."
        }
    }

    // MARK: Renewal profile

    /// One column per weekday, today first: accounts renewing that day, the
    /// bar's height their share of the busiest day, the points returning on
    /// hover. The day the pool runs dry is named in the runway's colour.
    private var renewalProfile: some View {
        let busiest = max(1, forecast.weekdayProfile.map(\.accounts).max() ?? 1)
        let zeroDay = forecast.zeroAt.map { calendar.component(.weekday, from: $0) }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Renewals, next 7 days")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.secondary)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(forecast.weekdayProfile.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: 1) {
                        Text(day.accounts > 0 ? "\(day.accounts)" : "")
                            .font(.system(size: 8, weight: .semibold))
                            .monospacedDigit()
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(day.accounts > 0 ? DesignRole.ready.color.opacity(0.75) : Color.primary.opacity(0.08))
                            .frame(height: max(2, 22 * CGFloat(day.accounts) / CGFloat(busiest)))
                        Text(FleetCapacityFormatting.weekdayName(day.weekday, calendar: calendar))
                            .font(.system(size: 8, weight: day.weekday == zeroDay ? .bold : .regular))
                            .foregroundColor(day.weekday == zeroDay ? role.color : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(day.accounts) account\(day.accounts == 1 ? "" : "s") renew, returning at least \(FleetCapacityFormatting.points(day.points)) points")
                }
            }
            .frame(height: 44, alignment: .bottom)
        }
        .padding(.top, 2)
    }
}
