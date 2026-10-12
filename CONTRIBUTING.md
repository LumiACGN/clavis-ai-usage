# 贡献指南

欢迎贡献！本项目最需要帮助的两类事：**适配 Clavis 新版本的锚点漂移**、以及**新数据源/展示改进**。

## 目录结构速览

| 路径 | 作用 |
|---|---|
| `bin/clavis-ai-usage` | 后端聚合脚本（bash）：采集 4 路数据 → 输出契约 JSON（`schema_version: 1`） |
| `qml/` | 装载进 Clavis overlay 的 6 个文件（看板、服务单例、顶栏按钮、图标） |
| `patches/manifest.json` | **锚点补丁的单一真相**：`kit`/`gates` 段 + 上游版本 + 每个锚点的 anchor/replace/hash（edit 可选 `mode: exact\|block`） |
| `scripts/patch_clavis_kit.py` | 通用锚点补丁器（exact / block 两种定位模式；apply / revert / verify / explain-drift / `--list-edits`） |
| `scripts/clavis_overlay.py` + `install.sh` | overlay 安装引擎 v2（install / sync / verify / uninstall / list / forget；多组件注册 + 按 order 重放） |
| `tests/` | 补丁器幂等/漂移用例、假 HOME 端到端、后端契约测试 |

## 为什么是"锚点补丁"

Clavis 没有插件系统，唯一官方扩展机制是 Quickshell 的 XDG 覆盖
（`~/.config/quickshell/clavis/` 优先于 `/etc/xdg/quickshell/clavis/`）。
我们因此镜像整树到用户目录，再用锚点把 AI 看板"缝"进 4 个上游文件。

## 锚点维护：Clavis 升级后 sync 失败了怎么办

1. 用漂移诊断工具查看详情（会打印每个锚点在**新版上游**中的实际文本）：
   ```bash
   python3 scripts/patch_clavis_kit.py --explain-drift \
     --manifest patches/manifest.json --target <你的 Clavis 源码树>
   ```
   加 `--json` 可得到机器可读报告（用于附在 issue 里）。
2. 打开 `patches/manifest.json`，按错误信息里的 `id`/`edit` 编号找到对应条目；
   用诊断输出中的新文本更新 `anchor`（保持锚点短且唯一），必要时同步调整 `replace`。
   block 模式（`mode: "block"`）的条目改的是 `block.unique_line` / `block.sanity`
   一类结构定位参数，维护细节见 [`patches/README.md`](patches/README.md#block-模式维护手记)。
3. 跑测试确认幂等：
   ```bash
   python3 -m pytest tests/test_patcher.py
   ./install.sh --verify
   ```
4. 提交 PR，标题格式：`compat: adapt anchors to Clavis <版本号>`。

## 两种定位模式（exact / block）

manifest 里每个 edit 都有 `mode`（缺省 `exact`）：

- **exact**：整段 `anchor` 必须在上游文件里**精确命中一次**。最严：一字不差，上游任何相关改动
  都会让它失配报错——适合短行与希望"一漂移就报错"的长块。
- **block**：结构块定位——`block.unique_line` 唯一命中 → 向上找开括号行（`block.opener_lookback`，
  缺省 8）→ 花括号配对 → 用 `block.sanity` 子串校验。对上游**只改外观不改结构**的改动鲁棒
  （例如全局字号补丁改了块内 `font.pixelSize`，exact 会全灭而 block 照常定位）。
  **硬约束**：`replace` 里的 BEGIN/END 标记必须落在所定位组件的花括号内，否则回滚会残留标记。

同一文件内的多个 edit 还有一条机器断言契约：**必须按文件位置升序登记、且互不重叠**
（block 回滚依赖它）。用 `--list-edits` 打印「文件 → edit id / mode / 定位首行」核对：

```bash
python3 scripts/patch_clavis_kit.py --list-edits --manifest patches/manifest.json
```

## 安装状态与 v0.1.0 → v0.1.1 迁移

状态从 v0.1.0 的 `~/.local/state/clavis-ai-usage/state.json`（schema 1）改为
`~/.local/state/clavis-overlay/kits/<kit-id>.json`（schema 2，多组件各一份）。
首次安装/同步时**自动迁移**，旧 `state.json` 原样保留不删，无需手工操作。

## 新增数据源

后端脚本的每个来源是独立函数，输出统一 JSON（见 `docs/ARCHITECTURE.md` 的字段表）。
新增来源时：保持 `schema_version: 1` 的**向后兼容**（只增字段不改语义）、
为失败路径提供降级（进 `stale_sources` 而不是让整个脚本失败）、并补一个
`tests/test_backend.sh` 用例。

## 代码风格

- QML 用仓库根的 `.qmlformat.ini`（与上游 Clavis 一致）：`qmlformat --check qml/*.qml`
- Shell：`shellcheck -S warning`
- Python：仅标准库，`python3 -m py_compile scripts/*.py`
