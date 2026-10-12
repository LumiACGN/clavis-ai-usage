#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 构建"预览环境"：一个假 HOME，里面用桩二进制生成**全合成**数据，
# 供截图（docs/screenshots）与手动调试使用——绝不含任何真实凭据或用量。
#
# 用法: scripts/dev/make_preview.sh <preview-home>
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREVIEW_HOME="${1:?用法: make_preview.sh <preview-home>}"

rm -rf "$PREVIEW_HOME"
mkdir -p "$PREVIEW_HOME/stub-bin" "$PREVIEW_HOME/.config/clavis-ai-usage" \
         "$PREVIEW_HOME/.local/bin" "$PREVIEW_HOME/rt"

install -m755 "$REPO/tests/fixtures/stub-bin/ai-usagebar" "$PREVIEW_HOME/stub-bin/ai-usagebar"
install -m755 "$REPO/tests/fixtures/stub-bin/ccusage" "$PREVIEW_HOME/stub-bin/ccusage"
install -m755 "$REPO/bin/clavis-ai-usage" "$PREVIEW_HOME/.local/bin/clavis-ai-usage"

cat > "$PREVIEW_HOME/.config/clavis-ai-usage/config.json" <<EOF
{
  "deepseekApiKey": "sk-preview-fake-key",
  "aiUsagebar": { "path": "$PREVIEW_HOME/stub-bin/ai-usagebar" },
  "ccusage": { "path": "$PREVIEW_HOME/stub-bin/ccusage" },
  "historyWindowDays": 30
}
EOF
chmod 600 "$PREVIEW_HOME/.config/clavis-ai-usage/config.json"

# Clavis 界面偏好：暗色 + 24 小时制（贴近中文用户的真实观感）
mkdir -p "$PREVIEW_HOME/.config/clavis"
cat > "$PREVIEW_HOME/.config/clavis/ui-preferences.json" <<'EOF'
{
  "darkMode": true,
  "useTwelveHourClock": false
}
EOF
chmod 600 "$PREVIEW_HOME/.config/clavis/ui-preferences.json"

# 第一遍：账上 ¥22.00（模拟今天早些时候的余额快照）
env HOME="$PREVIEW_HOME" XDG_CACHE_HOME="$PREVIEW_HOME/.cache" \
    XDG_RUNTIME_DIR="$PREVIEW_HOME/rt" STUB_BALANCE='22.00' \
    "$PREVIEW_HOME/.local/bin/clavis-ai-usage" >/dev/null
# 第二遍：实际余额 ¥18.36（--force 绕过 TTL）→ 生成"今日实扣 ¥3.64"的口径
env HOME="$PREVIEW_HOME" XDG_CACHE_HOME="$PREVIEW_HOME/.cache" \
    XDG_RUNTIME_DIR="$PREVIEW_HOME/rt" \
    "$PREVIEW_HOME/.local/bin/clavis-ai-usage" --force > "$PREVIEW_HOME/preview-doc.json"

jq -e '.schema_version == 1 and (.providers | length) > 0 and (.local.history | length) > 0' \
    "$PREVIEW_HOME/preview-doc.json" >/dev/null || {
    echo "预览数据生成失败，输出如下：" >&2
    jq . "$PREVIEW_HOME/preview-doc.json" | head -40 >&2
    exit 1
}

printf '预览环境就绪：%s\n' "$PREVIEW_HOME"
printf '  providers  %s 个\n' "$(jq '.providers | length' "$PREVIEW_HOME/preview-doc.json")"
printf '  history    %s 天\n' "$(jq '.local.history | length' "$PREVIEW_HOME/preview-doc.json")"
printf '  今日 tokens %s\n' "$(jq '.local.today_tokens // 0' "$PREVIEW_HOME/preview-doc.json")"
