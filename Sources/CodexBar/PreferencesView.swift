import AppKit
import CodexBarCore
import SwiftUI

/// Sidebar destinations of the settings window: fixed app panes plus one entry per provider.
enum SettingsPane: Hashable {
    case general
    case usageSpend
    case providers
    case relay
    case notifications
    case menuBar
    case menu
    case advanced
    case hooks
    case update
    case about
    case debug
    case provider(UsageProvider)

    static let windowWidth: CGFloat = 880
    static let windowHeight: CGFloat = 620
    static let windowMinWidth: CGFloat = 800
    static let windowMinHeight: CGFloat = 540
    static let sidebarMinWidth = SettingsWindowLayout.sidebarWidthRange.lowerBound
    static let sidebarIdealWidth = SettingsWindowLayout.sidebarIdealWidth
    static let sidebarMaxWidth = SettingsWindowLayout.sidebarWidthRange.upperBound
    static let detailMaxWidth: CGFloat = 780

    var title: String {
        switch self {
        case .general: L("tab_general")
        case .usageSpend: L("tab_usage_spend")
        case .providers: L("tab_providers")
        case .relay: L("settings_destination_accounts_apis")
        case .notifications: L("tab_notifications")
        case .menuBar: L("settings_destination_appearance")
        case .menu: L("tab_menu")
        case .advanced: L("tab_advanced")
        case .hooks: L("tab_hooks")
        case .update: L("section_updates")
        case .about: L("tab_about")
        case .debug: L("tab_debug")
        case let .provider(provider):
            ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        }
    }
}

@MainActor
struct PreferencesView: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageDomain
    let updater: UpdaterProviding
    @Bindable var selection: PreferencesSelection
    let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
    let codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator
    let runProviderLoginFlow: @MainActor (UsageProvider) async -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsOptionDiagnostics = false

    init(
        settings: SettingsStore,
        store: UsageDomain,
        updater: UpdaterProviding,
        selection: PreferencesSelection,
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator = ManagedCodexAccountCoordinator(),
        codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator? = nil,
        runProviderLoginFlow: @escaping @MainActor (UsageProvider) async -> Void = { _ in })
    {
        self.settings = settings
        self.store = store
        self.updater = updater
        self.selection = selection
        self.managedCodexAccountCoordinator = managedCodexAccountCoordinator
        self.codexAccountPromotionCoordinator = codexAccountPromotionCoordinator
            ?? CodexAccountPromotionCoordinator(
                settingsStore: settings,
                usageStore: store,
                managedAccountCoordinator: managedCodexAccountCoordinator)
        self.runProviderLoginFlow = runProviderLoginFlow
    }

    var body: some View {
        NavigationSplitView {
            // Golden Gate-style sidebar: edge-to-edge material with a hairline separator,
            // no floating card chrome.
            SettingsSidebarView(
                settings: self.settings,
                store: self.store,
                selection: self.$selection.pane,
                showsDiagnostics: self.showsOptionDiagnostics)
                .navigationSplitViewColumnWidth(
                    min: SettingsPane.sidebarMinWidth,
                    ideal: self.settings.sidebarWidth,
                    max: SettingsPane.sidebarMaxWidth)
                // The titlebar accessory already owns the sidebar toggle beside the pin. Without
                // this, NavigationSplitView adds a second toggle that moves between the sidebar
                // edge and the traffic lights as the sidebar collapses.
                .toolbar(removing: .sidebarToggle)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: SettingsSidebarWidthPreferenceKey.self,
                            value: proxy.size.width)
                    }
                }
                .background(ConsoleDesign.background.ignoresSafeArea())
        } detail: {
            self.detailView
                .frame(
                    maxWidth: SettingsPane.detailMaxWidth,
                    maxHeight: .infinity,
                    alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: SettingsPane.windowMinWidth,
            idealWidth: SettingsPane.windowWidth,
            maxWidth: .infinity,
            minHeight: SettingsPane.windowMinHeight,
            idealHeight: SettingsPane.windowHeight,
            maxHeight: .infinity)
        .preferredColorScheme(self.settings.consolePalette.preferredColorScheme)
        .background(ConsoleDesign.background)
        .id(self.settings.appLanguage)
        .background {
            SettingsWindowAppearanceBridge(
                colorScheme: self.colorScheme,
                windowTitle: self.selection.pane.destination.title,
                windowAlwaysOnTop: self.settings.windowAlwaysOnTop,
                onToggleAlwaysOnTop: { self.settings.windowAlwaysOnTop.toggle() })
                .allowsHitTesting(false)
        }
        .onAppear {
            self.showsOptionDiagnostics = NSEvent.modifierFlags.contains(.option)
            self.ensureValidSelection()
        }
        .persistingSettledWidth(SettingsSidebarWidthPreferenceKey.self, current: self.settings.sidebarWidth) { width in
            self.settings.sidebarWidth = width
        }
        .onChange(of: self.settings.debugMenuEnabled) { _, _ in
            self.ensureValidSelection()
        }
        .onChange(of: self.settings.shouldRequestAdaptiveActivityScanConsent) { _, shouldRequest in
            guard shouldRequest else { return }
            AdaptiveActivityConsentPresenter.presentIfNeeded(settings: self.settings)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch self.selection.pane {
        case .general:
            GeneralPane(settings: self.settings)
        case .usageSpend:
            SpendDashboardPane(
                settings: self.settings,
                store: self.store,
                selection: self.selection,
                managedCodexAccountCoordinator: self.managedCodexAccountCoordinator)
        case .providers:
            self.accountsAndAPIsPane
        case .relay:
            self.accountsAndAPIsPane
        case .notifications:
            NotificationsPane(settings: self.settings)
        case .menuBar:
            DisplayPane(settings: self.settings, store: self.store)
        case .menu:
            DisplayPane(settings: self.settings, store: self.store)
        case .advanced:
            AdvancedContainerPane(settings: self.settings, store: self.store)
        case .hooks:
            AdvancedContainerPane(settings: self.settings, store: self.store, initialSection: .hooks)
        case .update:
            AboutPane(updater: self.updater, initialSection: .updates)
        case .about:
            AboutPane(updater: self.updater)
        case .debug:
            AdvancedContainerPane(settings: self.settings, store: self.store, initialSection: .debug)
        case .provider:
            self.accountsAndAPIsPane
        }
    }

    private var accountsAndAPIsPane: some View {
        AccountsAndAPIsPane(
            settings: self.settings,
            selection: self.selection,
            store: self.store,
            managedCodexAccountCoordinator: self.managedCodexAccountCoordinator,
            codexAccountPromotionCoordinator: self.codexAccountPromotionCoordinator,
            runProviderLoginFlow: self.runProviderLoginFlow)
    }

    private func ensureValidSelection() {
        guard !self.showsOptionDiagnostics, !self.selection.pane.isRegularlyReachable else { return }
        self.selection.pane = self.selection.pane.regularPane
    }
}

