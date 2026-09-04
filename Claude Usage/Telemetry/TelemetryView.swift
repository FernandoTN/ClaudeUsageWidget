//
//  TelemetryView.swift
//  Claude Usage
//
//  Layout B (spec §3.2): a 220 pt source list that IS the filter — Fleet, each
//  provider, its accounts, an Unattributed row — beside a report pane: header
//  with the window control and the one provenance line, four KPI tiles, the
//  chart, the two tables, the footer. Every number carries its source and age;
//  nothing here is a percentage of a limit. Selecting a row is a scope, never
//  Viewing. The same views render in the DEBUG frame harness with constant
//  bindings, which is why the pane takes plain values rather than the model —
//  and why the sidebar and the segmented controls are pure SwiftUI (AppKit-
//  backed `List` / `Picker` cannot be rendered by `ImageRenderer`).
//

import SwiftUI

struct TelemetryActions {
    var refresh: () -> Void = {}
    var togglePause: () -> Void = {}
    var copyNumbers: () -> Void = {}
}

struct TelemetryView: View {
    @ObservedObject var model: TelemetryWindowModel

    var body: some View {
        TelemetryFrameView(
            sections: model.sidebar,
            selection: Binding(get: { model.scope }, set: { model.select($0) }),
            report: model.report, status: model.status, isLoading: model.isLoading, isPaused: model.isPaused,
            scopeTitle: model.scopeTitle,
            window: Binding(get: { model.window }, set: { model.window = $0 }),
            metric: Binding(get: { model.metric }, set: { model.metric = $0 }),
            owners: Set(model.sidebar.flatMap(\.rows).filter(\.isOwner).compactMap { UUID(uuidString: $0.id) }),
            actions: TelemetryActions(refresh: model.refreshNow, togglePause: model.togglePaused, copyNumbers: model.copyNumbers))
    }
}

struct TelemetryFrameView: View {
    var sections: [TelemetrySidebarSection]
    @Binding var selection: TelemetryScope
    var report: TelemetryReport?
    var status: IndexingStatus
    var isLoading: Bool
    var isPaused: Bool
    var scopeTitle: String
    @Binding var window: TelemetryWindow
    @Binding var metric: TelemetryMetric
    var owners: Set<UUID>
    var actions: TelemetryActions

