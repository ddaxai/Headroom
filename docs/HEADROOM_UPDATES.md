# Headroom updates / Headroom 更新

## Build 124: seventh-round Q4 menu information architecture / 第七轮 Q4 菜单信息架构

The status menu now presents the Codex overview in explicit groups: official accounts first,
API / Relay profiles second, System / Unassigned history third, and the grand total last. Each
official account card reads only the account-scoped token snapshot; it no longer borrows or
pro-rates another account's history. The old combined “official login · local history total” card
and the legacy “Codex accounts and API” entry have been removed. The official group header owns
the account checkmark submenu, and its checkmark follows the live system account rather than the
currently selected managed usage card.

顶部菜单现在按明确分组显示 Codex 概览：先是官方账号，其次是 API / 中转站，再是系统 / 未归属历史，最后是总计。
每个官方账号卡片只读取该账号范围内的 Token 快照，不再借用或平摊其他账号的历史记录。旧的“官方登录 · 本机历史合计”
卡片和“Codex 账号与 API”入口已移除。官方账号组头负责账号勾选子菜单，勾选状态跟随当前 live system account，而不是当前用量卡片选中的托管账号。

Relay switching is condensed into one provider-and-pill row with an inline settings button. The
standalone heading, duplicate provider switcher, and orphan placeholder are gone; wrapped pills,
actionable blockers, and the fixed two-line feedback area retain stable height fingerprints. The
footer now keeps only Settings and More at the root. More contains Add Account (only when Codex is
enabled), Refresh All, Open Logs, Check Updates, About, and Quit. Check Updates is disabled with a
reason when the updater is unavailable, and refresh actions keep their command shortcuts and
provider/global scope when invoked from the nested menu.

中转切换器合并为一行服务商与 pills，并把设置按钮放在同一行；独立标题、重复的服务商切换器和孤立占位均已删除。
换行的 pills、可操作的阻塞提示和固定双行反馈区继续使用稳定的高度指纹。底部根层只保留“设置”和“更多”；“更多”包含“添加账号”（仅在启用 Codex 时显示）、
“刷新全部”、“打开日志”、“检查更新”、“关于”和“退出”。更新器不可用时“检查更新”会禁用并显示原因；嵌套菜单中的刷新仍保留快捷键及 provider/global 作用域。

Focused validation passed the Q4 presentation, account grouping, footer architecture, menu-card
height fingerprint, and targeted menu refresh regressions. CostUsage validation was split into
serial groups: 356 tests passed across 25 suites, including scanner, cache, attribution, split
normalization, and Pi-session coverage. Keychain-prompt and live-account tests were intentionally
excluded. The local menu remains conservative for shared Codex history: sessions without reliable
provenance stay under System / Unassigned instead of being guessed into an individual account.

聚焦验证通过了 Q4 展示、账号分组、底部信息架构、菜单卡片高度指纹和定向菜单刷新回归测试。CostUsage 验证拆成串行小组执行：25 个套件共 356 个测试全部通过，覆盖扫描器、缓存、归属、拆分归一化和 Pi 会话；有意排除了会触发钥匙串提示的测试及 live 账号测试。对于共享 Codex 历史，菜单仍采取保守策略：没有可靠来源归属的会话保留在“系统 / 未归属”，不会猜测分配给某个账号。

## Build 117: relay switching fallback / 中转切换兜底

Codex relay switching no longer fails solely because unified-history migration could not complete.
Machines without existing Codex sessions skip the migration confirmation, while migration errors are
shown in a stable two-line feedback area with copyable details. Blocked provider pills expose their
reason on hover and click, missing-model errors link directly to Relay Settings, and the settings pane
can fill the current default model ID into every enabled client.

Codex 中转切换不再仅因统一历史迁移失败而中止。没有既有 Codex 会话的机器会跳过迁移确认；迁移错误
显示在稳定的双行反馈区，并可查看和复制完整详情。被阻止的供应商按钮会在悬浮和点击时显示原因；缺少
模型时可直达中转站设置；设置页可把当前默认模型 ID 一次填入所有已启用客户端。

Restoring an official Codex baseline that originally had no `config.toml` now removes the generated
file. The success message also distinguishes a Mac where Codex is not signed in.

若官方 Codex baseline 原本不存在 `config.toml`，恢复时现在会删除切换产生的文件；成功提示也会明确
区分本机尚未登录 Codex 的情况。

