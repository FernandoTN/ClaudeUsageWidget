//
//  TelemetryChartView.swift
//  Claude Usage
//
//  The hero chart (spec §3.2 frame 3), drawn with Canvas: columns ≤ 24 pt
//  with 2 pt surface gaps and a rounded top, hairline solid gridlines, a
//  nice-number axis, the 7-bucket mean, the partial bucket hatched, clipped
//  outliers marked with a break and their value, ⇄ switch counts under the
//  axis. Two modes: Stacked (one axis, series stacked) and Split (one row per
//  series with its own scale, shared days — the Fleet default, because Codex
//  and Grok are one-pixel slivers under Claude). Hover gives a crosshair and
//  one tooltip with every series; ←/→ move it from the keyboard; a click (or
//  Return) opens the bucket's breakdown. Legend click isolates a series
//  (emphasis: the others fade, nothing is recoloured). No AppKit-backed
//  views, so the frame harness renders it as the window does.
//

import SwiftUI

enum TelemetryChartMode: String, CaseIterable {
    case stacked, split
}

nonisolated enum TelemetryChartMath {
    /// The largest value rounded up to 1 / 1.2 / 1.5 / 2 / 2.5 / 3 / 4 / 5 / 6 / 8 / 10 × 10ⁿ.
    static func niceCeiling(_ value: Int) -> Int {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(Double(value))))
        let normalized = Double(value) / magnitude
        let step = [1.0, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].first { normalized <= $0 } ?? 10
        return Int((step * magnitude).rounded())
    }

    /// Trailing mean over `window` complete buckets; nil where fewer precede or a partial bucket is inside.
    static func trailingMean(_ values: [Int], partial: [Bool], window: Int = 7) -> [Int?] {
        var result: [Int?] = Array(repeating: nil, count: values.count)
        guard values.count == partial.count else { return result }
        for index in values.indices where index >= window - 1 {
            let slice = (index - window + 1)...index
            guard !slice.contains(where: { partial[$0] }) else { continue }
            result[index] = slice.reduce(0) { $0 + values[$1] } / window
        }
        return result
    }

    /// Which bucket a horizontal position falls in.
    static func bucketIndex(atX x: CGFloat, plotWidth: CGFloat, count: Int) -> Int? {
        guard count > 0, plotWidth > 0, x >= 0, x < plotWidth else { return nil }
        return min(count - 1, Int(x / (plotWidth / CGFloat(count))))
    }
}

struct TelemetryChartView: View {
    var report: TelemetryReport
    var metric: TelemetryMetric
    var mode: TelemetryChartMode
    @Binding var isolated: SeriesKey?
    @Binding var hoverIndex: Int?
    var onSelectBucket: (Int) -> Void
    /// The harness passes a fixed pointer position; the window uses hover.
    var interactive = true

