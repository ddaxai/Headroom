import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct DisplayPane: View {
    enum Section: String, CaseIterable, Identifiable {
        case appearance
        case menuBar
        case popover

        var id: String {
            self.rawValue
        }

        var title: String {
            switch self {
            case .appearance: L("console_palette_section")
            case .menuBar: L("Menu Bar")
            case .popover: L("Popover")
            }
        }
    }

    @Bindable var settings: SettingsStore
    @Bindable var store: UsageDomain
    @State private var section: Section = .menuBar

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("settings_destination_appearance"), selection: self.$section) {
                ForEach(Section.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Group {
                switch self.section {
                case .appearance:
                    ConsolePalettePane(settings: self.settings)
                case .menuBar:
                    MenuBarPane(settings: self.settings, store: self.store)
                case .popover:
                    MenuPane(settings: self.settings, store: self.store)
                }
            }
        }
        .background(ConsoleDesign.background)
    }
}

@MainActor
struct ConsolePalettePane: View {
    @Bindable var settings: SettingsStore

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: self.columns, spacing: 10) {
                    ForEach(ConsolePalette.allCases) { palette in
                        ConsolePaletteChoice(
                            palette: palette,
                            isSelected: self.settings.consolePalette == palette)
                        {
                            self.settings.consolePalette = palette
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(L("console_palette_title"))
            } footer: {
                SettingsSectionFooter(L("console_palette_subtitle"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(ConsoleDesign.background)
    }
}

private struct ConsolePaletteChoice: View {
    let palette: ConsolePalette
    let isSelected: Bool
    let action: @MainActor () -> Void

    private var tokens: ConsoleTokens {
        self.palette.tokens
    }

    var body: some View {
        Button(action: self.action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 5) {
                    self.swatch(self.tokens.background)
                    self.swatch(self.tokens.surface)
                    self.swatch(self.tokens.accent)
                    self.swatch(self.tokens.positive)
                    self.swatch(self.tokens.caution)
                    self.swatch(self.tokens.critical)
                }

                HStack(spacing: 8) {
                    Text(self.palette.displayName)
                        .font(ConsoleDesign.text(11, weight: .medium))
                        .foregroundStyle(ConsoleDesign.primaryText)
                    Spacer(minLength: 4)
                    Image(systemName: self.isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(self.isSelected ? ConsoleDesign.accent : ConsoleDesign.tertiaryText)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                    .fill(self.isSelected ? ConsoleDesign.surface2 : ConsoleDesign.surface))
            .overlay {
                RoundedRectangle(cornerRadius: ConsoleDesign.radiusCard, style: .continuous)
                    .stroke(self.isSelected ? ConsoleDesign.accent : ConsoleDesign.border, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(self.palette.displayName)
        .accessibilityValue(self.isSelected ? L("console_palette_selected") : "")
    }

    private func swatch(_ token: ConsoleColorToken) -> some View {
        RoundedRectangle(cornerRadius: ConsoleDesign.radiusChip, style: .continuous)
            .fill(token.color)
            .frame(maxWidth: .infinity)
            .frame(height: 16)
            .overlay {
                RoundedRectangle(cornerRadius: ConsoleDesign.radiusChip, style: .continuous)
                    .stroke(self.tokens.border.color, lineWidth: 1)
            }
    }
}

@MainActor
struct AdvancedContainerPane: View {
    enum Section: String, CaseIterable, Identifiable {
        case advanced
        case hooks
        case debug

        var id: String {
            self.rawValue
        }

        var title: String {
            switch self {
            case .advanced: L("Advanced")
            case .hooks: L("Automation")
            case .debug: L("Debug")
            }
        }
    }

    @Bindable var settings: SettingsStore
    @Bindable var store: UsageDomain
    @State private var section: Section

    init(
        settings: SettingsStore,
        store: UsageDomain,
        initialSection: Section = .advanced)
    {
        self.settings = settings
        self.store = store
        self._section = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(L("tab_advanced"), selection: self.$section) {
                ForEach(self.availableSections) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Group {
                switch self.section {
                case .advanced:
                    AdvancedPane(settings: self.settings, store: self.store)
                case .hooks:
                    HooksPane(settings: self.settings)
                case .debug:
                    DebugPane(settings: self.settings, store: self.store)
                }
            }
        }
        .background(ConsoleDesign.background)
    }

    private var availableSections: [Section] {
        self.settings.debugMenuEnabled ? Section.allCases : [.advanced, .hooks]
    }
}

private enum ConsoleUpdateFrequency: String, CaseIterable, Identifiable {
    case daily
    case weekly
    case manual

    var id: String {
        self.rawValue
    }

    var title: String {
        switch self {
        case .daily: L("Daily")
        case .weekly: L("Weekly")
        case .manual: L("Manual")
        }
    }

    var interval: TimeInterval {
        switch self {
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        case .manual: 0
        }
    }
}

@MainActor
struct UpdatePane: View {
    let updater: UpdaterProviding
    @State private var sourceUpdater = HeadroomSourceUpdateController()
    @State private var previousLastSourceUpdateAt: Double?
    @AppStorage("consoleUpdateFrequency") private var frequencyRaw = ConsoleUpdateFrequency.daily.rawValue
    @AppStorage("consoleLastManualUpdateCheckAt") private var lastManualCheckAt = 0.0
    @AppStorage("headroomSourceDirectory") private var sourceDirectoryPath =
        HeadroomSourceUpdateConfiguration.default.sourceDirectory.path
    @AppStorage("headroomSourceBranch") private var sourceBranch =
        HeadroomSourceUpdateConfiguration.default.branch
    @AppStorage("headroomLastSourceUpdateAt") private var lastSourceUpdateAt = 0.0
    @AppStorage(UpdateChannel.userDefaultsKey) private var updateChannelRaw = UpdateChannel.defaultChannel.rawValue

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private var versionAndCommitString: String {
        let commit = (Bundle.main.object(forInfoDictionaryKey: "CodexGitCommit") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commit, !commit.isEmpty else { return self.versionString }
        return "\(self.versionString) · \(commit.prefix(8))"
    }

    var body: some View {
        Form {
            Section(L("update_version_section")) {
                LabeledContent(L("update_current_version"), value: self.versionAndCommitString)
                HStack {
                    Button {
                        self.lastManualCheckAt = Date().timeIntervalSince1970
                        self.updater.checkForUpdates(nil)
                    } label: {
                        Label(L("check_for_updates"), systemImage: "arrow.clockwise")
                    }
                    .disabled(!self.updater.isAvailable)
                    Spacer()
                    Text(self.lastCheckText)
                        .font(ConsoleDesign.mono(10))
                        .foregroundStyle(ConsoleDesign.tertiaryForeground)
                }
            }

            Section(L("update_automatic_section")) {
                Toggle(L("check_updates_auto"), isOn: self.automaticChecksBinding)
                Picker(L("update_check_frequency"), selection: self.frequencyBinding) {
                    ForEach(ConsoleUpdateFrequency.allCases) { frequency in
                        Text(frequency.title).tag(frequency)
                    }
                }
                Toggle(L("update_automatic_downloads"), isOn: self.automaticDownloadsBinding)
                    .disabled(!self.updater.automaticallyChecksForUpdates)
                Picker(L("update_channel"), selection: self.updateChannelBinding) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
            }

            self.sourceUpdateSection

            Section(L("Advanced")) {
                LabeledContent(L("update_feed_url")) {
                    Text(self.feedURL)
                        .font(ConsoleDesign.mono(10))
                        .textSelection(.enabled)
                        .foregroundStyle(ConsoleDesign.secondaryText)
                }
            }

            if !self.updater.isAvailable {
                Section {
                    Text(self.updater.unavailableReason ?? L("updates_unavailable"))
                        .foregroundStyle(ConsoleDesign.secondaryText)
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(ConsoleDesign.background)
        .onAppear {
            self.sourceUpdater.configure(
                sourceDirectory: URL(fileURLWithPath: self.sourceDirectoryPath, isDirectory: true),
                branch: self.sourceBranch)
            self.sourceUpdater.refreshAvailability()
        }
        .onChange(of: self.sourceUpdater.state) { _, state in
            self.handleSourceUpdateState(state)
        }
    }

    private var sourceUpdateSection: some View {
        Section {
            LabeledContent(L("source_update_current_build"), value: self.versionAndCommitString)
            LabeledContent(L("source_update_source_directory")) {
                Text(self.sourceUpdater.configuration.sourceDirectory.path)
                    .font(ConsoleDesign.mono(10))
                    .textSelection(.enabled)
            }
            LabeledContent(L("source_update_branch")) {
                TextField(
                    HeadroomSourceUpdateConfiguration.default.branch,
                    text: self.$sourceBranch)
                    .font(ConsoleDesign.mono(11))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .disabled(self.sourceUpdater.isRunning)
                    .onSubmit {
                        self.reconfigureSourceUpdater()
                    }
                    .onChange(of: self.sourceBranch) { _, _ in
                        self.reconfigureSourceUpdater()
                    }
            }
            LabeledContent(L("source_update_last_updated"), value: self.lastSourceUpdateText)

            HStack {
                if self.sourceUpdater.sourceReady {
                    Button {
                        self.sourceUpdater.check()
                    } label: {
                        Label(L("source_update_check"), systemImage: "arrow.clockwise")
                    }
                    .disabled(self.sourceUpdater.isRunning)

                    Button {
                        self.beginSourceUpdate()
                    } label: {
                        Label(L("source_update_install"), systemImage: "arrow.down.app.fill")
                    }
                    .disabled(self.sourceUpdater.isRunning)
                }

                Button {
                    self.chooseSourceDirectory()
                } label: {
                    Label(L("source_update_choose_directory"), systemImage: "folder")
                }
                .disabled(self.sourceUpdater.isRunning)

                Spacer()

                Button {
                    self.openSourceUpdateLog()
                } label: {
                    Label(L("source_update_open_log"), systemImage: "doc.text.magnifyingglass")
                }
            }

            self.sourceUpdateStatusStrip

            if !self.sourceUpdater.sourceReady {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("source_update_setup_required"))
                        .font(.callout.weight(.semibold))
                    HStack(alignment: .top, spacing: 8) {
                        Text(self.sourceUpdater.configuration.cloneCommand)
                            .font(ConsoleDesign.mono(10))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            self.copySourceSetupCommand()
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help(L("source_update_copy_setup"))
                    }
                }
            }
        } header: {
            Text(L("source_update_section"))
        } footer: {
            Text(L("source_update_footer"))
        }
    }

    private var sourceUpdateStatusStrip: some View {
        HStack(spacing: 10) {
            if self.sourceUpdater.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: self.sourceUpdateStatusIcon)
                    .foregroundStyle(self.sourceUpdateStatusColor)
                    .frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(self.sourceUpdateStatusTitle)
                    .font(.callout.weight(.semibold))
                Text(self.sourceUpdater.detail.isEmpty ? L("source_update_idle_detail") : self.sourceUpdater.detail)
                    .font(ConsoleDesign.mono(10))
                    .foregroundStyle(ConsoleDesign.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if let recoveryAction = self.sourceUpdater.recoveryAction {
                Button(self.sourceUpdateRecoveryTitle(recoveryAction)) {
                    self.performSourceUpdateRecovery(recoveryAction)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: HeadroomSourceUpdatePresentation.statusStripHeight)
        .background(ConsoleDesign.surface2, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var sourceUpdateStatusTitle: String {
        switch self.sourceUpdater.state {
        case .idle: L("source_update_ready")
        case .setupRequired: L("source_update_setup_required")
        case .checking: self.sourceUpdateStageTitle ?? L("source_update_checking")
        case .updating: self.sourceUpdateStageTitle ?? L("source_update_updating")
        case .upToDate: L("source_update_current")
        case .updateAvailable: L("source_update_available")
        case .completed: L("source_update_completed")
        case .failed: L("source_update_failed")
        }
    }

    private var sourceUpdateStageTitle: String? {
        guard let stage = self.sourceUpdater.stage else { return nil }
        return switch stage {
        case .preflight: L("source_update_stage_preflight")
        case .fetching: L("source_update_stage_fetching")
        case .comparing: L("source_update_stage_comparing")
        case .syncing: L("source_update_stage_syncing")
        case .building: L("source_update_stage_building")
        case .stopping: L("source_update_stage_stopping")
        case .installing: L("source_update_stage_installing")
        case .scheduled: L("source_update_stage_scheduled")
        case .finished: L("source_update_stage_finished")
        }
    }

    private var sourceUpdateStatusIcon: String {
        switch self.sourceUpdater.state {
        case .setupRequired: "wrench.and.screwdriver.fill"
        case .upToDate, .completed: "checkmark.circle.fill"
        case .updateAvailable: "arrow.down.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .idle, .checking, .updating: "clock.arrow.circlepath"
        }
    }

    private var sourceUpdateStatusColor: Color {
        switch self.sourceUpdater.state {
        case .failed: ConsoleDesign.criticalForeground
        case .idle, .setupRequired, .checking, .updating, .updateAvailable: ConsoleDesign.accentForeground
        case .upToDate, .completed: ConsoleDesign.accentForeground
        }
    }

    private var lastSourceUpdateText: String {
        guard self.lastSourceUpdateAt > 0 else { return L("source_update_never_updated") }
        let date = Date(timeIntervalSince1970: self.lastSourceUpdateAt)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func beginSourceUpdate(options: HeadroomSourceUpdateOptions = .init()) {
        self.previousLastSourceUpdateAt = self.lastSourceUpdateAt
        self.lastSourceUpdateAt = Date().timeIntervalSince1970
        self.sourceUpdater.updateAndRelaunch(options: options)
    }

    private func sourceUpdateRecoveryTitle(_ action: HeadroomSourceUpdateRecoveryAction) -> String {
        switch action {
        case .retryIgnoringUntracked: L("source_update_action_ignore_untracked")
        case .retryReplacingLocalCommits: L("source_update_action_replace_local")
        case .copySSHCheck: L("source_update_action_copy_ssh")
        case .revealSource: L("source_update_action_reveal_source")
        case .chooseSource: L("source_update_choose_directory")
        }
    }

    private func performSourceUpdateRecovery(_ action: HeadroomSourceUpdateRecoveryAction) {
        switch action {
        case .retryIgnoringUntracked:
            self.beginSourceUpdate(options: .init(ignoreUntracked: true))
        case .retryReplacingLocalCommits:
            self.confirmReplacingLocalCommits()
        case .copySSHCheck:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("ssh -T git@github.com", forType: .string)
        case .revealSource:
            NSWorkspace.shared.activateFileViewerSelecting([self.sourceUpdater.configuration.sourceDirectory])
        case .chooseSource:
            self.chooseSourceDirectory()
        }
    }

    private func confirmReplacingLocalCommits() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("source_update_reset_confirmation_title")
        alert.informativeText = L("source_update_reset_confirmation_message")
        alert.addButton(withTitle: L("source_update_action_replace_local"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        self.beginSourceUpdate(options: .init(ignoreUntracked: true, allowLocalReset: true))
    }

    private func handleSourceUpdateState(_ state: HeadroomSourceUpdateState) {
        switch state {
        case .completed:
            self.previousLastSourceUpdateAt = nil
        case .failed:
            if let previous = self.previousLastSourceUpdateAt {
                self.lastSourceUpdateAt = previous
                self.previousLastSourceUpdateAt = nil
            }
        case .idle, .setupRequired, .checking, .updating, .upToDate, .updateAvailable:
            break
        }
    }

    private func chooseSourceDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = L("source_update_choose_directory")
        panel.directoryURL = URL(fileURLWithPath: self.sourceDirectoryPath, isDirectory: true)
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        self.sourceDirectoryPath = selectedURL.path
        self.reconfigureSourceUpdater()
    }

    private func reconfigureSourceUpdater() {
        let trimmedBranch = self.sourceBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBranch = trimmedBranch.isEmpty
            ? HeadroomSourceUpdateConfiguration.default.branch
            : trimmedBranch
        self.sourceUpdater.configure(
            sourceDirectory: URL(fileURLWithPath: self.sourceDirectoryPath, isDirectory: true),
            branch: effectiveBranch)
        self.sourceUpdater.refreshAvailability()
    }

    private func copySourceSetupCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(self.sourceUpdater.configuration.cloneCommand, forType: .string)
    }

    private func openSourceUpdateLog() {
        let logURL = self.sourceUpdater.configuration.logURL
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            NSWorkspace.shared.open(logURL.deletingLastPathComponent())
        }
    }

    private var frequency: ConsoleUpdateFrequency {
        ConsoleUpdateFrequency(rawValue: self.frequencyRaw) ?? .daily
    }

    private var frequencyBinding: Binding<ConsoleUpdateFrequency> {
        Binding(
            get: { self.frequency },
            set: { frequency in
                self.frequencyRaw = frequency.rawValue
                self.applyFrequency(frequency)
            })
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { self.updater.automaticallyChecksForUpdates },
            set: { isEnabled in
                self.updater.automaticallyChecksForUpdates = isEnabled
                if isEnabled, self.frequency == .manual {
                    self.frequencyRaw = ConsoleUpdateFrequency.daily.rawValue
                }
            })
    }

    private var automaticDownloadsBinding: Binding<Bool> {
        Binding(
            get: { self.updater.automaticallyDownloadsUpdates },
            set: { self.updater.automaticallyDownloadsUpdates = $0 })
    }

    private var updateChannelBinding: Binding<UpdateChannel> {
        Binding(
            get: { UpdateChannel(rawValue: self.updateChannelRaw) ?? .stable },
            set: { self.updateChannelRaw = $0.rawValue })
    }

    private var lastCheckText: String {
        guard let date = ConsoleUpdatePresentation.lastCheckDate(
            sparkleDate: self.updater.lastUpdateCheckDate,
            manualTimestamp: self.lastManualCheckAt)
        else { return L("update_never_checked") }
        return L("update_last_checked", date.formatted(date: .abbreviated, time: .shortened))
    }

    private var feedURL: String {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? L("update_not_configured")
    }

    private func applyFrequency(_ frequency: ConsoleUpdateFrequency) {
        self.updater.automaticallyChecksForUpdates = frequency != .manual
        self.updater.updateCheckInterval = frequency.interval
    }
}
