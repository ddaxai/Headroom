import CodexBarCore
import SwiftUI

struct AgentSpeedPresentation: Equatable, Sendable {
    let badgeText: String
    let primaryLine: String
    let detailLine: String?
    let inlineCompactLine: String
    let tooltipText: String
    var requests: [AgentSpeedRequestRow] = []
    var cacheExpiresAt: Date?

    /// The newest few replies, listed on the card itself.
    var inlineRequests: ArraySlice<AgentSpeedRequestRow> {
        self.requests.prefix(AgentSpeedRequestRow.inlineLimit)
    }

    var heightFingerprint: String {
        MenuCardHeightFingerprint.join([
            MenuCardHeightFingerprint.field("badge", self.badgeText),
            MenuCardHeightFingerprint.field("primary", self.primaryLine),
            MenuCardHeightFingerprint.field("detail", self.detailLine),
            MenuCardHeightFingerprint.field("inline", self.inlineCompactLine),
            MenuCardHeightFingerprint.field("requests", String(self.inlineRequests.count)),
        ])
    }

    static func from(_ summary: AgentSpeedSummary?) -> Self? {
        guard let summary, summary.hasData else { return nil }
        let latestFormatted: String? = if let tps = summary.latestTokensPerSecond,
                                          let kind = summary.latestKind
        {
            AgentSpeedSummary.formatTokensPerSecond(tps, kind: kind)
        } else {
            nil
        }
        let rollingFormatted: String? = if let tps = summary.rolling24hTokensPerSecond,
                                           let kind = summary.rolling24hKind
        {
            AgentSpeedSummary.formatTokensPerSecond(tps, kind: kind)
        } else {
            nil
        }

        guard latestFormatted != nil || rollingFormatted != nil else { return nil }

        // 1. Compact badge for Overview rows
        let badgeParts: [String] = switch (latestFormatted, rollingFormatted) {
        case let (latest?, rolling?) where latest != rolling && summary.rolling24hSampleCount >= 2:
            [latest, "\(L("relay_local_usage_24h")) \(rolling)"]
        case let (latest?, _):
            [latest]
        case let (nil, rolling?):
            ["\(L("relay_local_usage_24h")) \(rolling)"]
        case (nil, nil):
            []
        }
        let badgeText = badgeParts.joined(separator: " · ")

        // 2. Full primary line for detail cards
        var primaryParts: [String] = []
        if let latestFormatted {
            primaryParts.append(L("agent_speed_latest_format", latestFormatted))
        }
        if let rollingFormatted {
            primaryParts.append(L("agent_speed_24h_avg_format", rollingFormatted))
        }
        let primaryLine = primaryParts.joined(separator: " · ")

        // 3. Secondary detail line (TTFT + model / estimate provenance)
        var detailParts: [String] = []
        if let ttftMs = summary.latestFirstTokenMs ?? summary.rolling24hMedianFirstTokenMs, ttftMs > 0 {
            detailParts.append(L("agent_speed_ttft_format", AgentSpeedSummary.formatFirstTokenSeconds(ttftMs)))
        } else if summary.latestKind == .endToEndEstimated || summary.rolling24hKind == .endToEndEstimated {
            detailParts.append(L("agent_speed_includes_ttft_note"))
        }
        if let model = summary.latestModel {
            detailParts.append(model)
        }
        let detailLine = detailParts.isEmpty ? nil : detailParts.joined(separator: " · ")

        // 4. Single-line compact string for Codex account / Relay / Profile summary cards
        var inlineParts: [String] = []
        if let latestFormatted {
            inlineParts.append(latestFormatted)
        }
        if let ttftMs = summary.latestFirstTokenMs, ttftMs > 0 {
            inlineParts.append(L("agent_speed_ttft_format", AgentSpeedSummary.formatFirstTokenSeconds(ttftMs)))
        }
        if let rollingFormatted, rollingFormatted != latestFormatted || summary.rolling24hSampleCount >= 2 {
            inlineParts.append("\(L("relay_local_usage_24h")) \(rollingFormatted)")
        }
        if inlineParts.count == 1, let model = summary.latestModel {
            inlineParts.append(model)
        }
        let inlineCompactLine = inlineParts.joined(separator: " · ")

        return Self(
            badgeText: badgeText,
            primaryLine: primaryLine,
            detailLine: detailLine,
            inlineCompactLine: inlineCompactLine,
            tooltipText: L("agent_speed_readonly_tooltip"),
            requests: AgentSpeedRequestRow.rows(from: summary),
            cacheExpiresAt: AgentSpeedRequestRow.cacheExpiry(from: summary))
    }
}

