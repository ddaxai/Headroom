import Foundation
import Testing
@testable import CodexBar

/// Guards the settings layout rules that keep controls from moving between panes and keep the
/// relay surfaces fully localized.
struct SettingsLayoutConsistencyTests {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: self.repositoryRoot.appendingPathComponent(relativePath),
            encoding: .utf8)
    }

    @Test
    func `destinations with sub sections share one subsection picker`() throws {
        let files = [
            "Sources/CodexBar/PreferencesView.swift",
            "Sources/CodexBar/PreferencesConsolePanes.swift",
            "Sources/CodexBar/PreferencesAboutPane.swift",
        ]
        for file in files {
            let source = try Self.source(file)
            #expect(source.contains("SettingsSubsectionPicker("), "\(file) should use SettingsSubsectionPicker")
            #expect(
                !source.contains(".pickerStyle(.segmented)"),
                "\(file) builds its own segmented picker; use SettingsSubsectionPicker")
        }
        #expect(SettingsSubsectionMetrics.width == 320)
    }

    @Test
    func `relay surfaces contain no hard coded Chinese copy`() throws {
        let files = [
            "Sources/CodexBar/PreferencesRelayPane.swift",
            "Sources/CodexBar/PreferencesRelayComponents.swift",
            "Sources/CodexBar/RelayQuickSwitchMenu.swift",
        ]
        for file in files {
            let source = try Self.source(file)
            let hanLines = source.split(separator: "\n").filter { line in
                line.unicodeScalars.contains { (UInt32(0x4E00)...UInt32(0x9FFF)).contains($0.value) }
            }
            #expect(hanLines.isEmpty, "\(file) has unlocalized copy: \(hanLines.prefix(3))")
        }
    }

    @Test
    func `relay usage card scrolls inside the editor form`() throws {
        let source = try Self.source("Sources/CodexBar/PreferencesRelayPane.swift")
        let editor = try #require(
            source.split(separator: "private struct RelayProfileEditor: View", maxSplits: 1).last.map(String.init))
        let form = try #require(editor.range(of: "Form {")?.lowerBound)
        let card = try #require(editor.range(of: "RelayUsageSummaryCard(")?.lowerBound)
        #expect(form < card)
    }

    @Test
    func `relay strings resolve in both shipped languages`() {
        #expect(L("relay_ui_section_configuration", language: "en") == "Relay configuration")
        #expect(L("relay_ui_section_configuration", language: "zh-Hans") == "中转站配置")
        #expect(L("relay_menu_label_official", language: "en") == "Official account")
        #expect(L("relay_menu_label_official", language: "zh-Hans") == "官方账号")
    }
}