## Build 116: fixed-width Storage row / 固定宽度存储行

The remaining right-side column was caused by the native Storage menu item, not by the account-card
submenus. Its attributed title placed a tab stop near the 360-point content edge, after which AppKit
added native menu padding and submenu space and widened the root menu. Storage now uses the same
fixed-width `ConsoleMenuRowView` as the other console rows, while preserving the footprint value,
hover highlight, chevron, and breakdown submenu.

残留的右侧空列来自原生“存储”菜单项，而不是账号卡片的子菜单。旧实现把 attributed title 的制表位
放在 360pt 内容边缘附近，随后 AppKit 又叠加原生菜单边距和子菜单空间，导致根菜单被撑宽。现在“存储”
改用与其他控制台行一致的固定宽度 `ConsoleMenuRowView`，同时保留容量数值、悬浮高亮、箭头和明细子菜单。

Regression coverage now asserts the Storage row and its parent menu both remain exactly at the
configured menu-card width, and that the trailing footprint and submenu stay present.

回归测试现在会同时断言“存储”行和父菜单严格保持设定的卡片宽度，并确认右侧容量文字和子菜单仍然存在。

## Build 115: fifth-round palette and menu UX / 第五轮主题与菜单体验

This build adds five selectable console palettes (Console Blue, Slate Teal, Nocturne Violet,
Amber Graphite, and Daylight Paper), persists the selected palette, and applies the corresponding
appearance across the settings window and status menu. Account, official-total, relay, and grand-total
cards use a consistent 30-point detail rail; card refresh controls remain independent; Reset Credits
data stays visible; provider pills are no longer duplicated inside relay cards; and primary-card token
figures use fixed two-decimal million units such as `0.12M` and `1.00M`.

本构建加入五套可选控制台主题（Console Blue、Slate Teal、Nocturne Violet、Amber Graphite 和
Daylight Paper），持久化所选主题，并将对应外观统一应用到设置窗口与状态菜单。账号、官方汇总、中转站
和总计卡片使用一致的 30pt 详情轨；每张卡片保留独立刷新；Reset Credits 数据继续显示；中转站卡片不再
重复展示供应商 pills；首页卡片 Token 固定用两位小数的百万单位，例如 `0.12M` 和 `1.00M`。

The status menu's custom rows could mount after AppKit had already created a light Aqua tracking
window. Dark palette content then covered only the custom row width, exposing white strips in the
native submenu gutter and around native rows. Menu hosting views now synchronize the tracking
window's appearance and backing color when they actually attach to it. This preserves the existing
cards, detail rails, submenus, and theme colors while removing the mismatched side area.

状态菜单的自定义行可能在 AppKit 已经创建浅色 Aqua 跟踪窗口后才挂载。深色主题内容只覆盖自定义行宽度，
因而会在原生子菜单留白和原生菜单行周围露出白色侧条。现在菜单承载视图会在真正挂载到窗口时，同步该
窗口的外观与主题底色；原有卡片、详情轨、子菜单和主题配色均保持不变，同时移除不一致的侧边区域。

Focused regression coverage verifies the hosting-view lifecycle repair, palette appearance mapping,
card reuse, hosted submenu refresh, and provider-switcher layout.

聚焦回归覆盖承载视图生命周期修复、主题外观映射、卡片复用、详情子菜单刷新和服务商切换栏布局。

## Private source updater / 私有源码更新器

For installations built directly from the source repository, Headroom includes a local source updater. It fetches the configured branch, compares commits, builds only when a newer commit is available, and then replaces the installed app.

对于直接从源码仓库构建的安装，Headroom 提供本地源码更新脚本。它会拉取指定分支、比较 commit，只在存在新 commit 时构建，然后替换本机 App。

Check without changing the checkout or app:

只检查，不修改源码或 App：

```bash
~/Developer/Headroom/Scripts/update_headroom.sh --check-only
```

Fetch, build, install, and relaunch when an update exists:

发现更新后拉取、构建、安装并重新启动：

```bash
~/Developer/Headroom/Scripts/update_headroom.sh
```

The defaults are:

默认值如下：

