import Foundation

public enum LocalMeterTokenProvenance: String, Codable, Sendable {
    case localEstimated = "local_estimated"
}

public struct LocalMeterTokenEstimate: Codable, Equatable, Sendable {
    public let tokens: Int
    public let provenance: LocalMeterTokenProvenance
    public let strategy: String

    public init(
        tokens: Int,
        provenance: LocalMeterTokenProvenance = .localEstimated,
        strategy: String = LocalMeterTokenEstimator.strategy)
    {
        self.tokens = max(0, tokens)
        self.provenance = provenance
        self.strategy = strategy
    }
}

/// A deterministic, dependency-free approximation for text-only Local Meter accounting.
///
/// This is intentionally not presented as a provider tokenizer. It uses broad Unicode classes
/// so requests can still be measured offline without adding a tokenizer runtime dependency.
public enum LocalMeterTokenEstimator {
    public static let strategy = "unicode-heuristic-v1"

    private enum ScalarKind: Equatable {
        case asciiWord
        case digit
        case ideograph
        case horizontalWhitespace
        case lineBreak
        case punctuation
        case other
    }

    public static func estimate(_ text: String) -> LocalMeterTokenEstimate {
        var total = 0
        var currentKind: ScalarKind?
        var currentCount = 0

        func flush() {
            guard let currentKind, currentCount > 0 else { return }
            total += Self.estimateRun(kind: currentKind, count: currentCount)
            currentCount = 0
        }

        for scalar in text.unicodeScalars {
            let kind = Self.kind(of: scalar)
            if kind == currentKind {
                currentCount += 1
            } else {
                flush()
                currentKind = kind
                currentCount = 1
            }
        }
        flush()

        return LocalMeterTokenEstimate(tokens: total)
    }

    private static func estimateRun(kind: ScalarKind, count: Int) -> Int {
        switch kind {
        case .asciiWord:
            count <= 20 ? 1 : self.ceilingDivide(count, by: 6)
        case .digit:
            self.ceilingDivide(count, by: 3)
        case .ideograph:
            self.ceilingDivide(count * 3, by: 4)
        case .horizontalWhitespace:
            0
        case .lineBreak:
            max(1, self.ceilingDivide(count, by: 2))
        case .punctuation:
            self.ceilingDivide(count, by: 2)
        case .other:
            count * 2
        }
    }

    private static func kind(of scalar: Unicode.Scalar) -> ScalarKind {
        switch scalar.value {
        case 0x30...0x39:
            .digit
        case 0x41...0x5A, 0x61...0x7A, 0x5F:
            .asciiWord
        case 0x0A, 0x0D:
            .lineBreak
        case 0x09, 0x20:
            .horizontalWhitespace
        case 0x3040...0x30FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xAC00...0xD7AF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            .ideograph
        default:
            if CharacterSet.whitespaces.contains(scalar) {
                .horizontalWhitespace
            } else if CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar)
            {
                .punctuation
            } else if CharacterSet.letters.contains(scalar) {
                .ideograph
            } else {
                .other
            }
        }
    }

    private static func ceilingDivide(_ value: Int, by divisor: Int) -> Int {
        (value + divisor - 1) / divisor
    }
}