    var body: some View {
        HStack(spacing: 0) {
            TelemetrySidebarView(sections: sections, selection: $selection)
                .frame(width: 220)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
            Divider()
            TelemetryReportPane(report: report, status: status, isLoading: isLoading, isPaused: isPaused, scopeTitle: scopeTitle,
                                window: $window, metric: $metric, owners: owners, actions: actions)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Segmented control (pure SwiftUI, keyboard-focusable buttons)

struct TelemetrySegmentedPicker<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(selected ? Color(nsColor: .controlBackgroundColor) : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .stroke(selected ? Color(nsColor: .separatorColor) : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
    }
}

// MARK: - Sidebar

struct TelemetrySidebarView: View {
    var sections: [TelemetrySidebarSection]
    @Binding var selection: TelemetryScope
    @FocusState private var focused: Bool

    private var flatRows: [TelemetrySidebarRow] { sections.flatMap(\.rows) }

    /// Rows plus section headers, in points — decides whether a scroll view
    /// (AppKit-backed, invisible to `ImageRenderer`) is needed at all.
    private var contentHeight: CGFloat {
        CGFloat(flatRows.count) * 24 + CGFloat(max(0, sections.count - 1)) * 34 + 42
    }

    var body: some View {
        GeometryReader { geometry in
            if contentHeight > geometry.size.height {
                ScrollView { rows }
            } else {
                rows
            }
        }
        .focusable()
        .focused($focused)
        .onMoveCommand { direction in
            let rows = flatRows
            guard let index = rows.firstIndex(where: { $0.scope == selection }) else { return }
            switch direction {
            case .up where index > 0: selection = rows[index - 1].scope
            case .down where index + 1 < rows.count: selection = rows[index + 1].scope
            default: break
            }
        }
        .accessibilityLabel("Scope")
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sections) { section in
                if section.id != "fleet" { Spacer().frame(height: 10) }
                // The provider row is the section header: bold, with its account count.
                ForEach(section.rows) { row in rowView(row, count: row.indent ? nil : section.count) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 30)  // the hidden titlebar's traffic lights
        .padding(.bottom, 12)
    }

    private func rowView(_ row: TelemetrySidebarRow, count: Int? = nil) -> some View {
        let selected = row.scope == selection
        return Button { selection = row.scope } label: {
            HStack(spacing: 6) {
                Text(row.title)
                    .font(.system(size: 12, weight: row.indent ? .regular : .semibold))
                    .lineLimit(1)
                if let count {
                    Text("\(count)").font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                }
                if row.isOwner, let provider = row.provider {
                    Text(mark(for: provider))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.cyan)
                        .accessibilityLabel(ActiveVocabulary.activeFor(kind(provider)))
                }
                Spacer(minLength: 4)
                Text(row.total.map(TelemetryFormatting.compact) ?? "—")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .padding(.leading, row.indent ? 18 : 10)
            .padding(.trailing, 10)
            .frame(height: 22)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.22) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func mark(for provider: TelemetryProvider) -> String {
        switch provider {
        case .claude: return "Cl"
        case .codex: return "Cx"
        case .grok: return "Gk"
        }
    }

    private func kind(_ provider: TelemetryProvider) -> Profile.ProviderKind {
        switch provider {
        case .claude: return .claude
        case .codex: return .codex
        case .grok: return .grok
        }
    }
}

// MARK: - Report pane

struct TelemetryReportPane: View {
    var report: TelemetryReport?
    var status: IndexingStatus
    var isLoading: Bool
    var isPaused: Bool
    var scopeTitle: String
    @Binding var window: TelemetryWindow
    @Binding var metric: TelemetryMetric
    var owners: Set<UUID>
    var actions: TelemetryActions

    /// The clock every age in the pane is measured against — the report's,
    /// so a rendered frame and the live window agree.
    private var now: Date { report?.query.now ?? Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !status.ledgerAvailable {
                Text("telemetry.ledger_unavailable".localized)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                kpiRow
                TelemetryColumnStrip(report: report, metric: $metric, scopeTitle: scopeTitle,
                                     indexing: status.isCatchingUp && (report?.totals.isEmpty ?? true))
                    .frame(height: 230)
                if let report {
                    HStack(alignment: .top, spacing: 12) {
                        TelemetryTableView(title: "telemetry.by_model".localized, rows: report.models, kind: .models,
                                           stack: .model, owners: owners, now: now)
                        TelemetryTableView(title: "telemetry.by_account".localized, rows: report.accounts, kind: .accounts,
                                           stack: .account, owners: owners, now: now)
                    }
                }
                Spacer(minLength: 0)
                footer
            }
        }
        .padding(EdgeInsets(top: 30, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center) {
                Text(scopeTitle).font(.system(size: 13, weight: .bold))
                if isLoading {
                    ProgressView().controlSize(.mini).padding(.leading, 4)
                }
                Spacer()
                TelemetrySegmentedPicker(options: TelemetryWindow.allCases.map { ($0, $0.title) }, selection: $window)
                    .frame(width: 300)
            }
            Text(provenanceLine).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var provenanceLine: String {
        var parts = ["telemetry.disclaimer".localized]
        let providers = report?.provenance.map(\.provider) ?? TelemetryProvider.allCases
        for provider in providers {
            if let through = status.dataThrough[provider] {
                parts.append("telemetry.through".localized(with: TelemetryReportBuilder.providerLabel(provider),
                                                           TelemetryFormatting.timeOfDay(through, calendar: report?.query.calendar ?? .current)))
            }
        }
        if let scanned = status.scannedAt { parts.append("indexed \(DashboardFormatting.age(scanned, now: now))") }
        return parts.joined(separator: " · ")
    }

    private var kpiRow: some View {
        HStack(spacing: 12) {
            if status.isCatchingUp && (report?.totals.isEmpty ?? true) {
                TelemetryStatTile(label: "Indexing the CLI logs",
                                  value: "telemetry.indexing".localized(with: Int((status.progress * 100).rounded())),
                                  delta: nil,
                                  sub: "\(TelemetryFormatting.compact(status.backlogFiles)) of \(TelemetryFormatting.compact(status.filesSeen)) files remaining · the numbers appear as files complete",
                                  progress: status.progress)
            } else if let report {
                let totals = report.totals, previous = report.previousTotals
                let cacheShare = totals.inputClass > 0 ? Double(totals.cacheRead) / Double(totals.inputClass) : 0
                let writeShare = totals.inputClass > 0 ? Double(totals.cacheWrite) / Double(totals.inputClass) : 0
                TelemetryStatTile(label: "telemetry.kpi.input_class".localized,
                                  value: TelemetryFormatting.compact(totals.inputClass),
                                  delta: TelemetryFormatting.delta(current: totals.inputClass, previous: previous.inputClass),
                                  sub: "telemetry.kpi.input_class_sub".localized(with: TelemetryFormatting.percent(cacheShare), TelemetryFormatting.percent(writeShare)))
                let thinking = totals.output > 0 ? Double(totals.reasoning) / Double(totals.output) : 0
                TelemetryStatTile(label: "telemetry.kpi.output".localized,
                                  value: TelemetryFormatting.compact(totals.output),
                                  delta: TelemetryFormatting.delta(current: totals.output, previous: previous.output),
                                  sub: "telemetry.kpi.output_sub".localized(with: TelemetryFormatting.percent(thinking)))
                if let native = report.nativeCount {
                    TelemetryStatTile(label: native.label.capitalized, value: TelemetryFormatting.compact(native.value),
                                      delta: TelemetryFormatting.delta(current: totals.units, previous: previous.units), sub: native.detail)
                } else {
                    let oldest = report.coverage.oldestDataThrough.map {
                        "oldest \(TelemetryFormatting.timeOfDay($0, calendar: report.query.calendar))"
                    }
                    TelemetryStatTile(label: "telemetry.kpi.coverage".localized,
                                      value: TelemetryFormatting.percent(report.coverage.attributedShare),
                                      delta: nil,
                                      sub: ["telemetry.kpi.coverage_sub".localized(with: TelemetryFormatting.percent(report.coverage.unattributedShare)), oldest]
                                          .compactMap { $0 }.joined(separator: " · "))
                }
                let unpriced = totals.unpricedUnits > 0 ? " · " + "telemetry.kpi.unpriced".localized(with: totals.unpricedUnits) : ""
                TelemetryStatTile(label: "telemetry.kpi.cost".localized,
                                  value: TelemetryFormatting.usd(nanoUSD: totals.costNanoUSD),
                                  delta: TelemetryFormatting.delta(current: totals.costNanoUSD, previous: previous.costNanoUSD),
                                  sub: "telemetry.kpi.cost_sub".localized(with: TelemetryFormatting.mediumDate(report.priceTable.asOf)) + unpriced)
            } else {
                ForEach(0..<4, id: \.self) { _ in TelemetryStatTile(label: " ", value: "—", delta: nil, sub: nil) }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let report {
                ForEach(report.provenance, id: \.provider) { provenance in
                    ForEach(provenance.caveats, id: \.self) { caveat in
                        Text("\(TelemetryReportBuilder.providerLabel(provenance.provider)): \(caveat)")
                            .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if provenance.health.filesUnreadable + provenance.health.linesMalformed + provenance.health.unknownShapes > 0 {
                        Text("\(TelemetryReportBuilder.providerLabel(provenance.provider)): \(provenance.health.filesUnreadable) files unreadable · \(provenance.health.linesMalformed) lines skipped · \(provenance.health.unknownShapes) unknown shapes")
                            .font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                    }
                }
            }
            HStack(spacing: 8) {
                Button("telemetry.refresh_now".localized, action: actions.refresh)
                Button((isPaused ? "telemetry.resume" : "telemetry.pause").localized, action: actions.togglePause)
                Button("telemetry.copy_numbers".localized, action: actions.copyNumbers)
                if isPaused {
                    Text("indexing paused").font(.system(size: 9)).foregroundStyle(.orange)
                }
                Spacer()
                Text("telemetry.footer.storage".localized(with: TelemetryFormatting.compact(status.eventCount),
                                                           ByteCountFormatter.string(fromByteCount: status.storageBytes, countStyle: .file)))
                    .font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Stat tile

struct TelemetryStatTile: View {
    var label: String
    var value: String
    var delta: String?
    var sub: String?
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: 22, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                if let delta {
                    Text(delta).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(sub ?? " ").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            if let progress {
                // Pure SwiftUI: an NSProgressIndicator-backed ProgressView does
                // not render in the frame harness.
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.2))
                        Capsule().fill(Color.accentColor).frame(width: max(4, geometry.size.width * CGFloat(progress)))
                    }
                }
                .frame(height: 5)
                .padding(.top, 4)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }
}

// MARK: - Chart (stage 3a: static stacked columns; 3b adds hover, split, markers)

struct TelemetryColumnStrip: View {
    var report: TelemetryReport?
    @Binding var metric: TelemetryMetric
    var scopeTitle: String
    var indexing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(title).font(.system(size: 12, weight: .bold))
                Spacer()
                TelemetrySegmentedPicker(options: [(TelemetryMetric.inputClass, "Input-class"), (.inputByKind, "By kind"),
                                                   (.output, "Output"), (.cost, "≈ List")], selection: $metric)
                    .frame(width: 300)
            }
            if let report, !report.totals.isEmpty {
                legend(report)
                GeometryReader { geometry in columns(report, in: geometry.size) }
                axis(report)
            } else {
                Text(indexing ? "Indexing — the chart fills in as files complete." : "telemetry.empty".localized(with: scopeTitle))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var title: String {
        let unit: String
        switch report?.range.granularity ?? .day {
        case .hour: unit = "hour"
        case .day: unit = "day"
        case .week: unit = "week"
        case .month: unit = "month"
        }
        return "telemetry.chart.title".localized(with: metricLabel, unit)
    }

    private var metricLabel: String {
        switch metric {
        case .inputClass: return "Input-class tokens"
        case .inputByKind: return "Input tokens by kind"
        case .output: return "Output tokens"
        case .cost: return "API list-price equivalent"
        }
    }

    private func value(_ totals: TokenTotals) -> Int { totals.value(for: metric) }

    private func format(_ value: Int) -> String {
        metric == .cost ? TelemetryFormatting.usd(nanoUSD: value) : TelemetryFormatting.compact(value)
    }

    /// The axis ceiling: the largest column (or the typical range when an
    /// outlier is clipped) rounded up to 1 / 2 / 2.5 / 5 × 10ⁿ.
    static func niceCeiling(_ value: Int) -> Int {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(Double(value))))
        let normalized = Double(value) / magnitude
        let step = [1.0, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].first { normalized <= $0 } ?? 10
        return Int((step * magnitude).rounded())
    }

    private func legend(_ report: TelemetryReport) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(report.seriesOrder.enumerated()), id: \.element) { index, key in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TelemetryPalette.color(for: key, stack: report.query.effectiveStack, index: index))
                        .frame(width: 10, height: 10)
                    Text(key.label).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if report.movingAverage.contains(where: { $0 != nil }) {
                HStack(spacing: 4) {
                    Rectangle().fill(Color.secondary).frame(width: 12, height: 2)
                    Text("telemetry.chart.mean".localized).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if report.buckets.contains(where: \.isPartial) {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.45)).frame(width: 10, height: 10)
                    Text("telemetry.chart.partial".localized).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let outliers = report.outliers {
                let described = outliers.indices.sorted().prefix(2).map { index in
                    "\(TelemetryFormatting.bucketLabel(report.buckets[index].start, granularity: report.range.granularity, calendar: report.query.calendar, first: true)): \(format(value(report.buckets[index].total)))"
                }.joined(separator: ", ")
                Text("\(outliers.indices.count) outlier bucket\(outliers.indices.count == 1 ? "" : "s") clipped to the typical range (\(described))")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func columns(_ report: TelemetryReport, in size: CGSize) -> some View {
        let axisWidth: CGFloat = 48
        let plotWidth = max(1, size.width - axisWidth)
        let count = max(1, report.buckets.count)
        let pitch = plotWidth / CGFloat(count)
        let columnWidth = min(24, max(4, pitch * 0.6))
        let rawCeiling = report.outliers?.typicalMax ?? report.buckets.map { value($0.total) }.max() ?? 1
        let ceiling = max(1, Self.niceCeiling(rawCeiling))
        let stack = report.query.effectiveStack
        return ZStack(alignment: .topLeading) {
            ForEach([0.0, 0.5, 1.0], id: \.self) { fraction in
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: plotWidth, height: 1)
                    .offset(y: size.height * (1 - fraction))
            }
            ForEach(Array(report.buckets.enumerated()), id: \.offset) { index, bucket in
                let total = value(bucket.total)
                let clipped = report.outliers?.indices.contains(index) ?? false
                let height = size.height * CGFloat(min(total, ceiling)) / CGFloat(ceiling)
                VStack(spacing: 0) {
                    if clipped {
                        Text("▲ " + format(total)).font(.system(size: 8)).foregroundStyle(.secondary).fixedSize()
                    }
                    VStack(spacing: 2) {
                        ForEach(Array(report.seriesOrder.enumerated().reversed()), id: \.element) { seriesIndex, key in
                            let part = value(bucket.series[key] ?? TokenTotals())
                            if part > 0 {
                                Rectangle()
                                    .fill(TelemetryPalette.color(for: key, stack: stack, index: seriesIndex))
                                    .frame(height: max(1, height * CGFloat(part) / CGFloat(max(total, 1))))
                            }
                        }
                    }
                    .frame(width: columnWidth, height: height, alignment: .bottom)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3))
                    .opacity(bucket.isPartial ? 0.45 : 1)
                }
                .frame(width: pitch, height: size.height, alignment: .bottom)
                .offset(x: CGFloat(index) * pitch)
                .accessibilityHidden(true)
            }
            movingAverage(report, plotWidth: plotWidth, pitch: pitch, height: size.height, ceiling: ceiling)
            VStack {
                Text(format(ceiling)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Text(format(ceiling / 2)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Text("0").font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(width: axisWidth, height: size.height, alignment: .trailing)
            .offset(x: plotWidth)
        }
    }

    private func movingAverage(_ report: TelemetryReport, plotWidth: CGFloat, pitch: CGFloat, height: CGFloat, ceiling: Int) -> some View {
        Path { path in
            var started = false
            for (index, mean) in report.movingAverage.enumerated() {
                guard let mean else { started = false; continue }
                let point = CGPoint(x: CGFloat(index) * pitch + pitch / 2,
                                    y: height - height * CGFloat(min(mean, ceiling)) / CGFloat(ceiling))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
        }
        .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private func axis(_ report: TelemetryReport) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(report.buckets.enumerated()), id: \.offset) { index, bucket in
                let showLabel = report.buckets.count <= 12 || index % max(1, report.buckets.count / 8) == 0
                Text(showLabel ? TelemetryFormatting.bucketLabel(bucket.start, granularity: report.range.granularity,
                                                                  calendar: report.query.calendar, first: index == 0) : "")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .bottom) {
                        if bucket.switchCount > 0 {
                            Text("⇄\(bucket.switchCount > 1 ? String(bucket.switchCount) : "")")
                                .font(.system(size: 8)).foregroundStyle(.secondary).offset(y: 11)
                        }
                    }
            }
            Spacer().frame(width: 48)
        }
        .padding(.bottom, 10)
    }

    private var accessibilitySummary: String {
        guard let report, !report.totals.isEmpty else { return "telemetry.empty".localized(with: scopeTitle) }
        let peak = report.buckets.max { value($0.total) < value($1.total) }
        var summary = "\(scopeTitle), \(report.query.window.title): \(metricLabel) \(format(value(report.totals)))"
        if let peak { summary += ", peak \(format(value(peak.total))) on \(TelemetryFormatting.mediumDate(peak.start, calendar: report.query.calendar))" }
        return summary
    }
}

// MARK: - Tables

struct TelemetryTableView: View {
    enum Kind { case models, accounts }

    var title: String
    var rows: [TelemetryRow]
    var kind: Kind
    var stack: TelemetryStack
    var owners: Set<UUID>
    var now: Date
    private let visibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11, weight: .bold))
                Spacer()
                Text(kind == .models ? "\("telemetry.column.share".localized) · \("telemetry.column.cached".localized) · \("telemetry.column.cost".localized)"
                                     : "\("telemetry.column.share".localized) · \("telemetry.column.last_active".localized)")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
            ForEach(Array(rows.prefix(visibleRows).enumerated()), id: \.element.key) { index, row in
                rowView(row, index: index)
            }
            if rows.count > visibleRows {
                Text("\(rows.count - visibleRows) more…").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("—").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
    }

    private func barColor(_ row: TelemetryRow, index: Int) -> Color {
        if row.key.id.hasPrefix("unattributed") { return TelemetryPalette.other }
        switch kind {
        case .models: return TelemetryPalette.color(forModel: row.key.id)
        // An account's share is a magnitude; its identity is the provider's hue.
        case .accounts: return row.key.provider.map(TelemetryPalette.color(for:)) ?? TelemetryPalette.other
        }
    }

    private func rowView(_ row: TelemetryRow, index: Int) -> some View {
        let unattributed = row.key.id.hasPrefix("unattributed")
        let ownerId = UUID(uuidString: row.key.id)
        return HStack(spacing: 6) {
            Text(row.key.label)
                .font(.system(size: 9.5))
                .foregroundStyle(unattributed ? .secondary : .primary)
                .lineLimit(1)
            if kind == .accounts, let ownerId, owners.contains(ownerId), let provider = row.key.provider {
                Text(ActiveVocabulary.activeFor(kind(provider)))
                    .font(.system(size: 8.5)).foregroundStyle(.cyan).lineLimit(1)
            }
            Spacer(minLength: 4)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(row, index: index))
                    .frame(width: max(2, 90 * CGFloat(min(1, row.share))))
            }
            .frame(width: 90, height: 6)
            Text(TelemetryFormatting.percent(row.share))
                .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
            if kind == .models {
                Text(TelemetryFormatting.percent(row.totals.inputClass > 0 ? Double(row.totals.cacheRead) / Double(row.totals.inputClass) : 0))
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                Text(row.totals.unpricedUnits == row.totals.units && row.totals.units > 0 ? "n/a" : TelemetryFormatting.usd(nanoUSD: row.totals.costNanoUSD))
                    .font(.system(size: 9)).monospacedDigit().frame(width: 56, alignment: .trailing)
            } else {
                Text(row.lastActive.map { DashboardFormatting.age($0, now: now) } ?? "—")
                    .font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 72, alignment: .trailing)
            }
        }
        .frame(height: 16)
    }

    private func kind(_ provider: TelemetryProvider) -> Profile.ProviderKind {
        switch provider {
        case .claude: return .claude
        case .codex: return .codex
        case .grok: return .grok
        }
    }
}
