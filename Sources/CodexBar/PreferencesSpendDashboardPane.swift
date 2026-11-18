import AppKit
import Charts
import CodexBarCore
import SwiftUI

func spendDashboardDayRangeText(_ days: Int) -> String {
    let template: String
    switch days {
    case 7: template = L("7d")
    case 30: template = L("30d")
    default: return codexBarLocalizedInteger(days)
    }
    return template.replacingOccurrences(
        of: String(days),
        with: codexBarLocalizedInteger(days))
}

func spendDashboardRankText(_ rank: Int) -> String {
    "#\(codexBarLocalizedInteger(rank))"
}

func spendDashboardRefreshFailureText(_ count: Int) -> String {
    "\(L("Refresh failures")): \(codexBarLocalizedInteger(count))"
}

func spendDashboardCoverageText(covered: Int, requested: Int) -> String {
    "\(L("Coverage")): \(codexBarLocalizedInteger(covered)) / \(codexBarLocalizedInteger(requested))"
}

func spendDashboardUnassignedHistoryExplanation(accountKey: String) -> String? {
    guard accountKey == UsageIdentity.systemUnassignedAccountKey else { return nil }
    return L("spend_system_unassigned_history_explanation")
}

func resolvedManualAttributionTargetKey(current: String, candidates: [String]) -> String {
    candidates.contains(current) ? current : candidates.first ?? ""
}

func isValidManualAttributionTargetKey(_ target: String, candidates: [String]) -> Bool {
    candidates.contains(target)
}

enum SpendDashboardModelHistoryPresentation: Equatable {
    case unavailable
    case empty
    case partial
    case complete
}

func spendDashboardModelHistoryPresentation(
    _ group: SpendDashboardModel.CurrencyGroup) -> SpendDashboardModelHistoryPresentation
{
    if group.models.isEmpty {
        return group.modelHistoryCompleteness == .incomplete ? .unavailable : .empty
    }
    return group.modelHistoryCompleteness == .incomplete ? .partial : .complete
}

@MainActor
struct SpendDashboardPane: View {
    private enum ManualAttributionScope: String, CaseIterable, Identifiable {
        case entireBucket
        case dateRange

        var id: String {
            self.rawValue
        }
    }

    private struct ManualAttributionTarget: Identifiable, Equatable {
        let accountKey: String
        let label: String

        var id: String {
            self.accountKey
        }
    }

    @Bindable var settings: SettingsStore
    @Bindable var store: UsageDomain
    @Bindable var selection: PreferencesSelection
    let managedCodexAccountCoordinator: ManagedCodexAccountCoordinator
    @State private var controller: SpendDashboardController
    @State private var duplicateRemovalCandidate: SpendDashboardAccountDiagnostic?
    @State private var duplicateRemovalError: String?
    @State private var manualAttributionScope = ManualAttributionScope.entireBucket
    @State private var manualAttributionTargetKey = ""
    @State private var manualAttributionStart = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @State private var manualAttributionEndExclusive = Calendar.current
        .date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var manualAttributions: [CodexSessionOwnershipTimeline.ManualAttribution] = []
    @State private var manualAttributionError: String?

