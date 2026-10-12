# 常见问题

先跑一遍体检，多数问题它会直接告诉你原因：

```bash
./install.sh --verify
clavis-ai-usage --explain-keys     # 凭据来源（不显示值）
```

## 安装后侧边栏看不到「AI 用量」

1. `./install.sh --verify` 看补丁是否在位；
2. 确认 overlay 真的生效：`qs list --all` 里 `Config path` 应指向
   `~/.config/quickshell/clavis/shell.qml`（而不是 `/etc/xdg/...`）；
3. 看外壳日志：`journalctl --user -u clavis-shell -n 50 --no-pager`。

## Clavis 升级后「AI 用量」页整个消失

正常现象——overlay 是全树遮蔽，升级后必须对齐：

```bash
./install.sh --sync
```

## 页面能开，但没数据 / 部分卡片空

按数据源逐个排查：

- **供应商（余额/配额）空白** → 需要 [ai-usagebar](https://github.com/akitaonrails/ai-usagebar)
  （`paru -S ai-usagebar`）+ 至少一个供应商 key。`clavis-ai-usage --explain-keys` 看 key 来源。
- **Claude Code 一段空白** → 需要 [ccusage](https://github.com/ryoppippi/ccusage)
  （`npm i -g ccusage`），且本机用过 Claude Code 才有数据。
- **官方账单层没有** → 该层默认关闭且属非公开接口，见
  [CONFIGURATION.md 的风险说明](CONFIGURATION.md#️-deepseek-平台账单层official默认关闭)。
- **数据明显过期** → 各来源有 TTL 缓存（providers 9 分钟 / local 5 分钟 / official 1 小时）；
  手动刷新按钮只触发脚本，TTL 未过期时不会打接口，可用 `clavis-ai-usage --force` 强制。

后端脚本也可以单独诊断（不经过界面）：

```bash
clavis-ai-usage --offline | jq .            # 只用缓存，离线契约检查
clavis-ai-usage --force   | jq .stale_sources   # 强制刷新，看哪些源是旧数据
```

## sync 失败

补丁器报「anchor matched 0 times」= Clavis 改了上游文本，按
[`patches/README.md`](../patches/README.md) 的流程修锚点。你的桌面不受影响——
sync 失败会自动恢复旧 overlay，继续跑旧版。

## 外壳起不来（进入 failed 状态）

语法门禁会在"启用坏补丁"之前阻止安装/同步，所以正常情况下不会发生。
如果手动改过 overlay 导致崩溃循环：

```bash
systemctl --user stop clavis-shell
rm -rf ~/.config/quickshell/clavis        # 移除 overlay，立刻回到系统原生
systemctl --user reset-failed clavis-shell
systemctl --user start clavis-shell
```

（之后想恢复本项目：`./install.sh`）

## 重置数据 / 完全重来

```bash
rm -rf ~/.cache/clavis-ai-usage       # 清缓存（历史数据与 last-good 都在这里）
./install.sh --uninstall && ./install.sh   # overlay 层面完全重来（配置保留）
```

## 旧机器上的 /etc 补丁残留

若你以前用"直接改 /etc"的方式装过同类补丁，overlay 生效后那些改动会被遮蔽、
而且每次 Clavis 升级后它们会静默失效（不报错但无效）。建议把对 Clavis 树的定制
统一改到 overlay 上（即 `~/.config/quickshell/clavis/`），或卸载时用
`./install.sh --uninstall --restore-etc` 清理锚点文件。
