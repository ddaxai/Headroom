# UI/UX pass: problems found but not fixed

Found while doing the UI/UX pass on branch `claude/wizardly-cannon-tqel7y` (based on `headroom/v0.50-stabilize`).
That branch only changes UI/UX and copy. The items below were **not** changed there and are left for a follow-up.
GitHub Issues are disabled on this repository, so the list lives here.

Nothing on that branch has been compiled yet: it was written in a Linux container with no Swift toolchain.
**First step for whoever picks this up: run `make check` and `make test` on a Mac against
`claude/wizardly-cannon-tqel7y`, then launch the packaged app and look at Settings and the menu bar popup.**

## Needs a decision

1. **Notifications pane can't be reached.** `SettingsPane.notifications.regularPane` maps to `.usageSpend`, and
   nothing in the regular UI navigates to it. `PreferencesSelectionTests` lists it as a hidden pane on purpose.
   Quota-depleted, threshold and predictive-pace alerts still fire, but users can't turn them off or tune them.
   Either add it back (for example as a second tab under Usage & Cost via `SettingsSubsectionPicker`) or stop
   sending those alerts.
2. **The local meter toggle only works one way.** `RelaySettingsPane` shows the `localMeterEnabled` toggle only while
   the meter is on (`if self.settings.localMeterEnabled { … Toggle … }`). Once it's off, it can't be turned back on
   from the UI. If it's a kill switch for a retired feature, label it that way. If not, show it all the time.
3. **"⚡ Fast" speed label.** `codex_speed_fast` = `⚡ Fast` / `⚡ 快速`. The README names the button that way, so the
   UI pass left it alone. unslop advises against emoji used as icons. Consider plain `Fast`, or an SF Symbol in the
   button.

## Settings window

4. **Title-bar accessory still needs a check on a real Mac.** `SettingsTitlebarControlsController` (sidebar toggle
   and pin) uses `layoutAttribute = .left` inside a `NavigationSplitView` window, and
   `NinthRoundN4SettingsShellTests` asserts that layout. The UI pass added `.toolbar(removing: .sidebarToggle)` to
   remove the second, system sidebar toggle that SwiftUI adds. Whether the accessory itself still moves when the
   sidebar collapses, the sidebar is resized or the title changes can only be confirmed by looking at it. If it still
   moves, a SwiftUI `ToolbarItem` for the pin is the likely fix, and the source assertion
   `!source.contains(".toolbar {")` would need updating.
5. **Unused code in `PreferencesSidebar.swift`.** `RelaySettingsSidebarRow`, `SettingsSidebarPaneRow`,
   `SettingsSidebarAboutRow`, `SettingsSidebarProviderRow` (plus `SettingsSidebarBrandIcon` and
   `SettingsSidebarStatusDot`, which only that row uses), `SettingsSidebarSearchField` and
   `SettingsSidebarSortToggle` are private and never referenced.
6. **The legacy `PreferencesProviderManagementPane.swift` still has hard-coded Chinese** (`Text("服务商")`,
   `TextField("搜索服务商", …)`, `Toggle("显示未配置", …)`). It appears unreachable from the narrow entry. Delete it
   or localize it.
7. **Two localization keys are missing in both catalogs:** `Could not start Claude Code login` and
   `claude auth login exited with status %d.` (`StatusItemController+Actions.swift`).
8. **Sidebar width is written on every layout pass.** `PreferencesView` and `RelaySettingsPane` write `sidebarWidth`
   and `relayListWidth` to `UserDefaults` from a `PreferenceKey` on every pass that changes the width by 0.5pt or
   more, which includes live dragging. Consider writing once the drag ends, or debouncing.

## Menu bar popup

9. **`HeadroomPopupCardStack` uses `@ObservedObject var presentation: HeadroomPopupPresentationModel`.** AGENTS.md
   prefers `@Observable` with `@State` and `@Bindable`.
10. **`MenuCardView.groupHeader` uses `.textCase(.uppercase)`.** It only applies to the Doubao split, which upstream
    code still includes. Sentence case would match the rest of the UI.

## Naming and identity (rename to Headroom)

11. **The user-facing name is now Headroom** in the string catalogs, the status-item accessibility title, the share
    card and the relay accessibility labels. These internal identifiers were left as `CodexBar` on purpose, because
    changing them breaks migration or installed paths:
    - SwiftPM targets and products (`CodexBar`, `CodexBarCLI`, `CodexBarCore`, …) and the `codexbar` CLI name
    - `~/Library/Logs/CodexBar`, `Application Support/CodexBar`, the `CodexBar.StatusItem*` autosave names and the
      `com.steipete.codexbar` legacy defaults domain
    - the default source-update checkout `~/Developer/CodexBar` and the clone URL `git@github.com:ddaxai/CodexBar.git`

    If a full rename is wanted, plan a migration for each one. **The GitHub repository name (`ddaxai/CodexBar`) can
    only be changed by the owner** under Settings → General → Repository name. GitHub redirects the old URL, but
    update `HeadroomSourceUpdate.swift`, `PreferencesAboutPane.swift` and `About.swift` afterwards.

## Verification gap

12. **No macOS build was run for the UI branch.** CI's macOS jobs run only on pull requests and on pushes to `main`.
    This repo is private, so macOS runner minutes count against the account's Actions quota at a higher rate than
    Linux.
