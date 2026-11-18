import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SeventhRoundQ4PresentationTests {
    @Test
    func `single target quick switch uses one provider label without a standalone heading`() {
        let presentation = RelayQuickSwitchPresentation(visibleTargets: [.codex])

        #expect(!presentation.showsStandaloneHeading)
        #expect(presentation.labelMode == .provider("Codex"))
    }

    @Test
    func `overview quick switch preserves one label for every target`() {
        let presentation = RelayQuickSwitchPresentation(
            visibleTargets: RelayTargetApp.headroomManagedTargets)

        #expect(!presentation.showsStandaloneHeading)
        #expect(presentation.labelMode == .targets(["Codex", "OpenCode", "Claude Code", "Grok Build", "Pi Agent"]))
    }

    @Test
    func `quick switch layout keeps fixed feedback actionable blockers and flow wrapping`() {
        let blocked = RelayQuickSwitchPresentation.choice(
            isReady: false,
            blocker: "Please finish this profile in Settings.")

        #expect(RelayQuickSwitchFeedback.height == 32)
        #expect(blocked.isActionable)
        #expect(blocked.helpText == "Please finish this profile in Settings.")
        #expect(RelayQuickSwitchFlowLayout.rowCount(
            itemWidths: [72, 72, 72],
            availableWidth: 224,
            spacing: 4) == 1)
    }

    @Test
    func `account card height fingerprint tracks the optional usage line`() {
        let withoutUsage = MenuCardHeightFingerprint.codexAccountCard(
            baseFingerprint: "same-account-shape",
            usageLine: nil)
        let withUsage = MenuCardHeightFingerprint.codexAccountCard(
            baseFingerprint: "same-account-shape",
            usageLine: "private 24-hour usage")

        #expect(withoutUsage != withUsage)
        #expect(!withUsage.contains("private 24-hour usage"))
    }

    @Test
    func `quick switch height fingerprint tracks scope wrap and load error shapes`() {
        let singleTarget = Self.quickSwitchFingerprint()
        let multipleTargets = Self.quickSwitchFingerprint(visibleTargetCount: 4)
        let wrappedOptions = Self.quickSwitchFingerprint(optionRowCounts: [2])
        let loadError = Self.quickSwitchFingerprint(showsLoadError: true)

        #expect(Set([singleTarget, multipleTargets, wrappedOptions, loadError]).count == 4)
    }

    @Test
    func `stacked codex menu omits duplicate and obsolete visible presentations`() {
        let withRelay = CodexStackedMenuPresentation(hasRelay: true, relayUsageProfileCount: 2)
        let withoutRelay = CodexStackedMenuPresentation(hasRelay: false)

        #expect(withRelay.supplementaryItemIDs == [
            "codexCardGroupStatus",
            "codexRelaySummary",
            "codexStackedTotal",
        ])
        #expect(withoutRelay.supplementaryItemIDs == ["codexCardGroupStatus", "codexStackedTotal"])
        #expect(withRelay.relayCardShowsProviderSwitcher)
        #expect(!CodexStackedMenuPresentation(
            hasRelay: true,
            relayUsageProfileCount: 1).relayCardShowsProviderSwitcher)
        #expect(!withRelay.relayCardProviderSwitcherAffectsHeight)
    }

    private static func quickSwitchFingerprint(
        visibleTargetCount: Int = 1,
        optionRowCounts: [Int] = [1],
        showsLoadError: Bool = false) -> String
    {
        MenuCardHeightFingerprint.relayQuickSwitch(
            baseFingerprint: "same-switch-content",
            visibleTargetCount: visibleTargetCount,
            optionRowCounts: optionRowCounts,
            showsLoadError: showsLoadError)
    }
}
