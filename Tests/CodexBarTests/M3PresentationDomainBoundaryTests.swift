import Foundation
import Testing
@testable import CodexBar

struct M3PresentationDomainBoundaryTests {
    @Test
    func `presentation has no direct UsageStore references`() throws {
        let references = try Self.presentationUsageStoreReferences()
        let violations = Set(references.map(\.typeName)).sorted()

        #expect(
            violations.isEmpty,
            Comment(rawValue:
                "Presentation types must depend on the presentation domain instead of UsageStore:\n" +
                    violations.joined(separator: "\n")))
    }

    @Test
    func `presentation account and route operations use domain interfaces`() throws {
        let violations = try Self.presentationLines().compactMap { scopedLine -> String? in
            let trimmed = scopedLine.line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return nil }
            guard Self.forbiddenPresentationDomainBypasses.contains(where: { trimmed.contains($0) }) else {
                return nil
            }
            return "\(scopedLine.relativePath):\(scopedLine.line.number)|\(trimmed)"
        }.sorted()

        #expect(
            violations.isEmpty,
            Comment(rawValue:
                "Presentation code must route account and relay mutations through domain interfaces:\n" +
                    violations.joined(separator: "\n")))
    }

    private struct UsageStoreReference {
        let typeName: String
    }

    private struct TypeScope {
        let name: String
        let bodyDepth: Int
        let isPresentation: Bool
    }

    private struct SourceLine {
        let number: Int
        let text: String
    }

    private struct PresentationSource {
        let relativePath: String
        let lines: [SourceLine]
    }

    private struct ScopedPresentationLine {
        let relativePath: String
        let typeName: String
        let line: SourceLine
    }

    private static let forbiddenPresentationDomainBypasses = [
        ".selectCodexVisibleAccount(",
        ".selectDisplayedCodexVisibleAccount(",
        ".selectAuthenticatedManagedCodexAccount(",
        ".prepareCodexAccountScopedRefreshIfNeeded(",
        ".refreshCodexAccountScopedState(",
        ".loadProfiles(",
        ".applyProfile(",
    ]

    private static let repositoryURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func presentationUsageStoreReferences() throws -> [UsageStoreReference] {
        try self.presentationLines().compactMap { scopedLine in
            let trimmed = scopedLine.line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"),
                  trimmed.range(of: #"\bUsageStore\b"#, options: .regularExpression) != nil
            else {
                return nil
            }
            return UsageStoreReference(typeName: scopedLine.typeName)
        }
    }

    private static func presentationLines() throws -> [ScopedPresentationLine] {
        let sources = try self.presentationSources()
        let presentationTypes = self.presentationTypeNames(in: sources)
        return sources.flatMap { source -> [ScopedPresentationLine] in
            var braceDepth = 0
            var scopes: [TypeScope] = []
            var pendingDeclaration: (name: String, isPresentation: Bool)?
            var scopedLines: [ScopedPresentationLine] = []
            for line in source.lines {
                if let declaration = self.typeDeclaration(in: line.text) {
                    pendingDeclaration = (
                        declaration.name,
                        presentationTypes.contains(declaration.name))
                }
                let openingBraces = line.text.count(where: { $0 == "{" })
                let closingBraces = line.text.count(where: { $0 == "}" })
                if openingBraces > 0, let declaration = pendingDeclaration {
                    scopes.append(TypeScope(
                        name: declaration.name,
                        bodyDepth: braceDepth + 1,
                        isPresentation: declaration.isPresentation))
                    pendingDeclaration = nil
                }
                if let currentType = scopes.last(where: \.isPresentation)?.name {
                    scopedLines.append(ScopedPresentationLine(
                        relativePath: source.relativePath,
                        typeName: currentType,
                        line: line))
                }
                braceDepth += openingBraces - closingBraces
                scopes.removeAll { $0.bodyDepth > braceDepth }
            }
            return scopedLines
        }
    }

    private static func presentationSources() throws -> [PresentationSource] {
        let sources = try self.allSources()
        let presentationTypes = self.presentationTypeNames(in: sources)
        return sources.filter { source in
            source.lines.contains { line in
                self.typeDeclaration(in: line.text).map { presentationTypes.contains($0.name) } == true
            }
        }
    }

    private static func allSources() throws -> [PresentationSource] {
        let sourceRoot = self.repositoryURL.appendingPathComponent("Sources/CodexBar", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))
        return try enumerator.compactMap { item -> PresentationSource? in
            guard let fileURL = item as? URL, fileURL.pathExtension == "swift" else { return nil }
            let text = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .map { SourceLine(number: $0.offset + 1, text: String($0.element)) }
            return PresentationSource(
                relativePath: fileURL.path.replacingOccurrences(
                    of: self.repositoryURL.path + "/",
                    with: ""),
                lines: lines)
        }
    }

    private static func presentationTypeNames(in sources: [PresentationSource]) -> Set<String> {
        Set(sources.flatMap { source in
            source.lines.compactMap { line in
                self.typeDeclaration(in: line.text).flatMap { declaration in
                    if declaration.isPresentation {
                        return declaration.name
                    }
                    let isSharedProviderContext = source.relativePath
                        .hasPrefix("Sources/CodexBar/Providers/Shared/")
                        && declaration.name.hasPrefix("Provider")
                        && declaration.name.hasSuffix("Context")
                    return isSharedProviderContext ? declaration.name : nil
                }
            }
        })
    }

    private static func typeDeclaration(in line: String) -> (name: String, isPresentation: Bool)? {
        let pattern = #"^\s*(?:(?:private|fileprivate|internal|public)\s+)?(?:final\s+)?(?:struct|class|enum|extension)\s+([A-Za-z_][A-Za-z0-9_]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let nameRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        let name = String(line[nameRange])
        let presentationProtocols = [
            ": View", ": App", "NSViewRepresentable", "NSApplicationDelegate", "NSMenuDelegate",
            "NSViewController", "NSWindowController", "NSTitlebarAccessoryViewController", ": NSView",
        ]
        let presentationGlue = name == "StatusItemController"
            || name == "MenuDescriptor"
            || name == "RelayQuickSwitchCoordinator"
            || name == "RelaySettingsModel"
            || name == "SpendDashboardController"
            || name == "ProvidersPaneTestHarness"
        return (name, presentationGlue || presentationProtocols.contains(where: line.contains))
    }
}