@MainActor
struct AccountsAndAPIsPane: View {
    enum Section: String, CaseIterable, Identifiable {
        case providers
        case relay

        var id: String {
            self.rawValue
        }
    }

    @Bindable var settings: SettingsStore
    @Bindable var selection: PreferencesSelection
    var store: UsageDomain?
    var managedCodexAccountCoordinator: ManagedCodexAccountCoordinator?
    var codexAccountPromotionCoordinator: CodexAccountPromotionCoordinator?
    var runProviderLoginFlow: (@MainActor (UsageProvider) async -> Void)?
    @State private var selectedProvider: UsageProvider?

    private var section: Binding<Section> {
        Binding(
            get: { self.selection.pane == .relay ? .relay : .providers },
            set: { self.selection.pane = $0 == .relay ? .relay : .providers })
    }

    private var detailIsPresented: Binding<Bool> {
        Binding(
            get: { self.selectedProvider != nil && self.store != nil },
            set: { if !$0 { self.selectedProvider = nil } })
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSubsectionPicker(L("settings_destination_accounts_apis"), selection: self.section) {
                Text(L("tab_providers")).tag(Section.providers)
                Text(L("API / Relay")).tag(Section.relay)
            }

            Group {
                switch self.section.wrappedValue {
                case .providers:
                    ProviderAgentPane(
                        settings: self.settings,
                        store: self.store,
                        onConfigureProvider: self.store == nil ? nil : { provider in
                            self.selectedProvider = provider
                        })
                case .relay:
                    RelaySettingsPane(settings: self.settings)
                }
            }
        }
        .background(ConsoleDesign.background)
        .sheet(isPresented: self.detailIsPresented) {
            if let provider = self.selectedProvider, let store = self.store {
                let managedCoordinator = self.managedCodexAccountCoordinator
                    ?? ManagedCodexAccountCoordinator()
                let promotionCoordinator = self.codexAccountPromotionCoordinator
                    ?? CodexAccountPromotionCoordinator(
                        settingsStore: self.settings,
                        usageStore: store,
                        managedAccountCoordinator: managedCoordinator)
                ProviderDetailSheet(
                    provider: provider,
                    settings: self.settings,
                    store: store,
                    managedCodexAccountCoordinator: managedCoordinator,
                    codexAccountPromotionCoordinator: promotionCoordinator,
                    runProviderLoginFlow: self.runProviderLoginFlow ?? { _ in })
                    .frame(minWidth: 680, minHeight: 560)
                    .preferredColorScheme(ConsoleDesign.preferredColorScheme)
                    .presentationBackgroundInteraction(.enabled)
            }
        }
    }
}

