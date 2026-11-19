import AppKit
import CodexBarCore
import Foundation
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct NinthRoundN4SettingsShellTests {
    @Test
    func `settings controls install once beside traffic lights and survive bridge recreation`() throws {
        let bridge = SettingsWindowAppearanceView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = bridge

        bridge.refreshWindowAppearance(for: .dark, windowTitle: "General", windowAlwaysOnTop: false)
        bridge.refreshWindowAppearance(for: .dark, windowTitle: "Relay", windowAlwaysOnTop: true)

        #expect(window.titlebarAccessoryViewControllers.count == 1)
        let controls = try #require(
            window.titlebarAccessoryViewControllers.first as? SettingsTitlebarControlsController)
        #expect(controls.layoutAttribute == .left)
        #expect(controls.sidebarButton.image?.accessibilityDescription == "Show Sidebar")
        #expect(controls.pinButton.image?.accessibilityDescription == "Pinned")

        bridge.invalidate()
        var replacementPinToggleCount = 0
        let replacement = SettingsWindowAppearanceView(
            onToggleAlwaysOnTop: { replacementPinToggleCount += 1 })
        window.contentView = replacement
        replacement.refreshWindowAppearance(for: .dark, windowTitle: "Relay", windowAlwaysOnTop: true)

        #expect(window.titlebarAccessoryViewControllers.count == 1)
        #expect(window.titlebarAccessoryViewControllers.first === controls)
        controls.pinButton.performClick(nil)
        #expect(replacementPinToggleCount == 1)
    }

    @Test
    func `settings titlebar buttons dispatch sidebar and current pin callbacks`() {
        var sidebarToggleCount = 0
        var firstPinToggleCount = 0
        var replacementPinToggleCount = 0
        let controls = SettingsTitlebarControlsController(
            onToggleSidebar: { sidebarToggleCount += 1 },
            onTogglePin: { firstPinToggleCount += 1 })

        controls.sidebarButton.performClick(nil)
        controls.pinButton.performClick(nil)
        controls.update(isPinned: true, onTogglePin: { replacementPinToggleCount += 1 })
        controls.pinButton.performClick(nil)

        #expect(sidebarToggleCount == 1)
        #expect(firstPinToggleCount == 1)
        #expect(replacementPinToggleCount == 1)
        #expect(controls.pinButton.image?.accessibilityDescription == "Pinned")
    }

    @Test
    func `settings titlebar accessory exposes the full pin button frame`() throws {
        let initialControls = SettingsTitlebarControlsController(
            onToggleSidebar: {},
            onTogglePin: {})
        #expect(initialControls.view.bounds.size == SettingsTitlebarControlsController.contentSize)
        #expect(initialControls.preferredContentSize == SettingsTitlebarControlsController.contentSize)

        let bridge = SettingsWindowAppearanceView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = bridge
        bridge.refreshWindowAppearance(for: .dark, windowTitle: "General", windowAlwaysOnTop: false)

        let controls = try #require(
            window.titlebarAccessoryViewControllers.first as? SettingsTitlebarControlsController)
        controls.view.layoutSubtreeIfNeeded()

        let targets = [
            HeadroomGeometryAssertions.Target(name: "sidebar", view: controls.sidebarButton),
            HeadroomGeometryAssertions.Target(name: "pin", view: controls.pinButton),
        ]
        let failures = HeadroomGeometryAssertions.failures(root: controls.view, targets: targets)

        let frames = targets.map { "\($0.name)=\($0.view.convert($0.view.bounds, to: controls.view))" }
        #expect(
            failures.isEmpty,
            "Settings titlebar geometry failures: \(failures); root=\(controls.view.bounds); \(frames)")
        #expect(controls.layoutAttribute == .left)
        #expect(controls.view.bounds.width == SettingsTitlebarControlsController.contentSize.width)
        #expect(controls.preferredContentSize == SettingsTitlebarControlsController.contentSize)
        #expect(Self.hasRequiredDimension(controls.sidebarButton, attribute: .width, constant: 24))
        #expect(Self.hasRequiredDimension(controls.sidebarButton, attribute: .height, constant: 22))
        #expect(Self.hasRequiredDimension(controls.pinButton, attribute: .width, constant: 24))
        #expect(Self.hasRequiredDimension(controls.pinButton, attribute: .height, constant: 22))
    }

    @Test
    func `geometry assertions detect the historical zero width negative x titlebar layout`() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: 32))
        let sidebar = NSButton(frame: NSRect(x: -52, y: 5, width: 24, height: 22))
        let pin = NSButton(frame: NSRect(x: -26, y: 5, width: 24, height: 22))
        root.addSubview(sidebar)
        root.addSubview(pin)

        let failures = HeadroomGeometryAssertions.failures(
            root: root,
            targets: [
                .init(name: "sidebar", view: sidebar),
                .init(name: "pin", view: pin),
            ])

        #expect(failures.contains(.emptyRootBounds))
        #expect(failures.contains(.outsideRoot("sidebar")))
        #expect(failures.contains(.outsideRoot("pin")))
    }

    @Test
    nonisolated func `settings shell uses responder chain sidebar toggle and no SwiftUI toolbar`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesView.swift"),
            encoding: .utf8)

        #expect(source.contains("#selector(NSSplitViewController.toggleSidebar(_:))"))
        #expect(source.contains("NSTitlebarAccessoryViewController"))
        #expect(source.contains("layoutAttribute = .left"))
        #expect(!source.contains(".toolbar {"))
    }

    @Test
    func `new relay draft opts in while existing profile keeps the persisted global choice`() throws {
        let emptyRecorder = N4RelaySettingsRecorder()
        emptyRecorder.persistedUnifiedHistoryOptIn = false
        let newDraft = RelaySettingsModel(actions: emptyRecorder.actions)

        newDraft.loadIfNeeded()

        #expect(newDraft.unifiedHistoryOptIn)

        let existingRecorder = N4RelaySettingsRecorder()
        existingRecorder.persistedUnifiedHistoryOptIn = false
        let profileID = UUID()
        existingRecorder.profilesToLoad = try [Self.profile(id: profileID)]
        let existingDraft = RelaySettingsModel(actions: existingRecorder.actions)

        existingDraft.loadIfNeeded()

        #expect(existingDraft.isExistingProfile)
        #expect(!existingDraft.unifiedHistoryOptIn)
        existingDraft.startNewProfile()
        #expect(existingDraft.unifiedHistoryOptIn)
        existingDraft.selectProfile(profileID)
        #expect(!existingDraft.unifiedHistoryOptIn)
        #expect(existingRecorder.storedUnifiedHistoryOptIns.isEmpty)
    }

    @Test
    func `local relay usage loads independently from remote credentials and respects the cost toggle`() async throws {
        let recorder = N4RelaySettingsRecorder()
        let profileID = UUID()
        recorder.profilesToLoad = try [Self.profile(id: profileID)]
        recorder.localCodexUsage = CodexRelayLocalUsagePresentation(
            rolling24Hours: .init(relayTokens: 25, corpusTokens: 100),
            last7Days: nil)
        let model = RelaySettingsModel(actions: recorder.actions)
        model.loadIfNeeded()

        await model.refreshLocalCodexUsage(costUsageEnabled: false)

        #expect(recorder.localCodexUsageProfileIDs.isEmpty)
        #expect(model.localCodexUsage == nil)

        await model.refreshLocalCodexUsage(costUsageEnabled: true)

        #expect(recorder.localCodexUsageProfileIDs == [profileID])
        #expect(model.localCodexUsage == recorder.localCodexUsage)
    }

    @Test
    nonisolated func `Codex history disclosure is collapsed by default without changing profile schema`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let relayPane = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBar/PreferencesRelayPane.swift"),
            encoding: .utf8)
        let profileModel = try String(
            contentsOf: root.appendingPathComponent("Sources/CodexBarCore/RelayProfileModels.swift"),
            encoding: .utf8)

        #expect(relayPane.contains("@State private var isCodexHistoryExpanded = false"))
        #expect(relayPane.contains("DisclosureGroup(isExpanded: self.$isCodexHistoryExpanded)"))
        #expect(!profileModel.contains("unifiedHistoryOptIn"))
    }

    private static func profile(id: UUID) throws -> RelayProfile {
        try RelayProfile(
            id: id,
            name: "Existing relay",
            baseURL: #require(URL(string: "https://relay.example/v1")),
            apiFormat: .openAIResponses,
            credentialReference: RelayCredentialReference.make(for: id),
            targets: [.init(app: .codex, model: "test-model")])
    }

    private static func hasRequiredDimension(
        _ view: NSView,
        attribute: NSLayoutConstraint.Attribute,
        constant: CGFloat) -> Bool
    {
        view.constraints.contains { constraint in
            constraint.isActive
                && constraint.priority == .required
                && constraint.firstItem === view
                && constraint.firstAttribute == attribute
                && constraint.relation == .equal
                && constraint.secondItem == nil
                && constraint.constant == constant
        }
    }
}

