# 兼容性与升级

## 为什么是 overlay + 锚点补丁

- Quickshell（0.3.x）**没有插件系统**；Clavis Shell 也没有第三方扩展 API。
- 唯一官方支持的用户扩展机制是 **XDG 覆盖**：
  `~/.config/quickshell/clavis/` 存在时**整体优先**于 `/etc/xdg/quickshell/clavis/`
  （Quickshell 按 XDG 顺序取第一个含 `<name>/shell.qml` 的目录，**整目录独占，不合并**）。
- 所以本项目把系统 Clavis 树**完整镜像**到 overlay 目录，再用锚点把 AI 看板缝进
  4 个上游文件（外加 6 个新增文件）。**绝不写 `/etc`**（pacman 领地，升级即覆盖）。
- 同机的多个 clavis 组件（kit）共享这一个 overlay：引擎按各自的 `order` 重放全部已注册
  组件——「两个组件互相覆盖 overlay」不再是问题，见下节。

> ⚠️ overlay 是全树遮蔽：生效期间 `/etc` 里的 Clavis 副本被完全忽略（包括你自己对它打过的
> 其它补丁）。Clavis 升级后 **必须跑一次 `./install.sh --sync`** 把 overlay 对齐到新版本，
> 否则你会继续跑旧代码（`--verify` 会提醒）。任一组件的 `--sync` 都会重放全部组件。

## 与其它 clavis 组件共存（多 kit 重放）

引擎 v2 把每个组件注册为一个 kit（状态在 `~/.local/state/clavis-overlay/kits/<kit-id>.json`），
`sync` 是唯一写路径：镜像源树 → 按 `order` 重放全部已注册 kit（各自先回滚源树里烘入的旧补丁、
再重新打上）→ 并集语法门禁。因此**谁 sync 谁负责把大家都重新打上**，不存在"后装的把先装的
覆盖掉"。

- 组件之间不得使用相同的 `group`（引擎检测到会直接报错并给出两个 kit 的名字）。
- 某个组件的仓库被删除/搬走时，sync 会**响亮失败**而不是静默丢掉它——修复方式见
  [TROUBLESHOOTING.md](TROUBLESHOOTING.md) 的「多组件」一节。
- `./install.sh --list` 可看当前注册了哪些组件、各自的重放顺序（order）与仓库路径。

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

- 动手前把**当前 overlay 整体快照**到 `~/.local/state/clavis-overlay/backups/`（保留最近 3 份）；
- 若你手动改过 overlay 文件（哈希对不上），会**拒绝覆盖**，`--force` 才继续（仍先备份）；
  被兄弟 kit 补丁改写的共享文件不算手改，不会拦你；
- 补丁失败或语法门禁不过时，**自动恢复 sync 前的 overlay 并把你外壳拉起来**，而且**一个 kit
  状态文件都不写**——降级策略是"继续跑旧版"，绝不把桌面弄崩。

## 锚点漂移（sync 报 `anchor matched 0 times`）

说明 Clavis 改了上游文本，属预期内的维护工作。修复流程见
[`patches/README.md`](../patches/README.md)（含 `--explain-drift` 诊断工具与
"如何为新版本重新校准"分步说明）。仓库里还有
[compat-watch 工作流](../.github/workflows/compat.yml)：**手动触发**（Actions 页 →
compat-watch → Run workflow），会检查上游最新版本、锚点漂移时自动开 issue 预警。

## 卸载与回退

```bash
./install.sh --uninstall                 # 只移除本组件（其它已注册组件保持完好；配置/缓存/备份保留）
./install.sh --uninstall --purge --yes   # 连本组件的配置/缓存一起删（配置里有 key，谨慎）
./install.sh --uninstall --all           # 整体拆除：所有组件 + overlay（状态与备份保留）
```

（`--all` 再加 `--purge --yes` 会把状态与备份也删掉。）

若当初对 `/etc` 也打过补丁（历史遗留），可加 `--restore-etc` 从
`~/.local/state/clavis-overlay/backups/<kit>/etc-anchors-*.tar.gz` 还原源树锚点文件；
没有该备份时会报错退出。
