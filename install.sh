#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
#
# clavis-ai-usage 顶层入口（薄壳，转发给 overlay 引擎）
#
#   ./install.sh                 首次安装（会自动停/起 clavis-shell）
#   ./install.sh --sync          Clavis 升级后重新对齐（多组件时按 order 重放全部）
#   ./install.sh --verify        逐组件检查 + 孤儿标记报告
#   ./install.sh --list          列出已注册组件
#   ./install.sh --uninstall     移除本组件（--all 整体拆除，默认保留配置/缓存）
#   ./install.sh --forget <id>   从注册表摘除某组件（不动 overlay；repo 被删/搬走时的逃生舱）
#
# 其余参数原样转发：--dry-run / --adopt / --force / --tree <路径> / --repo-root <路径> /
# --overlay-dir <路径> / --skip-service / --skip-bin / --skip-missing / --allow-service /
# --purge --yes …
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="install"
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --sync) MODE="sync" ;;
        --verify) MODE="verify" ;;
        --uninstall) MODE="uninstall" ;;
        --list) MODE="list" ;;
        --forget) MODE="forget"; shift; ARGS+=("${1:?--forget 需要一个组件 id（见 --list）}") ;;
        *) ARGS+=("$1") ;;
    esac
    shift
done

exec python3 "$DIR/scripts/clavis_overlay.py" "$MODE" ${ARGS[@]+"${ARGS[@]}"}
