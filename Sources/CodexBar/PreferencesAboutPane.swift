import AppKit
import SwiftUI

@MainActor
struct AboutPane: View {
    enum Section: String, CaseIterable, Identifiable {
        case about
        case updates

        var id: String {
            self.rawValue
        }
    }

    let updater: UpdaterProviding
    @State private var section: Section
    @State private var iconHover = false

    init(updater: UpdaterProviding, initialSection: Section = .about) {
        self.updater = updater
        self._section = State(initialValue: initialSection)
    }

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private var buildTimestamp: String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "CodexBuildTimestamp") as? String else { return nil }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        guard let date = parser.date(from: raw) else { return raw }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = .current
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsSubsectionPicker(L("tab_about"), selection: self.$section) {
                Text(L("tab_about")).tag(Section.about)
                Text(L("section_updates")).tag(Section.updates)
            }

            switch self.section {
            case .about:
                self.aboutForm
            case .updates:
                UpdatePane(updater: self.updater)
            }
        }
        .background(ConsoleDesign.background)
    }

    private var aboutForm: some View {
        Form {
            SwiftUI.Section {
                self.hero
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            SwiftUI.Section {
                AboutLinkRow(
                    icon: "chevron.left.slash.chevron.right",
                    title: L("link_github"),
                    url: "https://github.com/ddaxai/Headroom")
                AboutLinkRow(
                    icon: "arrow.triangle.branch",
                    title: "CodexBar Upstream",
                    url: "https://github.com/steipete/CodexBar")
                AboutLinkRow(
                    icon: "arrow.triangle.branch",
                    title: "CC Switch Upstream",
                    url: "https://github.com/farion1231/cc-switch")
            } header: {
                Text(L("section_links"))
            } footer: {
                Text(L("copyright"))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            // Update actions live only in the Updates tab above; repeating them here gave the
            // same commands two homes on one screen.
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .scrollContentBackground(.hidden)
    }

    private var hero: some View {
        VStack(spacing: 10) {
            if let image = NSApplication.shared.applicationIconImage {
                Button(action: self.openProjectHome) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 92, height: 92)
                        .cornerRadius(16)
                        .opacity(self.iconHover ? 0.85 : 1.0)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(L("link_github"))
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) {
                        self.iconHover = hovering
                    }
                }
            }

            VStack(spacing: 2) {
                Text(HeadroomIdentity.appName)
                    .font(.title3).bold()
                Text(String(format: L("version_format"), self.versionString))
                    .foregroundStyle(.secondary)
                if let buildTimestamp {
                    Text(String(format: L("built_format"), buildTimestamp))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(L("about_tagline"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func openProjectHome() {
        guard let url = URL(string: "https://github.com/ddaxai/Headroom") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
struct AboutLinkRow: View {
    let icon: String
    let title: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: self.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: self.icon)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(self.title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(self.hovering ? ConsoleDesign.accentForeground : ConsoleDesign.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.hovering = $0 }
    }
}
