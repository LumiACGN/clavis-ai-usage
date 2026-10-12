#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
#
# overlay 引擎端到端彩排（假 HOME + 假 Clavis 树，零风险；CI 与本地共用）。
# 覆盖：dry-run 无写入 → 安装 → 断言 → verify → sync → uninstall。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$REPO/tests/fixtures/upstream-2026.9.25"

T="$(mktemp -d /tmp/overlay-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/src/quickshell/clavis"
cp -r "$FIXTURE/"* "$T/src/quickshell/clavis/"
rm -f "$T/src/quickshell/clavis/README.md"
printf '// stub shell.qml\n' > "$T/src/quickshell/clavis/shell.qml"

ENVV=(env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.state")
SRC="$T/src/quickshell/clavis"
OV="$T/home/.config/quickshell/clavis"
STATE="$T/home/.state/clavis-ai-usage/state.json"

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "### 1) dry-run 不应产生任何写入"
"${ENVV[@]}" "$REPO/install.sh" --dry-run --tree "$SRC" --skip-service --no-config-migrate >/dev/null
[ -e "$OV" ] && fail "dry-run 之后 overlay 竟存在"
[ -e "$STATE" ] && fail "dry-run 之后 state 竟存在"

echo "### 2) 安装 + 断言"
"${ENVV[@]}" "$REPO/install.sh" --tree "$SRC" --skip-service --no-config-migrate >/dev/null
grep -q 'BEGIN clavis-ai-view' "$OV/Common/SidebarPolicy.js" || fail "补丁未打"
[ -f "$OV/Services/AiUsageService.qml" ] || fail "payload 缺失"
[ -x "$T/home/.local/bin/clavis-ai-usage" ] || fail "bin 未安装"
[ -f "$STATE" ] || fail "state 缺失"
python3 - "$STATE" <<'PY' || fail "state 内容不正确"
import json, sys
st = json.load(open(sys.argv[1]))
assert st["schema"] == 1
assert len(st["patched_digest"]) == 4, st["patched_digest"]
assert len(st["payload_digest"]) == 6, st["payload_digest"]
PY

echo "### 3) verify 通过"
"${ENVV[@]}" "$REPO/install.sh" --verify --skip-service >/dev/null || fail "verify 非零退出"

echo "### 4) sync 幂等重放"
"${ENVV[@]}" "$REPO/install.sh" --sync --tree "$SRC" --skip-service >/dev/null || fail "sync 失败"
grep -q 'BEGIN clavis-ai-view' "$OV/Common/SidebarPolicy.js" || fail "sync 后补丁丢失"

echo "### 5) sync 在锚点漂移时干净失败且不动 overlay"
POLICY="$SRC/Common/SidebarPolicy.js"
cp "$POLICY" "$POLICY.bak"
python3 - "$POLICY" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('target === "weather"', 'target  === "weather"'))
PY
before="$(sha256sum "$OV/Common/SidebarPolicy.js" | cut -d' ' -f1)"
if "${ENVV[@]}" "$REPO/install.sh" --sync --tree "$SRC" --skip-service --force >/dev/null 2>&1; then
    fail "锚点漂移时 sync 不应成功"
fi
after="$(sha256sum "$OV/Common/SidebarPolicy.js" | cut -d' ' -f1)"
[ "$before" = "$after" ] || fail "sync 失败后 overlay 被改动（应保持原样）"
mv "$POLICY.bak" "$POLICY"

echo "### 6) uninstall 清理"
"${ENVV[@]}" "$REPO/install.sh" --uninstall --skip-service >/dev/null
[ -e "$OV" ] && fail "overlay 未移除"
[ -e "$T/home/.local/bin/clavis-ai-usage" ] && fail "bin 未移除"
[ -f "$STATE" ] || fail "state 应默认保留"

echo "全部通过 ✓"
