#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
#
# 本地 lint（与 CI 的 lint.yml 对齐）：shellcheck + bash -n + Python 语法 + manifest 自检。
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

echo "== shell 语法与 shellcheck"
mapfile -t SH_FILES < <(find . -path ./.git -prune -o -type f \
    \( -name '*.sh' -o -path './bin/clavis-ai-usage' \) -print | sort)
bash -n "${SH_FILES[@]}"
shellcheck -S warning "${SH_FILES[@]}"

echo "== Python 语法"
python3 - <<'PY'
import ast, pathlib
for f in pathlib.Path('.').rglob('*.py'):
    ast.parse(f.read_text(encoding='utf-8'), str(f))
print('python syntax ok')
PY

echo "== manifest 自检"
python3 tests/test_manifest.py

echo "lint 全部通过 ✓"
