import AppKit
import CoreText
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct TypographySnapshotTests {
    @Test
    func `typography has one centralized source`() {
        #expect(
            FileManager.default.fileExists(atPath: Self.typographySourceURL.path),
            "HeadroomTypography.swift must own the frozen font and line-height values")
    }

    @Test
    func `typography metrics and Berkeley Mono faces remain frozen`() throws {
        try Self.registerBerkeleyMono()

        let regular = HeadroomTypography.nsMono(11)
        let semibold = HeadroomTypography.nsMono(15, weight: .semibold)
        #expect(regular.fontName == "BerkeleyMono-Regular")
        #expect(regular.pointSize == 11)
        #expect(semibold.fontName == "BerkeleyMono-Bold")
        #expect(semibold.pointSize == 15)
        #expect(HeadroomTypography.menuBarStackedLineHeight == 9.5)
        #expect(HeadroomTypography.menuBarStackedLineSpacing == -1)
        #expect(HeadroomTypography.menuBarStackedBaselineOffset == -3)
        #expect(HeadroomTypography.relayStatusItemBaselineOffset == -1)
    }

    @Test
    func `English typography matches baseline`() throws {
        try self.assertSnapshot(.english)
    }

    @Test
    func `digit typography matches baseline`() throws {
        try self.assertSnapshot(.digits)
    }

    @Test
    func `Simplified Chinese typography matches baseline`() throws {
        try self.assertSnapshot(.simplifiedChinese)
    }

    @Test
    func `mixed typography matches baseline`() throws {
        try self.assertSnapshot(.mixed)
    }

    @Test
    func `legacy direct system font calls remain an exact allowlist`() throws {
        let expected = try Self.inventory(
            from: String(contentsOf: Self.legacyAllowlistURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init))
        let actual = try Self.inventory(from: Self.directSystemFontCalls())
        let unexpected = actual.compactMap { entry, count -> String? in
            let excess = count - expected[entry, default: 0]
            return excess > 0 ? "\(excess)x \(entry)" : nil
        }.sorted()
        let missing = expected.compactMap { entry, count -> String? in
            let deficit = count - actual[entry, default: 0]
            return deficit > 0 ? "\(deficit)x \(entry)" : nil
        }.sorted()

        #expect(
            unexpected.isEmpty,
            "New .font(.system( calls must use HeadroomTypography instead:\n\(unexpected.joined(separator: "\n"))")
        #expect(
            missing.isEmpty,
            "Update the legacy allowlist only when an existing call is intentionally migrated:\n\(missing.joined(separator: "\n"))")
    }

    private func assertSnapshot(_ fixture: TypographySnapshotFixture) throws {
        try Self.registerBerkeleyMono()
        let data = try #require(TypographySnapshotRenderer.pngData(for: fixture))
        let actual = try #require(NSBitmapImageRep(data: data))
        #expect(actual.pixelsWide == 520)
        #expect(actual.pixelsHigh == 150)
        #expect(try Self.distinctRGBCount(in: actual) > 2, "\(fixture.rawValue) rendered as a blank image")

        let baselineURL = Self.snapshotDirectoryURL.appendingPathComponent("\(fixture.rawValue).png")
        if ProcessInfo.processInfo.environment["HEADROOM_RECORD_TYPOGRAPHY_SNAPSHOTS"] == "1" {
            try FileManager.default.createDirectory(
                at: Self.snapshotDirectoryURL,
                withIntermediateDirectories: true)
            try data.write(to: baselineURL, options: .atomic)
            return
        }

        let baselineData = try #require(
            try? Data(contentsOf: baselineURL),
            "Missing typography baseline at \(baselineURL.path)")
        let baseline = try #require(NSBitmapImageRep(data: baselineData))
        #expect(baseline.pixelsWide == actual.pixelsWide)
        #expect(baseline.pixelsHigh == actual.pixelsHigh)
        #expect(
            try Self.rgbaBytes(in: baseline) == Self.rgbaBytes(in: actual),
            "Typography changed for \(fixture.rawValue); do not record a new baseline unless the M0 font contract changed")
    }

    private static let repositoryURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let typographySourceURL = repositoryURL
        .appendingPathComponent("Sources/CodexBar/HeadroomTypography.swift")

    private static let snapshotDirectoryURL = repositoryURL
        .appendingPathComponent("Tests/CodexBarTests/Fixtures/Typography")

    private static let legacyAllowlistURL = snapshotDirectoryURL
        .appendingPathComponent("legacy_system_font_allowlist.txt")

    private static func directSystemFontCalls() throws -> [String] {
        let sourcesURL = self.repositoryURL.appendingPathComponent("Sources")
        let roots = ["CodexBar", "CodexBarWidget"].map(sourcesURL.appendingPathComponent)
        var calls: [String] = []
        for root in roots {
            let enumerator = try #require(FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]))
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let relativePath = fileURL.path.replacingOccurrences(
                    of: self.repositoryURL.path + "/",
                    with: "")
                for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                    guard line.contains(".font(.system(") else { continue }
                    calls.append("\(relativePath)|\(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return calls.sorted()
    }

    private static func inventory(from entries: [String]) throws -> [String: Int] {
        try #require(entries.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        return Dictionary(entries.map { ($0, 1) }, uniquingKeysWith: +)
    }

    static func registerBerkeleyMono() throws {
        let faces = [
            (file: "Berkeley Mono Regular.otf", name: "BerkeleyMono-Regular"),
            (file: "Berkeley Mono Bold.otf", name: "BerkeleyMono-Bold"),
        ]
        let fontDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Fonts")
        for face in faces where NSFont(name: face.name, size: 11) == nil {
            let url = fontDirectory.appendingPathComponent(face.file)
            var error: Unmanaged<CFError>?
            let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            try #require(
                registered || NSFont(name: face.name, size: 11) != nil,
                "Could not register \(face.name) from \(url.path): \(String(describing: error?.takeRetainedValue()))")
        }
    }

    private static func rgbaBytes(in bitmap: NSBitmapImageRep) throws -> Data {
        let converted = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: bitmap.pixelsWide,
            pixelsHigh: bitmap.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: bitmap.pixelsWide * 4,
            bitsPerPixel: 32))
        let context = try #require(NSGraphicsContext(bitmapImageRep: converted))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        bitmap.draw(in: NSRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        let bytes = try #require(converted.bitmapData)
        return Data(bytes: bytes, count: converted.bytesPerRow * converted.pixelsHigh)
    }

    private static func distinctRGBCount(in bitmap: NSBitmapImageRep) throws -> Int {
        var colors: Set<UInt32> = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 5) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 5) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let red = UInt32((color.redComponent * 255).rounded())
                let green = UInt32((color.greenComponent * 255).rounded())
                let blue = UInt32((color.blueComponent * 255).rounded())
                colors.insert((red << 16) | (green << 8) | blue)
            }
        }
        return colors.count
    }
}