    private let axisWidth: CGFloat = 48
    private let axisHeight: CGFloat = 22
    private let rowTitleHeight: CGFloat = 16
    private let rowGap: CGFloat = 10

    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let plotWidth = max(1, size.width - axisWidth)
            let count = max(1, report.buckets.count)
            let pitch = plotWidth / CGFloat(count)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    draw(in: &context, size: size, plotWidth: plotWidth, pitch: pitch)
                }
                if let hoverIndex, report.buckets.indices.contains(hoverIndex) {
                    tooltip(for: hoverIndex, pitch: pitch, plotWidth: plotWidth, size: size)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard interactive else { return }
                switch phase {
                case .active(let point):
                    hoverIndex = TelemetryChartMath.bucketIndex(atX: point.x, plotWidth: plotWidth, count: count)
                case .ended:
                    hoverIndex = nil
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                guard interactive, let index = TelemetryChartMath.bucketIndex(atX: point.x, plotWidth: plotWidth, count: count) else { return }
                onSelectBucket(index)
            }
        }
        .focusable(interactive)
        .focused($focused)
        .onMoveCommand { direction in
            let count = report.buckets.count
            guard count > 0 else { return }
            switch direction {
            case .left: hoverIndex = max(0, (hoverIndex ?? count) - 1)
            case .right: hoverIndex = min(count - 1, (hoverIndex ?? -1) + 1)
            default: break
            }
        }
        .onKeyPress(.return) {
            guard let hoverIndex else { return .ignored }
            onSelectBucket(hoverIndex)
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: - Values

    private func value(_ totals: TokenTotals?) -> Int { totals?.value(for: metric) ?? 0 }

    private func format(_ value: Int) -> String {
        metric == .cost ? TelemetryFormatting.usd(nanoUSD: value) : TelemetryFormatting.compact(value)
    }

    private var series: [SeriesKey] { report.seriesOrder }

    private func color(_ key: SeriesKey, index: Int) -> Color {
        TelemetryPalette.color(for: key, stack: report.query.effectiveStack, index: index)
    }

    private func alpha(_ key: SeriesKey) -> Double {
        guard let isolated else { return 1 }
        return isolated == key ? 1 : 0.22
    }

    // MARK: - Drawing

    private struct Row {
        var key: SeriesKey?          // nil = the stacked total
        var index: Int
        var top: CGFloat
        var height: CGFloat
        var ceiling: Int
    }

    private func rows(size: CGSize) -> [Row] {
        let plotHeight = size.height - axisHeight
        switch mode {
        case .stacked:
            let raw = report.outliers?.typicalMax ?? report.buckets.map { value($0.total) }.max() ?? 1
            return [Row(key: nil, index: 0, top: 0, height: max(1, plotHeight), ceiling: TelemetryChartMath.niceCeiling(raw))]
        case .split:
            let count = max(1, series.count)
            let each = (plotHeight - CGFloat(count - 1) * rowGap) / CGFloat(count)
            return series.enumerated().map { index, key in
                let raw = report.buckets.map { value($0.series[key]) }.max() ?? 1
                return Row(key: key, index: index, top: CGFloat(index) * (each + rowGap) + rowTitleHeight,
                           height: max(1, each - rowTitleHeight), ceiling: TelemetryChartMath.niceCeiling(raw))
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, plotWidth: CGFloat, pitch: CGFloat) {
        let columnWidth = min(24, max(4, pitch * 0.6))
        let surface = Color(nsColor: .windowBackgroundColor)
        let grid = Color(nsColor: .separatorColor)
        let secondary = Color.secondary
        let buckets = report.buckets

        for row in rows(size: size) {
            // Row title (split) and gridlines.
            if let key = row.key {
                let total = buckets.reduce(0) { $0 + value($1.series[key]) }
                let share = report.totals.value(for: metric) > 0 ? Double(total) / Double(report.totals.value(for: metric)) : 0
                let title = Text("\(key.label)  ").font(.system(size: 10.5, weight: .semibold)).foregroundColor(.primary)
                    + Text("\(format(total)) · \(TelemetryFormatting.percent(share))").font(.system(size: 9.5)).foregroundColor(.secondary)
                context.opacity = alpha(key)
                context.draw(title, at: CGPoint(x: 0, y: row.top - rowTitleHeight + 2), anchor: .topLeading)
                context.opacity = 1
            }
            for fraction in [0.0, 0.5, 1.0] {
                let y = row.top + row.height * (1 - fraction)
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: plotWidth, y: y)) },
                               with: .color(grid), lineWidth: 1)
                let label = fraction == 0 ? "0" : format(Int(Double(row.ceiling) * fraction))
                context.draw(Text(label).font(.system(size: 9)).foregroundColor(secondary),
                             at: CGPoint(x: size.width, y: y), anchor: fraction == 1 ? .topTrailing : (fraction == 0 ? .bottomTrailing : .trailing))
            }

            // Columns.
            for (index, bucket) in buckets.enumerated() {
                let x = CGFloat(index) * pitch + (pitch - columnWidth) / 2
                let hovered = hoverIndex == index
                if hovered {
                    context.fill(Path(CGRect(x: CGFloat(index) * pitch, y: row.top, width: pitch, height: row.height)),
                                 with: .color(Color.primary.opacity(0.06)))
                }
                let segments: [(SeriesKey, Int)] = row.key.map { [($0, value(bucket.series[$0]))] }
                    ?? series.map { ($0, value(bucket.series[$0])) }
                let total = segments.reduce(0) { $0 + $1.1 }
                guard total > 0 else { continue }
                let clipped = row.key == nil && (report.outliers?.indices.contains(index) ?? false)
                let scale = row.height / CGFloat(row.ceiling)
                let columnHeight = min(row.height, CGFloat(total) * scale)
                var y = row.top + row.height
                var drawn = 0
                for (seriesIndex, (key, part)) in segments.enumerated() where part > 0 {
                    let fraction = CGFloat(part) / CGFloat(total)
                    var height = columnHeight * fraction
                    let isTop = segments.suffix(from: seriesIndex + 1).allSatisfy { $0.1 == 0 }
                    let gap: CGFloat = drawn > 0 ? 2 : 0
                    height = max(1, height - gap)
                    y -= gap
                    let rect = CGRect(x: x, y: y - height, width: columnWidth, height: height)
                    let path = isTop && !clipped
                        ? Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(topLeading: 3, topTrailing: 3))
                        : Path(rect)
                    let paletteIndex = row.key == nil ? seriesIndex : row.index
                    context.opacity = alpha(key) * (bucket.isPartial ? 0.55 : 1)
                    context.fill(path, with: .color(color(key, index: paletteIndex)))
                    context.opacity = 1
                    if bucket.isPartial { hatch(&context, rect: rect, surface: surface) }
                    y -= height
                    drawn += 1
                }
                if clipped {
                    // A break mark and the true value above the clipped column.
                    let breakY = row.top + 6
                    var mark = Path()
                    mark.move(to: CGPoint(x: x - 3, y: breakY + 3)); mark.addLine(to: CGPoint(x: x + columnWidth + 3, y: breakY - 3))
                    mark.move(to: CGPoint(x: x - 3, y: breakY + 7)); mark.addLine(to: CGPoint(x: x + columnWidth + 3, y: breakY + 1))
                    context.stroke(mark, with: .color(surface), lineWidth: 3)
                    context.stroke(mark, with: .color(secondary), lineWidth: 1)
                    context.draw(Text("▲ " + format(total)).font(.system(size: 8)).foregroundColor(secondary),
                                 at: CGPoint(x: x + columnWidth / 2, y: row.top - 2), anchor: .bottom)
                }
            }

            // Trailing mean.
            let values = buckets.map { bucket in row.key.map { value(bucket.series[$0]) } ?? value(bucket.total) }
            let means = row.key == nil ? report.movingAverage : TelemetryChartMath.trailingMean(values, partial: buckets.map(\.isPartial))
            var line = Path()
            var started = false
            for (index, mean) in means.enumerated() {
                guard let mean else { started = false; continue }
                let point = CGPoint(x: CGFloat(index) * pitch + pitch / 2,
                                    y: row.top + row.height - min(row.height, CGFloat(mean) * row.height / CGFloat(row.ceiling)))
                if started { line.addLine(to: point) } else { line.move(to: point); started = true }
            }
            context.opacity = row.key.map(alpha) ?? 1
            context.stroke(line, with: .color(secondary), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            context.opacity = 1
        }

        // Crosshair.
        if let hoverIndex, buckets.indices.contains(hoverIndex) {
            let x = CGFloat(hoverIndex) * pitch + pitch / 2
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height - axisHeight)) },
                           with: .color(secondary.opacity(0.6)), lineWidth: 1)
        }

        // Axis labels and switch marks.
        let labelEvery = buckets.count <= 12 ? 1 : max(1, buckets.count / 8)
        for (index, bucket) in buckets.enumerated() {
            let centerX = CGFloat(index) * pitch + pitch / 2
            if index % labelEvery == 0 {
                let label = TelemetryFormatting.bucketLabel(bucket.start, granularity: report.range.granularity,
                                                            calendar: report.query.calendar, first: index == 0)
                context.draw(Text(label).font(.system(size: 9)).foregroundColor(secondary),
                             at: CGPoint(x: centerX, y: size.height - axisHeight + 3), anchor: .top)
            }
            if bucket.switchCount > 0 {
                let mark = "⇄" + (bucket.switchCount > 1 ? String(bucket.switchCount) : "")
                context.draw(Text(mark).font(.system(size: 8)).foregroundColor(secondary),
                             at: CGPoint(x: centerX, y: size.height - 1), anchor: .bottom)
            }
        }
    }

    /// Diagonal hatch in the surface colour over a partial bucket's column.
    private func hatch(_ context: inout GraphicsContext, rect: CGRect, surface: Color) {
        var lines = Path()
        var offset: CGFloat = -rect.height
        while offset < rect.width {
            lines.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            lines.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
            offset += 4
        }
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            layer.stroke(lines, with: .color(surface), lineWidth: 1.2)
        }
    }

    // MARK: - Tooltip

    private func tooltip(for index: Int, pitch: CGFloat, plotWidth: CGFloat, size: CGSize) -> some View {
        let bucket = report.buckets[index]
        let width: CGFloat = 220
        let anchorX = CGFloat(index) * pitch + pitch / 2
        let x = min(max(0, anchorX + 12), max(0, plotWidth - width))
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(TelemetryFormatting.bucketLabel(bucket.start, granularity: report.range.granularity, calendar: report.query.calendar, first: true))
                    .font(.system(size: 9.5, weight: .semibold))
                if bucket.isPartial {
                    Text("telemetry.chart.partial".localized).font(.system(size: 8.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(format(value(bucket.total))).font(.system(size: 9.5, weight: .semibold)).monospacedDigit()
            }
            ForEach(Array(series.enumerated()), id: \.element) { seriesIndex, key in
                let part = value(bucket.series[key])
                if part > 0 || series.count <= 3 {
                    HStack(spacing: 5) {
                        Rectangle().fill(color(key, index: seriesIndex)).frame(width: 10, height: 2)
                        Text(key.label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(format(part)).font(.system(size: 9)).monospacedDigit()
                    }
                }
            }
            if bucket.switchCount > 0 {
                Text("telemetry.switches".localized(with: bucket.switchCount)).font(.system(size: 8.5)).foregroundStyle(.secondary)
            }
            Text(interactive ? "click for the breakdown" : "")
                .font(.system(size: 8)).foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .offset(x: x, y: 4)
        .allowsHitTesting(false)
    }

    private var accessibilitySummary: String {
        guard !report.totals.isEmpty else { return "telemetry.empty".localized(with: "") }
        let total = format(value(report.totals))
        let peak = report.buckets.max { value($0.total) < value($1.total) }
        var summary = "\(report.query.window.title): \(total) in \(report.buckets.count) buckets"
        if let peak { summary += ", peak \(format(value(peak.total))) on \(TelemetryFormatting.mediumDate(peak.start, calendar: report.query.calendar))" }
        if mode == .split { summary += ", one row per series: " + series.map(\.label).joined(separator: ", ") }
        return summary
    }
}

/// The click-a-bucket popover: that bucket's by-model and by-account rows.
struct TelemetryBucketBreakdown: View {
    var bucket: TelemetryBucket
    var report: TelemetryReport
    var metric: TelemetryMetric

    private func value(_ totals: TokenTotals) -> Int { totals.value(for: metric) }
    private func format(_ value: Int) -> String {
        metric == .cost ? TelemetryFormatting.usd(nanoUSD: value) : TelemetryFormatting.compact(value)
    }

    var body: some View {
        let total = max(1, value(bucket.total))
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(TelemetryFormatting.mediumDate(bucket.start, calendar: report.query.calendar))
                    .font(.system(size: 12, weight: .bold))
                if bucket.isPartial { Text("telemetry.chart.partial".localized).font(.system(size: 9)).foregroundStyle(.secondary) }
                Spacer()
                Text(format(value(bucket.total))).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            HStack(alignment: .top, spacing: 16) {
                column(title: "telemetry.by_model".localized, rows: bucket.byModel, total: total)
                column(title: "telemetry.by_account".localized, rows: bucket.byAccount, total: total)
            }
            if bucket.switchCount > 0 {
                Text("telemetry.switches".localized(with: bucket.switchCount)).font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 440)
    }

    private func column(title: String, rows: [SeriesKey: TokenTotals], total: Int) -> some View {
        let sorted = rows.sorted { value($0.value) > value($1.value) }.prefix(8)
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(Array(sorted), id: \.key) { key, totals in
                HStack(spacing: 6) {
                    Text(key.label).font(.system(size: 9.5)).lineLimit(1)
                        .foregroundStyle(key.id.hasPrefix("unattributed") ? .secondary : .primary)
                    Spacer(minLength: 4)
                    Text(format(value(totals))).font(.system(size: 9)).monospacedDigit()
                    Text(TelemetryFormatting.percent(Double(value(totals)) / Double(total)))
                        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            if rows.isEmpty { Text("—").font(.system(size: 9)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
