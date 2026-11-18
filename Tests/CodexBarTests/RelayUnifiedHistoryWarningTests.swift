import Foundation
import Testing

struct RelayUnifiedHistoryWarningTests {
    private static let localizationKey = "relay_unified_history_disabled_warning"

    @Test
    func `settings show the localized warning beside unified history`() throws {
        let source = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/CodexBar/PreferencesRelayPane.swift"),
            encoding: .utf8)

        #expect(source.contains("L(\"\(Self.localizationKey)\")"))
        #expect(source.contains(".foregroundStyle(ConsoleDesign.secondaryText)"))
    }

    @Test
    func `warning explains apparent history loss without claiming disk loss`() throws {
        let english = try Self.catalog("en")
        let chinese = try Self.catalog("zh-Hans")

        #expect(
            english[Self.localizationKey] ==
                "Disabling unified history can make the Codex history list look empty, but sessions remain on disk.")
        #expect(
            chinese[Self.localizationKey] ==
                "关闭统一历史会让 Codex 历史列表看起来变空，但磁盘上的会话不会丢失。")
    }

    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func catalog(_ locale: String) throws -> [String: String] {
        let url = self.repositoryRoot.appendingPathComponent(
            "Sources/CodexBar/Resources/\(locale).lproj/Localizable.strings")
        return try #require(
            NSDictionary(contentsOf: url) as? [String: String],
            "Failed to read localization catalog at \(url.path)")
    }
}
