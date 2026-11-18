# Relay switching and balance queries

This fork adds a Relay pane for switching Codex, Claude Code, Claude Desktop, Grok Build, and OpenCode between saved relay profiles and the original official configuration. Codex can optionally share one session-history bucket across official and relay configurations.

Unified Codex history is enabled automatically before the first Codex relay switch. Machines without existing Codex history skip the confirmation step. If migration fails, Headroom surfaces a copyable warning but still applies the requested relay profile; history unification is an enhancement, not a routing prerequisite. Restoring an empty baseline removes the generated `config.toml` instead of leaving a synthetic official configuration behind.

统一 Codex 历史会在第一次把 Codex 切到中转站前自动启用。没有既有 Codex 历史的机器会跳过确认步骤。若迁移失败，Headroom 会显示可复制的完整警告，但仍继续应用所选中转站；统一历史是增强功能，不是切换路由的硬前置。若最初没有 `config.toml`，恢复空 baseline 时会删除切换产生的配置文件，而不是留下合成的官方配置。

Blocked relay choices remain clickable so the fixed feedback area can explain the missing model or credential. Hovering shows the same blocker, and missing-model failures include a direct Settings shortcut. Relay Settings can also copy the current default model ID into every enabled client in one action.

被阻止的中转站选项仍可点击，固定反馈区会解释缺少的模型或凭据；悬浮时也会显示同一原因。缺少模型时，反馈区提供直达设置的入口。中转站设置还可以把当前默认模型 ID 一次填入所有已启用客户端。

Saved relay profiles can be deleted from Settings → Accounts & Relay. Deleting an inactive profile removes its metadata and local credential. Deleting an active profile first restores the original official baseline; if that restore fails, the profile and credential are retained.

## Balance queries

Balance queries are enabled by default for relay profiles. New profiles use the Sub2API endpoint because it is the
gateway format used by this fork; OpenAI-compatible inference APIs still do not define a standard balance endpoint.

- **Sub2API** is the default and calls `GET /v1/usage` with the profile API key as a Bearer token.
- **Generic balance** calls `GET /user/balance` with the profile API key as a Bearer token and recognizes common balance, usage, total, currency, and plan fields.
- **Disabled** is still available when a relay does not expose either accounting endpoint.

Use Settings → Relay → Relay balance to choose the endpoint type and run a manual query. Successful results are cached locally and shown in the menu switcher and the stacked Codex API card. Existing version-one relay profiles are migrated to the default Sub2API mode once; a later manual choice of **Disabled** is preserved.

The cache stores only the returned balance summary. API keys remain in the separate local relay credential file and are never written into profile metadata or the balance cache.

### Custom balance mapping

When a relay exposes a different, documented balance endpoint, choose **Custom balance** and enter one HTTPS base URL, one `GET` path, either `Authorization: Bearer` or `x-api-key` authentication, and the JSON paths for `remaining`, `used`, and `total`. A currency code and divisor allow integer minor-unit responses to be presented correctly.

Custom balance is deliberately a balance mapping only. Headroom does not infer token counts, request counts, or per-model spend from that response, and it never sends an inference request while refreshing a balance card.

如果中转站提供了不同但已文档化的余额接口，可选择 **自定义余额**，填写一个 HTTPS Base URL、一个 `GET` 路径、`Authorization: Bearer` 或 `x-api-key` 鉴权方式，以及 `remaining`、`used`、`total` 的 JSON 路径。货币代码与除数可用于正确展示以最小货币单位返回的整数。

自定义余额严格只是余额映射：Headroom 不会从该响应推导 Token、请求次数或各模型成本，也不会在刷新余额卡片时发送推理请求。