private struct SettingsSidebarWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

/// Persists a split width once it stops changing. The preference fires on every layout pass of a divider drag,
/// and each write went straight to `UserDefaults`.
private struct SettledWidthPersistence<Key: PreferenceKey>: ViewModifier where Key.Value == CGFloat {
    let current: CGFloat
    let persist: (CGFloat) -> Void
    @State private var pendingWidth: CGFloat?

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(Key.self) { width in
                let changed = width > 0 && abs(width - self.current) >= 0.5
                self.pendingWidth = changed ? width : nil
            }
            .task(id: self.pendingWidth) {
                guard let width = self.pendingWidth else { return }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                self.persist(width)
                self.pendingWidth = nil
            }
            .onDisappear {
                guard let width = self.pendingWidth else { return }
                self.persist(width)
                self.pendingWidth = nil
            }
    }
}

extension View {
    func persistingSettledWidth<Key: PreferenceKey>(
        _: Key.Type,
        current: CGFloat,
        persist: @escaping (CGFloat) -> Void) -> some View where Key.Value == CGFloat
    {
        self.modifier(SettledWidthPersistence<Key>(current: current, persist: persist))
    }
}

@MainActor
enum SettingsWindowSizing {
    static func enforceMinimumSize(_ window: NSWindow) {
        let toolbarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let minimumSize = NSSize(
            width: SettingsPane.windowMinWidth,
            height: SettingsPane.windowMinHeight + toolbarHeight)
        window.minSize = minimumSize

        if window.frame.width < minimumSize.width || window.frame.height < minimumSize.height {
            var frame = window.frame
            let repairedSize = NSSize(
                width: max(frame.width, minimumSize.width),
                height: max(frame.height, minimumSize.height))
            frame.origin.y += frame.height - repairedSize.height
            frame.size = repairedSize
            window.setFrame(frame, display: true)
        }
    }
}

@MainActor
enum SettingsWindowAppearance {
    typealias ResetAction = @MainActor @Sendable () -> Void
    typealias ResetScheduler = @MainActor @Sendable (@escaping ResetAction) -> Void

    static func refresh(
        _ window: NSWindow,
        colorScheme: ColorScheme,
        application: NSApplication = NSApp,
        scheduleReset: ResetScheduler = Self.scheduleReset)
    {
        SettingsWindowSizing.enforceMinimumSize(window)
        window.appearanceSource = application
        let appearanceName: NSAppearance.Name = colorScheme == .light ? .aqua : .darkAqua
        let consoleAppearance = NSAppearance(named: appearanceName) ?? application.effectiveAppearance
        window.appearance = consoleAppearance
        scheduleReset { [weak window] in
            if let window {
                SettingsWindowSizing.enforceMinimumSize(window)
            }
            window?.appearance = consoleAppearance
            window?.viewsNeedDisplay = true
        }
    }

    static func scheduleReset(_ action: @escaping ResetAction) {
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }
}

@MainActor
struct SettingsWindowAppearanceBridge: NSViewRepresentable {
    let colorScheme: ColorScheme
    let windowTitle: String
    let windowAlwaysOnTop: Bool
    let onToggleAlwaysOnTop: @MainActor () -> Void

    init(
        colorScheme: ColorScheme,
        windowTitle: String,
        windowAlwaysOnTop: Bool = false,
        onToggleAlwaysOnTop: @escaping @MainActor () -> Void = {})
    {
        self.colorScheme = colorScheme
        self.windowTitle = windowTitle
        self.windowAlwaysOnTop = windowAlwaysOnTop
        self.onToggleAlwaysOnTop = onToggleAlwaysOnTop
    }

