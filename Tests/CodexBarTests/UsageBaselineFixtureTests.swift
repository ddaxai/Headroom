import AppKit
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@Suite("M0 usage baseline fixture")
struct UsageBaselineFixtureTests {
    @Test
    func `fixture preserves the five required usage sources`() throws {
        let fixture = try UsageBaselineFixture.load()

        #expect(fixture.schemaVersion == 1)
        #expect(fixture.officialAccounts.map(\.id) == ["official_a", "official_b"])
        #expect(fixture.relays.map(\.id) == ["relay_x", "relay_y"])
        #expect(fixture.unassigned.id == "unassigned")

        let officialA = try #require(fixture.officialAccounts.first { $0.id == "official_a" })
        let officialB = try #require(fixture.officialAccounts.first { $0.id == "official_b" })
        #expect(officialA.isActive)
        #expect(officialA.resetCredits?.count == 2)
        #expect(officialA.resetCredits?.expiresAt == Date(timeIntervalSince1970: 1_791_072_000))
        #expect(!officialB.isActive)
        #expect(officialB.resetCredits == nil)
    }

    @Test
    func `relay usage distinguishes reported values from unavailable values`() throws {
        let fixture = try UsageBaselineFixture.load()
        let relayX = try #require(fixture.relays.first { $0.id == "relay_x" })
        let relayY = try #require(fixture.relays.first { $0.id == "relay_y" })

        #expect(relayX.multiplier == 1.5)
        #expect(relayX.reportsUsage)
        for period in UsageBaselinePeriod.allCases {
            let local = try #require(relayX.localTokens(for: period))
            #expect(relayX.reportedTokens(for: period) == Int(Double(local) * 1.5))
        }

        #expect(relayY.multiplier == nil)
        #expect(!relayY.reportsUsage)
        for period in UsageBaselinePeriod.allCases {
            #expect(relayY.localTokens(for: period) == nil)
            #expect(relayY.reportedTokens(for: period) == nil)
        }
    }

    @Test
    func `official relay and unassigned usage conserves every window`() throws {
        let fixture = try UsageBaselineFixture.load()

        for period in UsageBaselinePeriod.allCases {
            let total = try #require(fixture.totalLocalTokens(for: period))
            #expect(fixture.localSourceSum(for: period) == total, "Usage does not conserve for \(period.rawValue)")

            let chart = try #require(fixture.chart(for: period))
            #expect(chart.rows.map(\.id) == ["official_a", "official_b", "relay_x", "unassigned"])
            #expect(chart.unavailableSourceIDs == ["relay_y"])
            #expect(chart.rows.reduce(0) { $0 + $1.localTokens } == total)
            #expect(chart.totalLocalTokens == total)
        }
    }

    @Test @MainActor
    func `all three baseline windows render nonblank charts`() throws {
        let fixture = try UsageBaselineFixture.load()

        for period in UsageBaselinePeriod.allCases {
            let chart = try #require(fixture.chart(for: period))
            let data = try #require(UsageBaselineChartRenderer.pngData(for: chart))
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == 480)
            #expect(bitmap.pixelsHigh == 220)
            #expect(try Self.distinctRGBCount(in: bitmap) > 2, "\(period.rawValue) rendered as a blank chart")
        }
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

@MainActor
private enum UsageBaselineChartRenderer {
    static func pngData(for chart: UsageBaselineFixture.Chart) -> Data? {
        let size = CGSize(width: 480, height: 220)
        let view = NSHostingView(rootView: UsageBaselineChartFixtureView(chart: chart))
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

private struct UsageBaselineChartFixtureView: View {
    let chart: UsageBaselineFixture.Chart
    private let tokens = ConsolePalette.consoleBlue.tokens

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(self.chart.period.rawValue)
                .font(HeadroomTypography.mono(13, weight: .semibold))
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(self.chart.rows) { row in
                        Rectangle()
                            .fill(self.tokens.accent.color)
                            .frame(maxWidth: .infinity)
                            .frame(height: max(
                                2,
                                geometry.size.height * CGFloat(row.localTokens) /
                                    CGFloat(self.chart.totalLocalTokens)))
                    }
                }
            }
            .frame(height: 140)
        }
        .padding(20)
        .foregroundStyle(self.tokens.primaryText.color)
        .background(self.tokens.background.color)
        .environment(\.colorScheme, .dark)
    }
}