struct AgentSpeedSectionContent: View {
    let presentation: AgentSpeedPresentation
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "bolt.fill")
                    .font(ConsoleDesign.text(10, weight: .semibold))
                    .foregroundStyle(ConsoleDesign.accentForeground)
                Text(L("agent_speed_section_title"))
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                Spacer(minLength: 4)
            }
            Text(self.presentation.primaryLine)
                .font(ConsoleDesign.mono(11.5, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                .lineLimit(1)
            if self.presentation.inlineRequests.isEmpty {
                if let detailLine = self.presentation.detailLine {
                    Text(detailLine)
                        .font(ConsoleDesign.mono(10))
                        .monospacedDigit()
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                AgentSpeedInlineRequestList(rows: Array(self.presentation.inlineRequests))
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(self.presentation.tooltipText)
    }
}

/// The newest replies as a small table: age, model, speed, first token, cache hit rate.
private struct AgentSpeedInlineRequestList: View {
    let rows: [AgentSpeedRequestRow]
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        let now = Date()
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            GridRow {
                ForEach(Array(AgentSpeedRequestRow.columnTitles.enumerated()), id: \.offset) { index, title in
                    Text(title)
                        .font(ConsoleDesign.text(9))
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.75))
                        .gridColumnAlignment(index >= AgentSpeedRequestRow.speedColumnIndex ? .trailing : .leading)
                }
            }
            ForEach(Array(self.rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.columns(now: now).enumerated()), id: \.offset) { index, value in
                        Text(value)
                            .font(ConsoleDesign.mono(
                                10,
                                weight: self.emphasizes(row, column: index) ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(self.color(row, column: index))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emphasizes(_ row: AgentSpeedRequestRow, column: Int) -> Bool {
        row.countsAsRealUsage && column == AgentSpeedRequestRow.speedColumnIndex
    }

    private func color(_ row: AgentSpeedRequestRow, column: Int) -> Color {
        guard row.countsAsRealUsage else {
            return MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.6)
        }
        return self.emphasizes(row, column: column)
            ? MenuHighlightStyle.primary(self.isHighlighted)
            : MenuHighlightStyle.secondary(self.isHighlighted)
    }
}

extension StatusItemController {
    func startInitialLocalAgentSpeedHydration() {
        guard !SettingsStore.isRunningTests else { return }
        self.localAgentSpeedRefreshTask?.cancel()
        self.localAgentSpeedRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshLocalAgentSpeedReport()
            self.invalidateMenus(
                refreshOpenMenus: true,
                deferOpenParentMenuRebuild: true,
                allowStaleContentDuringDataRefresh: true)
        }
    }

    func refreshLocalAgentSpeedReport(
        sources: Set<LocalAgentSpeedSource> = Set(LocalAgentSpeedSource.allCases),
        now: Date = Date()) async
    {
        let codexRequests = SpendDashboardSource.makeCodexRefreshRequest(
            settings: self.settings,
            store: self.store,
            now: now).codexRequests
        let managedHomes: [LocalAgentSpeedScanConfiguration.CodexManagedHome] = codexRequests.compactMap { req in
            guard !req.usageIdentity.isSystemUnassigned else { return nil }
            return LocalAgentSpeedScanConfiguration.CodexManagedHome(
                accountKey: req.usageIdentity.accountKey,
                homeURL: URL(fileURLWithPath: req.homePath, isDirectory: true))
        }
        let timeline = codexRequests.compactMap(\.sessionOwnershipTimeline).first
            ?? (try? FileCodexSessionOwnershipTimelineStore.default.load())
        let relayProviderMap = self.relayQuickSwitchCoordinator.providerKeyByProfileID()
        var accountKeyByVisibleID: [String: String] = [:]
        for req in codexRequests where !req.usageIdentity.isSystemUnassigned {
            accountKeyByVisibleID[req.id] = req.usageIdentity.accountKey
        }

        let configuration = LocalAgentSpeedScanConfiguration(
            codexManagedHomes: managedHomes,
            codexOwnershipTimeline: timeline,
            relayProviderKeyByProfileID: relayProviderMap)

        let scanned = await Task.detached(priority: .utility) {
            LocalAgentSpeedScanner.shared.scan(
                configuration: configuration,
                sources: sources,
                now: now)
        }.value

        guard !Task.isCancelled, !self.hasPreparedForAppShutdown else { return }
        self.codexSpeedAccountKeyByVisibleID = accountKeyByVisibleID
        if sources.count == LocalAgentSpeedSource.allCases.count || self.localAgentSpeedReport == nil {
            self.localAgentSpeedReport = scanned
        } else if let previous = self.localAgentSpeedReport {
            var mergedBySource = previous.bySource
            for source in sources {
                mergedBySource[source] = scanned.bySource[source]
            }
            self.localAgentSpeedReport = LocalAgentSpeedReport(
                updatedAt: now,
                bySource: mergedBySource,
                codexOfficialSummary: sources.contains(.codex) ? scanned.codexOfficialSummary : previous
                    .codexOfficialSummary,
                codexByAccountKey: sources.contains(.codex) ? scanned.codexByAccountKey : previous.codexByAccountKey,
                codexByHomePath: sources.contains(.codex) ? scanned.codexByHomePath : previous.codexByHomePath,
                codexByRelayProfileID: sources.contains(.codex) ? scanned.codexByRelayProfileID : previous
                    .codexByRelayProfileID,
                codexByProviderKey: sources.contains(.codex) ? scanned.codexByProviderKey : previous.codexByProviderKey,
                openCodeByProviderKey: sources.contains(.openCode) ? scanned.openCodeByProviderKey : previous
                    .openCodeByProviderKey,
                piByProviderKey: sources.contains(.pi) ? scanned.piByProviderKey : previous.piByProviderKey,
                relayCombinedByProviderKey: scanned.relayCombinedByProviderKey.merging(
                    previous.relayCombinedByProviderKey,
                    uniquingKeysWith: { new, _ in new }))
        }
    }

    func agentSpeedPresentation(for provider: UsageProvider) -> AgentSpeedPresentation? {
        guard let report = self.localAgentSpeedReport else { return nil }
        switch provider {
        case .antigravity:
            return AgentSpeedPresentation.from(report.bySource[.antigravity])
        case .claude:
            return AgentSpeedPresentation.from(report.bySource[.claude])
        case .opencode:
            return AgentSpeedPresentation.from(report.bySource[.openCode])
        case .codex:
            return AgentSpeedPresentation.from(report.bySource[.codex])
        default:
            return nil
        }
    }

    func codexAccountSpeedPresentation(for account: CodexVisibleAccount) -> AgentSpeedPresentation? {
        guard let report = self.localAgentSpeedReport else { return nil }
        if let accountKey = self.codexSpeedAccountKeyByVisibleID[account.id],
           let summary = report.codexByAccountKey[accountKey]
        {
            return AgentSpeedPresentation.from(summary)
        }
        if let storedID = account.storedAccountID {
            let managedKey = CodexSessionOwnershipTimeline.managedAccountKey(id: storedID)
            if let summary = report.codexByAccountKey[managedKey] {
                return AgentSpeedPresentation.from(summary)
            }
        }
        if let homePath = account.managedCodexHomePath ?? account.codexHomePath {
            let canonical = URL(fileURLWithPath: homePath, isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL.path
            if let summary = report.codexByHomePath[canonical] {
                return AgentSpeedPresentation.from(summary)
            }
        }
        if self.settings.codexVisibleAccountProjection.visibleAccounts.count == 1 {
            return AgentSpeedPresentation.from(report.codexOfficialSummary)
        }
        return nil
    }

    func relaySpeedPresentation(profileID: UUID, providerKey: String) -> AgentSpeedPresentation? {
        guard let report = self.localAgentSpeedReport else { return nil }
        if let combined = report.relayCombinedByProviderKey[providerKey] {
            return AgentSpeedPresentation.from(combined)
        }
        if let byProfile = report.codexByRelayProfileID[profileID] {
            return AgentSpeedPresentation.from(byProfile)
        }
        if let byProvider = report.codexByProviderKey[providerKey] {
            return AgentSpeedPresentation.from(byProvider)
        }
        return nil
    }

    func openCodeProfileSpeedPresentation(providerKey: String) -> AgentSpeedPresentation? {
        guard let report = self.localAgentSpeedReport else { return nil }
        return AgentSpeedPresentation.from(report.openCodeByProviderKey[providerKey])
    }

    var piAgentOverallSpeedPresentation: AgentSpeedPresentation? {
        guard let report = self.localAgentSpeedReport else { return nil }
        return AgentSpeedPresentation.from(report.bySource[.pi])
    }

    func piAgentProfileSpeedPresentation(providerKey: String) -> AgentSpeedPresentation? {
        guard let report = self.localAgentSpeedReport else { return nil }
        return AgentSpeedPresentation.from(report.piByProviderKey[providerKey])
    }
}
