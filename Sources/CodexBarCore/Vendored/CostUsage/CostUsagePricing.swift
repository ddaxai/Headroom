import Foundation

// swiftlint:disable:next type_body_length
enum CostUsagePricing {
    private static let codexPriorityInputTokenLimit = 272_000
    static let codexUnattributedModel = "unknown"

    struct CodexPricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double?
        /// Optional cache-write (cache creation) rate. When nil, write tokens are billed at the
        /// uncached input rate (legacy Codex folding behavior).
        let cacheWriteInputCostPerToken: Double?
        let displayLabel: String?

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
        let cacheWriteInputCostPerTokenAboveThreshold: Double?
        let priorityInputCostPerToken: Double?
        let priorityOutputCostPerToken: Double?
        let priorityCacheReadInputCostPerToken: Double?
        let priorityCacheWriteInputCostPerToken: Double?

        init(
            inputCostPerToken: Double,
            outputCostPerToken: Double,
            cacheReadInputCostPerToken: Double?,
            displayLabel: String? = nil,
            cacheWriteInputCostPerToken: Double? = nil,
            thresholdTokens: Int? = nil,
            inputCostPerTokenAboveThreshold: Double? = nil,
            outputCostPerTokenAboveThreshold: Double? = nil,
            cacheReadInputCostPerTokenAboveThreshold: Double? = nil,
            cacheWriteInputCostPerTokenAboveThreshold: Double? = nil,
            priorityInputCostPerToken: Double? = nil,
            priorityOutputCostPerToken: Double? = nil,
            priorityCacheReadInputCostPerToken: Double? = nil,
            priorityCacheWriteInputCostPerToken: Double? = nil)
        {
            self.inputCostPerToken = inputCostPerToken
            self.outputCostPerToken = outputCostPerToken
            self.cacheReadInputCostPerToken = cacheReadInputCostPerToken
            self.cacheWriteInputCostPerToken = cacheWriteInputCostPerToken
            self.displayLabel = displayLabel
            self.thresholdTokens = thresholdTokens
            self.inputCostPerTokenAboveThreshold = inputCostPerTokenAboveThreshold
            self.outputCostPerTokenAboveThreshold = outputCostPerTokenAboveThreshold
            self.cacheReadInputCostPerTokenAboveThreshold = cacheReadInputCostPerTokenAboveThreshold
            self.cacheWriteInputCostPerTokenAboveThreshold = cacheWriteInputCostPerTokenAboveThreshold
            self.priorityInputCostPerToken = priorityInputCostPerToken
            self.priorityOutputCostPerToken = priorityOutputCostPerToken
            self.priorityCacheReadInputCostPerToken = priorityCacheReadInputCostPerToken
            self.priorityCacheWriteInputCostPerToken = priorityCacheWriteInputCostPerToken
        }
    }

    private static func longContextPricing(
        input: Double,
        cached: Double? = nil,
        write: Double? = nil,
        output: (standard: Double, long: Double)) -> CodexPricing
    {
        CodexPricing(
            inputCostPerToken: input,
            outputCostPerToken: output.standard,
            cacheReadInputCostPerToken: cached,
            displayLabel: nil,
            cacheWriteInputCostPerToken: write,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: input * 2,
            outputCostPerTokenAboveThreshold: output.long,
            cacheReadInputCostPerTokenAboveThreshold: cached.map { $0 * 2 },
            cacheWriteInputCostPerTokenAboveThreshold: write.map { $0 * 2 })
    }

    struct ClaudePricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheCreationInputCostPerToken: Double
        let cacheReadInputCostPerToken: Double

        let thresholdTokens: Int?
        let inputCostPerTokenAboveThreshold: Double?
        let outputCostPerTokenAboveThreshold: Double?
        let cacheCreationInputCostPerTokenAboveThreshold: Double?
        let cacheReadInputCostPerTokenAboveThreshold: Double?
    }

    private struct ClaudeCostTokens {
        let input: Int
        let cacheRead: Int
        let cacheCreation: Int
        let cacheCreation1h: Int
        let output: Int
    }

    private static let codex: [String: CodexPricing] = [
        "gpt-5": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8,
            displayLabel: nil),
        "gpt-5-nano": CodexPricing(
            inputCostPerToken: 5e-8,
            outputCostPerToken: 4e-7,
            cacheReadInputCostPerToken: 5e-9,
            displayLabel: nil),
        "gpt-5-pro": CodexPricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 1.2e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.1": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex-max": CodexPricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: nil),
        "gpt-5.1-codex-mini": CodexPricing(
            inputCostPerToken: 2.5e-7,
            outputCostPerToken: 2e-6,
            cacheReadInputCostPerToken: 2.5e-8,
            displayLabel: nil),
        "gpt-5.2": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.2-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.2-pro": CodexPricing(
            inputCostPerToken: 2.1e-5,
            outputCostPerToken: 1.68e-4,
            cacheReadInputCostPerToken: nil,
            displayLabel: nil),
        "gpt-5.3-codex": CodexPricing(
            inputCostPerToken: 1.75e-6,
            outputCostPerToken: 1.4e-5,
            cacheReadInputCostPerToken: 1.75e-7,
            displayLabel: nil),
        "gpt-5.3-codex-spark": CodexPricing(
            inputCostPerToken: 0,
            outputCostPerToken: 0,
            cacheReadInputCostPerToken: 0,
            displayLabel: "Research Preview"),
        "gpt-5.4": CodexPricing(
            inputCostPerToken: 2.5e-6,
            outputCostPerToken: 1.5e-5,
            cacheReadInputCostPerToken: 2.5e-7,
            displayLabel: nil,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 5e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheReadInputCostPerTokenAboveThreshold: 5e-7,
            priorityInputCostPerToken: 5e-6,
            priorityOutputCostPerToken: 3e-5,
            priorityCacheReadInputCostPerToken: 5e-7),
        "gpt-5.4-mini": CodexPricing(
            inputCostPerToken: 7.5e-7,
            outputCostPerToken: 4.5e-6,
            cacheReadInputCostPerToken: 7.5e-8,
            displayLabel: nil,
            priorityInputCostPerToken: 1.5e-6,
            priorityOutputCostPerToken: 9e-6,
            priorityCacheReadInputCostPerToken: 1.5e-7),
        "gpt-5.4-nano": CodexPricing(
            inputCostPerToken: 2e-7,
            outputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 2e-8,
            displayLabel: nil),
        "gpt-5.4-pro": Self.longContextPricing(input: 3e-5, output: (1.8e-4, 2.7e-4)),
        "gpt-5.5": CodexPricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 3e-5,
            cacheReadInputCostPerToken: 5e-7,
            displayLabel: nil,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: 1e-5,
            outputCostPerTokenAboveThreshold: 4.5e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6,
            priorityInputCostPerToken: 1.25e-5,
            priorityOutputCostPerToken: 7.5e-5,
            priorityCacheReadInputCostPerToken: 1.25e-6),
        "gpt-5.5-pro": Self.longContextPricing(input: 3e-5, output: (1.8e-4, 2.7e-4)),
        // Current published Standard and Fast contracts, verified 2026-10-04:
        // https://developers.openai.com/api/docs/pricing
        "gpt-6-astra": Self.modernOpenAIPricing(input: 10, output: 50, cacheRead: 1),
        "gpt-6-sol": Self.modernOpenAIPricing(input: 2, output: 10, cacheRead: 0.2),
        "gpt-6.1-sol": Self.modernOpenAIPricing(input: 2, output: 10, cacheRead: 0.1),
        "gpt-6.1-terra": Self.modernOpenAIPricing(input: 1, output: 5, cacheRead: 0.05),
        "gpt-6-luna": Self.modernOpenAIPricing(input: 0.1, output: 0.5, cacheRead: 0.01),
        "gpt-5.6-sol": Self.modernOpenAIPricing(input: 4, output: 20, cacheRead: 0.4),
        "gpt-5.6-terra": Self.modernOpenAIPricing(input: 2, output: 12, cacheRead: 0.2),
        "gpt-5.6-luna": Self.modernOpenAIPricing(input: 0.2, output: 1.2, cacheRead: 0.02),
        "gpt-5.6-cyber": CodexPricing(
            inputCostPerToken: 1.25e-5,
            outputCostPerToken: 7.5e-5,
            cacheReadInputCostPerToken: 1.25e-6,
            cacheWriteInputCostPerToken: 1.5625e-5),
        "gpt-5.5-cyber": CodexPricing(
            inputCostPerToken: 1.25e-5,
            outputCostPerToken: 7.5e-5,
            cacheReadInputCostPerToken: 1.25e-6),
    ]

    /// Only used for the named modern OpenAI models above; these multipliers are their published
    /// contract, not inferred defaults for arbitrary providers or future models.
    private static func modernOpenAIPricing(input: Double, output: Double, cacheRead: Double) -> CodexPricing {
        CodexPricing(
            inputCostPerToken: input / 1_000_000,
            outputCostPerToken: output / 1_000_000,
            cacheReadInputCostPerToken: cacheRead / 1_000_000,
            displayLabel: nil,
            cacheWriteInputCostPerToken: input * 1.25 / 1_000_000,
            thresholdTokens: 272_000,
            inputCostPerTokenAboveThreshold: input * 2 / 1_000_000,
            outputCostPerTokenAboveThreshold: output * 1.5 / 1_000_000,
            cacheReadInputCostPerTokenAboveThreshold: cacheRead * 2 / 1_000_000,
            cacheWriteInputCostPerTokenAboveThreshold: input * 2.5 / 1_000_000,
            priorityInputCostPerToken: input * 2 / 1_000_000,
            priorityOutputCostPerToken: output * 2 / 1_000_000,
            priorityCacheReadInputCostPerToken: cacheRead * 2 / 1_000_000,
            priorityCacheWriteInputCostPerToken: input * 2.5 / 1_000_000)
    }

    private static let modernFastModels: Set<String> = [
        "gpt-6-astra", "gpt-6-sol", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna",
        "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
    ]
    private static let gpt56RepricingCutoff = Date(timeIntervalSince1970: 1_785_369_600) // 2026-07-30 UTC
    private static let solRepricingCutoff = Date(timeIntervalSince1970: 1_787_270_400) // 2026-08-21 UTC
    private static let fastLongContextCutoff = Date(timeIntervalSince1970: 1_785_888_000) // 2026-08-05 UTC

    private static func historicalCodexPricing(model: String, date: Date?) -> CodexPricing? {
        guard let date else { return nil }
        switch model {
        case "gpt-5.6-sol" where date < self.solRepricingCutoff:
            return self.modernOpenAIPricing(input: 5, output: 30, cacheRead: 0.5)
        case "gpt-5.6-terra" where date < self.gpt56RepricingCutoff:
            return self.modernOpenAIPricing(input: 2.5, output: 15, cacheRead: 0.25)
        case "gpt-5.6-luna" where date < self.gpt56RepricingCutoff:
            return self.modernOpenAIPricing(input: 1, output: 6, cacheRead: 0.1)
        default:
            return nil
        }
    }

    static func codexBuiltInPricingFingerprint() -> String {
        var parts = [
            "priorityInputTokenLimit=\(self.codexPriorityInputTokenLimit)",
            "fastPricingDefinition=api-fast-usd-v1",
            "pricingRevision=2026-10-04",
        ]
        for model in self.codex.keys.sorted() {
            guard let pricing = self.codex[model] else { continue }
            parts.append([
                "model=\(model)",
                self.optionalPricingFingerprint(pricing.inputCostPerToken),
                self.optionalPricingFingerprint(pricing.outputCostPerToken),
                self.optionalPricingFingerprint(pricing.cacheReadInputCostPerToken),
                self.optionalPricingFingerprint(pricing.cacheWriteInputCostPerToken),
                pricing.displayLabel ?? "nil",
                pricing.thresholdTokens.map(String.init) ?? "nil",
                self.optionalPricingFingerprint(pricing.inputCostPerTokenAboveThreshold),
                self.optionalPricingFingerprint(pricing.outputCostPerTokenAboveThreshold),
                self.optionalPricingFingerprint(pricing.cacheReadInputCostPerTokenAboveThreshold),
                self.optionalPricingFingerprint(pricing.cacheWriteInputCostPerTokenAboveThreshold),
                self.optionalPricingFingerprint(pricing.priorityInputCostPerToken),
                self.optionalPricingFingerprint(pricing.priorityOutputCostPerToken),
                self.optionalPricingFingerprint(pricing.priorityCacheReadInputCostPerToken),
                self.optionalPricingFingerprint(pricing.priorityCacheWriteInputCostPerToken),
                self.optionalPricingFingerprint(self.codexAPIFastMultiplier(model: model)),
                "fastLongContext=\(self.codexAPIFastAllowsLongContext(model: model))",
            ].joined(separator: "|"))
        }
        return parts.joined(separator: "\n")
    }

    private static func optionalPricingFingerprint(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%.17g", value)
    }

    private static let claude: [String: ClaudePricing] = [
        // https://platform.claude.com/docs/en/about-claude/pricing (2026-10-04).
        "claude-fable-5-1": ClaudePricing(
            inputCostPerToken: 1e-05,
            outputCostPerToken: 5e-05,
            cacheCreationInputCostPerToken: 1.25e-05,
            cacheReadInputCostPerToken: 2.5e-07,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-5-5": ClaudePricing(
            inputCostPerToken: 4e-06,
            outputCostPerToken: 2e-05,
            cacheCreationInputCostPerToken: 5e-06,
            cacheReadInputCostPerToken: 2e-07,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-5-5": ClaudePricing(
            inputCostPerToken: 2e-06,
            outputCostPerToken: 1e-05,
            cacheCreationInputCostPerToken: 2.5e-06,
            cacheReadInputCostPerToken: 2e-07,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-5": ClaudePricing(
            inputCostPerToken: 5e-06,
            outputCostPerToken: 2.5e-05,
            cacheCreationInputCostPerToken: 6.25e-06,
            cacheReadInputCostPerToken: 5e-07,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-5": ClaudePricing(
            inputCostPerToken: 2e-06,
            outputCostPerToken: 1e-05,
            cacheCreationInputCostPerToken: 2.5e-06,
            cacheReadInputCostPerToken: 2e-07,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-fable-5": ClaudePricing(
            inputCostPerToken: 1e-5,
            outputCostPerToken: 5e-5,
            cacheCreationInputCostPerToken: 1.25e-5,
            cacheReadInputCostPerToken: 1e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5-20251001": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-haiku-4-5": ClaudePricing(
            inputCostPerToken: 1e-6,
            outputCostPerToken: 5e-6,
            cacheCreationInputCostPerToken: 1.25e-6,
            cacheReadInputCostPerToken: 1e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-mythos-5": ClaudePricing(
            inputCostPerToken: 1e-5,
            outputCostPerToken: 5e-5,
            cacheCreationInputCostPerToken: 1.25e-5,
            cacheReadInputCostPerToken: 1e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-mythos-5-1": ClaudePricing(
            inputCostPerToken: 1e-5,
            outputCostPerToken: 5e-5,
            cacheCreationInputCostPerToken: 1.25e-5,
            cacheReadInputCostPerToken: 2.5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-mythos-5-2": ClaudePricing(
            inputCostPerToken: 8e-6,
            outputCostPerToken: 4e-5,
            cacheCreationInputCostPerToken: 1e-5,
            cacheReadInputCostPerToken: 2e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5-20251101": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-5": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6-20260205": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-6": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-7": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-8": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-sonnet-4-6": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-5-20250929": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
        "claude-opus-4-20250514": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-opus-4-1": ClaudePricing(
            inputCostPerToken: 1.5e-5,
            outputCostPerToken: 7.5e-5,
            cacheCreationInputCostPerToken: 1.875e-5,
            cacheReadInputCostPerToken: 1.5e-6,
            thresholdTokens: nil,
            inputCostPerTokenAboveThreshold: nil,
            outputCostPerTokenAboveThreshold: nil,
            cacheCreationInputCostPerTokenAboveThreshold: nil,
            cacheReadInputCostPerTokenAboveThreshold: nil),
        "claude-sonnet-4-20250514": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
    ]

    private static let claudeFullContextStandardPricingCutoff = Date(timeIntervalSince1970: 1_773_360_000)
    private static let claudeHistoricalLongContext: [String: ClaudePricing] = [
        "claude-opus-4-6": ClaudePricing(
            inputCostPerToken: 5e-6,
            outputCostPerToken: 2.5e-5,
            cacheCreationInputCostPerToken: 6.25e-6,
            cacheReadInputCostPerToken: 5e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 1e-5,
            outputCostPerTokenAboveThreshold: 3.75e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 1.25e-5,
            cacheReadInputCostPerTokenAboveThreshold: 1e-6),
        "claude-sonnet-4-6": ClaudePricing(
            inputCostPerToken: 3e-6,
            outputCostPerToken: 1.5e-5,
            cacheCreationInputCostPerToken: 3.75e-6,
            cacheReadInputCostPerToken: 3e-7,
            thresholdTokens: 200_000,
            inputCostPerTokenAboveThreshold: 6e-6,
            outputCostPerTokenAboveThreshold: 2.25e-5,
            cacheCreationInputCostPerTokenAboveThreshold: 7.5e-6,
            cacheReadInputCostPerTokenAboveThreshold: 6e-7),
    ]

    private static let codexModelsDevProviderID = "openai"
    private static let claudeModelsDevProviderID = "anthropic"

    static func normalizeCodexModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = trimmed.lastIndex(of: "/") {
            trimmed = String(trimmed[trimmed.index(after: slash)...])
        }

        // OpenAI model aliases.
        if trimmed == "gpt-5.6" || trimmed == "gpt-daybreak-blue-latest" {
            return "gpt-5.6-sol"
        }
        if trimmed == "gpt-reserve" {
            return "gpt-5.6-luna"
        }
        if trimmed == "gpt-daybreak-red-latest" {
            return "gpt-5.6-cyber"
        }

        if self.codex[trimmed] != nil {
            return trimmed
        }

        if let datedSuffix = trimmed.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if self.codex[base] != nil {
                return base
            }
        }
        return trimmed
    }

    static func isCodexUnattributedModel(_ raw: String) -> Bool {
        self.normalizeCodexModel(raw) == self.codexUnattributedModel
    }

    static func codexDisplayLabel(model: String) -> String? {
        let key = self.normalizeCodexModel(model)
        return self.codex[key]?.displayLabel
    }

    static func normalizeClaudeModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("anthropic.") {
            trimmed = String(trimmed.dropFirst("anthropic.".count))
        }

        if let lastDot = trimmed.lastIndex(of: "."),
           trimmed.contains("claude-")
        {
            let tail = String(trimmed[trimmed.index(after: lastDot)...])
            if tail.hasPrefix("claude-") {
                trimmed = tail
            }
        }

        if let vRange = trimmed.range(of: #"-v\d+:\d+$"#, options: .regularExpression) {
            trimmed.removeSubrange(vRange)
        }

        if let baseRange = trimmed.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let base = String(trimmed[..<baseRange.lowerBound])
            if self.claude[base] != nil {
                return base
            }
        }

        return trimmed
    }

    static func codexCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        pricingDate: Date? = nil,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> Double?
    {
        let key = self.normalizeCodexModel(model)
        guard key != self.codexUnattributedModel else { return nil }
        if let historical = self.historicalCodexPricing(model: key, date: pricingDate) {
            return self.codexCostUSD(
                pricing: historical,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                cacheWriteInputTokens: cacheWriteInputTokens,
                outputTokens: outputTokens)
        }
        let modelsDevLookup = self.modelsDevLookup(
            providerID: self.codexModelsDevProviderID,
            model: model,
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
            ?? (model == key ? nil : self.modelsDevLookup(
                providerID: self.codexModelsDevProviderID,
                model: key,
                catalog: modelsDevCatalog,
                cacheRoot: modelsDevCacheRoot))
        if let lookup = modelsDevLookup {
            let bundled = self.codex[key]
            // A missing catalog context block means models.dev has no long-context opinion, so use
            // the bundled tuple. Once the block exists, preserve its omissions and normal fallback
            // semantics instead of filling individual fields from a different pricing source.
            let bundledLongContext = lookup.pricing.thresholdTokens == nil ? bundled : nil
            let cacheReadAboveThreshold = lookup.pricing.cacheReadInputCostPerTokenAboveThreshold
                ?? (lookup.pricing.thresholdTokens != nil
                    ? lookup.pricing.cacheReadInputCostPerToken
                    ?? lookup.pricing.inputCostPerTokenAboveThreshold
                    ?? lookup.pricing.inputCostPerToken
                    : bundledLongContext?.cacheReadInputCostPerTokenAboveThreshold)
            let cacheWriteAboveThreshold = lookup.pricing.cacheCreationInputCostPerTokenAboveThreshold
                ?? (lookup.pricing.thresholdTokens != nil
                    ? lookup.pricing.cacheCreationInputCostPerToken
                    ?? lookup.pricing.inputCostPerTokenAboveThreshold
                    ?? lookup.pricing.inputCostPerToken
                    : bundledLongContext?.cacheWriteInputCostPerTokenAboveThreshold)
            return self.codexCostUSD(
                pricing: lookup.pricing,
                thresholdTokens: bundled?.thresholdTokens ?? lookup.pricing.thresholdTokens,
                inputCostPerTokenAboveThreshold: lookup.pricing.inputCostPerTokenAboveThreshold
                    ?? bundledLongContext?.inputCostPerTokenAboveThreshold,
                outputCostPerTokenAboveThreshold: lookup.pricing.outputCostPerTokenAboveThreshold
                    ?? bundledLongContext?.outputCostPerTokenAboveThreshold,
                cacheReadInputCostPerToken: lookup.pricing.cacheReadInputCostPerToken
                    ?? bundled?.cacheReadInputCostPerToken,
                cacheReadInputCostPerTokenAboveThreshold: cacheReadAboveThreshold,
                cacheWriteInputCostPerToken: lookup.pricing.cacheCreationInputCostPerToken
                    ?? bundled?.cacheWriteInputCostPerToken,
                cacheWriteInputCostPerTokenAboveThreshold: cacheWriteAboveThreshold,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                cacheWriteInputTokens: cacheWriteInputTokens,
                outputTokens: outputTokens)
        }

        guard let pricing = self.codex[key] else { return nil }
        return self.codexCostUSD(
            pricing: pricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens)
    }

    static func codexPriorityCostUSD(
        model: String,
        inputTokens: Int,
        cachedInputTokens: Int = 0,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int,
        pricingDate: Date? = nil) -> Double?
    {
        let key = self.normalizeCodexModel(model)
        guard let pricing = self.historicalCodexPricing(model: key, date: pricingDate) ?? self.codex[key],
              let priorityInputCostPerToken = pricing.priorityInputCostPerToken,
              let priorityOutputCostPerToken = pricing.priorityOutputCostPerToken
        else { return nil }
        if self.modernFastModels.contains(key) {
            // API service_tier=priority is Fast mode. Long-context support began on August 5.
            if max(0, inputTokens) > self.codexPriorityInputTokenLimit,
               let pricingDate, pricingDate < self.fastLongContextCutoff
            {
                return nil
            }
            return self.codexCostUSD(
                pricing: pricing,
                inputTokens: inputTokens,
                cachedInputTokens: cachedInputTokens,
                cacheWriteInputTokens: cacheWriteInputTokens,
                outputTokens: outputTokens) * 2
        }
        if max(0, inputTokens) > self.codexPriorityInputTokenLimit { return nil }

        let priorityPricing = CodexPricing(
            inputCostPerToken: priorityInputCostPerToken,
            outputCostPerToken: priorityOutputCostPerToken,
            cacheReadInputCostPerToken: pricing.priorityCacheReadInputCostPerToken,
            displayLabel: nil,
            cacheWriteInputCostPerToken: pricing.priorityCacheWriteInputCostPerToken)
        return self.codexCostUSD(
            pricing: priorityPricing,
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens)
    }

    static func codexAPIFastMultiplier(model: String) -> Double? {
        switch self.normalizeCodexModel(model) {
        case "gpt-5.4", "gpt-5.4-mini", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna": 2
        case "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna": 2
        case "gpt-5.5": 2.5
        default: nil
        }
    }

    private static func codexAPIFastAllowsLongContext(model: String) -> Bool {
        switch self.normalizeCodexModel(model) {
        case "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-sol", "gpt-6-luna": true
        default: false
        }
    }

    private static func codexCostUSD(
        pricing: CodexPricing,
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int) -> Double
    {
        // Codex/OpenAI reports `input_tokens` as the total prompt size, with cached reads as a
        // SUBSET of it. Cache writes (when tracked separately, e.g. Pi) are also a subset of the
        // non-cached remainder. Clamp so tokens are never invented or double-billed.
        let totalInput = max(0, inputTokens)
        let cached = min(max(0, cachedInputTokens), totalInput)
        let remainingAfterCache = totalInput - cached
        let cacheWrite = min(max(0, cacheWriteInputTokens), remainingAfterCache)
        let nonCached = remainingAfterCache - cacheWrite
        let cachedRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken

        let usesLongContextRates = pricing.thresholdTokens.map { totalInput > $0 } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cachedInputRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken ?? inputRate
            : cachedRate
        let cacheWriteRate = usesLongContextRates
            ? pricing.cacheWriteInputCostPerTokenAboveThreshold
            ?? pricing.cacheWriteInputCostPerToken
            ?? inputRate
            : pricing.cacheWriteInputCostPerToken ?? inputRate
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return (Double(nonCached) * inputRate)
            + (Double(cached) * cachedInputRate)
            + (Double(cacheWrite) * cacheWriteRate)
            + (Double(max(0, outputTokens)) * outputRate)
    }

    private static func codexCostUSD(
        pricing: ModelsDevPricingInfo,
        thresholdTokens: Int? = nil,
        inputCostPerTokenAboveThreshold: Double? = nil,
        outputCostPerTokenAboveThreshold: Double? = nil,
        cacheReadInputCostPerToken: Double? = nil,
        cacheReadInputCostPerTokenAboveThreshold: Double? = nil,
        cacheWriteInputCostPerToken: Double? = nil,
        cacheWriteInputCostPerTokenAboveThreshold: Double? = nil,
        inputTokens: Int,
        cachedInputTokens: Int,
        cacheWriteInputTokens: Int = 0,
        outputTokens: Int) -> Double
    {
        self.codexCostUSD(
            pricing: CodexPricing(
                inputCostPerToken: pricing.inputCostPerToken,
                outputCostPerToken: pricing.outputCostPerToken,
                cacheReadInputCostPerToken: cacheReadInputCostPerToken
                    ?? pricing.cacheReadInputCostPerToken,
                displayLabel: nil,
                cacheWriteInputCostPerToken: cacheWriteInputCostPerToken
                    ?? pricing.cacheCreationInputCostPerToken,
                thresholdTokens: thresholdTokens ?? pricing.thresholdTokens,
                inputCostPerTokenAboveThreshold: inputCostPerTokenAboveThreshold
                    ?? pricing.inputCostPerTokenAboveThreshold,
                outputCostPerTokenAboveThreshold: outputCostPerTokenAboveThreshold
                    ?? pricing.outputCostPerTokenAboveThreshold,
                cacheReadInputCostPerTokenAboveThreshold: cacheReadInputCostPerTokenAboveThreshold
                    ?? pricing.cacheReadInputCostPerTokenAboveThreshold,
                cacheWriteInputCostPerTokenAboveThreshold: cacheWriteInputCostPerTokenAboveThreshold
                    ?? pricing.cacheCreationInputCostPerTokenAboveThreshold),
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens)
    }

    static func claudeCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int,
        cacheCreationInputTokens: Int,
        cacheCreationInputTokens1h: Int = 0,
        outputTokens: Int,
        pricingDate: Date? = nil,
        modelsDevCatalog: ModelsDevCatalog? = nil,
        modelsDevCacheRoot: URL? = nil) -> Double?
    {
        let tokens = ClaudeCostTokens(
            input: inputTokens,
            cacheRead: cacheReadInputTokens,
            cacheCreation: cacheCreationInputTokens,
            cacheCreation1h: cacheCreationInputTokens1h,
            output: outputTokens)
        let key = self.normalizeClaudeModel(model)
        if let pricingDate,
           let historicalPricing = self.claudeHistoricalLongContext[key],
           let currentPricing = self.claude[key]
        {
            return self.claudeCostUSD(
                pricing: pricingDate < self.claudeFullContextStandardPricingCutoff
                    ? historicalPricing
                    : currentPricing,
                tokens: tokens)
        }
        if let lookup = self.modelsDevLookup(
            providerID: self.claudeModelsDevProviderID,
            model: model,
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        {
            return self.claudeCostUSD(
                pricing: lookup.pricing,
                tokens: tokens)
        }

        guard let pricing = self.claude[key] else { return nil }
        return self.claudeCostUSD(
            pricing: pricing,
            tokens: tokens)
    }

    private static func claudeCostUSD(
        pricing: ClaudePricing,
        tokens: ClaudeCostTokens) -> Double
    {
        let input = max(0, tokens.input)
        let cacheRead = max(0, tokens.cacheRead)
        let cacheCreationTotal = max(0, tokens.cacheCreation)
        let cacheCreation1h = min(max(0, tokens.cacheCreation1h), cacheCreationTotal)
        let cacheCreation5m = cacheCreationTotal - cacheCreation1h
        let usesLongContextRates = pricing.thresholdTokens.map {
            input + cacheRead + cacheCreationTotal > $0
        } ?? false
        let inputRate = usesLongContextRates
            ? pricing.inputCostPerTokenAboveThreshold ?? pricing.inputCostPerToken
            : pricing.inputCostPerToken
        let cacheReadRate = usesLongContextRates
            ? pricing.cacheReadInputCostPerTokenAboveThreshold ?? pricing.cacheReadInputCostPerToken
            : pricing.cacheReadInputCostPerToken
        let cacheCreation5mRate = usesLongContextRates
            ? pricing.cacheCreationInputCostPerTokenAboveThreshold ?? pricing.cacheCreationInputCostPerToken
            : pricing.cacheCreationInputCostPerToken
        let outputRate = usesLongContextRates
            ? pricing.outputCostPerTokenAboveThreshold ?? pricing.outputCostPerToken
            : pricing.outputCostPerToken

        return Double(input) * inputRate
            + Double(cacheRead) * cacheReadRate
            + Double(cacheCreation5m) * cacheCreation5mRate
            + Double(cacheCreation1h) * inputRate * 2
            + Double(max(0, tokens.output)) * outputRate
    }

    private static func claudeCostUSD(
        pricing: ModelsDevPricingInfo,
        tokens: ClaudeCostTokens) -> Double
    {
        self.claudeCostUSD(
            pricing: ClaudePricing(
                inputCostPerToken: pricing.inputCostPerToken,
                outputCostPerToken: pricing.outputCostPerToken,
                cacheCreationInputCostPerToken: pricing.cacheCreationInputCostPerToken ?? pricing.inputCostPerToken,
                cacheReadInputCostPerToken: pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken,
                thresholdTokens: pricing.thresholdTokens,
                inputCostPerTokenAboveThreshold: pricing.inputCostPerTokenAboveThreshold,
                outputCostPerTokenAboveThreshold: pricing.outputCostPerTokenAboveThreshold,
                cacheCreationInputCostPerTokenAboveThreshold: pricing.cacheCreationInputCostPerTokenAboveThreshold,
                cacheReadInputCostPerTokenAboveThreshold: pricing.cacheReadInputCostPerTokenAboveThreshold),
            tokens: tokens)
    }

    static func modelsDevCatalog(now: Date = Date(), cacheRoot: URL? = nil) -> ModelsDevCatalog? {
        ModelsDevCache.load(now: now, cacheRoot: cacheRoot).artifact?.catalog
    }

    private static func modelsDevLookup(
        providerID: String,
        model: String,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> ModelsDevPricingLookup?
    {
        if let catalog {
            return catalog.pricing(providerID: providerID, modelID: model)
        }

        return ModelsDevPricingPipeline.lookup(
            providerID: providerID,
            modelID: model,
            cacheRoot: cacheRoot)
    }
}