    init(
        settings: SettingsStore,
        store: UsageDomain,
        selection: PreferencesSelection = PreferencesSelection(),
        managedCodexAccountCoordinator: ManagedCodexAccountCoordinator = ManagedCodexAccountCoordinator())
    {
        self.settings = settings
        self.store = store
        self.selection = selection
        self.managedCodexAccountCoordinator = managedCodexAccountCoordinator
        self._controller = State(initialValue: SpendDashboardController(requestBuilder: { mode in
            await SpendDashboardSource.makeRequest(settings: settings, store: store, mode: mode)
        }))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    self.header
                    self.content
                    self.provenance
                    self.shareAction
                }
                .padding(24)
            }
            .background(FocusResigningBackground())
            .onAppear {
                self.controller.refreshDateWindow()
                self.controller.update(configuration: self.configuration)
                self.reloadManualAttributions()
                self.ensureManualAttributionTarget()
                self.scrollToRequestedFocusIfPossible(proxy)
            }
            .onChange(of: self.configuration) { _, configuration in
                self.controller.update(configuration: configuration)
            }
            .onChange(of: self.manualAttributionTargets.map(\.accountKey)) { _, _ in
                self.ensureManualAttributionTarget()
            }
            .onChange(of: self.settings.codexAccountReconciliationGeneration) { _, _ in
                self.ensureManualAttributionTarget()
            }
            .onChange(of: self.selection.usageSpendFocusTarget) { _, _ in
                self.scrollToRequestedFocusIfPossible(proxy)
            }
            .onChange(of: self.showsManualAttributionPanel) { _, _ in
                self.ensureManualAttributionTarget()
                self.scrollToRequestedFocusIfPossible(proxy)
            }
            .onDisappear {
                self.controller.stop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                self.controller.refreshDateWindow()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                self.controller.refreshDateWindow()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                self.controller.refreshDateWindow()
            }
            .confirmationDialog(
                L("spend_diagnostic_remove_confirmation_title"),
                isPresented: Binding(
                    get: { self.duplicateRemovalCandidate != nil },
                    set: { if !$0 { self.duplicateRemovalCandidate = nil } }),
                titleVisibility: .visible)
            {
                Button(L("spend_diagnostic_remove_action"), role: .destructive) {
                    self.removeDuplicateCandidate()
                }
            } message: {
                Text(L("spend_diagnostic_remove_confirmation_message"))
            }
        }
    }

    private func scrollToRequestedFocusIfPossible(_ proxy: ScrollViewProxy) {
        guard self.selection.usageSpendFocusTarget == .systemUnassigned,
              self.controller.model.groups.flatMap(\.providers).contains(where: {
                  $0.accountDiagnostic?.accountKey == UsageIdentity.systemUnassignedAccountKey
              })
        else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(UsageIdentity.systemUnassignedAccountKey, anchor: .center)
        }
        self.selection.consumeUsageSpendFocus(.systemUnassigned)
    }

    private var configuration: SpendDashboardConfiguration {
        SpendDashboardSource.configuration(settings: self.settings, store: self.store)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Usage & Spend"))
                    .font(.title2.weight(.semibold))
                Text(L("Local estimated cost history across supported providers."))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker(L("Time range"), selection: self.daysBinding) {
                Text(spendDashboardDayRangeText(7)).tag(7)
                Text(spendDashboardDayRangeText(30)).tag(30)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 116)

            Button {
                self.controller.refresh()
            } label: {
                if self.controller.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label(L("Refresh"), systemImage: "arrow.clockwise")
                }
            }
            .disabled(self.controller.isRefreshing || !self.settings.costUsageEnabled)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !self.settings.costUsageEnabled {
            SpendDashboardPanel {
                ContentUnavailableView {
                    Label(L("Cost tracking is off"), systemImage: "chart.bar.xaxis")
                } description: {
                    Text(L("Turn on Track costs to build local estimates."))
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        } else if self.controller.model.groups.isEmpty {
            SpendDashboardPanel {
                ContentUnavailableView {
                    Label(L("No local cost history yet"), systemImage: "chart.bar.xaxis")
                } description: {
                    Text(L("Turn on cost tracking or refresh after using a supported provider."))
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            }
        } else {
            ForEach(self.controller.model.groups) { group in
                SpendCurrencySection(
                    group: group,
                    requestedDays: self.controller.model.requestedDays,
                    onRemoveDuplicate: { diagnostic in self.duplicateRemovalCandidate = diagnostic })
            }
        }

        if self.showsManualAttributionPanel {
            self.manualAttributionPanel
        }

        if !self.controller.failedCodexDiagnostics.isEmpty {
            SpendDashboardPanel {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(self.controller.failedCodexDiagnostics, id: \.stableDiagnosticID) { diagnostic in
                        Label(
                            L(
                                "spend_diagnostic_unreadable_record",
                                diagnostic.accountKey == UsageIdentity.systemUnassignedAccountKey
                                    ? L("spend_diagnostic_system_unassigned")
                                    : diagnostic.email ?? diagnostic.accountKey),
                            systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        if self.controller.failedSourceCount > 0 {
            Label(
                spendDashboardRefreshFailureText(self.controller.failedSourceCount),
                systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let duplicateRemovalError {
            Label(duplicateRemovalError, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var provenance: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Native currencies stay separate; Codex account rows exclude Pi session history."))
                Text(L("spend_shared_history_attribution_note"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Toggle(L("Track costs"), isOn: self.$settings.costUsageEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var manualAttributionPanel: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label(L("spend_manual_attribution_title"), systemImage: "person.crop.circle.badge.checkmark")
                        .font(.headline)
                    Spacer()
                    Text(L("spend_manual_attribution_marker"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(ConsoleDesign.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: RoundedRectangle(
                            cornerRadius: ConsoleDesign.radiusChip,
                            style: .continuous))
                }

                Text(L("spend_manual_attribution_help"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(L("spend_manual_attribution_scope"), selection: self.$manualAttributionScope) {
                    Text(L("spend_manual_attribution_entire_bucket"))
                        .tag(ManualAttributionScope.entireBucket)
                    Text(L("spend_manual_attribution_date_range"))
                        .tag(ManualAttributionScope.dateRange)
                }
                .pickerStyle(.segmented)

                if self.manualAttributionScope == .dateRange {
                    HStack(spacing: 12) {
                        DatePicker(
                            L("spend_manual_attribution_start"),
                            selection: self.$manualAttributionStart,
                            displayedComponents: .date)
                        DatePicker(
                            L("spend_manual_attribution_end_exclusive"),
                            selection: self.$manualAttributionEndExclusive,
                            displayedComponents: .date)
                    }
                }

                HStack(spacing: 10) {
                    Picker(L("spend_manual_attribution_target"), selection: self.manualAttributionTargetBinding) {
                        ForEach(self.manualAttributionTargets) { target in
                            Text(target.label).tag(target.accountKey)
                        }
                    }
                    .frame(maxWidth: 360)

                    Button(L("spend_manual_attribution_assign")) {
                        self.recordManualAttribution()
                    }
                    .disabled(!self.hasValidManualAttributionTarget)
                }

                if let manualAttributionError {
                    Label(manualAttributionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(ConsoleDesign.criticalForeground)
                }

                if !self.manualAttributions.isEmpty {
                    Divider()
                    ForEach(self.manualAttributions) { attribution in
                        HStack(spacing: 8) {
                            Text(L("spend_manual_attribution_marker"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(ConsoleDesign.accent)
                            Text(self.manualAttributionDescription(attribution))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                self.removeManualAttribution(attribution)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(L("spend_manual_attribution_remove"))
                            .accessibilityLabel(L("spend_manual_attribution_remove"))
                        }
                    }
                }
            }
        }
    }

    private var manualAttributionTargets: [ManualAttributionTarget] {
        var seen: Set<String> = []
        return self.settings.codexVisibleAccountProjection.visibleAccounts.compactMap { account in
            guard let storedAccountID = account.storedAccountID else { return nil }
            let accountKey = CodexSessionOwnershipTimeline.managedAccountKey(id: storedAccountID)
            guard seen.insert(accountKey).inserted else { return nil }
            return ManualAttributionTarget(accountKey: accountKey, label: account.displayName)
        }
    }

    private var showsManualAttributionPanel: Bool {
        guard !self.manualAttributionTargets.isEmpty else { return false }
        if !self.manualAttributions.isEmpty { return true }
        return self.controller.model.groups.flatMap(\.providers).contains {
            $0.accountDiagnostic?.accountKey == UsageIdentity.systemUnassignedAccountKey
        }
    }

    private var hasValidManualAttributionTarget: Bool {
        isValidManualAttributionTargetKey(
            self.selectedManualAttributionTargetKey,
            candidates: self.manualAttributionTargetCandidates)
    }

    private var manualAttributionTargetCandidates: [String] {
        self.manualAttributionTargets.map(\.accountKey)
    }

    private var selectedManualAttributionTargetKey: String {
        resolvedManualAttributionTargetKey(
            current: self.manualAttributionTargetKey,
            candidates: self.manualAttributionTargetCandidates)
    }

    private var manualAttributionTargetBinding: Binding<String> {
        Binding(
            get: { self.selectedManualAttributionTargetKey },
            set: { self.manualAttributionTargetKey = $0 })
    }

    private func ensureManualAttributionTarget() {
        self.manualAttributionTargetKey = self.selectedManualAttributionTargetKey
    }

    private func reloadManualAttributions() {
        self.manualAttributions = (try? FileCodexSessionOwnershipTimelineStore.default.load().manualAttributions) ?? []
    }

    private func recordManualAttribution() {
        self.manualAttributionError = nil
        guard self.hasValidManualAttributionTarget else {
            self.ensureManualAttributionTarget()
            return
        }
        let targetKey = self.selectedManualAttributionTargetKey
        let calendar = Calendar.current
        let start: Date?
        let endExclusive: Date?
        switch self.manualAttributionScope {
        case .entireBucket:
            start = nil
            endExclusive = nil
        case .dateRange:
            start = calendar.startOfDay(for: self.manualAttributionStart)
            endExclusive = calendar.startOfDay(for: self.manualAttributionEndExclusive)
        }
        do {
            _ = try FileCodexSessionOwnershipTimelineStore.default.recordManualAttribution(
                accountKey: targetKey,
                start: start,
                endExclusive: endExclusive)
            self.reloadManualAttributions()
            self.controller.refresh()
        } catch {
            self.manualAttributionError = error.localizedDescription
        }
    }

    private func removeManualAttribution(_ attribution: CodexSessionOwnershipTimeline.ManualAttribution) {
        self.manualAttributionError = nil
        do {
            _ = try FileCodexSessionOwnershipTimelineStore.default.removeManualAttribution(id: attribution.id)
            self.reloadManualAttributions()
            self.controller.refresh()
        } catch {
            self.manualAttributionError = error.localizedDescription
        }
    }

    private func manualAttributionDescription(
        _ attribution: CodexSessionOwnershipTimeline.ManualAttribution) -> String
    {
        let target = self.manualAttributionTargets.first { $0.accountKey == attribution.accountKey }?.label
            ?? attribution.accountKey
        guard let startUnixMs = attribution.startUnixMs,
              let endUnixMsExclusive = attribution.endUnixMsExclusive
        else {
            return L("spend_manual_attribution_entire_description", target)
        }
        let start = Date(timeIntervalSince1970: Double(startUnixMs) / 1000)
        let end = Date(timeIntervalSince1970: Double(endUnixMsExclusive) / 1000)
        return L(
            "spend_manual_attribution_range_description",
            target,
            start.formatted(date: .abbreviated, time: .omitted),
            end.formatted(date: .abbreviated, time: .omitted))
    }

    private var shareAction: some View {
        HStack {
            Spacer()
            Button {
                guard let payload = self.sharePayload else { return }
                ShareStatsPresenter.shared.present(payload: payload)
            } label: {
                Label(L("Share Stats…"), systemImage: "square.and.arrow.up")
            }
            .disabled(self.sharePayload == nil)
        }
    }

    private var sharePayload: ShareStatsPayload? {
        ShareStatsBuilder.make(
            model: self.controller.model,
            subscriptionNames: self.subscriptionNames)
    }

    private var subscriptionNames: [String: ShareStatsSubscriptionName] {
        var names: [String: ShareStatsSubscriptionName] = [:]
        let codexRowCount = self.controller.model.groups
            .flatMap(\.providers)
            .count { $0.provider == .codex }
        for group in self.controller.model.groups {
            for row in group.providers {
                let snapshots: [UsageSnapshot?] = if row.provider == .codex,
                                                     row.id.hasPrefix("codex:")
                {
                    [
                        self.store.codexAccountSnapshots.first {
                            row.id == "codex:\($0.id)"
                        }?.snapshot,
                        codexRowCount == 1 ? self.store.snapshot(for: .codex) : nil,
                    ]
                } else {
                    [self.store.snapshot(for: row.provider)]
                }
                if let name = ShareStatsSubscriptionName.first(from: snapshots, provider: row.provider) {
                    names[row.id] = name
                }
            }
        }
        return names
    }

    private var daysBinding: Binding<Int> {
        Binding(
            get: { self.controller.selectedDays },
            set: { self.controller.selectDays($0) })
    }

    private func removeDuplicateCandidate() {
        guard let candidate = self.duplicateRemovalCandidate,
              candidate.canRemove,
              candidate.isDuplicate,
              let id = candidate.storedAccountID
        else { return }
        self.duplicateRemovalCandidate = nil
        self.duplicateRemovalError = nil
        Task {
            do {
                let removed = try await self.managedCodexAccountCoordinator.removeManagedAccountIfStillDuplicate(
                    id: id,
                    expectedAuthFingerprint: candidate.authFingerprint,
                    expectedWorkspaceAccountID: candidate.workspaceAccountID)
                guard removed else {
                    self.duplicateRemovalError = L("spend_diagnostic_remove_stale")
                    return
                }
                await self.store.refreshProvider(.codex)
                self.controller.refresh()
            } catch {
                self.duplicateRemovalError = L("spend_diagnostic_remove_failed")
            }
        }
    }
}

private struct SpendCurrencySection: View {
    let group: SpendDashboardModel.CurrencyGroup
    let requestedDays: Int
    let onRemoveDuplicate: (SpendDashboardAccountDiagnostic) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(self.group.currencyCode)
                    .font(.headline)
                Spacer()
                Text(self.group.totalCost.map {
                    UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                } ?? L("Spend unavailable"))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }

            Text(
                "\(L("Local estimated history")) · " +
                    spendDashboardCoverageText(
                        covered: self.group.coveredDayCount,
                        requested: self.requestedDays))
                .font(.caption)
                .foregroundStyle(.secondary)

            SpendDashboardPanel {
                HStack(spacing: 24) {
                    SpendSummaryValue(
                        title: L("Estimated spend"),
                        value: self.group.totalCost.map {
                            UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                        } ?? "—")
                    SpendSummaryValue(
                        title: L("Tracked tokens"),
                        value: self.group.totalTokens.map(UsageFormatter.tokenCountString) ?? "—")
                    SpendSummaryValue(
                        title: L("Subscriptions"),
                        value: codexBarLocalizedInteger(self.group.providers.count))
                    Spacer()
                }
            }

            SpendProviderPanel(group: self.group, onRemoveDuplicate: self.onRemoveDuplicate)
            SpendModelPanel(group: self.group)
            SpendDailyChart(group: self.group)
        }
    }
}

private struct SpendSummaryValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(self.title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(self.value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
    }
}

private struct SpendProviderPanel: View {
    let group: SpendDashboardModel.CurrencyGroup
    let onRemoveDuplicate: (SpendDashboardAccountDiagnostic) -> Void

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("By subscription")).font(.headline).padding(.bottom, 8)
                ForEach(self.group.providers) { row in
                    if row.rank > 1 {
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text(spendDashboardRankText(row.rank))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 26, alignment: .leading)
                            SpendProviderIcon(provider: row.provider)
                            Text(row.displayName).lineLimit(1)
                            if let diagnostic = row.accountDiagnostic {
                                SpendIdentityBadge(diagnostic: diagnostic)
                                if diagnostic.hasManualAttribution {
                                    Text(L("spend_manual_attribution_marker"))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(ConsoleDesign.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            .quaternary,
                                            in: RoundedRectangle(
                                                cornerRadius: ConsoleDesign.radiusChip,
                                                style: .continuous))
                                }
                            }
                            Spacer()
                            Text(row.totalCost.map {
                                UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                            } ?? L("Spend unavailable"))
                                .foregroundStyle(row.totalCost == nil ? .secondary : .primary)
                                .monospacedDigit()
                        }
                        if let diagnostic = row.accountDiagnostic {
                            SpendAccountDiagnosticView(
                                diagnostic: diagnostic,
                                onRemoveDuplicate: self.onRemoveDuplicate)
                        }
                    }
                    .padding(.vertical, 9)
                    .id(row.accountDiagnostic?.accountKey ?? row.id)
                }
            }
        }
    }
}

private struct SpendIdentityBadge: View {
    let diagnostic: SpendDashboardAccountDiagnostic

    var body: some View {
        Text(self.diagnostic.accountKey == UsageIdentity.systemUnassignedAccountKey
            ? L("spend_diagnostic_system_unassigned")
            : L("usage_identity_subscription"))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(self.diagnostic.accountKey == UsageIdentity.systemUnassignedAccountKey
                ? ConsoleDesign.cautionForeground
                : ConsoleDesign.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                .quaternary,
                in: RoundedRectangle(cornerRadius: ConsoleDesign.radiusChip, style: .continuous))
    }
}

private struct SpendAccountDiagnosticView: View {
    let diagnostic: SpendDashboardAccountDiagnostic
    let onRemoveDuplicate: (SpendDashboardAccountDiagnostic) -> Void

    var body: some View {
        DisclosureGroup(L("spend_diagnostic_details")) {
            VStack(alignment: .leading, spacing: 4) {
                if let explanation = spendDashboardUnassignedHistoryExplanation(
                    accountKey: self.diagnostic.accountKey)
                {
                    Text(explanation)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                }
                self.value(L("spend_diagnostic_account_key"), self.diagnostic.accountKey)
                if let email = self.diagnostic.email { self.value(L("spend_diagnostic_email"), email) }
                if let workspace = self.diagnostic.workspaceAccountID {
                    self.value(L("spend_diagnostic_workspace"), workspace)
                }
                if let fingerprint = self.diagnostic.truncatedAuthFingerprint {
                    self.value(L("spend_diagnostic_auth_fingerprint"), fingerprint)
                }
                self.value(L("spend_diagnostic_codex_home"), self.diagnostic.codexHome)
                self.value(L("spend_diagnostic_sidecar"), self.diagnostic.sidecarFingerprint)
                self.value(
                    L("spend_diagnostic_last_scan"),
                    self.diagnostic.lastScanAt?.formatted(date: .abbreviated, time: .shortened)
                        ?? L("spend_diagnostic_not_scanned"))
                if self.diagnostic.isDuplicate {
                    Label(L("spend_diagnostic_duplicate_warning"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ConsoleDesign.cautionForeground)
                    if self.diagnostic.canRemove, self.diagnostic.storedAccountID != nil {
                        Button(L("spend_diagnostic_remove_action"), role: .destructive) {
                            self.onRemoveDuplicate(self.diagnostic)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .padding(.leading, 36)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func value(_ label: String, _ value: String) -> some View {
        Text("\(label): \(value)")
    }
}

private struct SpendModelPanel: View {
    let group: SpendDashboardModel.CurrencyGroup

    var body: some View {
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Models")).font(.headline).padding(.bottom, 8)
                let presentation = spendDashboardModelHistoryPresentation(self.group)
                switch presentation {
                case .unavailable:
                    Text(L("Model breakdown unavailable"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                case .empty:
                    Text(L("No model-level history"))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                case .partial, .complete:
                    if presentation == .partial {
                        Label(L("Model breakdown unavailable"), systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                    }
                    ForEach(self.group.models.prefix(8)) { row in
                        if row.rank > 1 {
                            Divider()
                        }
                        HStack(spacing: 10) {
                            if presentation == .complete {
                                Text(spendDashboardRankText(row.rank))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 26, alignment: .leading)
                            } else {
                                Image(systemName: "circle.dashed")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 26, alignment: .leading)
                            }
                            SpendProviderIcon(provider: row.provider)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.modelName).lineLimit(1)
                                Text(row.providerName).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(row.totalCost.map {
                                UsageFormatter.currencyString($0, currencyCode: self.group.currencyCode)
                            } ?? "—")
                                .monospacedDigit()
                        }
                        .padding(.vertical, 9)
                    }
                }
            }
        }
    }
}

struct SpendDailyChartPresentation: Equatable {
    enum Content: Equatable {
        case chart
        case unavailable
    }

    struct Series: Equatable {
        let name: String
        let provider: UsageProvider
    }

    let content: Content
    let series: [Series]
    let dayCount: Int

    init(dailyPoints: [SpendDashboardModel.DailyPoint], aggregateTotal: Double?) {
        self.content = dailyPoints.isEmpty && aggregateTotal == nil ? .unavailable : .chart
        self.dayCount = Set(dailyPoints.map(\.day)).count

        var seenNames: Set<String> = []
        self.series = dailyPoints.compactMap { point in
            guard seenNames.insert(point.providerName).inserted else { return nil }
            return Series(name: point.providerName, provider: point.provider)
        }
    }

    var accessibilityValue: String {
        L("%d days of usage data across %d services", self.dayCount, self.series.count)
    }
}

private struct SpendDailyChart: View {
    let group: SpendDashboardModel.CurrencyGroup

    var body: some View {
        let presentation = SpendDailyChartPresentation(
            dailyPoints: self.group.dailyPoints,
            aggregateTotal: self.group.totalCost)
        SpendDashboardPanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Daily estimated spend")).font(.headline)
                if presentation.content == .unavailable {
                    ContentUnavailableView(L("Spend unavailable"), systemImage: "chart.bar.xaxis")
                        .frame(maxWidth: .infinity, minHeight: 170)
                } else {
                    Chart(self.group.dailyPoints) { point in
                        BarMark(
                            x: .value(L("Day"), point.day, unit: .day),
                            yStart: .value(L("Estimated spend"), point.stackStart),
                            yEnd: .value(L("Estimated spend"), point.stackEnd),
                            width: .ratio(0.72))
                            .foregroundStyle(by: .value(L("Provider"), point.providerName))
                            .accessibilityLabel(Text(self.pointAccessibilityLabel(point)))
                            .accessibilityValue(Text(UsageFormatter.currencyString(
                                point.cost,
                                currencyCode: self.group.currencyCode)))
                    }
                    .chartXScale(domain: self.group.chartDomain)
                    .chartForegroundStyleScale(
                        domain: presentation.series.map(\.name),
                        range: presentation.series.map { self.providerColor($0.provider) })
                    .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                    .chartYAxis {
                        AxisMarks(position: .leading) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let amount = value.as(Double.self) {
                                    Text(UsageFormatter.compactCurrencyString(
                                        amount,
                                        currencyCode: self.group.currencyCode))
                                }
                            }
                        }
                    }
                    .frame(height: 170)
                    .accessibilityLabel(L("Daily estimated spend"))
                    .accessibilityValue(presentation.accessibilityValue)
                }
            }
        }
    }

    private func pointAccessibilityLabel(_ point: SpendDashboardModel.DailyPoint) -> String {
        let day = point.day.formatted(
            .dateTime.month(.abbreviated).day().locale(codexBarLocalizedLocale()))
        return "\(point.providerName), \(day)"
    }

    private func providerColor(_ provider: UsageProvider) -> Color {
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }
}

private struct SpendProviderIcon: View {
    let provider: UsageProvider

    var body: some View {
        Group {
            if let icon = ProviderBrandIcon.image(for: self.provider) {
                Image(nsImage: icon).resizable().scaledToFit()
            } else {
                Image(systemName: "circle.dotted")
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }
}

private struct SpendDashboardPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        self.content
            .padding(16)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35))
            }
    }
}
