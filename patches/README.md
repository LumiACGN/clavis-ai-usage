# 锚点补丁：结构与维护手册

## 为什么需要补丁

Clavis Shell **没有插件系统**（Quickshell 与 Clavis 上游均无第三方注册机制），
唯一官方支持的用户扩展方式是 Quickshell 的 XDG 覆盖：
`~/.config/quickshell/clavis/` 存在时整体优先于 `/etc/xdg/quickshell/clavis/`。

因此本项目的接入方式是：**镜像整棵 Clavis 树到用户目录，再用锚点补丁把 AI 看板
"缝"进 4 个上游文件**（外加整文件安装 6 个新文件）。好处是零侵入 `/etc`
（不碰包管理器领地、Clavis 升级后一条 `--sync` 重新对齐、失败可整体回滚）。

## manifest.json 结构

| 字段 | 含义 |
|---|---|
| `upstream.version` | 锚点所对应的 Clavis 版本（校准基线） |
| `upstream.tree_hint` | 默认目标树路径 |
| `marker.begin/end` | 补丁标记模板，`{group}` 会被替换为组名（如 `// BEGIN clavis-ai-view`） |
| `files[].path` | 要补丁的上游文件（相对树根） |
| `files[].upstream_sha256` | 该文件在基线版本下的整文件哈希（用于诊断信息） |
| `files[].edits[]` | 每处补丁：`id` / `anchor`（上游原文，必须唯一）/ `replace`（替换文本）/ `anchor_sha256` |
| `payload[]` | 整文件安装映射：`src`（本仓库 `qml/` 下的文件）→ `dest`（树内路径） |

## 标记与幂等

- 替换文本**内含** `BEGIN/END` 标记；补丁器据此判断"已打/未打"。
- 标记数 ≠ 该文件 edits 数 → 直接拒绝（绝不猜测半打补丁的文件）。
- 每次 apply **先做全树预校验**（写任何字节前所有锚点必须可精确命中一次）——
  宁可不开始，不会打一半。

## Clavis 升级导致 sync 失败时（标准修复流程）

```bash
# 1) 看漂移详情（会打印新版上游在锚点附近 ±3 行的实际文本）
python3 scripts/patch_clavis_ai_card.py --explain-drift \
  --manifest patches/manifest.json --target <你的 Clavis 源码树>
#    加 --json 可得机器可读报告（附在 issue 里用）
```

2) 打开 `patches/manifest.json`，按报告里的 `file` + `edit` 找到条目：

- 若上游只是**挪了位置/换了写法**：把 `anchor` 更新为诊断输出里对应的新文本。
  原则：**锚点尽量短且唯一**（3~8 行、含足够特征），避免整段函数。
- 若上游**动了补丁本身要插入的代码结构**（如 tab 数组、Loader 布局变了）：
  `replace` 里的引用片段也要跟着改，把 `// BEGIN/END` 标记保持包裹整个替换块。
- 更新 `files[].upstream_sha256`（改为新版文件的哈希）与 `upstream.version`。

3) 本地验证（在纯净的新版树上）：

```bash
python3 scripts/patch_clavis_ai_card.py --target <新版树> --dry-run   # 看 diff 是否合理
python3 -m unittest discover -s tests                                 # 幂等/回滚/漂移用例
```

4) 提交 PR：`compat: adapt anchors to Clavis <版本号>`，并在 PR 里附 `--explain-drift --json`
   的输出作为证据。

## 校准小技巧

- 新版本的正交做法：把新版发行树的 4 个锚点文件放进 `tests/fixtures/upstream-<版本>/`，
  跑 `--target tests/fixtures/upstream-<版本> --dry-run`——这样不必动你的真实桌面。
- `--expect-upstream <版本>`：给 overlay 引擎传"当前系统版本"，与 manifest 记录不符时
  只告警不阻断——**锚点匹配才是唯一判据**，版本字符串只是提示。