private enum TypographySnapshotFixture: String {
    case english = "typo_en"
    case digits = "typo_digits"
    case simplifiedChinese = "typo_zh"
    case mixed = "typo_mixed"
}

@MainActor
private enum TypographySnapshotRenderer {
    static func pngData(for fixture: TypographySnapshotFixture) -> Data? {
        let size = CGSize(width: 520, height: 150)
        let view = NSHostingView(rootView: TypographySnapshotFixtureView(fixture: fixture))
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: representation)
        else {
            return nil
        }
        representation.size = size
        view.displayIgnoringOpacity(view.bounds, in: context)
        return representation.representation(using: .png, properties: [:])
    }
}

private struct TypographySnapshotFixtureView: View {
    let fixture: TypographySnapshotFixture
    private let tokens = ConsolePalette.consoleBlue.tokens

    var body: some View {
        self.content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(20)
            .foregroundStyle(self.tokens.primaryText.color)
            .background(self.tokens.background.color)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch self.fixture {
        case .english:
            VStack(alignment: .leading, spacing: 10) {
                Text("Account Usage")
                    .font(ConsoleDesign.mono(15, weight: .semibold))
                Text("Local tokens remain available for this account.")
                    .font(ConsoleDesign.mono(11))
                    .foregroundStyle(self.tokens.secondaryText.color)
                Text("Open Details")
                    .font(ConsoleDesign.mono(10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .overlay {
                        RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl)
                            .stroke(self.tokens.border.color, lineWidth: 1)
                    }
            }
        case .digits:
            VStack(alignment: .leading, spacing: 8) {
                Text("0123456789")
                Text("1,234,567")
                HStack(spacing: 20) {
                    Text("98.7%")
                    Text("$12.34")
                }
            }
            .font(ConsoleDesign.mono(15, weight: .semibold))
        case .simplifiedChinese:
            VStack(alignment: .leading, spacing: 10) {
                Text("账号用量")
                    .font(ConsoleDesign.text(15, weight: .semibold))
                Text("此账号仍可查看本地用量。")
                    .font(ConsoleDesign.text(11))
                    .foregroundStyle(self.tokens.secondaryText.color)
            }
        case .mixed:
            Text("官方账号 A · 24h 1,234 tokens · 剩 87%")
                .font(ConsoleDesign.mono(11, weight: .medium))
        }
    }
}
