//
//  TelemetryExport.swift
//  Claude Usage
//
//  The CSV behind "Export CSV…" (spec §4, stage 4a): one row per bucket ×
//  (provider, model, account, source, sidechain), built from the same input
//  as the report, and every row carries its provenance — provider, source
//  kind, attribution basis, cost basis — so the file can never be read as
//  quota. Pure; the window only chooses where to save it.
//

import Foundation

nonisolated enum TelemetryExport {
    static let columns = ["bucket_start", "provider", "model", "account", "attribution", "source", "sidechain", "units",
                          "input", "cache_read", "cache_write", "cache_write_1h", "output", "reasoning", "input_class",
                          "cost_usd", "cost_basis"]

    struct Row: Sendable, Equatable {
        var bucketStart: Date
        var provider: TelemetryProvider
        var model: String
        var account: String
        var attribution: String
        var source: String
        var sidechain: Bool
        var totals: TokenTotals
    }

    /// "timeline" / "by_path" / "sole_account" / "unattributed:gap" — the
    /// resolver's own words, never a guess.
    static func attributionLabel(_ attribution: Attribution) -> String {
        switch attribution {
        case .profile(_, let basis):
            switch basis {
            case .timeline: return "timeline"
            case .byPath: return "by_path"
            case .soleAccount: return "sole_account"
            }
        case .unattributed(let reason):
            switch reason {
            case .beforeLog: return "unattributed:before_log"
            case .gap: return "unattributed:gap"
            case .noOwner: return "unattributed:no_owner"
            }
        }
    }

    static func rows(query: TelemetryQuery, input: TelemetryReportBuilder.Input) -> [Row] {
        let range = query.range()
        let resolver = AttributionResolver(ownership: input.ownership, roster: input.roster)
        let attributed = TelemetryReportBuilder.attributedRows(input.aggregates, resolver: resolver, prices: input.prices)
            .filter { TelemetryReportBuilder.inScope($0, query.scope) }
        struct Key: Hashable { var bucket: Int; var provider: TelemetryProvider; var model: String; var account: String; var attribution: String; var source: String; var sidechain: Bool }
        var grouped: [Key: TokenTotals] = [:]
        for row in attributed {
            guard let index = TelemetryQuery.bucketIndex(for: row.aggregate.minute, in: range.buckets) else { continue }
            let account = row.attribution.profileId.flatMap { resolver.roster[$0]?.name } ?? ""
            let key = Key(bucket: index, provider: row.aggregate.provider, model: row.aggregate.model, account: account,
                          attribution: attributionLabel(row.attribution), source: row.aggregate.source ?? "", sidechain: row.aggregate.sidechain)
            grouped[key, default: TokenTotals()].add(row.totals)
        }
        return grouped.map { key, totals in
            Row(bucketStart: range.buckets[key.bucket].start, provider: key.provider, model: key.model, account: key.account,
                attribution: key.attribution, source: key.source, sidechain: key.sidechain, totals: totals)
        }.sorted {
            ($0.bucketStart, $0.provider.rawValue, $0.model, $0.account, $0.source, $0.sidechain ? 1 : 0)
                < ($1.bucketStart, $1.provider.rawValue, $1.model, $1.account, $1.source, $1.sidechain ? 1 : 0)
        }
    }

    static func csv(query: TelemetryQuery, input: TelemetryReportBuilder.Input, scopeTitle: String) -> String {
        let range = query.range()
        let stamp = ISO8601DateFormatter()
        stamp.timeZone = query.calendar.timeZone
        stamp.formatOptions = [.withInternetDateTime]
        var lines = [
            "# Claude Usage — token consumption read from local CLI logs. Not quota, not billed.",
            "# scope: \(scopeTitle) · window: \(query.window.title) (\(stamp.string(from: range.start)) → \(stamp.string(from: range.end))) · bucket: \(range.granularity.rawValue) · exported: \(stamp.string(from: query.now))",
            "# cost_usd: API list-price equivalent (price table as of \(TelemetryFormatting.mediumDate(input.prices.asOf))) or Grok's reported cost; empty when the model is unpriced.",
            "# attribution: timeline = ownership log by time · by_path = isolated Codex home · sole_account = the provider's only account · unattributed:<reason>",
            columns.joined(separator: ","),
        ]
        for row in rows(query: query, input: input) {
            let t = row.totals
            let priced = t.unpricedUnits == 0
            let costBasis = row.provider == .grok ? "reported" : (priced ? "list_price" : "")
            let cost = priced || row.provider == .grok ? String(format: "%.4f", Double(t.costNanoUSD) / 1_000_000_000) : ""
            let fields = [stamp.string(from: row.bucketStart), row.provider.rawValue, row.model, row.account, row.attribution, row.source,
                          row.sidechain ? "true" : "false", String(t.units), String(t.input), String(t.cacheRead), String(t.cacheWrite),
                          String(t.cacheWrite1h), String(t.output), String(t.reasoning), String(t.inputClass), cost, costBasis]
            lines.append(fields.map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// RFC 4180: quote when the value carries a comma, a quote or a newline.
    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// "token-usage-fleet-7-days-2026-09-04.csv"
    static func suggestedFileName(scopeTitle: String, window: TelemetryWindow, now: Date, calendar: Calendar) -> String {
        let slug = { (text: String) -> String in
            text.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
                .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "token-usage-\(slug(scopeTitle))-\(slug(window.title))-\(formatter.string(from: now)).csv"
    }
}
