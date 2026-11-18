import CodexBarCore
import Foundation

extension UsageStore {
    func refreshProviderStatus(_ provider: UsageProvider) async {
        guard self.settings.statusChecksEnabled else { return }
        guard let meta = self.providerMetadata[provider] else { return }
        let publicationRevision = self.providerPublicationRevision(for: provider)
        self.providerStatusRequestGeneration &+= 1
        let requestGeneration = self.providerStatusRequestGeneration

        do {
            let status: ProviderStatus
            var components: [ProviderStatusComponent]?
            if let override = self._test_providerStatusFetchOverride {
                status = try await override(provider)
            } else if let urlString = meta.statusPageURL, let baseURL = URL(string: urlString) {
                let summary = try await Self.fetchStatusSummary(from: baseURL)
                status = summary.status
                components = summary.components
            } else if let productID = meta.statusWorkspaceProductID {
                status = try await Self.fetchWorkspaceStatus(productID: productID)
            } else {
                return
            }
            guard self.statusRefreshPublicationIsCurrent(
                publicationRevision, requestGeneration: requestGeneration, for: provider) else { return }
            // Only successful evidence retires older requests; a newer failure cannot hide
            // an older success that is still useful.
            self.providerStatusPublishedGenerations[provider] = requestGeneration
            self.statuses[provider] = status
            // A component endpoint is best-effort. Preserve the last good list when the
            // overall status succeeds but the component request or decoding fails.
            if let components {
                self.statusComponents[provider] = components
            }
            self.emitProviderStatusHooks(provider: provider, indicator: status.indicator)
        } catch {
            guard self.statusRefreshPublicationIsCurrent(
                publicationRevision, requestGeneration: requestGeneration, for: provider) else { return }
            self.recordStartupConnectivityRetryableFailure(error)
            // Keep the previous status to avoid flapping when the API hiccups.
            if self.statuses[provider] == nil {
                self.statuses[provider] = ProviderStatus(
                    indicator: .unknown,
                    description: error.localizedDescription,
                    updatedAt: nil)
            }
        }
    }

    private func statusRefreshPublicationIsCurrent(
        _ publicationRevision: ProviderPublicationRevision,
        requestGeneration: UInt64,
        for provider: UsageProvider) -> Bool
    {
        self.providerPublicationRevisionIsCurrent(publicationRevision, for: provider) &&
            requestGeneration >= self.providerStatusPublishedGenerations[provider, default: 0] &&
            self.settings.statusChecksEnabled &&
            self.settings.isProviderEnabledCached(
                provider: provider,
                metadataByProvider: self.providerMetadata)
    }
}
