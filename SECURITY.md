# 安全说明

## 凭据处理承诺

- 本项目所有代码**不会**将 API key / token 写入日志、stdout、错误信息或仓库。
- 仓库中**永远不包含**任何真实凭据；示例配置一律使用占位符（如 `sk-xxxx`）。
- 后端脚本 `bin/clavis-ai-usage` 运行时按以下优先级读取凭据：
  1. 环境变量（`DEEPSEEK_API_KEY` / `ZAI_API_KEY` / `KIMI_API_KEY` / `OPENROUTER_API_KEY` 等）
  2. `~/.config/clavis-ai-usage/config.json`（要求 `0600` 权限，脚本会检查并告警）
- 可选行为：将 `~/.claude/settings.json` 中的令牌作为 DeepSeek key 的兜底读取——
  **默认关闭**，需在配置中显式开启（`deepseekApiKeyFromClaudeSettings`）。
- 诊断命令 `--explain-keys` 只显示每个凭据的**来源**（env / config / 未配置），
  永不显示其值。

## 报告问题

发现安全问题时，请优先通过 GitHub 的私密渠道报告：

- 仓库 → Security → Report a vulnerability（GitHub Security Advisory），或
- 若该入口不可用，开一个不含敏感细节的 issue 说明意图，另行沟通细节。
