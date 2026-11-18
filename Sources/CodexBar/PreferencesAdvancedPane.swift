import CodexBarCore
import SwiftUI

@MainActor
struct AdvancedPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageDomain
    @State private var keychainDiagnosticsExpanded = false
    @State private var keychainCacheStatus: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: self.$settings.hidePersonalInfo) {
                    SettingsRowLabel(L("hide_personal_info_title"), subtitle: L("hide_personal_info_subtitle"))
                }

                Toggle(isOn: self.$settings.debugDisableKeychainAccess) {
                    SettingsRowLabel(
                        L("disable_keychain_access_title"),
                        subtitle: L("disable_keychain_access_subtitle"))
                }
            } header: {
                Text(L("section_privacy"))
            } footer: {
                SettingsSectionFooter(L("keychain_access_caption"))
            }

            Section {
                DisclosureGroup(isExpanded: self.$keychainDiagnosticsExpanded) {
                    if let remaining = BrowserCookieAccessGate.chromiumFamilyCooldownRemaining() {
                        LabeledContent(
                            L("keychain_diagnostic_cooldown"),
                            value: Duration.seconds(remaining).formatted(.time(pattern: .hourMinute)))
                    } else {
                        LabeledContent(L("keychain_diagnostic_cooldown"), value: L("keychain_diagnostic_none"))
                    }

                    ForEach(Array(BrowserCookieAccessGate.recentDiagnostics().enumerated()), id: \.offset) { _, event in
                        LabeledContent(event.item) {
                            Text("\(event.result) · \(event.date.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button(L("keychain_diagnostic_open_access")) {
                            let url = URL(fileURLWithPath: "/System/Applications/Utilities/Keychain Access.app")
                            NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        }
                        Button(L("keychain_diagnostic_rebuild_cache")) {
                            let summary = CookieHeaderCache.clearAllDetailed()
                            self.keychainCacheStatus = L("keychain_diagnostic_cleared_count", summary.clearedCount)
                        }
                    }
                    if let keychainCacheStatus {
                        Text(keychainCacheStatus).foregroundStyle(.secondary)
                    }
                } label: {
                    SettingsRowLabel(
                        L("keychain_diagnostic_title"),
                        subtitle: L("keychain_diagnostic_subtitle"))
                }
            } header: {
                Text(L("section_keychain_diagnostics"))
            }

            Section {
                Toggle(isOn: self.$settings.providerStorageFootprintsEnabled) {
                    SettingsRowLabel(
                        L("show_provider_storage_usage_title"),
                        subtitle: L("show_provider_storage_usage_subtitle"))
                }

                Toggle(isOn: self.$settings.debugMenuEnabled) {
                    SettingsRowLabel(L("show_debug_settings_title"), subtitle: L("show_debug_settings_subtitle"))
                }
            } header: {
                Text(L("section_diagnostics"))
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
    }
}
