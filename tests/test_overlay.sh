#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
#
# overlay 引擎 v2 端到端彩排（假 HOME + 假 Clavis 树，零风险；CI 与本地共用）。
# 覆盖：dry-run 零写入 → 安装 → 断言 → verify → sync 幂等 → 源树漂移时干净失败
#       → uninstall → 源树里已烘进旧补丁时的规范化重放（6a 回滚重放）。
#
# 期望值（fixture 版本、kit 状态路径、marker 串、各文件标记数）全部从
# patches/manifest.json 派生，不硬编码。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO/patches/manifest.json"

mfield() { python3 -c "import json,sys; print($1)" "$MANIFEST"; }
FIXTURE="$REPO/tests/fixtures/upstream-$(mfield 'json.load(open(sys.argv[1]))["upstream"]["version"]')"
GROUP="$(mfield 'sorted({e["group"] for e in json.load(open(sys.argv[1]))["files"]})[0]')"
KIT_ID="$(mfield 'json.load(open(sys.argv[1]))["kit"]["id"]')"
BEGIN="// BEGIN clavis-$GROUP"
SHARED="Common/SidebarPolicy.js"
SHARED_EDITS="$(mfield "len([e for e in json.load(open(sys.argv[1]))['files'] if e['path'] == '$SHARED'][0]['edits'])")"

T="$(mktemp -d /tmp/overlay-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/src/quickshell/clavis"
cp -r "$FIXTURE/"* "$T/src/quickshell/clavis/"
rm -f "$T/src/quickshell/clavis/README.md"
printf '// stub shell.qml\n' > "$T/src/quickshell/clavis/shell.qml"

ENVV=(env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_STATE_HOME="$T/home/.state")
SRC="$T/src/quickshell/clavis"
OV="$T/home/.config/quickshell/clavis"
STATE_ROOT="$T/home/.state/clavis-overlay"
STATE="$STATE_ROOT/kits/$KIT_ID.json"

fail() { echo "FAIL: $*" >&2; exit 1; }
treehash() { find "$1" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1; }

echo "### 1) dry-run 不应产生任何写入"
"${ENVV[@]}" "$REPO/install.sh" --dry-run --tree "$SRC" --skip-service --no-config-migrate >/dev/null
[ -e "$OV" ] && fail "dry-run 之后 overlay 竟存在"
[ -e "$STATE_ROOT" ] && fail "dry-run 之后 state 目录竟存在"

echo "### 2) 安装 + 断言（状态 schema v2，路径 $STATE）"
"${ENVV[@]}" "$REPO/install.sh" --tree "$SRC" --skip-service --no-config-migrate >/dev/null
grep -q "$BEGIN" "$OV/$SHARED" || fail "补丁未打"
[ -f "$OV/Services/AiUsageService.qml" ] || fail "payload 缺失"
[ -x "$T/home/.local/bin/clavis-ai-usage" ] || fail "bin 未安装"
[ -f "$STATE" ] || fail "kit 状态缺失：$STATE"
python3 - "$STATE" "$MANIFEST" "$KIT_ID" "$STATE_ROOT/registry.json" "$SRC" "$OV" <<'PY' || fail "kit 状态 / registry / 载荷内容不正确"
import json, pathlib, sys
state_path, manifest_path, kit_id, registry_path, source, overlay = sys.argv[1:7]
st = json.load(open(state_path))
mf = json.load(open(manifest_path))
assert st["schema"] == 2, st["schema"]
assert st["kit"] == kit_id, st["kit"]
assert st["order"] == mf["kit"]["order"], st["order"]
assert st["groups"] == sorted({e["group"] for e in mf["files"]}), st["groups"]
assert len(st["digests"]["patched"]) == len(mf["files"]), st["digests"]["patched"]
assert len(st["digests"]["payload"]) == len(mf["payload"]), st["digests"]["payload"]
assert st["bin"] and st["bin"]["digest"], "bin 摘要应记录"
assert st["migrated_from"] is None, st["migrated_from"]
assert st["repo_root"] and pathlib.Path(st["repo_root"]).is_dir(), st["repo_root"]
assert st["source_tree"] == source, (st["source_tree"], source)
assert st["overlay_dir"] == overlay, (st["overlay_dir"], overlay)
missing = [p["dest"] for p in mf["payload"] if not (pathlib.Path(overlay) / p["dest"]).is_file()]
assert not missing, missing
reg = json.load(open(registry_path))
assert reg["schema"] == 2 and reg["engine_revision"], reg
assert reg["kits"] == [kit_id], reg["kits"]
assert reg["last_sync_ok"] is True, reg
PY
H0="$(treehash "$OV")"

