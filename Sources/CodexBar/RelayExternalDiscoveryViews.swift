import CodexBarCore
import Foundation
import SwiftUI

extension RelaySettingsModel {
    var effectiveActiveProfileIDsByTarget: [RelayTargetApp: UUID] {
        var result = self.activationState?.activeProfileIDsByTarget ?? [:]
        guard let report = self.externalConfigurationReport else { return result }
        for (target, route) in report.liveRouteByTarget {
            switch route {
            case let .managedProfile(profileID):
                result[target] = profileID
            case .official, .external:
                result.removeValue(forKey: target)
            }
        }
        return result
    }

    var discoveredExternalRelays: [DiscoveredExternalRelay] {
        self.externalConfigurationReport?.unimportedRelays ?? []
    }

    func externalActiveName(for target: RelayTargetApp) -> String? {
        guard case let .external(_, displayName) = self.externalConfigurationReport?.liveRouteByTarget[target] else {
            return nil
        }
        return displayName
    }

    func refreshExternalConfiguration() {
        self.externalConfigurationReport = self.actions.inspectExternalConfiguration(self.profiles)
    }

    func importExternalRelay(_ external: DiscoveredExternalRelay) {
        do {
            let profile = external.makeRelayProfile(
                existingProfiles: self.profiles,
                externalProviderBaseURLsByKey: self.externalConfigurationReport?.externalProviderBaseURLsByKey ?? [:])
            let importedKey = external.importableAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !importedKey.isEmpty {
                try self.actions.storeCredential(importedKey, profile.credentialReference)
            }

            var updated = self.profiles.filter { $0.id != profile.id }
            updated.append(profile)
            updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            do {
                try self.actions.storeProfiles(updated)
            } catch {
                if !importedKey.isEmpty {
                    try? self.actions.removeCredential(profile.credentialReference)
                }
                throw error
            }

            self.profiles = updated
            self.loadedProfileIDs.insert(profile.id)
            self.externalConfigurationReport = self.actions.inspectExternalConfiguration(updated)
            self.selectProfile(profile.id)
            self.status = .importedExternal(profile.name)
        } catch {
            self.status = .failed(error.localizedDescription)
        }
    }

    func importAllExternalRelays() {
        let pending = self.discoveredExternalRelays
        guard !pending.isEmpty else { return }
        var updated = self.profiles
        var storedReferences: [String] = []
        var importedIDs: [UUID] = []

        do {
            for external in pending {
                let profile = external.makeRelayProfile(
                    existingProfiles: updated,
                    externalProviderBaseURLsByKey: self.externalConfigurationReport?
                        .externalProviderBaseURLsByKey ?? [:])
                let importedKey = external.importableAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !importedKey.isEmpty {
                    try self.actions.storeCredential(importedKey, profile.credentialReference)
                    storedReferences.append(profile.credentialReference)
                }
                updated.append(profile)
                importedIDs.append(profile.id)
            }
            updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            try self.actions.storeProfiles(updated)
            self.profiles = updated
            self.loadedProfileIDs.formUnion(importedIDs)
            self.externalConfigurationReport = self.actions.inspectExternalConfiguration(updated)
            if let firstImported = importedIDs.first {
                self.selectProfile(firstImported)
            }
            self.status = .importedAllExternal(importedIDs.count)
        } catch {
            for reference in storedReferences {
                try? self.actions.removeCredential(reference)
            }
            self.status = .failed(error.localizedDescription)
        }
    }
}

@MainActor
struct RelayExternalDiscoverySidebarSection: View {
    @Bindable var model: RelaySettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.caption)
                    .foregroundStyle(ConsoleDesign.accentForeground)
                Text(L("relay_external_detected_header", self.model.discoveredExternalRelays.count))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if self.model.discoveredExternalRelays.count > 1 {
                    Button(L("relay_external_import_all_action")) {
                        self.model.importAllExternalRelays()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            Text(L("relay_external_detected_subtitle"))
                .font(.caption2)
                .foregroundStyle(ConsoleDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(self.model.discoveredExternalRelays) { external in
                        self.externalRow(external)
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .padding(10)
        .background(ConsoleDesign.surface.opacity(0.6))
    }

    private func externalRow(_ external: DiscoveredExternalRelay) -> some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(external.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if !external.activeTargets.isEmpty {
                        Circle()
                            .fill(ConsoleDesign.accent)
                            .frame(width: 5, height: 5)
                            .help(L("relay_usage_card_status_active"))
                    }
                }
                Text(self.metadataLine(for: external))
                    .font(.caption2)
                    .foregroundStyle(ConsoleDesign.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(L("relay_external_import_action")) {
                self.model.importExternalRelay(external)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help(external.baseURL.absoluteString)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: ConsoleDesign.radiusControl, style: .continuous)
                .fill(ConsoleDesign.surface2))
    }

    private func metadataLine(for external: DiscoveredExternalRelay) -> String {
        let apps = external.configuredTargets
            .map(RelaySettingsModel.displayName(for:))
            .joined(separator: " · ")
        let credentialNote = external.hasImportableAPIKey
            ? L("relay_external_has_key")
            : L("relay_external_needs_key")
        return "\(apps) · \(credentialNote)"
    }
}