@MainActor
private final class N4RelaySettingsRecorder {
    var profilesToLoad: [RelayProfile] = []
    var persistedUnifiedHistoryOptIn = false
    var storedUnifiedHistoryOptIns: [Bool] = []
    var localCodexUsage: CodexRelayLocalUsagePresentation?
    var localCodexUsageProfileIDs: [UUID] = []

    var actions: RelaySettingsActions {
        var actions = RelaySettingsActions(
            loadProfiles: { [weak self] in self?.profilesToLoad ?? [] },
            storeProfiles: { _ in },
            loadCredential: { _ in nil },
            storeCredential: { _, _ in },
            removeCredential: { _ in },
            captureBaseline: { URL(fileURLWithPath: "/test/n4-baseline", isDirectory: true) },
            applyProfile: { _ in throw N4RelaySettingsError.unused },
            restoreBaseline: { _ in throw N4RelaySettingsError.unused },
            restoreBaselineForTargets: nil,
            discardBackup: { _ in },
            loadActivationState: { nil },
            storeActivationState: { _ in },
            clearActivationState: {},
            loadUnifiedHistoryEnabled: { false },
            loadUnifiedHistoryOptIn: { [weak self] in self?.persistedUnifiedHistoryOptIn ?? false },
            storeUnifiedHistoryOptIn: { [weak self] value in self?.storedUnifiedHistoryOptIns.append(value) },
            hasCodexHistory: { false },
            isCodexLoggedIn: { true },
            enableUnifiedHistory: { throw N4RelaySettingsError.unused },
            loadUsageSummary: { _ in nil },
            storeUsageSummary: { _, _ in },
            fetchUsageSummary: { _, _ in throw N4RelaySettingsError.unused })
        actions.loadLocalCodexUsage = { [weak self] profileID in
            self?.localCodexUsageProfileIDs.append(profileID)
            return self?.localCodexUsage
        }
        return actions
    }
}

private enum N4RelaySettingsError: Error {
    case unused
}
