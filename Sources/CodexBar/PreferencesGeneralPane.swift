import AppKit
import CodexBarCore
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case chineseSimplified = "zh-Hans"

    var id: String {
        self.rawValue
    }

    var label: String {
        L(self.labelKey, language: self.labelLanguage)
    }

    private var labelLanguage: String {
        switch self {
        case .system, .english:
            "en"
        case .chineseSimplified:
            "zh-Hans"
        }
    }

    private var labelKey: String {
        switch self {
        case .system: "language_system"
        case .english: "language_english"
        case .chineseSimplified: "language_chinese_simplified"
        }
    }
}

enum PreferredCurrencyOption: String, CaseIterable, Identifiable {
    case auto
    case usd = "USD"
    case gbp = "GBP"
    case eur = "EUR"
    case cny = "CNY"
    case jpy = "JPY"
    case cad = "CAD"
    case aud = "AUD"
    case hkd = "HKD"
    case twd = "TWD"
    case sgd = "SGD"
    case inr = "INR"

    var id: String {
        self.rawValue
    }

    var label: String {
        switch self {
        case .auto: L("currency_auto")
        case .usd: "USD ($)"
        case .gbp: "GBP (£)"
        case .eur: "EUR (€)"
        case .cny: "CNY (¥)"
        case .jpy: "JPY (¥)"
        case .cad: "CAD ($)"
        case .aud: "AUD ($)"
        case .hkd: "HKD ($)"
        case .twd: "TWD (NT$)"
        case .sgd: "SGD ($)"
        case .inr: "INR (₹)"
        }
    }
}

@MainActor
struct GeneralPane: View {
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                SettingsMenuPicker(
                    selection: self.$settings.appLanguage,
                    options: GeneralSettingsMenuOptions.languages,
                    label: {
                        SettingsRowLabel(L("language_title"), subtitle: L("language_subtitle"))
                    },
                    optionLabel: { rawValue in
                        Text(verbatim: AppLanguage(rawValue: rawValue)?.label ?? rawValue)
                    })

                SettingsMenuPicker(
                    selection: self.$settings.preferredCurrencyCode,
                    options: PreferredCurrencyOption.allCases.map(\.rawValue),
                    label: {
                        SettingsRowLabel(L("currency_title"), subtitle: L("currency_subtitle"))
                    },
                    optionLabel: { rawValue in
                        Text(verbatim: PreferredCurrencyOption(rawValue: rawValue)?.label ?? rawValue)
                    })
                    .onChange(of: self.settings.preferredCurrencyCode) { _, newValue in
                        guard CurrencyExchange.requiresLiveRates(preferredCurrencyCode: newValue) else { return }
                        Task {
                            await CurrencyExchange.shared.fetchLatestRatesIfNeeded(
                                preferredCurrencyCode: newValue)
                        }
                    }

                SettingsMenuPicker(
                    selection: self.$settings.terminalApp,
                    options: GeneralSettingsMenuOptions.terminalApps(selected: self.settings.terminalApp),
                    label: {
                        SettingsRowLabel(L("terminal_app_title"), subtitle: L("terminal_app_subtitle"))
                    },
                    optionLabel: { option in
                        HStack(spacing: 6) {
                            if let icon = option.pickerIcon {
                                Image(nsImage: icon)
                            }
                            Text(option.label)
                        }
                    })

                Toggle(L("start_at_login_title"), isOn: self.$settings.launchAtLogin)

                Toggle(isOn: self.$settings.windowAlwaysOnTop) {
                    SettingsRowLabel(
                        L("settings_window_always_on_top"),
                        subtitle: L("settings_window_always_on_top_help"))
                }
            } header: {
                Text(L("section_system"))
            }

            Section {
                SettingsMenuPicker(
                    selection: self.$settings.refreshFrequency,
                    options: GeneralSettingsMenuOptions.refreshFrequencies,
                    label: { Text(L("refresh_interval_title")) },
                    optionLabel: { option in Text(option.label) })

                SettingsMenuPicker(
                    selection: self.$settings.localUsageRefreshMode,
                    options: GeneralSettingsMenuOptions.localUsageRefreshModes,
                    label: {
                        SettingsRowLabel(
                            L("local_usage_refresh_mode_title"),
                            subtitle: L("local_usage_refresh_mode_subtitle"))
                    },
                    optionLabel: { option in Text(option.label) })

                Toggle(L("refresh_on_open_title"), isOn: self.$settings.refreshAllProvidersOnMenuOpen)

                Toggle(isOn: self.$settings.statusChecksEnabled) {
                    SettingsRowLabel(
                        L("check_provider_status_title"),
                        subtitle: L("check_provider_status_subtitle"))
                }
            } header: {
                Text(L("section_refreshing"))
            } footer: {
                if self.settings.refreshFrequency == .manual {
                    SettingsSectionFooter(L("manual_refresh_hint"))
                } else if self.settings.localUsageRefreshMode == .realtime,
                          self.settings.localUsageRealtimeStatus == .scheduledFallback
                {
                    SettingsSectionFooter(L("local_usage_refresh_fallback"))
                }
            }

            Section {
                LabeledContent(L("open_menu_shortcut_title")) {
                    OpenMenuShortcutRecorder()
                }
            } header: {
                Text(L("section_keyboard_shortcut"))
            }

            Section {
                HStack {
                    Spacer()
                    Button(L("restart_app")) {
                        guard HeadroomRelaunchCoordinator.scheduleRelaunch() else { return }
                        NSApp.terminate(nil)
                    }
                    Button(L("quit_app")) { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
        .background(FocusResigningBackground())
    }
}
