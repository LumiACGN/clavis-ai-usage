# 架构说明

## 总览

```
┌────────────────────────── Clavis Shell（Quickshell）──────────────────────────┐
│  AiView.qml（「AI 用量」页）                                                   │
│      ↑ 读 singleton                                                           │
│  AiUsageService.qml ──Process──▶ bin/clavis-ai-usage（bash，本仓库）           │
└───────────────────────────────────────────────────────────────────────────────┘
                                       │ 聚合 4 路数据（独立进程，互不阻塞）
        ┌──────────────────┬───────────┴──────────┬─────────────────────┐
        ▼                  ▼                      ▼                     ▼
  ai-usagebar        ccusage（可选）        New-API 中转站         DeepSeek 平台
 （余额/配额）      （本地 Claude Code        （可选，默认关）      （可选，默认关）
                      token/费用）
```

- **契约**：后端脚本对 stdout 输出**恰好一个 JSON 文档**（`schema_version = 1`）并且**永远 exit 0**；
  诊断信息一律走 stderr。QML 侧只接受 `schema_version == 1` 的文档。
- **降级**：任何一路数据源失败都不会让脚本失败——该来源进 `stale_sources`，
  页面显示上次成功的数据（`last-good.json`）。
- **并发**：`flock` 单实例；已有实例在跑时，后到者直接吐 `last-good.json`。
- **超时链**：QML 侧 60s 发 SIGTERM（脚本 trap 后吐 `last-good.json`），再 +15s 硬停。

## 文件系统布局

| 路径 | 内容 |
|---|---|
| `~/.config/quickshell/clavis/` | **overlay**：Clavis 树的镜像 + 各已注册组件的补丁与新增文件（本组件：4 个锚点文件 + 6 个新增文件） |
| `~/.config/clavis-ai-usage/config.json` | 用户配置（0600；旧路径 `~/.config/clavis/ai-usage.json` 仍兼容） |
| `~/.cache/clavis-ai-usage/` | 运行缓存：`providers.json` / `local.json` / `history.json`（180 天）/ `official.json` / `last-good.json` 等，全部原子写 |
| `~/.local/state/clavis-overlay/kits/<kit-id>.json` | **每组件一份**安装状态（schema 2）：repo 位置与 order、补丁组、上次成功同步后的文件字节摘要、上游版本 |
| `~/.local/state/clavis-overlay/registry.json` | 引擎级共享事实：overlay/源树路径、最近一次成功 sync、全部已注册组件清单 |
| `~/.local/state/clavis-overlay/backups/` | overlay 整体快照（`overlay-*.tar.gz`，保留最近 3 份）；`<kit>/etc-anchors-*.tar.gz` 供 `--uninstall --restore-etc` 读取 |
| `~/.local/state/clavis-ai-usage/state.json` | **v0.1.0 旧状态**（schema 1）：首次运行 v2 时自动迁移，**旧文件保留不删** |
| `~/.local/bin/clavis-ai-usage` | 后端脚本（由安装器部署） |

`kits/<kit-id>.json` 每组件独立、互不 read-modify-write，且只在整条重放流水线**成功后**写入
（见下节）。

## 多 kit 重放（引擎 v2）

overlay 同时只能有一份镜像，所以多个 clavis 组件（kit）共享它：每个 kit 在
`$XDG_STATE_HOME/clavis-overlay/kits/<kit-id>.json` 记录自己的注册信息（repo 位置、`order`、
补丁组、摘要），引擎用「共享注册表 + 重放」让它们共存。

**sync 是唯一写路径**（install 复用同一条流水线）：

1. 停止 clavis-shell——HOME 不是当前用户的真实家目录时**自动跳过服务控制**（彩排/测试安全；
   用 `--allow-service` 可覆盖）；
2. 校验所有已注册 kit 的仓库文件都在（任一缺失 → **响亮失败**：可把仓库移回原处、或到
   **新位置重跑 `install.sh`** 自动重绑 `repo_root`、或 `forget <kit-id>`、或应急 `--skip-missing`）；
3. 手改检查：与上次摘要不一致的文件，**能归因到兄弟 kit 补丁改写的跳过**，只有无法归因的差异
   才要求 `--force`；
4. 备份当前 overlay（保留最近 3 份）；
5. **全量镜像**源树 → overlay（这一步会抹掉 overlay 里的一切补丁）；
6. 按 `order`（同 order 按 kit id）依次重放**全部**已注册 kit：先回滚源树里烘入的本组件旧补丁
   （例如源树本身就被手工打过补丁）→ 重新 apply → 语法门禁（同一文件一次 sync 只查一遍，
   各 kit 的门禁因此是并集）→ 可选的 smoke 门禁；
7. 成功后为**所有** kit 重采摘要，再写各自的 kit 状态文件与 `registry.json`。

