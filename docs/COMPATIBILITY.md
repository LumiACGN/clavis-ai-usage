# 兼容性与升级

## 为什么是 overlay + 锚点补丁

- Quickshell（0.3.x）**没有插件系统**；Clavis Shell 也没有第三方扩展 API。
- 唯一官方支持的用户扩展机制是 **XDG 覆盖**：
  `~/.config/quickshell/clavis/` 存在时**整体优先**于 `/etc/xdg/quickshell/clavis/`
  （Quickshell 按 XDG 顺序取第一个含 `<name>/shell.qml` 的目录，**整目录独占，不合并**）。
- 所以本项目把系统 Clavis 树**完整镜像**到 overlay 目录，再用锚点把 AI 看板缝进
  4 个上游文件（外加 6 个新增文件）。**绝不写 `/etc`**（pacman 领地，升级即覆盖）。

> ⚠️ overlay 是全树遮蔽：生效期间 `/etc` 里的 Clavis 副本被完全忽略（包括你自己对它打过的
> 其它补丁）。Clavis 升级后 **必须跑一次 `./install.sh --sync`** 把 overlay 对齐到新版本，
> 否则你会继续跑旧代码（`--verify` 会提醒）。

## 版本兼容表

| Clavis 版本 | 状态 | 说明 |
|---|---|---|
| 2026.9.25 | ✅ 基线 | `patches/manifest.json` 以此为锚点校准 |
| 其它版本 | ⚠️ 未验证 | 先跑 `./install.sh --sync --dry-run` 看锚点是否仍匹配 |

版本探测顺序：`pacman -Q clavis-shell` → 源码树 `RELEASE.json` → `unknown`。
版本字符串只做提示；**锚点是否精确匹配才是唯一判据**。

## 升级流程（Clavis 升级后）

```bash
./install.sh --verify        # 会提示“Clavis 已升级但 overlay 陈旧”
./install.sh --sync --dry-run   # 预览：看补丁器对当前源树的 diff
./install.sh --sync          # 正式对齐（停 shell → 重镜像 → 重打补丁 → 门禁 → 起 shell）
```

`--sync` 的安全承诺：

- 动手前把**当前 overlay 整体快照**到 `~/.local/state/clavis-ai-usage/backups/`（保留最近 3 份）；
- 若你手动改过 overlay 文件（哈希对不上），会**拒绝覆盖**，`--force` 才继续（仍先备份）；
- 补丁失败或语法门禁不过时，**自动恢复 sync 前的 overlay 并把你外壳拉起来**——
  降级策略是"继续跑旧版"，绝不把桌面弄崩。

## 锚点漂移（sync 报 `anchor matched 0 times`）

说明 Clavis 改了上游文本，属预期内的维护工作。修复流程见
[`patches/README.md`](../patches/README.md)（含 `--explain-drift` 诊断工具与
"如何为新版本重新校准"分步说明）。仓库里还有一个每周跑的
[compat-watch 工作流](../.github/workflows/compat.yml) 会提前开 issue 预警。

## 卸载与回退

```bash
./install.sh --uninstall            # 移除 overlay 与后端脚本（保留配置/缓存/备份）
./install.sh --uninstall --purge --yes   # 连配置/缓存/备份一起删（配置里有 key，谨慎）
```

若当初对 `/etc` 也打过补丁（历史遗留），可加 `--restore-etc` 从安装时的备份还原
那 4 个锚点文件。
