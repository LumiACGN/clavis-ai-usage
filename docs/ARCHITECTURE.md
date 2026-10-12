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
| `~/.config/quickshell/clavis/` | **overlay**：Clavis 树的镜像 + 本项目的 4 处补丁 + 6 个新增文件 |
| `~/.config/clavis-ai-usage/config.json` | 用户配置（0600；旧路径 `~/.config/clavis/ai-usage.json` 仍兼容） |
| `~/.cache/clavis-ai-usage/` | 运行缓存：`providers.json` / `local.json` / `history.json`（180 天）/ `official.json` / `last-good.json` 等，全部原子写 |
| `~/.local/state/clavis-ai-usage/state.json` | 安装状态：基线版本、源树、各文件哈希、备份索引 |
| `~/.local/state/clavis-ai-usage/backups/` | /etc 锚点备份、overlay 快照（保留最近 3 份） |
| `~/.local/bin/clavis-ai-usage` | 后端脚本（由安装器部署） |

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
  - `patches/manifest.json` 是唯一真相：4 个上游文件、11 个锚点（anchor/replace/sha256）、6 个新增文件映射。
  - 补丁器（`scripts/patch_clavis_ai_card.py`）**先全量校验再写入**：任一锚点不精确命中一次就整体失败，
    绝不产生"打了一半"的文件；幂等（`BEGIN/END clavis-ai-view` 标记计数校验）；`--revert` 可逐字节还原。
  - overlay 引擎（`scripts/clavis_overlay.py`）负责镜像、停/起 shell、备份、状态与回滚，
  流程见 [COMPATIBILITY.md](COMPATIBILITY.md)。
