#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 后端脚本契约测试：无需网络、无需 Clavis，全部在假 HOME 里执行。
# 覆盖：CLI、JSON 契约、坏缓存兜底、explain-keys 防泄漏、配置路径优先级、并发锁。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$REPO/bin/clavis-ai-usage"

T="$(mktemp -d /tmp/backend-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/rt" "$T/.cache"

run() { env HOME="$T" XDG_CACHE_HOME="$T/.cache" XDG_RUNTIME_DIR="$T/rt" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "### 1) 基础 CLI"
"$BIN" --version | grep -q '^clavis-ai-usage ' || fail "--version 输出异常"
"$BIN" --help | grep -q '用法' || fail "--help 输出异常"
rc=0; "$BIN" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "未知参数应 exit 2（实际 $rc）"

echo "### 2) --offline 空缓存输出契约"
run "$BIN" --offline > "$T/out.json" || fail "--offline 应 exit 0"
jq -e '.schema_version == 1 and (.providers | type == "array")' "$T/out.json" >/dev/null \
    || fail "--offline 输出不符合 schema_version=1 契约"

echo "### 3) 损坏缓存仍输出合法 JSON"
mkdir -p "$T/.cache/clavis-ai-usage"
printf '{broken' > "$T/.cache/clavis-ai-usage/history.json"
run "$BIN" --offline > "$T/out2.json" || fail "坏缓存时应 exit 0"
jq -e '.schema_version == 1' "$T/out2.json" >/dev/null || fail "坏缓存后 JSON 契约不成立"

echo "### 4) --explain-keys 不泄漏凭据值"
out="$(run env DEEPSEEK_API_KEY="sk-TESTLEAK123" "$BIN" --explain-keys 2>/dev/null)"  # gitleaks:allow（哨兵值，用于断言不会被打印）
printf '%s' "$out" | grep -q 'sk-TESTLEAK123' && fail "explain-keys 泄漏了凭据值！"
printf '%s' "$out" | grep -q '环境变量' || fail "explain-keys 应报告来源为环境变量"

echo "### 5) 配置路径优先级 + 旧路径提示 + 权限告警"
mkdir -p "$T/.config/clavis"
printf '{}' > "$T/.config/clavis/ai-usage.json"
chmod 644 "$T/.config/clavis/ai-usage.json"
run "$BIN" --explain-keys 2>"$T/err" | grep -q 'ai-usage.json' || fail "应命中旧路径配置"
grep -q '旧路径配置' "$T/err" || fail "旧路径应有迁移提示"
grep -q '权限为 644' "$T/err" || fail "过宽权限应有告警"

mkdir -p "$T/.config/clavis-ai-usage"
printf '{}' > "$T/.config/clavis-ai-usage/config.json"
chmod 600 "$T/.config/clavis-ai-usage/config.json"
run "$BIN" --explain-keys 2>"$T/err2" | grep -q 'clavis-ai-usage/config.json' || fail "新路径应优先"
grep -q '旧路径配置' "$T/err2" && fail "命中新路径时不应再提示旧路径"

echo "### 6) 并发锁：他方持锁时服务缓存而非重跑"
exec 8>"$T/rt/clavis-ai-usage.lock"
flock -n 8
run "$BIN" --offline > "$T/out3.json" 2>"$T/err3" || fail "持锁时也应 exit 0"
jq -e '.schema_version == 1' "$T/out3.json" >/dev/null || fail "持锁时 JSON 契约不成立"
grep -q 'serving cache' "$T/err3" || fail "持锁时应提示 serving cache"
exec 8>&-

echo "全部通过 ✓"
