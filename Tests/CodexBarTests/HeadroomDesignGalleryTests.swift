#if DEBUG
import AppKit
import SwiftUI
import Testing
@testable import CodexBar

@Suite("M1 Headroom Design Gallery")
struct HeadroomDesignGalleryTests {
    @Test
    func `catalog contains every popup card in every required state`() {
        let entries = HeadroomDesignGalleryCatalog.entries

        #expect(HeadroomDesignGalleryCardKind.allCases.count == 3)
        #expect(HeadroomDesignGalleryState.allCases.count == 5)
        #expect(entries.count == 15)
        #expect(Set(entries.map(\.id)).count == entries.count)
        for kind in HeadroomDesignGalleryCardKind.allCases {
            #expect(entries.filter { $0.kind == kind }.map(\.state) == HeadroomDesignGalleryState.allCases)
        }
    }

    @Test
    func `gallery reads the checked in M0 usage baseline`() throws {
        let baseline = try HeadroomDesignGalleryBaseline.load()

        #expect(HeadroomDesignGalleryBaseline.sourceURL.lastPathComponent == "usage_baseline.json")
        #expect(baseline.officialAccounts.map(\.id) == ["official_a", "official_b"])
        #expect(baseline.relays.map(\.id) == ["relay_x", "relay_y"])
        #expect(baseline.total(for: .rolling24Hours) == 2750)
        #expect(baseline.officialAccounts[0].window(for: .rolling24Hours)?.localTokens == 1200)
        #expect(baseline.relays[0].window(for: .rolling24Hours)?.reportedTokens == 750)
    }

    @Test
    func `all gallery states build each production popup card model`() throws {
        let baseline = try HeadroomDesignGalleryBaseline.load()

        for state in HeadroomDesignGalleryState.allCases {
            let provider = HeadroomDesignGalleryModels.provider(state: state, baseline: baseline)
            let account = HeadroomDesignGalleryModels.officialAccount(state: state, baseline: baseline)
            let relay = HeadroomDesignGalleryModels.relay(state: state, baseline: baseline)

            #expect(provider.provider == .codex)
            #expect(!account.email.isEmpty)
            #expect(!relay.name.isEmpty)
        }

        let multiAccount = HeadroomDesignGalleryModels.officialAccount(state: .multiAccount, baseline: baseline)
        let accountWithResetCredits = HeadroomDesignGalleryModels.officialAccount(state: .longCopy, baseline: baseline)
        let multiRelay = HeadroomDesignGalleryModels.relay(state: .multiAccount, baseline: baseline)
        #expect(multiAccount.ordinal == 2)
        #expect(multiAccount.email.contains("official_b"))
        #expect(accountWithResetCredits.resetCredits?.items.count == 2)
        #expect(multiAccount.resetCredits == nil)
        #expect(multiRelay.profileOptions.count == 2)
    }

    @Test @MainActor
    func `gallery window hosts the complete fixture catalog`() throws {
        let baseline = try HeadroomDesignGalleryBaseline.load()
        let controller = HeadroomDesignGalleryWindowController(baseline: baseline)
        let window = try #require(controller.window)
        let requiredGridWidth = HeadroomDesignGalleryLayout.rowLabelWidth
            + HeadroomDesignGalleryLayout.cardWidth * CGFloat(HeadroomDesignGalleryState.allCases.count)
            + HeadroomDesignGalleryLayout.columnSpacing * CGFloat(HeadroomDesignGalleryState.allCases.count)
            + HeadroomDesignGalleryLayout.contentPadding * 2

        #expect(HeadroomDesignGalleryLayout.windowContentSize.width == requiredGridWidth)
        #expect(window.contentMinSize == HeadroomDesignGalleryLayout.windowContentSize)
        #expect(window.contentViewController is NSHostingController<HeadroomDesignGalleryView>)
        #expect(HeadroomDesignGalleryCatalog.resetCreditEntries.count == 2)
        #expect(window.styleMask.contains(.resizable))
        #expect(window.title == L("design_gallery_title"))
    }
}
#endif