任一步失败 → 恢复 sync 前的 overlay、拉起服务，并且**一个 kit 状态文件都不写**（原子）：
磁盘上的摘要与 overlay 实际内容永远自洽，「降级继续跑旧版」的承诺在多组件下同样成立。

## O0：外来标记检测

overlay 是全树遮蔽，谁都可以往里面放/残留 `BEGIN clavis-*` 标记。引擎的 `scan_markers`
（扫 overlay 下全部 `.qml` / `.js`）与 `attribute_markers`（按各 kit manifest 的
`files[].group` 反查归属）把标记归因到具体的 kit，共四处落点：

| 落点 | 行为 |
|---|---|
| `install` 接管已存在的 overlay（`--adopt`）前 | 列出检测到的标记组，告知接管重新镜像后会先清掉谁 |
| `sync` 的手改检查 | 区分「兄弟 kit 改写」（预期内，不拦）与「用户手改」（`--force` 才覆盖） |
| `verify` 末尾 | 孤儿标记报告：overlay 里存在、但没有任何 kit 认领的 group（手工补丁 / 已 `forget` 的 kit）；有孤儿时 verify 返回非零 |
| 最后一个 kit 卸载、删除 overlay 之前 | 警告仍存在未注册标记 |

## JSON 契约（schema_version = 1）

```
{
  "schema_version": 1,
  "generated_at":  <epoch 秒>,
  "error":         "<全局错误信息，正常为空串>",
  "stale_sources": ["ai-usagebar", ...],          // 本次用了旧缓存的数据源
  "providers": [                                   // 供应商卡片（来自 ai-usagebar）
    { "id", "name", "plan", "kind": "quota"|"balance",
      "status": "ready"|"error", "stale": bool, "fetched_at": <epoch>,
      "metrics": [...], "sections": [...],
      "reset_at": <epoch|null>, "reset_text": "3h40m 后",
      "display": "¥18.36/¥42.10" }                  // 余额卡特有（剩余/总额）
  ],
  "local": {
    "show_cost": bool,
    "history": [ { "date": "2026-10-12", "tokens": n, "cache_hit_tokens": n, ... } ],
    "history_window_days": n, "history_active_days": n,
    "today": {...}|null, "today_spend_cny": n|null,
    "spend_topup": bool,                            // 期间是否充值过（影响实扣口径）
    "balance_cny": n|null,
    "avg_daily_cny": n|null, "avg_daily_cny_basis": ..., "avg_daily_cny_days": n,
    "balance_days_left": n|null,                    // 余额还能用几天
    "pricing": {...}, "official": {...},
    "wallet": { "remaining_cny", "spent_cny", "total_cny", "source":"official" } | null
  }
}
```

**兼容承诺**：`schema_version` 不轻动；演进只做**增字段**。消费方（AiView）对未知字段宽容，
对缺失字段降级显示。

## 补丁与 overlay 架构

- Clavis 没有插件系统（详见 [COMPATIBILITY.md](COMPATIBILITY.md)），因此接入 = **overlay + 锚点补丁**：
  - `patches/manifest.json` 是唯一真相：`kit` 段（id / order / 后端脚本 / 配置目录）、
    `gates` 段（语法门禁覆盖与可选 smoke）、4 个上游文件、11 个锚点（anchor/replace/sha256）、
    6 个新增文件映射。
  - 补丁器（`scripts/patch_clavis_kit.py`）支持两种定位模式：**exact**（整段 `anchor` 精确命中
    一次；缺省）与 **block**（结构块定位：`unique_line` 唯一命中 → 向上找开括号行 → 花括号配对
    → sanity 子串校验；对上游"只改外观不改结构"的改动鲁棒）。
  - 补丁器**先全量校验再写入**：任一锚点不精确命中一次就整体失败，绝不产生"打了一半"的文件；
    幂等（`BEGIN/END clavis-ai-view` 标记计数校验）；`--revert` 可逐字节还原。
  - **契约**：同一文件内的多个 edit 必须按文件位置**升序**登记、互不重叠（机器断言；block 的
    回滚依赖它；`--list-edits` 可按序打印 id/mode/首行核对）；block 的 `replace` 中 BEGIN/END
    必须落在所定位组件的花括号内（否则回滚会残留标记，见
    [patches/README.md](../patches/README.md#block-模式维护手记)）。
  - overlay 引擎 v2（`scripts/clavis_overlay.py`）负责镜像、停/起 shell、备份、注册表、多 kit
    重放与回滚。子命令：`install` / `sync` / `verify` / `uninstall`（默认 **kit 级**，`--all`
    才整体拆除）/ `list` / `forget`；常用 flag：`--dry-run`、`--tree`、`--repo-root`、
    `--overlay-dir`、`--force`、`--skip-missing`、`--skip-service`、`--allow-service`。
    流程见 [COMPATIBILITY.md](COMPATIBILITY.md)。