    func makeNSView(context: Context) -> SettingsWindowAppearanceView {
        SettingsWindowAppearanceView()
    }

    func updateNSView(_ nsView: SettingsWindowAppearanceView, context: Context) {
        nsView.refreshWindowAppearance(
            for: self.colorScheme,
            windowTitle: self.windowTitle,
            windowAlwaysOnTop: self.windowAlwaysOnTop,
            onToggleAlwaysOnTop: self.onToggleAlwaysOnTop)
    }

    static func dismantleNSView(_ nsView: SettingsWindowAppearanceView, coordinator: ()) {
        nsView.invalidate()
    }
}

@MainActor
final class SettingsTitlebarControlsController: NSTitlebarAccessoryViewController {
    typealias Action = @MainActor () -> Void
    static let contentSize = NSSize(width: 56, height: 22)

    let sidebarButton: NSButton
    let pinButton: NSButton
    private var onToggleSidebar: Action
    private var onTogglePin: Action

    init(
        onToggleSidebar: @escaping Action,
        onTogglePin: @escaping Action)
    {
        self.onToggleSidebar = onToggleSidebar
        self.onTogglePin = onTogglePin
        self.sidebarButton = NSButton(
            image: NSImage(
                systemSymbolName: "sidebar.left",
                accessibilityDescription: "Show Sidebar")!,
            target: nil,
            action: nil)
        self.pinButton = NSButton(
            image: NSImage(
                systemSymbolName: "pin",
                accessibilityDescription: "Not Pinned")!,
            target: nil,
            action: nil)
        super.init(nibName: nil, bundle: nil)

        self.layoutAttribute = .left
        self.sidebarButton.target = self
        self.sidebarButton.action = #selector(self.toggleSidebar(_:))
        self.pinButton.target = self
        self.pinButton.action = #selector(self.togglePin(_:))
        for button in [self.sidebarButton, self.pinButton] {
            button.bezelStyle = .accessoryBar
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.controlSize = .small
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        self.sidebarButton.toolTip = L("Toggle Sidebar")
        self.pinButton.toolTip = L("settings_window_always_on_top_help")

        let stack = NSStackView(views: [self.sidebarButton, self.pinButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(
            frame: NSRect(origin: .zero, size: Self.contentSize))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 22),
        ])
        self.preferredContentSize = Self.contentSize
        self.view = container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(isPinned: Bool, onTogglePin: Action? = nil) {
        if let onTogglePin {
            self.onTogglePin = onTogglePin
        }
        let imageName = isPinned ? "pin.fill" : "pin"
        let accessibilityDescription = isPinned ? "Pinned" : "Not Pinned"
        self.pinButton.image = NSImage(
            systemSymbolName: imageName,
            accessibilityDescription: accessibilityDescription)
        self.pinButton.contentTintColor = isPinned ? ConsoleDesign.tokens.accent.nsColor : .secondaryLabelColor
    }

    @objc private func toggleSidebar(_ sender: NSButton) {
        self.onToggleSidebar()
    }

    @objc private func togglePin(_ sender: NSButton) {
        self.onTogglePin()
    }
}

@MainActor
final class SettingsWindowAppearanceView: NSView {
    private let scheduleReset: SettingsWindowAppearance.ResetScheduler
    private var titlebarControls: SettingsTitlebarControlsController?
    private weak var controlsWindow: NSWindow?
    private var onToggleAlwaysOnTop: SettingsTitlebarControlsController.Action
    private var colorScheme: ColorScheme?
    private var windowTitle: String?
    private var windowAlwaysOnTop = false

