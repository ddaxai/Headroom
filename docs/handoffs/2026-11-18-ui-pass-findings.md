# UI/UX pass: problems found but not fixed

Found while doing the UI/UX pass on branch `claude/ui-ux-pass`.
That branch only changes UI/UX and copy. The items below were **not** changed there and are left for a follow-up.

The branch was written in a Linux container with no Swift toolchain. Its macOS CI run is the first compile;
after that, launch the packaged app and look at Settings and the menu bar popup.

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
   CI on `macos-15-intel` already shows a geometry problem:
   `settings titlebar accessory exposes the full pin button frame` fails at
   `NinthRoundN4SettingsShellTests.swift:90` with `outsideRoot("pin")`, while the accessory width is still 56.
   So part of the pin button's frame lies outside the accessory view, which can leave part of the button unclickable.
   It also fails on the CI baseline branch, so the UI pass didn't cause it. Check the button frames in that window on
   macOS 15 before changing the layout.
Items 5–8 (unused sidebar views, the legacy provider management pane, two missing localization keys, split widths
written on every layout pass) are fixed.

## Menu bar popup

Items 9–10 (`@ObservedObject` in `HeadroomPopupCardStack`, uppercase group header) are fixed.

## Naming and identity (rename to Headroom)

11. **The user-facing name is now Headroom** in the string catalogs, the status-item accessibility title, the share
    card and the relay accessibility labels. These internal identifiers were left as `CodexBar` on purpose, because
    changing them breaks migration or installed paths:
    - SwiftPM targets and products (`CodexBar`, `CodexBarCLI`, `CodexBarCore`, …) and the `codexbar` CLI name
    - `~/Library/Logs/CodexBar`, `Application Support/CodexBar`, the `CodexBar.StatusItem*` autosave names and the
      `com.steipete.codexbar` legacy defaults domain

    If a full rename is wanted, plan a migration for each one. The source updater and About links already point
    at `https://github.com/ddaxai/Headroom` (`main`, checkout `~/Developer/Headroom`).

## Verification gap

12. **CI coverage.** CI's macOS jobs run only on pull requests and on pushes to `main`; open a pull request to get
    a macOS build of a branch.