- Source / 源码目录: `~/Developer/Headroom`
- Branch / 分支: `main`
- Remote / 远端: the current branch's configured remote, otherwise `origin` / 当前分支配置的远端，否则为 `origin`
- Append-only log / 追加日志: `~/Library/Logs/Headroom/update.log`

Override the checkout, branch, or remote for another authorized clone:

如需使用另一个已授权的 clone，可覆盖源码目录或分支：

```bash
HEADROOM_SOURCE_DIR=/path/to/Headroom \
HEADROOM_BRANCH=main \
HEADROOM_REMOTE=fork \
  /path/to/Headroom/Scripts/update_headroom.sh
```

### Update guarantees / 更新保护

The updater follows this fixed sequence:

更新器严格按以下顺序执行：

1. Verify the source directory, branch, and tracked working tree. A clean checkout is moved to the requested local branch when that branch already exists.
2. Fetch `$HEADROOM_REMOTE/$HEADROOM_BRANCH` with non-interactive Git/SSH settings and compare its commit with local `HEAD`.
3. Emit a structured `HEADROOM_UPDATE_STATUS=...` line for `available`, `up_to_date`, `local_ahead`, `diverged`, `scheduled`, `completed`, or `failed`.
4. Exit without compiling when both commits are equal, or report only when `--check-only` is used.
5. Refuse to replace local-ahead or diverged commits unless the caller explicitly supplies `--allow-local-reset`. Untracked files require `--ignore-untracked`; they are never removed by `git clean`.
6. Run `ARCHES=arm64 package_relay_app.sh release`, then submit `finalize_headroom_update.sh` through `launchctl`. The finalizer stops the old process, installs the bundle, and lets the installer relaunch it outside the updater's process tree.

1. 检查源码目录、已跟踪改动和当前分支；本地已有目标分支时会从干净 checkout 自动切换过去。
2. 使用禁止交互的 Git/SSH 拉取 `$HEADROOM_REMOTE/$HEADROOM_BRANCH`，并把远端 commit 与本地 `HEAD` 比较。
3. 输出结构化的 `HEADROOM_UPDATE_STATUS=...`，区分 `available`、`up_to_date`、`local_ahead`、`diverged`、`scheduled`、`completed` 和 `failed`。
4. commit 相同时直接退出且不编译；使用 `--check-only` 时只报告比较结果。
5. 本地领先或分叉时，除非调用方明确传入 `--allow-local-reset`，否则拒绝替换；未跟踪文件必须显式传入 `--ignore-untracked`，绝不自动执行 `git clean`。
6. 先执行 `ARCHES=arm64 package_relay_app.sh release`，再用 `launchctl` 提交 `finalize_headroom_update.sh`。收尾脚本脱离更新器进程树执行停止、安装，最后由安装脚本重新启动 App。

If tracked local changes exist, the updater aborts before `reset --hard`, packaging, stopping, or installing. Untracked files can be explicitly ignored with `--ignore-untracked`, but are never deleted. A local-ahead or diverged branch requires an explicit `--allow-local-reset`; without it the updater reports a structured safety failure and preserves the checkout. A successful update intentionally makes the selected local branch match the fetched branch.

如果存在已跟踪的本地改动，更新器会在 `reset --hard`、构建、停止和安装之前中止。未跟踪文件可以通过 `--ignore-untracked` 明确忽略，但绝不会被删除。本地领先或分叉时必须显式传入 `--allow-local-reset`；否则更新器会输出结构化安全失败状态并保留 checkout。成功更新会让所选本地分支与刚拉取的分支一致。

Settings maps these failures to recovery controls: preserve and ignore untracked files, confirm replacement of local-only commits, copy the SSH verification command, or reveal/choose the source checkout. After relaunch, Headroom continues observing the append-only log until the detached finalizer reports `completed` or `failed`.

设置页会把这些失败映射为直接修复操作：保留并忽略未跟踪文件、确认替换仅存在于本地的提交、复制 SSH 检查命令，或显示/重新选择源码目录。重新启动后，Headroom 会继续观察追加日志，直到脱离式收尾进程报告 `completed` 或 `failed`。

Every stage is printed in the terminal and appended to the update log. If a command fails, its exit status is preserved and the last 20 log lines are printed to standard error. The complete history remains in `~/Library/Logs/Headroom/update.log`.

