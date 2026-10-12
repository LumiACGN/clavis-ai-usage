<!--
SPDX-FileCopyrightText: 2026 LumiACGN
SPDX-License-Identifier: GPL-3.0-or-later
-->

# dummy-kit：测试夹具（不是真实组件）

这份「组件」只服务于 `tests/test_coexist.sh`（多 kit 共存彩排），**不会安装到任何
真实 Clavis 环境**，也不随本项目发布。

它是刻意设计成「最难场景」的：

- `kit.id = clavis-dummy-kit`、`order = 20`（排在 `clavis-ai-usage` 的 order 10 之后）；
- 打的文件是 **`Common/SidebarPolicy.js`**——与 `clavis-ai-usage` 同一个文件（共享文件，
  两个 kit 的标记必须并存且互不干扰）；
- 锚点选在 `normalizeSide()` 函数（AI 组件的两处补丁都不碰的区域），因此谁先打都成立；
- payload 是一个 QML JS 文件 `Common/functions/DummyProbe.js`；
- `bin_name` / `config_dir` / `cache_dir` / `legacy_config` 全为 `null`（组件无后端脚本、
  无配置），用于覆盖引擎的「无 bin 组件」分支。

`tests/test_coexist.sh` 会把 `scripts/patch_clavis_kit.py` 与本目录的 `manifest.json`、
`qml/` 组装成一个临时的完整组件仓库（`$T/dummy-kit/`），再用引擎的
`install --repo-root` 注册它。

维护须知：改这里的 `anchor` 之前先读
`tests/fixtures/upstream-2026.9.25/Common/SidebarPolicy.js` 的真实文本核对——
`tests/test_manifest.py` 会校验锚点在该基线里恰好命中一次。