    init(
        scheduleReset: @escaping SettingsWindowAppearance.ResetScheduler = SettingsWindowAppearance.scheduleReset,
        onToggleAlwaysOnTop: @escaping SettingsTitlebarControlsController.Action = {})
    {
        self.scheduleReset = scheduleReset
        self.onToggleAlwaysOnTop = onToggleAlwaysOnTop
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func invalidate() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
        // The window owns one stable accessory controller. SwiftUI may dismantle and recreate
        // this bridge during locale or scene updates; synchronous AppKit removal here can race
        // NSToolbar teardown. The replacement bridge adopts and updates the existing controller.
        self.titlebarControls = nil
        self.controlsWindow = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.windowDidUpdate(_:)),
                name: NSWindow.didUpdateNotification,
                object: window)
        }
        self.configureWindowStyle()
        if let window {
            self.installTitlebarControls(in: window)
        }
        self.refreshWindowAppearance()
    }

    @objc private func windowDidUpdate(_ notification: Notification) {
        self.configureWindowStyle()
        if let window {
            self.installTitlebarControls(in: window)
        }
        self.configureWindowLevel()
    }

    func refreshWindowAppearance(
        for colorScheme: ColorScheme,
        windowTitle: String? = nil,
        windowAlwaysOnTop: Bool = false,
        onToggleAlwaysOnTop: (@MainActor () -> Void)? = nil)
    {
        if let onToggleAlwaysOnTop {
            self.onToggleAlwaysOnTop = onToggleAlwaysOnTop
        }
        self.titlebarControls?.update(
            isPinned: windowAlwaysOnTop,
            onTogglePin: self.onToggleAlwaysOnTop)
        let colorSchemeChanged = self.colorScheme != colorScheme
        let windowTitleChanged = self.windowTitle != windowTitle
        let windowLevelChanged = self.windowAlwaysOnTop != windowAlwaysOnTop
        guard colorSchemeChanged || windowTitleChanged || windowLevelChanged else { return }
        self.colorScheme = colorScheme
        self.windowTitle = windowTitle
        self.windowAlwaysOnTop = windowAlwaysOnTop

        guard let window else { return }
        self.configureWindowStyle()
        self.installTitlebarControls(in: window)
        self.configureWindowLevel()
        if windowTitleChanged, let windowTitle {
            window.title = windowTitle
        }
        if colorSchemeChanged {
            SettingsWindowAppearance.refresh(window, colorScheme: colorScheme, scheduleReset: self.scheduleReset)
        }
    }

    private func refreshWindowAppearance() {
        guard let window else { return }
        self.configureWindowStyle()
        self.installTitlebarControls(in: window)
        self.titlebarControls?.update(isPinned: self.windowAlwaysOnTop)
        self.configureWindowLevel()
        if let windowTitle {
            window.title = windowTitle
        }
        SettingsWindowAppearance.refresh(
            window,
            colorScheme: self.colorScheme ?? .dark,
            scheduleReset: self.scheduleReset)
    }

    override func layout() {
        super.layout()
        self.configureWindowStyle()
        if let window {
            self.installTitlebarControls(in: window)
        }
    }

    private func configureWindowStyle() {
        guard let window else { return }
        if !window.styleMask.contains(.resizable) {
            window.styleMask.insert(.resizable)
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        if window.titleVisibility != .visible {
            window.titleVisibility = .visible
        }
        if window.titlebarSeparatorStyle != .none {
            window.titlebarSeparatorStyle = .none
        }
        // Full-size content lets the sidebar material extend behind the titlebar so the
        // edge-to-edge sidebar reaches the top of the window; content stays below the
        // titlebar via the safe area.
        if !window.styleMask.contains(.fullSizeContentView) {
            window.styleMask.insert(.fullSizeContentView)
        }
    }

    private func installTitlebarControls(in window: NSWindow) {
        if self.controlsWindow === window, let titlebarControls,
           window.titlebarAccessoryViewControllers.contains(where: { $0 === titlebarControls })
        {
            titlebarControls.update(
                isPinned: self.windowAlwaysOnTop,
                onTogglePin: self.onToggleAlwaysOnTop)
            return
        }
        let controls = window.titlebarAccessoryViewControllers
            .compactMap { $0 as? SettingsTitlebarControlsController }
            .first ?? SettingsTitlebarControlsController(
                onToggleSidebar: {
                    NSApp.sendAction(
                        #selector(NSSplitViewController.toggleSidebar(_:)),
                        to: nil,
                        from: nil)
                },
                onTogglePin: self.onToggleAlwaysOnTop)
        if !window.titlebarAccessoryViewControllers.contains(where: { $0 === controls }) {
            window.addTitlebarAccessoryViewController(controls)
        }
        controls.update(isPinned: self.windowAlwaysOnTop, onTogglePin: self.onToggleAlwaysOnTop)
        self.titlebarControls = controls
        self.controlsWindow = window
    }

    private func configureWindowLevel() {
        guard let window else { return }
        let level: NSWindow.Level = self.windowAlwaysOnTop ? .floating : .normal
        if window.level != level {
            window.level = level
        }
    }
}
