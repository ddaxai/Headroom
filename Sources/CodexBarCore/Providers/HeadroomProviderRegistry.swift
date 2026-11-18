public enum HeadroomProviderRegistry {
    public static let launchDirectoryNames = [
        "Shared", "Codex", "Claude", "Antigravity", "OpenCode", "Sub2API",
    ]

    public static let providerIDs: [UsageProvider] = [
        .codex, .claude, .antigravity, .opencode, .sub2api,
    ]

    public static var descriptors: [ProviderDescriptor] {
        self.providerIDs.map { ProviderDescriptorRegistry.descriptor(for: $0) }
    }

    public static func descriptor(for id: UsageProvider) -> ProviderDescriptor? {
        guard self.providerIDs.contains(id) else { return nil }
        return ProviderDescriptorRegistry.descriptor(for: id)
    }
}
