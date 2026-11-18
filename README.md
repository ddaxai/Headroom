<p align="center">
  <img src="docs/headroom-icon.png" width="128" height="128" alt="Headroom">
</p>

# Headroom

Headroom 是一个原生 macOS 菜单栏工具，面向 Codex 官方账号与自定义中转站：显示额度、过去 24 小时 token/价格，并在官方账号与已保存 API 之间快速切换。

Headroom is a native macOS menu-bar app for Codex official accounts and custom relays. It shows quota, token/cost usage for the past 24 hours, and switches between official accounts and saved APIs.

## 当前范围 / Current scope

- Codex 官方账号：账号切换、共享额度、token 与美元用量。
- Codex official accounts: account switching, shared quota, token usage, and USD cost.
- 自定义中转：保存、编辑、删除和快速切换 API 配置；默认支持 Sub2API 额度查询。
- Custom relays: save, edit, remove, and quickly switch API profiles; Sub2API balance queries are enabled by default.
- Claude Code、Claude Desktop、Grok Build、OpenCode 和 Pi Agent 的路由配置，以及统一 Codex 会话历史。
- Routing configuration for Claude Code, Claude Desktop, Grok Build, OpenCode, and Pi Agent, plus unified Codex session history.
- 菜单栏卡片支持过去 24 小时/30 天 token 柱状图；用量详情从卡片右侧固定抽屉打开，不改变主菜单高度。
- Menu cards support 24-hour/30-day token charts; usage details open in a fixed right-side drawer without changing the parent menu height.
- 本地 Agent 生成速度（`tok/s`）与首字延迟（TTFT）：以纯只读方式解析 Antigravity、Codex（含多官方账号与中转归属）、Claude Code、OpenCode 和 Pi Agent 的本地会话记录，不经任何本地反代、不触碰客户端网络链路。
- Read-only local Agent token speed (`tok/s`) and TTFT across Antigravity, Codex (official accounts and relays), Claude Code, OpenCode, and Pi Agent, with zero proxy or network interception.

## Codex 新会话速度 / New chat speed

在菜单栏 Codex 接口切换区选择 **普通** 或 **⚡ Fast**。Headroom 会按每个中转站和
官方接入分别记住速度；切换接口或恢复官方接入时，写入对应默认值。

速度设置只对**新聊天**生效。已经打开的聊天保留自己的速度；Headroom 不会中断正在
生成的回复，也不会自动重启 Codex。Fast 请求是否获准及实际消耗取决于上游，按钮不代表
已测得加速。配置无法安全识别、当前接口不匹配或写入失败时会显示错误。

Choose **Standard** or **⚡ Fast** below the Codex connection choices in the menu bar.
The preference is remembered separately for each relay and official access. It applies to
**new chats**; loaded chats retain their own speed. No active reply is interrupted and Codex
is not restarted. Actual priority processing, speed and usage depend on the upstream.

Offline runtime verification (synthetic backend; no real accounts):

```sh
python3 Scripts/probe_codex_speed.py --codex /path/to/codex
```

## 开发 / Development

`main` 是唯一的正式分支。版本记录见 [Headroom 更新记录](docs/HEADROOM_UPDATES.md)，产品要求见 [产品需求](docs/HEADROOM_PRODUCT_REQUIREMENTS.md)。

`main` is the release branch. See [Headroom updates](docs/HEADROOM_UPDATES.md) for the change history and [product requirements](docs/HEADROOM_PRODUCT_REQUIREMENTS.md) for scope.

要求 macOS 14+、Xcode Command Line Tools 和 Swift 6.2 或更新版本。

Requires macOS 14+, Xcode Command Line Tools, and Swift 6.2 or newer.

    swift test
    make check
    Scripts/package_relay_app.sh release
    Scripts/install_headroom.sh

Headroom 的正式打包产物固定写入 .build/headroom-artifacts/Headroom.app，不会在仓库根目录生成可运行副本。开发和 QA 也应从这个路径启动，避免同一个菜单栏应用被多次注册。

首次替换旧安装前，请先退出旧的 Headroom/CodexBar 菜单栏进程；安装脚本会拒绝覆盖运行中的 App，并把旧副本移到可恢复的临时目录。

The release package is written to .build/headroom-artifacts/Headroom.app; no runnable copy is created in the repository root. Development and QA should launch this path so the menu-bar app is not registered multiple times.

Before the first replacement, quit the old Headroom/CodexBar menu-bar processes. The installer refuses to replace a running app and moves old bundles to a recoverable temporary directory.

## 数据与隐私 / Data and privacy

配置和本地会话历史沿用现有 CodexBar 数据路径以保证迁移兼容；中转站 API 配置由 Headroom 管理，额度展示以服务端返回的 token/价格为准，不在本地重复估算中转费用。

Existing CodexBar configuration and local session-history paths are kept for migration compatibility. Relay profiles are managed by Headroom, and relay token/cost display uses the server-reported values instead of recalculating relay prices locally.

## 功能来源 / Feature sources

请查看 [功能来源与上游同步清单](docs/UPSTREAM_FEATURE_SOURCES.md) / See [Feature Sources & Upstream Sync Map](docs/UPSTREAM_FEATURE_SOURCES.md). The file records the exact baseline and the narrow sync boundary for each adopted capability.

## 许可 / License

Based on CodexBar by Peter Steinberger, MIT License.
