#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 无头截图产线：假 HOME（全合成数据）→ overlay 安装 → 纯看板 harness →
# cage（headless 合成器）渲染 → grim 抓图 → 裁切出 docs/screenshots。
#
# 用法: scripts/dev/capture_screenshots.sh [输出目录] [预览HOME]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="${1:-$REPO/docs/screenshots}"
PH="${2:-/tmp/clavis-screenshot-home}"

echo "== 1) 构建预览数据（合成）"
"$REPO/scripts/dev/make_preview.sh" "$PH" >/dev/null

echo "== 2) 安装 overlay 到预览 HOME（跳过服务控制）"
env HOME="$PH" XDG_CONFIG_HOME="$PH/.config" XDG_STATE_HOME="$PH/.state" \
    "$REPO/install.sh" --tree /etc/xdg/quickshell/clavis --skip-service >/dev/null

OV="$PH/.config/quickshell/clavis"

echo "== 3) 写入纯看板 harness"
cat > "$OV/shell.qml" <<'QML'
// SPDX-FileCopyrightText: 2026 LumiACGN
// SPDX-License-Identifier: GPL-3.0-or-later
// 截图 harness（仅预览用）：把 AI 看板铺满输出（输出被设为侧边栏比例 480x1600）。
import QtQuick
import Quickshell
import qs.Modules.Sidebars.Dashboard

ShellRoot {
    FloatingWindow {
        color: "#17161f"
        AiView {
            anchors.fill: parent
            foreground: true
        }
    }
}
QML

echo "== 4) cage 无头渲染 + grim 抓图"
SHOT_TMP="$(mktemp -d /tmp/clavis-shot.XXXXXX)"
mkdir -p "$SHOT_TMP/rt"
chmod 700 "$SHOT_TMP/rt"
trap 'rm -rf "$SHOT_TMP"' EXIT

timeout 90 env HOME="$PH" XDG_RUNTIME_DIR="$SHOT_TMP/rt" \
    WLR_BACKENDS=headless WLR_HEADLESS_OUTPUTS=1 \
    SHOT_OVERLAY="$OV" SHOT_DIR="$SHOT_TMP" SHOT_MODE=480x1600 \
    cage -- "$REPO/scripts/dev/capture_shot.sh"

[ -f "$SHOT_TMP/shot.png" ] || { echo "截图失败，qs 日志：" >&2; cat "$SHOT_TMP/qs.log" >&2; exit 1; }

echo "== 5) 裁切产物"
mkdir -p "$OUT_DIR"
cp "$SHOT_TMP/shot.png" "$OUT_DIR/preview.png"                       # 整页（480x1600）
magick "$SHOT_TMP/shot.png" -crop 480x380+0+66  +repage "$OUT_DIR/providers.png"   # 供应商区
magick "$SHOT_TMP/shot.png" -crop 480x640+0+690 +repage "$OUT_DIR/history.png"     # 历史用量区
magick identify "$OUT_DIR"/*.png
echo "完成：$OUT_DIR"
