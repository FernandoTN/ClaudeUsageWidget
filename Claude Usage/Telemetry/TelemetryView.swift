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
//  backed `List` / `Picker` / `ScrollView` / `ProgressView` cannot be rendered
//  by `ImageRenderer`).
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
            chartMode: Binding(get: { model.effectiveChartMode }, set: { model.chartMode = $0 }),
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
    @Binding var chartMode: TelemetryChartMode
    var owners: Set<UUID>
    var actions: TelemetryActions
    /// Harness-only: a fixed pointer position and an isolated series.
    var initialHover: Int? = nil
    var initialIsolated: SeriesKey? = nil
    var interactive = true

    var body: some View {
        HStack(spacing: 0) {
            TelemetrySidebarView(sections: sections, selection: $selection)
                .frame(width: 220)
                .background(Color(nsColor: .underPageBackgroundColor).opacity(0.6))
            Divider()
            TelemetryReportPane(report: report, status: status, isLoading: isLoading, isPaused: isPaused, scopeTitle: scopeTitle,
                                window: $window, metric: $metric, chartMode: $chartMode, owners: owners, actions: actions,
                                initialHover: initialHover, initialIsolated: initialIsolated, interactive: interactive)
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

    /// Rows plus section gaps, in points — decides whether a scroll view
    /// (AppKit-backed, invisible to `ImageRenderer`) is needed at all.
    private var contentHeight: CGFloat {
        CGFloat(flatRows.count) * 24 + CGFloat(max(0, sections.count - 1)) * 10 + 42
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
    @Binding var chartMode: TelemetryChartMode
    var owners: Set<UUID>
    var actions: TelemetryActions
    var interactive = true

    @State private var isolated: SeriesKey?
    @State private var hoverIndex: Int?
    @State private var breakdownIndex: Int?

    init(report: TelemetryReport?, status: IndexingStatus, isLoading: Bool, isPaused: Bool, scopeTitle: String,
         window: Binding<TelemetryWindow>, metric: Binding<TelemetryMetric>, chartMode: Binding<TelemetryChartMode>,
         owners: Set<UUID>, actions: TelemetryActions, initialHover: Int? = nil, initialIsolated: SeriesKey? = nil,
         interactive: Bool = true) {
        self.report = report; self.status = status; self.isLoading = isLoading; self.isPaused = isPaused
        self.scopeTitle = scopeTitle; _window = window; _metric = metric; _chartMode = chartMode
        self.owners = owners; self.actions = actions; self.interactive = interactive
        _hoverIndex = State(initialValue: initialHover)
        _isolated = State(initialValue: initialIsolated)
    }

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
                chartSection
                    .frame(minHeight: 230, maxHeight: .infinity)
                    .layoutPriority(1)
                if let report {
                    HStack(alignment: .top, spacing: 12) {
                        TelemetryTableView(title: "telemetry.by_model".localized, rows: report.models, kind: .models,
                                           stack: .model, owners: owners, now: now)
                        TelemetryTableView(title: "telemetry.by_account".localized, rows: report.accounts, kind: .accounts,
                                           stack: .account, owners: owners, now: now)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
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

    // MARK: Chart section

    private var chartTitle: String {
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

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text(chartTitle).font(.system(size: 12, weight: .bold))
                Spacer()
                TelemetrySegmentedPicker(options: [(TelemetryChartMode.stacked, "telemetry.chart.stacked".localized),
                                                   (.split, "telemetry.chart.split".localized)], selection: $chartMode)
                    .frame(width: 130)
                TelemetrySegmentedPicker(options: [(TelemetryMetric.inputClass, "Input-class"), (.inputByKind, "By kind"),
                                                   (.output, "Output"), (.cost, "≈ List")], selection: $metric)
                    .frame(width: 300)
            }
            if let report, !report.totals.isEmpty {
                legend(report)
                TelemetryChartView(report: report, metric: metric, mode: chartMode, isolated: $isolated, hoverIndex: $hoverIndex,
                                   onSelectBucket: { breakdownIndex = $0 }, interactive: interactive)
                    .popover(isPresented: Binding(get: { breakdownIndex != nil }, set: { if !$0 { breakdownIndex = nil } }),
                             arrowEdge: .bottom) {
                        if let index = breakdownIndex, report.buckets.indices.contains(index) {
                            TelemetryBucketBreakdown(bucket: report.buckets[index], report: report, metric: metric)
                        }
                    }
            } else {
                Text(status.isCatchingUp && (report?.totals.isEmpty ?? true)
                     ? "Indexing — the chart fills in as files complete." : "telemetry.empty".localized(with: scopeTitle))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Always present for ≥ 2 series; a click isolates (emphasis), a second
    /// click restores. Series are never recoloured.
    private func legend(_ report: TelemetryReport) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(report.seriesOrder.enumerated()), id: \.element) { index, key in
                Button {
                    isolated = isolated == key ? nil : key
                } label: {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(TelemetryPalette.color(for: key, stack: report.query.effectiveStack, index: index))
                            .frame(width: 10, height: 10)
                        Text(key.label).font(.system(size: 9, weight: isolated == key ? .semibold : .regular)).foregroundStyle(.secondary)
                    }
                    .opacity(isolated == nil || isolated == key ? 1 : 0.4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(key.label)\(isolated == key ? ", isolated" : "")")
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
            if let outliers = report.outliers, chartMode == .stacked {
                let described = outliers.indices.sorted().prefix(2).map { index in
                    let total = report.buckets[index].total.value(for: metric)
                    let value = metric == .cost ? TelemetryFormatting.usd(nanoUSD: total) : TelemetryFormatting.compact(total)
                    return "\(TelemetryFormatting.bucketLabel(report.buckets[index].start, granularity: report.range.granularity, calendar: report.query.calendar, first: true)): \(value)"
                }.joined(separator: ", ")
                Text("\(outliers.indices.count) outlier bucket\(outliers.indices.count == 1 ? "" : "s") clipped to the typical range (\(described))")
                    .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
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
