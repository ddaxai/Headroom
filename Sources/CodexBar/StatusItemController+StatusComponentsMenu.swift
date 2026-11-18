import AppKit
import CodexBarCore

extension StatusItemController {
    /// Providers that surface the live component list as a native submenu. Every other provider
    /// keeps the plain "Status Page" link that opens the website. Kept deliberately small: these
    /// are the statuspage.io/incident.io feeds we actively curate and trust to render well.
    static let statusComponentsSubmenuProviders: Set<UsageProvider> = [.claude, .codex, .augment, .zoommate]

    /// Filters `components` down to a provider's descriptor-owned named allowlist, if configured;
    /// returns `components` unchanged when the provider has no allowlist. Matching is by exact
    /// `name` equality at the top level only (groups and leaves alike).
    static func filterStatusComponents(
        _ components: [ProviderStatusComponent],
        for provider: UsageProvider) -> [ProviderStatusComponent]
    {
        let metadata = ProviderDescriptorRegistry.descriptor(for: provider).metadata
        guard let allowlist = metadata.statusComponentAllowlist else { return components }
        return components.filter { allowlist.contains($0.name) }
    }

    /// For curated providers, turns the status-page row into a submenu of live component
    /// statuses instead of a direct website link (the link moves to the bottom of the submenu).
    func attachStatusComponentsSubmenuIfNeeded(
        to item: NSMenuItem,
        action: MenuDescriptor.MenuAction,
        menu: NSMenu,
        width: CGFloat)
    {
        guard action == .statusPage,
              let statusProvider = self.menuProvider(for: menu) ?? self.lastMenuProvider,
              let submenu = self.makeStatusComponentsSubmenu(provider: statusProvider, width: width)
        else { return }
        item.action = nil
        item.submenu = submenu
    }

    func makeStatusComponentsSubmenu(provider: UsageProvider, width: CGFloat? = nil) -> NSMenu? {
        guard self.store.statusChecksEnabled else { return nil }
        guard Self.statusComponentsSubmenuProviders.contains(provider) else { return nil }
        guard ProviderDescriptorRegistry.descriptor(for: provider).metadata.statusPageURL != nil else { return nil }
        if let width {
            return self.makeHostedSubviewPlaceholderMenu(
                chartID: Self.statusComponentsID,
                provider: provider,
                width: width)
        }
        return self.makeHostedSubviewPlaceholderMenu(chartID: Self.statusComponentsID, provider: provider)
    }
}
