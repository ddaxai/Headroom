import Testing
@testable import CodexBarCore

@Suite("M5 S4 local meter token estimator")
struct LocalMeterTokenEstimatorTests {
    private struct BenchmarkSample {
        let name: String
        let text: String
        let reportedTokens: Int
    }

    /// Fixed GPT-5.x / O1/3 counts captured from OpenAI's public Tokenizer on 2026-08-24.
    private static let benchmarkSamples = [
        BenchmarkSample(
            name: "long English word",
            text: "antidisestablishmentarianism",
            reportedTokens: 6),
        BenchmarkSample(
            name: "spaced arithmetic",
            text: "2 + 2 = 4",
            reportedTokens: 7),
        BenchmarkSample(
            name: "Japanese",
            text: "お誕生日おめでとう",
            reportedTokens: 8),
        BenchmarkSample(
            name: "English sentence",
            text: "The quick brown fox jumps over the lazy dog.",
            reportedTokens: 10),
        BenchmarkSample(
            name: "Swift source",
            text: "let total = items.reduce(0) { $0 + $1.count }",
            reportedTokens: 16),
        BenchmarkSample(
            name: "compact JSON",
            text: #"{"status":"ok","items":[1,2,3]}"#,
            reportedTokens: 13),
        BenchmarkSample(
            name: "Simplified Chinese",
            text: "请总结这段代码并指出潜在的并发问题。",
            reportedTokens: 14),
        BenchmarkSample(
            name: "provider prose",
            text: "Local meter estimates tokens; provider usage remains authoritative.",
            reportedTokens: 10),
    ]

    /// This dependency-free heuristic is deliberately approximate. Keep the ceiling explicit:
    /// changing the estimator or benchmark corpus must not silently make accuracy worse.
    private static let maximumRelativeError = 0.30

    @Test
    func `fixed official benchmark stays within the hard error ceiling`() {
        for sample in Self.benchmarkSamples {
            let estimate = LocalMeterTokenEstimator.estimate(sample.text)
            let error = abs(Double(estimate.tokens - sample.reportedTokens))
                / Double(sample.reportedTokens)

            #expect(estimate.provenance == .localEstimated)
            #expect(
                error <= Self.maximumRelativeError,
                "\(sample.name): estimated \(estimate.tokens), reported \(sample.reportedTokens), error \(error)")
        }
    }

    @Test
    func `empty content estimates zero without claiming provider authority`() {
        let estimate = LocalMeterTokenEstimator.estimate("")

        #expect(estimate.tokens == 0)
        #expect(estimate.provenance == .localEstimated)
        #expect(estimate.strategy == "unicode-heuristic-v1")
    }
}