每个阶段都会显示在终端并追加到更新日志。命令失败时，脚本会保留原始退出状态，并把日志最后 20 行输出到标准错误；完整历史保存在 `~/Library/Logs/Headroom/update.log`。

The source repository `ddaxai/Headroom` is public, so fetching needs no GitHub authorization. The updater never stores or embeds a GitHub token.

源码仓库 `ddaxai/Headroom` 是公开的，拉取不需要 GitHub 权限。更新器不会保存或内置 GitHub token。

## One-time setup on another Mac / 另一台 Mac 的一次性准备

1. No access request is needed: `ddaxai/Headroom` is public.
2. On that Mac, install the full Xcode release that provides Swift 6.2 and WidgetKit builds. Command Line Tools alone are not enough for release packaging.
3. Clone the repository:

```bash
git clone https://github.com/ddaxai/Headroom.git ~/Developer/Headroom
cd ~/Developer/Headroom
```

4. Build and install once from Terminal:

```bash
ARCHES=arm64 ./Scripts/package_relay_app.sh release
./Scripts/stop_headroom.sh
./Scripts/install_headroom.sh
```

5. In Headroom Settings > Updates, select `~/Developer/Headroom` as the source directory. Future updates can use **Check and update**.

1. 不需要申请权限：`ddaxai/Headroom` 是公开仓库。
2. 在朋友的 Mac 上安装提供 Swift 6.2 和 WidgetKit 构建能力的完整 Xcode；只有 Command Line Tools 不足以完成 release 打包。
3. clone 仓库：

```bash
git clone https://github.com/ddaxai/Headroom.git ~/Developer/Headroom
cd ~/Developer/Headroom
```

4. 先在终端完整构建和安装一次：

```bash
ARCHES=arm64 ./Scripts/package_relay_app.sh release
./Scripts/stop_headroom.sh
./Scripts/install_headroom.sh
```

5. 在 Headroom 设置 > 更新中选择 `~/Developer/Headroom` 作为源码目录；以后使用“检查并更新”即可。

## Current state / 当前状态

The source repository `ddaxai/Headroom` is public. The installed Headroom build currently has an empty `SUFeedURL` and is signed as `CodexBar Development`, so Sparkle correctly disables the update button. This is why pushing a commit to the source repository does not make the local app update automatically.

源码仓库 `ddaxai/Headroom` 是公开的。当前安装的 Headroom 包里 `SUFeedURL` 为空，并且使用 `CodexBar Development` 开发签名，因此 Sparkle 会关闭更新功能。只把 commit 推到源码仓库，不会让本地 App 自动更新。

## Recommended distribution / 推荐分发方式

Publish signed binaries and `appcast.xml` through a release channel:

1. Source: `ddaxai/Headroom` (public).
2. Binaries: GitHub Releases of `ddaxai/Headroom`, or a CDN.
3. The appcast and release ZIP contain the compiled app, not the source tree.
4. Sparkle verifies the Ed25519 signature before installing.

把签名后的二进制和 `appcast.xml` 发布到分发渠道：

1. 源码：`ddaxai/Headroom`（公开）。
2. 二进制：`ddaxai/Headroom` 的 GitHub Releases，或 CDN。
3. appcast 和 ZIP 只包含编译后的 App，不包含源码仓库。
4. Sparkle 安装前会校验 Ed25519 签名。

The signed release packaging can then use:

```bash
HEADROOM_FEED_URL=https://raw.githubusercontent.com/ddaxai/Headroom/main/appcast.xml \
  ARCHES="arm64 x86_64" ./Scripts/package_relay_app.sh release
```

For a real Sparkle release, the package must also be signed with a Developer ID Application certificate and notarized. A local `CodexBar Development` build remains a development build and is intentionally not an update target.

## Release/update sequence / 发布与更新流程

1. Push source changes to `ddaxai/Headroom`.
2. Create a versioned release and build a notarized ZIP.
3. Generate a signed `appcast.xml` and publish the ZIP/appcast to the distribution channel.
4. Users click “Check for Updates…”; Sparkle downloads, verifies, and installs the new build.

1. 把源码改动推送到 `ddaxai/Headroom`。
2. 创建带版本号的 Release，生成 notarized ZIP。
3. 生成签名后的 `appcast.xml`，把 ZIP 和 appcast 发布到分发渠道。
4. 用户点击“检查更新”；Sparkle 会下载、校验并安装新版本。
