import Foundation
import Testing
@testable import CodexBar

struct LocalizationLanguageCatalogTests {
    @Test
    func `app language catalog exposes only system English and Simplified Chinese`() {
        #expect(AppLanguage.allCases.map(\.rawValue) == ["", "en", "zh-Hans"])
    }

    @Test
    func `system language keeps the empty persisted value`() {
        #expect(AppLanguage.system.rawValue.isEmpty)
    }

    @Test
    func `English language uses the en resource identifier`() {
        #expect(AppLanguage.english.rawValue == "en")
    }

    @Test
    func `Simplified Chinese uses the zh Hans resource identifier`() {
        #expect(AppLanguage.chineseSimplified.rawValue == "zh-Hans")
    }

    @Test
    func `app language identifiers are unique`() {
        #expect(Set(AppLanguage.allCases.map(\.id)).count == AppLanguage.allCases.count)
    }

    @Test
    func `system picker label stays English`() {
        #expect(AppLanguage.system.label == "System")
    }

    @Test
    func `English picker label stays English`() {
        #expect(AppLanguage.english.label == "English")
    }

    @Test
    func `Simplified Chinese picker label uses its native name`() {
        #expect(AppLanguage.chineseSimplified.label == "简体中文")
    }

    @Test
    func `general settings language options mirror the app catalog`() {
        #expect(GeneralSettingsMenuOptions.languages == AppLanguage.allCases.map(\.rawValue))
    }

