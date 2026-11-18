# Codex 跨账号续聊兼容原型

目标是继续由 Headroom 切换 API/官方账号，同时保留聊天正文、图片、已完成的工具结果和任务上下文。
当前交付是离线请求兼容模块、CLI 与隔离运行验证；尚未接入桌面端发送链路，安装版切号行为没有改变。

2026-10-01 用户已反馈 ID 相关修复验收通过，已在原私有仓库的交接记录中登记。该反馈不提供逐场景覆盖清单，也不改变下述源码接入边界；不要将本次用户验收再次标记为待验收，
或推定所有 API/官方账号、压缩长历史和 WebSocket 链路均已验证。

## 问题与接入边界

统一 `codexbar_shared` 只解决历史的可见性，不代表不同服务/账号的响应状态可以互用。
例如 `type=reasoning` 携带 `item_…` ID，官方服务要求 `rs_…`，会报 `invalid_id_prefix`。
将字符串改成 `rs_…` 不能创造合法服务端状态；原始 JSONL 也不能直接当作发送请求。

本机桌面端捆绑 Codex 0.159.2。隔离生成的 `thread/resume` schema 包含配置覆盖，也包含 `history` 参数；
后者明确标注 `[UNSTABLE] FOR CODEX CLOUD - DO NOT USE`，不是可支持的桌面接入口。
隔离对照验证中，普通 `thread/resume` 能恢复同一已加载聊天，但附加 `history` 会被拒绝（`-32600`，
`cannot resume thread ... with history while it is already running`）。这里的“running”也包括已经完成失败回合、仍被加载的聊天。
`thread/inject_items` 是追加历史，不会移除错误项目。未找到可支持的发送请求过滤器或已加载历史替换操作。
不在正式聊天中尝试这些操作，也不通过覆写应用内二进制、改 auth 文件或扫描全盘历史来模拟修复。

参考：[官方 app-server 协议](https://learn.chatgpt.com/docs/app-server)、
[Codex 问题 #38855](https://github.com/openai/codex/issues/38855)、
[CC Switch 问题 #6503](https://github.com/farion1231/cc-switch/issues/6503)。
项目 ID 类型映射依据 Codex `ResponseItem::id_prefix`，后续版本新增类型需要重新核验。

## 已实现的处理

`CodexReplayCompatibility.prepare` 输入完整 Responses 请求，返回一个发送副本及不含内容的诊断报告。
它不读取账号、配置、数据库或聊天文件，不发送网络请求，不修改输入 Data 或持久化记录。

- 同一服务：清除可携带正文/工具数据的错误类型 ID；省略无密文且类型 ID 错误的 reasoning。
- 跨服务或账号：清除可移植项目的 ID 和内部服务元数据，省略原服务 reasoning 状态。
- 保留消息的正文、图片 URL/data URI、phase，以及 `call_id`、参数、工具输出和顺序。
- 工具调用必须有唯一、在其后出现且类型匹配的输出。待完成、孤立、重复或错序记录阻止生成请求。
- 不可移植的压缩状态、加密工具参数、服务端文件 ID、未知项目、原服务响应/会话引用会阻止跨服务生成。
  这些情况需要来源服务上的可移植上下文检查点或附件物化，不能静默丢弃。
- 此版本不生成摘要，也不执行工具；不会声称被加密的压缩上下文已恢复。

`sameBackend` 只能由接入层在确认所有历史项目属于相同服务和身份后使用。
共享 provider 名称、相同 URL 或相同模型名不足以证明身份相同；混合来源/来源未知使用 `crossBackend`。
HTTP 与 WebSocket 请求体共用同一投影逻辑。WebSocket 的增量请求或 `previous_response_id` 缓存
必须先由运行时恢复完整输入，否则阻止处理，避免失去前文。

## 离线开发入口

```sh
.build/debug/CodexBarCLI history prepare-request \
  --input-file /path/to/synthetic-request.json --cross-backend --json

.build/debug/CodexBarCLI history prepare-request \
  --input-file /path/to/synthetic-request.json --cross-backend \
  --output-file /path/to/new-projected-request.json --json
```

默认只输出项目数量、操作数量及阻止原因。退出码：0 可生成，2 不可安全生成，1 输入/文件错误。
输出文件必须不存在，创建时权限为 0600；已有文件、符号链接和硬链接均拒绝覆盖。
不要把真实完整聊天请求输出到提交记录或共享日志。

```sh
Scripts/test.sh --filter CodexReplayCompatibilityTests
python3 Scripts/probe_codex_replay_compatibility.py \
  --codex /Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex \
  --headroom-cli .build/debug/CodexBarCLI
```

运行探针显式选择二进制，使用临时 HOME/CODEX_HOME、合成工具记录和回环 HTTP 服务；
模型回复也由本地服务生成，没有真实模型推理。它检查原始请求被模拟服务以相同 ID 规则拒绝，
再检查投影后的输入能否经过真实 Codex 进程完成回复，并核对源请求文件未改变。
它不连接桌面端的控制 socket，HTTP 运行测试不等于 WebSocket 或真实官方账号验收。

## 下一阶段验收要求

先落实 Codex 运行时发送层的可支持接入口，再把 Headroom 的路由切换接入该能力。
配置切换后必须确认已加载聊天使用目标路由；回复/工具仍在执行时排队切换。
发送层在序列化 HTTP/WS 请求前按真实服务与身份边界处理完整活动输入，保留原始历史。
仅补 UI 提示、通知 Headroom 自身或调用 `thread/fork` 不算完成。

对不可移植压缩状态，先在来源服务生成包含目标、约束、决策、已完成结果和未完成工作的文本检查点，
保留原始记录，并验证切换后继续任务不会重复执行已完成工具。
没有可支持的桌面接入口时，优先跟进/实现 Codex 运行时修复；不得把离线命令的通过包装成正式切号已修复。

另一条实现路径是在 Headroom 中增加本地兼容转发层，把处理逻辑接到实际请求上。它需要完整实现官方登录和 API
认证转发、HTTP/WS 流式协议、活动回合的切换协调、已加载聊天的路由应用，以及跨服务压缩状态的文本检查点。
当前没有实现或启用这一层；它与修复 Codex 发送层都是后续实装方案，不是本次离线模块已经提供的能力。
保留密文或盲目删除压缩项目都不能保证保留任务上下文，不能承诺任意旧聊天一次性无损跨服务续聊。

发布验收还需 API→官方→API 的真实账号链路、长历史/压缩、图片、工具、失败回滚与应用重启。
未获得部署授权前不安装、替换或重启正式 Headroom，也不更改真实路由。
