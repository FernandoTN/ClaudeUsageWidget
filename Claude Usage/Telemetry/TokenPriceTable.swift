//
//  TokenPriceTable.swift
//  Claude Usage
//
//  The shipped list prices behind the "API list-price equivalent — not billed"
//  figure (spec §2.5, research §6). Subscriptions are flat; this is a common
//  unit across models and providers, priced uniformly at the shipped rates
//  (comparison, not accounting). Grok's figure is the CLI's own nano-USD and
//  never recomputed here; an unknown model contributes tokens but no cost.
//

import Foundation

/// USD per million tokens.
nonisolated struct TokenPrice: Sendable, Equatable {
    var input: Double
    var cacheRead: Double
    var cacheWrite5m: Double
    var cacheWrite1h: Double
    var output: Double

    /// Nano-USD for the given token counts (1 nano-USD = 1e-9 USD; a price of
    /// $X per million tokens is X × 1,000 nano-USD per token).
    func nanoUSD(input: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int, output: Int) -> Int {
        let write1h = min(cacheWrite1h, cacheWrite)
        let write5m = cacheWrite - write1h
        let usdPerToken: (Double, Int) -> Double = { pricePerMillion, tokens in pricePerMillion * 1_000 * Double(tokens) }
        let total = usdPerToken(self.input, input) + usdPerToken(self.cacheRead, cacheRead)
            + usdPerToken(self.cacheWrite5m, write5m) + usdPerToken(self.cacheWrite1h, write1h)
            + usdPerToken(self.output, output)
        return Int(total.rounded())
    }
}

nonisolated struct TokenPriceTable: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var prefix: String
        var price: TokenPrice
        var source: String
    }

    var asOf: Date
    var version: String
    /// Matched by LONGEST prefix, so "claude-fable-5-1" beats "claude-fable-5".
    var entries: [Entry]

    func price(forModel model: String) -> TokenPrice? {
        entries
            .filter { model.hasPrefix($0.prefix) }
            .max(by: { $0.prefix.count < $1.prefix.count })?
            .price
    }

    func costNanoUSD(model: String, input: Int, cacheRead: Int, cacheWrite: Int, cacheWrite1h: Int, output: Int) -> Int? {
        price(forModel: model)?.nanoUSD(input: input, cacheRead: cacheRead, cacheWrite: cacheWrite,
                                        cacheWrite1h: cacheWrite1h, output: output)
    }

    /// Prices published 2026-09-04 (Anthropic first-party API; OpenAI API
    /// pricing page; xAI docs — Grok listed for reference only, the CLI's own
    /// figure is used). Codex has no cache-write price: writes bill as input.
    static let shipped: TokenPriceTable = {
        let anthropic = "Anthropic API pricing (claude-api reference, cached 2026-06-24; Fable 5.1 cache read $0.25)"
        let openai = "developers.openai.com/api/docs/pricing, fetched 2026-09-04"
        let xai = "docs.x.ai/docs/models, fetched 2026-09-04 (<200k tier; reference only)"
        func claude(_ p: String, _ i: Double, _ r: Double, _ o: Double) -> Entry {
            Entry(prefix: p, price: TokenPrice(input: i, cacheRead: r, cacheWrite5m: i * 1.25, cacheWrite1h: i * 2, output: o), source: anthropic)
        }
        func gpt(_ p: String, _ i: Double, _ r: Double, _ o: Double) -> Entry {
            Entry(prefix: p, price: TokenPrice(input: i, cacheRead: r, cacheWrite5m: i, cacheWrite1h: i, output: o), source: openai)
        }
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 4
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return TokenPriceTable(
            asOf: utc.date(from: components) ?? Date(timeIntervalSince1970: 1_788_480_000),
            version: "2026-09-04",
            entries: [
                claude("claude-fable-5-1", 10, 0.25, 50),
                claude("claude-fable-5", 10, 1.0, 50),
                claude("claude-mythos-5", 10, 0.25, 50),
                claude("claude-opus-5", 5, 0.5, 25),
                claude("claude-opus-4-8", 5, 0.5, 25),
                claude("claude-opus-4-7", 5, 0.5, 25),
                claude("claude-opus-4-6", 5, 0.5, 25),
                claude("claude-sonnet-5", 2, 0.2, 10),
                claude("claude-sonnet-4-6", 3, 0.3, 15),
                claude("claude-haiku-4-5", 1, 0.1, 5),
                gpt("gpt-5.6-sol", 4, 0.4, 20),
                gpt("gpt-5.6-terra", 2, 0.2, 12),
                gpt("gpt-5.6-luna", 0.2, 0.02, 1.2),
                gpt("gpt-5.5", 5, 0.5, 30),
                gpt("gpt-5.3-codex", 1.75, 0.175, 14),
                gpt("gpt-5.2", 1.75, 0.175, 14),
                gpt("gpt-5.1", 1.25, 0.125, 10),
                gpt("gpt-5", 1.25, 0.125, 10),
                Entry(prefix: "grok-4.6", price: TokenPrice(input: 2, cacheRead: 0.5, cacheWrite5m: 2, cacheWrite1h: 2, output: 6), source: xai),
                Entry(prefix: "grok-4.5", price: TokenPrice(input: 2, cacheRead: 0.3, cacheWrite5m: 2, cacheWrite1h: 2, output: 6), source: xai),
            ])
    }()
}