    @Test
    func `resources contain exactly two localization directories`() throws {
        let directories = try FileManager.default.contentsOfDirectory(
            at: Self.resourcesURL,
            includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
            .map(\.lastPathComponent)
            .sorted()
        #expect(directories == ["en.lproj", "zh-Hans.lproj"])
    }

    @Test
    func `resources contain exactly two strings files`() throws {
        let enumerator = try #require(FileManager.default.enumerator(
            at: Self.resourcesURL,
            includingPropertiesForKeys: nil))
        let stringsFiles = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "strings" }
        #expect(stringsFiles.count == 2)
    }

    @Test
    func `English catalog is readable`() throws {
        #expect(try Self.catalog("en").isEmpty == false)
    }

    @Test
    func `Simplified Chinese catalog is readable`() throws {
        #expect(try Self.catalog("zh-Hans").isEmpty == false)
    }

    @Test
    func `English catalog keeps the full application vocabulary`() throws {
        #expect(try Self.catalog("en").count > 1000)
    }

    @Test
    func `Simplified Chinese catalog keeps the full application vocabulary`() throws {
        #expect(try Self.catalog("zh-Hans").count > 1000)
    }

    @Test
    func `the two supported catalogs currently have matching keys`() throws {
        #expect(try Set(Self.catalog("en").keys) == Set(Self.catalog("zh-Hans").keys))
    }

    @Test
    func `English catalog has no blank values`() throws {
        let blankKeys = try Self.catalog("en")
            .filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #expect(blankKeys.isEmpty)
    }

    @Test
    func `Simplified Chinese catalog has no blank values`() throws {
        let blankKeys = try Self.catalog("zh-Hans")
            .filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #expect(blankKeys.isEmpty)
    }

    @Test
    func `both catalogs include the three language picker labels`() throws {
        let keys = ["language_system", "language_english", "language_chinese_simplified"]
        for locale in ["en", "zh-Hans"] {
            let catalog = try Self.catalog(locale)
            #expect(keys.allSatisfy { catalog[$0]?.isEmpty == false })
        }
    }

    @Test
    func `both catalogs include adaptive activity consent copy`() throws {
        let keys = [
            "refresh_adaptive_agent_aware",
            "adaptive_activity_consent_title",
            "adaptive_activity_consent_message",
            "adaptive_activity_consent_allow",
            "adaptive_activity_consent_decline",
        ]
        for locale in ["en", "zh-Hans"] {
            let catalog = try Self.catalog(locale)
            #expect(keys.allSatisfy { catalog[$0]?.isEmpty == false })
        }
    }

    @Test
    func `both catalogs include model breakdown unavailable copy`() throws {
        for locale in ["en", "zh-Hans"] {
            #expect(try Self.catalog(locale)["Model breakdown unavailable"]?.isEmpty == false)
        }
    }

    @Test
    func `both catalogs include workday pace setting copy`() throws {
        let keys = ["weekly_progress_work_days_title", "weekly_progress_work_days_subtitle"]
        for locale in ["en", "zh-Hans"] {
            let catalog = try Self.catalog(locale)
            #expect(keys.allSatisfy { catalog[$0]?.isEmpty == false })
        }
    }

    @Test
    func `both catalogs include default terminal setting copy`() throws {
        let keys = ["terminal_app_title", "terminal_app_subtitle"]
        for locale in ["en", "zh-Hans"] {
            let catalog = try Self.catalog(locale)
            #expect(keys.allSatisfy { catalog[$0]?.isEmpty == false })
        }
    }

    @Test
    func `quota warning format renders in both supported languages`() throws {
        for locale in ["en", "zh-Hans"] {
            let format = try #require(Self.catalog(locale)["quota_warning_notification_body"])
            let rendered = String(format: format, arguments: ["20%", 15, "weekly"])
            #expect(rendered.contains("20%"))
            #expect(rendered.contains("15%"))
        }
    }

    @Test
    func `Simplified Chinese catalog keeps representative general copy`() throws {
        let catalog = try Self.catalog("zh-Hans")
        #expect(catalog["tab_general"] == "通用")
        #expect(catalog["language_system"] == "跟随系统")
    }

    @Test
    func `Simplified Chinese catalog keeps representative relay copy`() throws {
        #expect(try Self.catalog("zh-Hans")["relay_local_usage_title"] == "本地中转占比")
    }

    @Test
    func `both catalogs retain reset credit copy`() throws {
        for locale in ["en", "zh-Hans"] {
            #expect(try Self.catalog(locale)["Limit Reset Credits"]?.isEmpty == false)
        }
    }

    @Test
    func `system language preserves an external Apple Languages override`() {
        Self.withTemporaryDefaults(for: #function) { defaults, _ in
            defaults.set(["de"], forKey: "AppleLanguages")
            AppLanguagePreferenceMigration.clearLegacyOverrideIfOwned(
                storedAppLanguage: "",
                defaults: defaults)
            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["de"])
        }
    }

    @Test
    func `matching legacy language override is cleared`() {
        Self.withTemporaryDefaults(for: #function) { defaults, suiteName in
            defaults.set(["ja"], forKey: "AppleLanguages")
            AppLanguagePreferenceMigration.clearLegacyOverrideIfOwned(
                storedAppLanguage: "ja",
                defaults: defaults)
            #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil)
        }
    }

    @Test
    func `unrelated external language override is preserved`() {
        Self.withTemporaryDefaults(for: #function) { defaults, _ in
            defaults.set(["de"], forKey: "AppleLanguages")
            AppLanguagePreferenceMigration.clearLegacyOverrideIfOwned(
                storedAppLanguage: "ja",
                defaults: defaults)
            #expect(defaults.stringArray(forKey: "AppleLanguages") == ["de"])
        }
    }

    @Test
    func `removed language codes are no longer valid picker choices`() {
        for code in ["ar", "de", "es", "fr", "ja", "zh-Hant"] {
            #expect(AppLanguage(rawValue: code) == nil)
        }
    }

    private static let resourcesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/CodexBar/Resources")

    private static func catalog(_ locale: String) throws -> [String: String] {
        let url = self.resourcesURL.appendingPathComponent("\(locale).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    private static func withTemporaryDefaults(
        for testName: String,
        _ body: (UserDefaults, String) -> Void)
    {
        let suiteName = "LocalizationLanguageCatalogTests.\(testName).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults, suiteName)
    }
}
