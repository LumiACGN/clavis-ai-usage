# 项目级说明（给自动化流程/代理）

本文件覆盖 `/home/lumi/GitHub-Projects/CLAUDE.md`（父目录规则）中与本仓库冲突的部分。
**冲突时以本文件为准。**

## 许可证是既定事实，不要"自动修复"

- 本项目**既定以 GPL-3.0-or-later 发布**（见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)）。
- 父目录规则里的这几条**不适用于本仓库**，禁止执行：
  - 「默认创建 MIT LICENSE / 自动补 MIT」——`LICENSE` 就是 GPL-3.0 原文，**不要替换、不要新增 MIT LICENSE**；
  - 「依赖许可证为 GPL/AGPL 时自动移除依赖」——这里的 GPL 是**本项目的许可证**，不是可移除的依赖。
- 新增源码文件的 SPDX 头沿用：

  ```
  SPDX-FileCopyrightText: 2026 LumiACGN
  SPDX-License-Identifier: GPL-3.0-or-later
  ```

  （**不是** MIT——父目录规则里的 MIT 模板在本仓库一律换成 GPL-3.0-or-later。）

## 提交署名

提交信息末尾按**实际驱动会话的模型**署名，格式：

```
Co-Authored-By: <模型名> <noreply@deepseek.com>
```

**禁止**统一写成 `Co-Authored-By: Claude Code <noreply@anthropic.com>` 或任何与实际模型不符的名字。

## 防泄漏四层防线（不要削弱任何一层）

1. `.gitignore`：用户数据、凭据类文件、临时产物一律不入库；
2. `.githooks/pre-commit`（`git config core.hooksPath .githooks`）：gitleaks 对 staged 内容扫描；
3. CI `.github/workflows/lint.yml`：gitleaks **全历史**扫描（用 CLI 直跑，不用 gitleaks-action
   ——后者对仓库首个提交必然失败）；
4. [SECURITY.md](SECURITY.md)：凭据/副作用承诺 + GitHub Security Advisory 报告渠道。

配置模板里只允许占位符（如 `sk-your-key-here`）；`config.json` 永不入库，
`config/config.example.json` 才是可提交的示例。

## 引擎与姊妹仓的硬联动

- `scripts/clavis_overlay.py` 与 `scripts/patch_clavis_kit.py` 与姊妹仓
  [clavis-lunar-calendar](https://github.com/LumiACGN/clavis-lunar-calendar) **逐字节相同**：
  改其中一个必须同步另一个（同一引擎、两份副本）。`ENGINE_REVISION` 是对账锚。
- 补丁器是 **kit 无关**的：组件身份（id/order/bin/config）一律写在 `patches/manifest.json`
  的 `kit` 段里，**不要**把本组件的名字硬编码回脚本。
- 锚点改动只动 `patches/manifest.json`，不要手改替换文本的语义；
  `tests/test_manifest.py` 会校验锚点唯一性、`anchor_sha256` 与 fixture 一致。
- `git config core.hooksPath .githooks` 已配置；提交前 gitleaks 会扫 staged 内容。

## 版本号与联动

版本**五处**必须一致（`release.yml` 校验其中四处）：

1. `bin/clavis-ai-usage` 的 `VERSION="x.y.z"`
2. `patches/manifest.json` 的 `tool_version`
3. `CHANGELOG.md` 的 `[x.y.z]` 小节
4. `packaging/aur/clavis-ai-usage/PKGBUILD` 的 `pkgver`
5. `packaging/aur/clavis-ai-usage/.SRCINFO`（用 `makepkg --printsrcinfo` 重新生成，别手改）

PKGBUILD 的 `source=` 指向 **release 资产**（`releases/download/v$pkgver/...`），
`sha256sums` 在发版后从 Release 页的 `SHA256SUMS` 回填。

## 硬边界

- **不写 `/etc`、不碰包管理器领地**：安装只写 `~/.config/quickshell/clavis/`、
  `~/.local/bin/clavis-ai-usage` 与 `~/.local/state/clavis-overlay/`；
  `/etc/xdg/quickshell/clavis` 只读。
- 调试验证用**假 HOME**（`HOME=<临时目录>`）+ `--skip-service`；跑 `install.sh` 会停/起
  `clavis-shell`，不要在用户真实桌面上试装，除非用户明确要求。
- 后端脚本的运行期契约（`schema_version=1` JSON）是公开接口：字段只增不改。
