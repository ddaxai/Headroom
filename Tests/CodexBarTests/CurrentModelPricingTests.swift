import Foundation
import Testing
@testable import CodexBarCore

struct CurrentModelPricingTests {
    @Test
    func `current OpenAI models have offline prices for every token bucket`() throws {
        let root = Self.emptyCacheRoot()
        let rates: [(String, TokenRates)] = [
            ("gpt-6-astra", TokenRates(input: 10, read: 1, write: 12.5, output: 50)),
            ("gpt-6-sol", TokenRates(input: 2, read: 0.2, write: 2.5, output: 10)),
            ("gpt-6.1-sol", TokenRates(input: 2, read: 0.1, write: 2.5, output: 10)),
            ("gpt-6-luna", TokenRates(input: 0.1, read: 0.01, write: 0.125, output: 0.5)),
            ("gpt-5.6-sol", TokenRates(input: 4, read: 0.4, write: 5, output: 20)),
            ("gpt-5.6-terra", TokenRates(input: 2, read: 0.2, write: 2.5, output: 12)),
            ("gpt-5.6-luna", TokenRates(input: 0.2, read: 0.02, write: 0.25, output: 1.2)),
        ]
        for (model, rate) in rates {
            let short = try #require(CostUsagePricing.codexCostUSD(
                model: model,
                inputTokens: 100,
                cachedInputTokens: 10,
                outputTokens: 5,
                cacheWriteInputTokens: 20,
                modelsDevCacheRoot: root))
            #expect(abs(short - (70 * rate.input + 10 * rate.read + 20 * rate.write + 5 * rate.output) / 1_000_000) <
                1e-12)
            let long = try #require(CostUsagePricing.codexCostUSD(
                model: model,
                inputTokens: 272_001,
                cachedInputTokens: 10,
                outputTokens: 5,
                cacheWriteInputTokens: 20,
                modelsDevCacheRoot: root))
            #expect(abs(long -
                    (271_971 * rate.input * 2 + 10 * rate.read * 2 + 20 * rate.write * 2 + 5 * rate.output * 1.5)
                    / 1_000_000) < 1e-10)
            #expect(CostUsagePricing.normalizeCodexModel("openai/\(model)-2099-01-01") == model)
        }
    }

    @Test
    func `Claude prices reflect the distinct cache discounts of current models`() throws {
        let root = Self.emptyCacheRoot()
        let rates: [(String, TokenRates)] = [
            ("claude-sonnet-5", TokenRates(input: 2, read: 0.2, write: 2.5, output: 10)),
            ("claude-sonnet-5-5", TokenRates(input: 2, read: 0.2, write: 2.5, output: 10)),
            ("claude-opus-5", TokenRates(input: 5, read: 0.5, write: 6.25, output: 25)),
            ("claude-opus-5-5", TokenRates(input: 4, read: 0.2, write: 5, output: 20)),
            ("claude-fable-5-1", TokenRates(input: 10, read: 0.25, write: 12.5, output: 50)),
        ]
        for (model, rate) in rates {
            let cost = try #require(CostUsagePricing.claudeCostUSD(
                model: model,
                inputTokens: 70,
                cacheReadInputTokens: 10,
                cacheCreationInputTokens: 20,
                cacheCreationInputTokens1h: 5,
                outputTokens: 5,
                modelsDevCacheRoot: root))
            #expect(abs(cost -
                    (70 * rate.input + 10 * rate.read + 15 * rate.write + 5 * rate.input * 2 + 5 * rate.output)
                    / 1_000_000) < 1e-12)
        }
    }

    @Test
    func `Fast mode supports current long context but preserves the historical cutoff`() throws {
        let root = Self.emptyCacheRoot()
        for model in ["gpt-6-astra", "gpt-6-sol", "gpt-6.1-sol", "gpt-6-luna", "gpt-5.6-sol"] {
            let standard = try #require(CostUsagePricing.codexCostUSD(
                model: model,
                inputTokens: 272_001,
                cachedInputTokens: 10,
                outputTokens: 5,
                modelsDevCacheRoot: root))
            let fast = try #require(CostUsagePricing.codexPriorityCostUSD(
                model: model,
                inputTokens: 272_001,
                cachedInputTokens: 10,
                outputTokens: 5))
            #expect(fast == standard * 2)
        }
        let cutoff = Date(timeIntervalSince1970: 1_785_888_000)
        #expect(CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 272_001,
            outputTokens: 5,
            pricingDate: cutoff.addingTimeInterval(-1)) == nil)
        #expect(CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 272_001,
            outputTokens: 5,
            pricingDate: cutoff) != nil)
    }

    @Test
    func `Codex usage rows retain prices on both sides of the Sol repricing boundary`() {
        let cutoff = Date(timeIntervalSince1970: 1_787_270_400)
        let rows = [cutoff.addingTimeInterval(-1), cutoff].map { date in
            CostUsageScanner.CodexUsageRow(
                day: "2026-08-21",
                model: "gpt-5.6-sol",
                turnID: nil,
                eventIndex: nil,
                timestampUnixMs: Int64(date.timeIntervalSince1970 * 1000),
                input: 100,
                cached: 10,
                output: 5)
        }
        let priced = CostUsageScanner.codexRowsWithPricingAudit(
            rows, priorityTurns: [:], modelsDevCatalog: nil, modelsDevCacheRoot: Self.emptyCacheRoot())
        #expect(priced.map(\.knownCostNanos) == [605_000, 464_000])
        #expect(priced.allSatisfy { $0.unpricedTokens == 0 })
    }

    @Test
    func `new OpenAI models use the 272K threshold with a catalog context block`() throws {
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {"openai":{"id":"openai","models":{"gpt-6.1-sol":{
          "id":"gpt-6.1-sol","cost":{"input":2,"output":10,"cache_read":0.1,
          "context_over_200k":{"input":4,"output":15,"cache_read":0.2}}
        }}}}
        """.utf8))
        let cost = try #require(CostUsagePricing.codexCostUSD(
            model: "gpt-6.1-sol",
            inputTokens: 220_000,
            cachedInputTokens: 0,
            outputTokens: 10,
            modelsDevCatalog: catalog))
        #expect(abs(cost - 0.4401) < 1e-12)
    }

    private struct TokenRates {
        let input: Double
        let read: Double
        let write: Double
        let output: Double
    }

    private static func emptyCacheRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("current-pricing-\(UUID().uuidString)")
    }
}
