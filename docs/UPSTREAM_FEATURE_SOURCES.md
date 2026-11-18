# Headroom 功能来源与上游同步清单

# Headroom Feature Sources & Upstream Sync Map

这份文档记录 Headroom 中每组非原创基础能力的来源、当前基线和同步边界。以后检查上游更新时，应按功能逐项同步，不要整仓覆盖 Headroom 的产品取舍。

This document records the source, pinned baseline, and sync boundary for each inherited or adapted capability in Headroom. Future upstream updates should be reviewed feature by feature instead of replacing the Headroom product layer wholesale.

## 1. CodexBar

- Repository: <https://github.com/steipete/CodexBar>
- Headroom fork baseline: `8ef86077e70ac27d45ddddaf49e409824ccdf668` (before the Headroom rename and per-card usage work)
- Latest selectively synced upstream HEAD: `1f6da9bec44455288ddee5ef6f3617a803d8eb2a` (v0.84.0, selectively ported GPT-6 / Claude Mythos / Fast-tier pricing, symlinked `~/.codex/sessions` traversal, `.jsonl.zst` archived rollout cache retention, and managed Codex shared-home deletion guards)
- Adopted / 已采用：
  - Native AppKit + SwiftUI menu-bar shell / 原生菜单栏框架
  - Codex OAuth quota fetching and managed account switching / Codex 官方额度抓取与账号切换
  - Local Codex JSONL session scanning / 本地 Codex 会话扫描
  - Model pricing tables, token aggregation, rolling 24-hour cost calculation / 模型价格表、token 汇总和滚动 24 小时美元计算
  - Hourly usage chart and reset-time presentation / 分时用量图与重置时间显示
- Headroom policy / Headroom 边界：官方账号的 token 和美元只使用这套本地扫描与价格计算；共享 JSONL 没有可靠账号归属时，不伪造逐账号成本。
- Future sync entry points / 后续同步入口：
  - `Sources/CodexBarCore/CostUsage*`
  - `Sources/CodexBar/SpendDashboard*`
  - `Sources/CodexBar/UsageStore+Token*`
  - `Sources/CodexBar/StatusItemController+Codex*`
- Conflict risk / 冲突风险：菜单卡片、账号投影、缓存失效策略是 Headroom 定制区，更新前必须跑相关回归测试和真实 UI 验收。

## 2. CC Switch

