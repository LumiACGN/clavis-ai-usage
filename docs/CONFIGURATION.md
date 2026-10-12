# 配置说明

## 配置文件位置（按优先级）

1. `--config <路径>`（命令行参数）
2. 环境变量 `CLAVIS_AI_USAGE_CONFIG`
3. `~/.config/clavis-ai-usage/config.json`（**推荐**）
4. `~/.config/clavis/ai-usage.json`（旧路径，兼容；命中时会提示迁移）

模板见 [`config/config.example.json`](../config/config.example.json)。
文件建议 `chmod 600`（含 API key；权限过宽时脚本会告警）。
目录可用 `CLAVIS_AI_USAGE_CONFIG_DIR` 覆盖。

## 全部配置项

| 键 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `deepseekApiKey` | string | — | DeepSeek API key（ai-usagebar 用它查余额） |
| `deepseekApiKeyFromClaudeSettings` | bool | `false` | 从 `~/.claude/settings.json` 的令牌兜底作为 DeepSeek key（**显式 opt-in**，默认关） |
| `balanceProvider` | string | `"deepseek"` | 哪个供应商条目承载"余额"，用于计算实扣消费 |
| `providers.zaiApiKey` / `providers.kimiApiKey` / `providers.openrouterApiKey` | string | — | 其余供应商凭据 |
| `aiUsagebar.path` | string | `~/.local/bin/ai-usagebar` | ai-usagebar 可执行文件路径（显式填写时**优先于 PATH** 中的同名命令） |
| `ccusage.path` | string | `~/.npm-global/bin/ccusage` | ccusage 路径（同上） |
| `ccusage.enabled` | bool | `true` | 关掉后不采集本地 Claude Code 用量 |
| `ccusage.showCost` | bool | `true` | 页面上是否显示费用（token 始终显示） |
| `historyWindowDays` | int | `30` | 历史窗口（7~90；缓存保留 180 天原始数据） |
| `pricing.offPeak.cacheHit` / `.cacheMiss` / `.output` | number | `0.02 / 1 / 4` | 估算用价目表（CNY / 1M tokens，闲时） |
| `pricing.peakMultiplier` | number | `2` | 高峰倍率（估算用） |
| `relay.enabled` | bool | `false` | 是否启用 New-API 中转站数据 |
| `relay.baseUrl` / `relay.apiKey` | string | — | 中转站地址与访问令牌 |
| `official.enabled` | bool | `false` | DeepSeek 平台账单层（见下节，风险自担） |
| `official.tokenFile` | string | `~/.config/clavis/deepseek-platform.token` | 平台网页登录态 token 文件（支持 `~/` 展开） |
| `official.baseUrl` | string | `https://platform.deepseek.com` | 平台地址 |
| `official.ttlSeconds` | int | `3600` | 该层缓存时间 |
| `official.tz` | int | `28800` | 平台账单日界时区偏移（秒；默认北京时间） |
| `official.days` | int | `30` | 拉取多少天的账单 |

## 凭据

凭据按 **环境变量 → 配置文件** 的顺序解析；`--explain-keys` 可以审计每个凭据的**来源**
（永不显示值）：

```
$ clavis-ai-usage --explain-keys
凭据来源（只显示来源，不显示值）：
  deepseek    环境变量
  zai         配置文件（/home/you/.config/clavis-ai-usage/config.json）
  ...
```

支持的环境变量：`DEEPSEEK_API_KEY`、`ZAI_API_KEY`、`KIMI_API_KEY`、
`OPENROUTER_API_KEY`、`RELAY_API_KEY`，以及路径类覆盖
`AI_USAGEBAR_BIN`、`CCUSAGE_BIN`。

安全承诺（见 [SECURITY.md](../SECURITY.md)）：凭据不落 stdout、不进日志、
不进本仓库的 git 历史。

## ⚠️ DeepSeek 平台账单层（`official`，默认关闭）

- 数据来自 **DeepSeek 官方服务器**（你的真实账单），但走的是平台网站的
  **非公开内部接口**（不是文档化的 OpenAPI），鉴权需要**网页登录态的 session token**
  （API key 会被该接口拒绝）。
- 因此：**可能随时失效、可能触碰服务条款、账号层面有风控风险，风险自担**。
  默认关闭；开启方式：把 token 写入 `official.tokenFile` 指向的文件（0600），
  并在配置里设 `"official.enabled": true`。
- 用 `clavis-ai-usage --official-test` 可做接口联通性自检（输出诊断到 stderr）。