echo "### 3) verify 通过"
"${ENVV[@]}" "$REPO/install.sh" --verify --skip-service >"$T/verify.out" 2>&1 || {
    cat "$T/verify.out" >&2; fail "verify 非零退出"; }
grep -q "verify ok" "$T/verify.out" || fail "verify 未报告成功"
grep -q "无孤儿标记" "$T/verify.out" || fail "verify 应报告无孤儿标记"

echo "### 4) sync 幂等重放"
"${ENVV[@]}" "$REPO/install.sh" --sync --tree "$SRC" --skip-service >/dev/null || fail "sync 失败"
grep -q "$BEGIN" "$OV/$SHARED" || fail "sync 后补丁丢失"
[ "$(grep -c "$BEGIN" "$OV/$SHARED")" -eq "$SHARED_EDITS" ] || fail "sync 后标记数变化"
H4="$(treehash "$OV")"
[ "$H4" = "$H0" ] || fail "sync 后 overlay 应与安装后逐字节一致（幂等）"

echo "### 5) sync 在锚点漂移时干净失败且不动 overlay"
POLICY="$SRC/$SHARED"
cp "$POLICY" "$POLICY.bak"
python3 - "$POLICY" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace('target === "weather"', 'target  === "weather"'))
PY
if "${ENVV[@]}" "$REPO/install.sh" --sync --tree "$SRC" --skip-service >"$T/drift.out" 2>&1; then
    fail "锚点漂移时 sync 不应成功"
fi
grep -q "恢复到同步前状态" "$T/drift.out" || fail "失败时应提示已恢复到同步前状态"
[ "$(treehash "$OV")" = "$H4" ] || fail "sync 失败后 overlay 被改动（应保持原样）"
mv "$POLICY.bak" "$POLICY"

echo "### 6) uninstall 清理（kit 状态移除、状态目录保留）"
"${ENVV[@]}" "$REPO/install.sh" --uninstall --skip-service >/dev/null
[ -e "$OV" ] && fail "overlay 未移除"
[ -e "$T/home/.local/bin/clavis-ai-usage" ] && fail "bin 未移除"
[ -e "$STATE" ] && fail "kit 状态文件应被移除：$STATE"
[ -d "$STATE_ROOT" ] || fail "clavis-overlay 状态目录应保留"
[ -d "$STATE_ROOT/backups" ] || fail "状态目录里的 backups 应保留"
find "$STATE_ROOT/backups" -name '*.tar.gz' -print -quit | grep -q . || fail "backups 里应有备份"

echo "### 7) 源树里已烘进旧补丁 → 安装后仍是「规范化后的单一版本」"
"${ENVV[@]}" python3 "$REPO/scripts/patch_clavis_kit.py" --manifest "$MANIFEST" \
    --payload "$REPO/qml" --target "$SRC" >/dev/null || fail "无法把旧补丁烘进源树"
grep -q "$BEGIN" "$SRC/$SHARED" || fail "源树里应有已烘入的旧补丁"
"${ENVV[@]}" "$REPO/install.sh" --tree "$SRC" --skip-service --no-config-migrate >/dev/null \
    || fail "对已含旧补丁的源树安装失败"
python3 - "$MANIFEST" "$OV" <<'PY' || fail "overlay 里的补丁不是规范化后的单一版本（标记数翻倍？）"
import json, pathlib, sys
mf = json.load(open(sys.argv[1])); ov = pathlib.Path(sys.argv[2])
for entry in mf["files"]:
    begin = mf["marker"]["begin"].replace("{group}", entry["group"])
    end = mf["marker"]["end"].replace("{group}", entry["group"])
    text = (ov / entry["path"]).read_text(encoding="utf-8")
    assert text.count(begin) == len(entry["edits"]), (entry["path"], "BEGIN", text.count(begin))
    assert text.count(end) == len(entry["edits"]), (entry["path"], "END", text.count(end))
PY
[ "$(grep -c "$BEGIN" "$OV/$SHARED")" -eq "$SHARED_EDITS" ] || fail "共享/锚点文件里标记数翻倍"
[ "$(treehash "$OV")" = "$H4" ] || fail "烘焙旧补丁后安装的 overlay 应与干净安装逐字节一致"

echo "全部通过 ✓"
