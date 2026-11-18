import Foundation
import Testing

struct LocalizationParityTests {
    @Test
    func `English and Simplified Chinese key sets match exactly`() throws {
        let englishKeys = Set(try Self.catalog("en").keys)
        let chineseKeys = Set(try Self.catalog("zh-Hans").keys)
        let missingFromChinese = englishKeys.subtracting(chineseKeys).sorted()
        let missingFromEnglish = chineseKeys.subtracting(englishKeys).sorted()

        #expect(
            missingFromChinese.isEmpty,
            "Keys missing from zh-Hans: \(Self.formatted(missingFromChinese))")
        #expect(
            missingFromEnglish.isEmpty,
            "Keys missing from en: \(Self.formatted(missingFromEnglish))")
    }

    @Test
    func `supported catalogs contain no blank values or translation placeholders`() throws {
        for locale in ["en", "zh-Hans"] {
            let catalog = try Self.catalog(locale)
            let blankKeys = catalog.compactMap { key, value in
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? key : nil
            }.sorted()
            let placeholderKeys = catalog.compactMap { key, value in
                Self.isTranslationPlaceholder(value) ? key : nil
            }.sorted()

            #expect(blankKeys.isEmpty, "Blank values in \(locale): \(Self.formatted(blankKeys))")
            #expect(
                placeholderKeys.isEmpty,
                "Translation placeholders in \(locale): \(Self.formatted(placeholderKeys))")
        }
    }

    @Test
    func `format placeholder argument positions and types match`() throws {
        let english = try Self.catalog("en")
        let chinese = try Self.catalog("zh-Hans")
        let sharedKeys = Set(english.keys).intersection(chinese.keys).sorted()
        let mismatches = sharedKeys.compactMap { key -> String? in
            guard let englishValue = english[key], let chineseValue = chinese[key] else { return nil }
            let englishSignature = Self.placeholderSignature(in: englishValue)
            let chineseSignature = Self.placeholderSignature(in: chineseValue)
            guard englishSignature != chineseSignature else { return nil }
            return "\(key): en=\(englishSignature), zh-Hans=\(chineseSignature)"
        }

        #expect(
            mismatches.isEmpty,
            "Format placeholder mismatches:\n\(mismatches.joined(separator: "\n"))")
    }

    @Test
    func `parity diagnostics expose both key set differences`() {
        let englishKeys: Set<String> = ["shared", "english_only"]
        let chineseKeys: Set<String> = ["shared", "chinese_only"]

        #expect(englishKeys.subtracting(chineseKeys).sorted() == ["english_only"])
        #expect(chineseKeys.subtracting(englishKeys).sorted() == ["chinese_only"])
    }

    @Test
    func `placeholder signatures allow safe positional reordering`() {
        #expect(
            Self.placeholderSignature(in: "%@ · %d") ==
                Self.placeholderSignature(in: "%2$d · %1$@"))
        #expect(
            Self.placeholderSignature(in: "%@ · %d") !=
                Self.placeholderSignature(in: "%1$d · %2$@"))
    }

    private struct Placeholder: Equatable, CustomStringConvertible {
        let argument: Int
        let type: Character

        var description: String {
            "\(self.argument):\(self.type)"
        }
    }

    private static let resourcesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/CodexBar/Resources")

    private static func catalog(_ locale: String) throws -> [String: String] {
        let url = self.resourcesURL.appendingPathComponent("\(locale).lproj/Localizable.strings")
        return try #require(
            NSDictionary(contentsOf: url) as? [String: String],
            "Failed to read localization catalog at \(url.path)")
    }

    private static func placeholderSignature(in value: String) -> [Placeholder] {
        let escapedPercentsRemoved = value.replacingOccurrences(of: "%%", with: "")
        guard let regex = try? NSRegularExpression(
            pattern: "%(?:(\\d+)\\$)?(?:\\.\\d+)?([@df])")
        else {
            return []
        }
        let range = NSRange(escapedPercentsRemoved.startIndex..., in: escapedPercentsRemoved)
        var implicitArgument = 1
        let placeholders = regex.matches(in: escapedPercentsRemoved, range: range).compactMap { match -> Placeholder? in
            guard let typeRange = Range(match.range(at: 2), in: escapedPercentsRemoved),
                  let type = escapedPercentsRemoved[typeRange].first
            else {
                return nil
            }
            let argument: Int
            if let explicitRange = Range(match.range(at: 1), in: escapedPercentsRemoved),
               let explicit = Int(escapedPercentsRemoved[explicitRange])
            {
                argument = explicit
            } else {
                argument = implicitArgument
                implicitArgument += 1
            }
            return Placeholder(argument: argument, type: type)
        }
        return placeholders.sorted {
            ($0.argument, String($0.type)) < ($1.argument, String($1.type))
        }
    }

    private static func isTranslationPlaceholder(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("<#"), normalized.hasSuffix("#>") {
            return true
        }
        let markers = [
            "__missing__",
            "__todo__",
            "missing translation",
            "tbd",
            "todo",
            "translate me",
            "translation needed",
            "untranslated",
        ]
        return markers.contains(normalized)
    }

    private static func formatted(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.joined(separator: ", ")
    }
}
