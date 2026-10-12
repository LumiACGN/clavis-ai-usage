#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
#
# clavis-ai-usage 顶层入口（薄壳，转发给 overlay 引擎）
#
#   ./install.sh                 首次安装（会自动停/起 clavis-shell）
#   ./install.sh --sync          Clavis 升级后重新对齐
#   ./install.sh --verify        检查安装状态
#   ./install.sh --uninstall     卸载（默认保留配置/缓存）
#
# 其余参数原样转发：--dry-run / --adopt / --force / --tree <路径> /
# --overlay-dir <路径> / --skip-service / --skip-bin / --purge --yes …
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="install"
ARGS=()
for a in "$@"; do
    case "$a" in
        --sync) MODE="sync" ;;
        --verify) MODE="verify" ;;
        --uninstall) MODE="uninstall" ;;
        *) ARGS+=("$a") ;;
    esac
done

exec python3 "$DIR/scripts/clavis_overlay.py" "$MODE" ${ARGS[@]+"${ARGS[@]}"}
