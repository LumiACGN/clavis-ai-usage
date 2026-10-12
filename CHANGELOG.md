# Changelog

本文件记录项目的显著变更。
格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.1.1] - 2026-10-12

overlay 引擎 v2（多组件共存）+ 补丁器 block 模式。**对 v0.1.0 用户是平滑升级**：
旧状态自动迁移（`~/.local/state/clavis-ai-usage/state.json` 保留不删），
看板与后端脚本零行为变化（AI 侧 11 个锚点、6 个 payload 一字未动）。

### 新增

- **多组件共存**：overlay 状态改为 `~/.local/state/clavis-overlay/kits/<kit-id>.json`
  （每个组件一份，互不覆盖）+ 共享 `registry.json`；`sync` 成为唯一写路径——按各组件的
  `order` 重放**全部**已注册组件（先回滚源树里烘入的旧补丁再重打），谁 sync 都不会
  抹掉别人；任一步失败整体恢复到同步前状态，且一个状态文件都不写（原子）
- **组件级卸载**：`--uninstall` 默认只移除本组件（其它组件不受影响）；`--all` 才整体拆除
- 新子命令：`list`（列出组件与重放顺序）、`forget <kit-id>`（从注册表摘除，不碰 overlay；
  仓库被删/搬走时的逃生舱）
- 新参数：`--repo-root`、`--skip-missing`（应急）、`--allow-service`（假 HOME 彩排时强制控制服务）
- **孤儿标记检测**：`verify` 会报告 overlay 中存在但不属于任何已注册组件的补丁标记
- 补丁器 **block 模式**（manifest 里 `"mode": "block"`）：结构块定位 + sanity 校验，
  上游「外观类改动」（例如全局字号 +1px）不再击穿锚点；新增 `--list-edits` 便于校准
- 假 HOME 守卫：在非真实家目录下自动跳过 clavis-shell 服务控制（彩排/测试安全）
- 测试与 CI：新增 `tests/test_engine.py`、`tests/test_coexist.sh`、
  `tests/fixtures/dummy-kit/`（双组件共享同一文件端到端：共存 / 交替 sync 幂等 /
  组件级卸载 / 负例），`test.yml` 增加共存彩排

### 变更

- overlay 状态迁移：`$XDG_STATE_HOME/clavis-ai-usage/state.json`（schema 1）→
  `$XDG_STATE_HOME/clavis-overlay/kits/clavis-ai-usage.json`（schema 2），
  首次运行新版本时自动迁移，**旧文件保留不删**
- 补丁器改名 `scripts/patch_clavis_ai_card.py` → `scripts/patch_clavis_kit.py`（组件无关，
  与姊妹仓 clavis-lunar-calendar 逐字节相同）；引用它的文档/脚本/CI 已同步
- 同一文件内的多个 edit 现在被机器断言「按文件位置升序、互不重叠」，manifest 的
  登记顺序即文件顺序（`--list-edits` 可核对）
- 语法门禁覆盖范围扩大到 payload 里的 `.js`（组件家族共用引擎的前提）

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
