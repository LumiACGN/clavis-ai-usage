# Changelog

本文件记录项目的显著变更。
格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.1.0] - 2026-10-12

首个公开版本。

- **AI 用量看板**（Clavis Shell 侧边栏第 4 页 + 顶栏快捷按钮）：供应商余额/配额、
  Claude Code 今日用量与 5h 计费块、每日历史堆叠图 + 缓存命中率折线、每日明细（实扣/估算口径）
- **后端聚合脚本**：聚合 ai-usagebar / ccusage / New-API 中转站（可选）/ DeepSeek 平台账单
  （可选，默认关闭）；`schema_version=1` JSON 契约、TTL 缓存、并发锁、last-good 降级、
  `--help` / `--explain-keys`
- **overlay 安装器**：镜像 Clavis 树到 `~/.config/quickshell/clavis` 叠加锚点补丁，不触碰 `/etc`；
  `--sync` 升级对齐（失败自动回滚）、`--verify`、`--uninstall`
- **锚点补丁器**：manifest 数据驱动、全量预校验、幂等、`--revert` 与 `--explain-drift` 漂移诊断
- 文档四篇、合成数据截图产线、CI（lint / 测试 / gitleaks 全历史扫描）、
  compat-watch（手动触发的上游兼容巡检）、AUR 打包元数据（待提交）
