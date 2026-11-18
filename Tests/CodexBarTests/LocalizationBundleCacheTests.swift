import Foundation
import Testing
@testable import CodexBar

/// Regression coverage for the localized-bundle caching added for #1347.
///
/// The cache is process-global and these tests run in a parallel suite, so identity (`===`) assertions
/// would race against any other test that resolves a different language. Instead these assert the
/// concurrency-safe property that matters for correctness: every call resolves to the right `.lproj`
/// regardless of what is currently cached, so a language switch (and switch-back) is always honored and
/// the cache can never serve a stale localization.
struct LocalizationBundleCacheTests {
    @Test(arguments: ["zh", "zh-CN", "zh-Hant", "zh-HK"])
    func `every Chinese preference resolves to Simplified Chinese`(language: String) {
        resetCodexBarLocalizationCacheForTesting()

        let bundle = CodexBarLocalizationOverride.$appLanguage.withValue(language) {
            codexBarLocalizedBundleForTesting()
        }
        #expect(bundle.bundleURL.lastPathComponent.lowercased() == "zh-hans.lproj")
    }

    @Test(arguments: ["de", "fr", "ja", "zz-unknown"])
    func `every non Chinese unsupported preference resolves to English`(language: String) {
        resetCodexBarLocalizationCacheForTesting()

        let bundle = CodexBarLocalizationOverride.$appLanguage.withValue(language) {
            codexBarLocalizedBundleForTesting()
        }
        #expect(bundle.bundleURL.lastPathComponent == "en.lproj")
    }

    @Test
    func `resolves the correct lproj per language and re-resolves on switch`() {
        resetCodexBarLocalizationCacheForTesting()

        let chinese = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(chinese.bundleURL.lastPathComponent.lowercased() == "zh-hans.lproj")

        // Switching language must re-resolve rather than return the cached Chinese bundle.
        let english = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(english.bundleURL.lastPathComponent == "en.lproj")

        // Switching back must still produce the Chinese bundle (cache key is the language).
        let chineseAgain = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(chineseAgain.bundleURL.lastPathComponent.lowercased() == "zh-hans.lproj")
    }

    @Test
    func `repeated same-language calls keep resolving the same lproj`() {
        resetCodexBarLocalizationCacheForTesting()

        for _ in 0..<5 {
            let bundle = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
                codexBarLocalizedBundleForTesting()
            }
            #expect(bundle.bundleURL.lastPathComponent.lowercased() == "zh-hans.lproj")
        }
    }

    @Test
    func `unknown language falls back to en lproj`() {
        resetCodexBarLocalizationCacheForTesting()

        let bundle = CodexBarLocalizationOverride.$appLanguage.withValue("zz-unknown") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(bundle.bundleURL.lastPathComponent == "en.lproj")
    }

    @Test
    func `format locale follows the resolved resource bundle`() {
        let english = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            codexBarLocalizedResourceLocale()
        }
        #expect(english.language.languageCode?.identifier == "en")

        let fallback = CodexBarLocalizationOverride.$appLanguage.withValue("zz-unknown") {
            codexBarLocalizedResourceLocale()
        }
        #expect(fallback.language.languageCode?.identifier == "en")
    }

    @Test
    func `resource locale expands English stringsdict singular forms`() {
        let rendered = CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            String(
                format: L("≈%d full 5h windows of weekly left · %d windows until reset"),
                locale: codexBarLocalizedResourceLocale(),
                arguments: [1, 1])
        }

        #expect(rendered == "≈1 full 5h window of weekly left · 1 window until reset")
    }

    @Test
    func `resolution survives an explicit cache reset`() {
        let first = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(first.bundleURL.lastPathComponent.lowercased() == "zh-hans.lproj")

        resetCodexBarLocalizationCacheForTesting()

        let afterReset = CodexBarLocalizationOverride.$appLanguage.withValue("zh-Hans") {
            codexBarLocalizedBundleForTesting()
        }
        #expect(afterReset.bundleURL.lastPathComponent.lowercased() == "zh-hans.lproj")
    }
}