- Repository: <https://github.com/farion1231/cc-switch>
- Reviewed commit: `09678477ec19947f1ea67966a49271a1dddd308c` (updated from `4bfb3fc30d78ecfbc41340da3ad72720ee28843c`)
- Adopted or independently reimplemented / 已采用或按其思路独立实现：
  - Saved relay/provider profiles / 自定义中转站配置
  - Writing routing configuration for Codex, Claude Code, Claude Desktop, Grok Build, OpenCode, and Pi Agent (with symlink-preserving atomic writes and retired-key scrubbing) / 写入多应用路由配置（保留软链接原子写入并清理废弃内联密钥）
  - Unified Codex session history across official and relay modes / 官方账号与中转模式共用 Codex 会话历史
  - Read-only session-log `tok/s` & TTFT estimation across Antigravity, Codex, Claude Code, OpenCode, and Pi Agent (without enabling CC Switch's local proxy) / 纯只读本地会话日志 `tok/s` 与首字耗时还原（不启用本地反代）
  - Relay usage query flow / 中转额度查询流程
  - Displaying relay-reported `total_tokens` and `actual_cost` without recalculating price locally / 直接显示中转站返回的 token 和实际价格
- Not adopted / 未采用：账号池、CPA 代理、MCP 管理和与当前 Headroom 范围无关的余额/运营功能。
- Future sync entry points / 后续同步入口：
  - `Sources/CodexBarCore/Relay*`
  - `Sources/CodexBarCore/Providers/Sub2API/`
  - `Sources/CodexBar/PreferencesRelayPane.swift`
  - `Sources/CodexBar/RelayQuickSwitchMenu.swift`
- Conflict risk / 冲突风险：不要把 CC Switch 的 Tauri/Rust UI 或全量设置模型直接合并；只对照路由、迁移和用量协议。

## 3. sub2api

- Repository: <https://github.com/Wei-Shaw/sub2api>
- Reviewed commit: `15871f904056f548dd874a1d069ffc6cdf777b78` (updated from `7e2e9ba05026b7126318aa0754c1afa0ac00bc58`; `/v1/usage` contract verified compatible)
- Integration contract / 集成契约：Headroom 默认使用 `/v1/usage`，读取服务端已经计算好的余额、token 与 `actual_cost`。
- Display truth / 展示原则：
  - `rolling_24_hours` 或 `last_24_hours` → 显示 `24h`
  - 仅有 `today` → 明确显示“今日”，不能写成滚动 24 小时
  - 不用 CodexBar 本地价格表重算中转费用
- Future sync entry points / 后续同步入口：
  - `Sources/CodexBarCore/Providers/Sub2API/Sub2APIUsageFetcher.swift`
  - `Sources/CodexBarCore/RelayUsageQueryFetcher.swift`
- Conflict risk / 冲突风险：上游响应字段、鉴权 header 或 endpoint 变化时，必须先更新 fixture/test，再改解析器。

## 4. AgentDuck 0.12

- Local reference / 本地参考：the AgentDuck 0.12 build supplied during product research (local-only reference; no absolute workstation path is recorded here)
- Source availability / 源码状态：当前只发现已构建 `.app` 和 `USAGE.md`，没有可核实的公开源码仓库或 commit。
- Reference only / 仅作参考：菜单栏信息密度、低资源常驻、agent 活动反馈和模块化卡片思路。
- Provenance rule / 来源规则：除非以后找到公开源码及许可证，否则不得声称移植 AgentDuck 代码，只能记录为产品/视觉参考。

## Sync workflow / 同步流程

1. 先记录候选上游 commit、release 或 PR。
2. 只定位本清单中的对应功能和文件，不做无差别 merge。
3. 行为变更先补失败测试，再做最小实现。
4. 运行聚焦测试、完整构建、格式/静态检查和真实菜单栏视觉验收。
5. 在本文件更新“Reviewed commit”和同步结果，并在 PR 中列出未采用的上游变化。

1. Record the candidate upstream commit, release, or PR.
2. Map it to the specific feature and files above; avoid wholesale merging.
3. Add a failing behavior test before implementation.
4. Run focused tests, a full build, formatting/static checks, and real menu-bar visual QA.
5. Update the reviewed baseline and document intentionally skipped upstream changes in the PR.

## 2026-10-04 候选审查

本次对照了 `steipete/CodexBar` 当前 release `v0.71.1`（HEAD `a555a82`）、`farion1231/cc-switch` `v3.20.4`、`Wei-Shaw/sub2api` `v0.2.13`、`Javis603/token-monitor` `v0.65.0` 和 `Carstin520/token-remain` `v1.3.9`，并检查了 Sparkle 2.10.0、KeyboardShortcuts 3.1.0、SweetCookieKit 0.5.5、Commander 0.3.0、swift-log 1.15.1、swift-crypto 5.0.0 的候选升级。

| 仓库 | 本次检查的 HEAD | Release |
| --- | --- | --- |
| steipete/CodexBar | `a555a82bad569e801e1628a43ceb507b0764b337` | v0.71.1 |
| farion1231/cc-switch | `372b1698968ced988ce046d705732cb799000533` | v3.20.4 |
| Wei-Shaw/sub2api | `b8dece9000c68815a5b867ca5a1e6f236e173905` | v0.2.13 |
| Javis603/token-monitor | `a2e57285468af007ce6e5f3eff614da3ba101579` | v0.65.0 |
| Carstin520/token-remain | `c30f66fdd84e23d0ef8e9670709600085eb8794e` | v1.3.9 |

这些是候选检查版本，不表示 Headroom 已同步到相应 HEAD。

- **已局部采用**：CodexBar PR #4175 的 provider 状态请求代际发布规则；PR #4176 的 Pi/OMP 一小时 cache-write 字段语义。两项都改写为 Headroom 现有状态模型和缓存格式，未整仓合并。
- **10-04 候选，10-05 已局部适配**：CodexBar [a555a82](https://github.com/steipete/CodexBar/commit/a555a82bad569e801e1628a43ceb507b0764b337)（#4195/#3303）恢复旧会话后的 request-ledger 计费修复。10-04 的本地解析器依赖 legacy `last_token_usage`/`total_token_usage`，计数重置后存在漏记新用量的风险；10-05 已加入 typed `token_usage_record` 和完整 request-ledger 语义，结果见下节。补丁跨解析、thread/session 身份、response 去重、legacy 镜像对齐及 SQLite 增量/旧缓存迁移；只加字段读取会造成双计或错误归属，应按完整记账语义适配并补跨日、恢复、重复记录、缓存重开回归。
- **已采用官方价格**：OpenAI pricing/changelog 与 Claude pricing 页面中当前可对应的模型、272K 长上下文、Fast 计费和 Claude cache retention。行级事件日期进入历史价格判断，价格指纹会使旧成本缓存失效重建。
- **仅参考**：CC Switch 的代理/MCP/Rust/Tauri 功能、sub2api 后端结算实现、token-monitor/token-remain 的独立 UI 与数据源；Headroom 继续显示服务端 `actual_cost`，不在本地重算中转站费用。
- **暂缓依赖升级**：KeyboardShortcuts、SweetCookieKit、Commander 和 swift-log 尚未发现必须升级的兼容性缺陷；swift-crypto 5.0.0 可能带来破坏性 API 变化；Sparkle 升级也不属于本轮大问题修复。后续若升级，须单独建立兼容性变更和完整回归。
- **不上游 AntiGravity token reader**：上游支持 SQLite/JSONL，但本机只有 `.pb` conversation 文件，未发现可读取的 `.db` 或 tokscale session JSONL；移植 parser 不能形成真实 token 数据，继续明确显示不可用。

## 2026-10-05 request-ledger 局部适配

- 已适配上述 `a555a82` 的请求记账、归属、response 去重、legacy mirror 和缓存迁移语义。沿用 Headroom JSON cache、扫描预算和定价审计，不引入上游 SQLite 或替换 Headroom 账号/展示模型。
- 兼容当前已提交和 10-04 parser producer key，按文件有界重读；恢复历史 known cost、priority 和 unpriced 证据。未知 producer key 仍按原失效策略重建。
- 重复 response 页面保留镜像证据，缓存重开及原 owner 页面消失后重新认领一次；foreign thread/session、copied parent/subagent prefix 不计为当前会话用量。
- 窄回归 29 tests / 2 suites passed；扩大回归 409 tests / 31 suites passed，另有 2 tests / 1 suite passed。完整测试、格式基线与资源检查结果见现有详细交接的 10-05 节。
- 全部改动仍未提交、未推送、未安装、未重启；真实运行与 UI 验收未完成。10-04 的其他依赖和上游取舍继续有效，本节不宣称已跟进 10-04 检查之后的远端变化。
