#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
"""补丁器测试：在纯净上游 fixture 上验证 应用 / 幂等 / 校验 / 回滚 / 漂移拒绝。

无需 Clavis 环境（CI 也能跑）——fixture 是 2026.9.25 发行树中的 4 个锚点文件。
"""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PATCHER = REPO / "scripts" / "patch_clavis_ai_card.py"
MANIFEST = REPO / "patches" / "manifest.json"
PAYLOAD = REPO / "qml"
FIXTURE = REPO / "tests" / "fixtures" / "upstream-2026.9.25"

ANCHOR_FILES = [
    "Modules/Sidebars/Dashboard/DashboardSidebarContent.qml",
    "Common/SidebarPolicy.js",
    "Modules/Sidebars/SidebarHostWindow.qml",
    "Modules/Bar/ActiveWindow/SidebarButton.qml",
]
PAYLOAD_FILES = [
    "Services/AiUsageService.qml",
    "Modules/Sidebars/Dashboard/AiView.qml",
    "Modules/Sidebars/Dashboard/AiUsageHistoryCard.qml",
    "Modules/Sidebars/Dashboard/deepseek-logo.svg",
    "Modules/Sidebars/Dashboard/claude-logo.svg",
    "Modules/Bar/ActiveWindow/SidebarAiButton.qml",
]


def run(target, *args):
    return subprocess.run(
        [sys.executable, str(PATCHER), "--manifest", str(MANIFEST),
         "--payload", str(PAYLOAD), "--target", str(target), *args],
        capture_output=True, text=True)


class PatcherTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="patcher-test-"))
        shutil.copytree(FIXTURE, self.tmp, dirs_exist_ok=True)
        (self.tmp / "README.md").unlink(missing_ok=True)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_apply_then_idempotent_then_verify(self):
        r = run(self.tmp)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count("patched"), 4)
        self.assertEqual(r.stdout.count("installed"), 6)
        policy = (self.tmp / "Common/SidebarPolicy.js").read_text()
        self.assertEqual(policy.count("// BEGIN clavis-ai-view"), 2)

        before = {p: (self.tmp / p).read_bytes() for p in ANCHOR_FILES + PAYLOAD_FILES}
        r2 = run(self.tmp)
        self.assertEqual(r2.returncode, 0, r2.stderr)
        self.assertEqual(r2.stdout.count("already-patched"), 4)
        self.assertEqual(r2.stdout.count("unchanged"), 6)
        after = {p: (self.tmp / p).read_bytes() for p in ANCHOR_FILES + PAYLOAD_FILES}
        self.assertEqual(before, after, "重跑不应改变任何字节")

        r3 = run(self.tmp, "--verify")
        self.assertEqual(r3.returncode, 0, r3.stderr)

    def test_verify_fails_before_apply(self):
        r = run(self.tmp, "--verify")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("verify failed", r.stderr)

    def test_revert_roundtrip(self):
        self.assertEqual(run(self.tmp).returncode, 0)
        r = run(self.tmp, "--revert", "--remove-payload")
        self.assertEqual(r.returncode, 0, r.stderr)
        for rel in ANCHOR_FILES:
            self.assertEqual((self.tmp / rel).read_bytes(), (FIXTURE / rel).read_bytes(),
                             f"{rel} 回滚后应与纯净上游逐字节一致")
        for rel in PAYLOAD_FILES:
            self.assertFalse((self.tmp / rel).exists(), f"{rel} 应已被移除")

    def test_drift_fails_before_any_write(self):
        policy = self.tmp / "Common/SidebarPolicy.js"
        policy.write_text(policy.read_text().replace('target === "weather"',
                                                     'target  === "weather"'))
        r = run(self.tmp)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("anchor matched 0 times", r.stderr)
        # 全树预校验：即便前面的文件锚点完好，也不允许发生任何写入
        content = (self.tmp / ANCHOR_FILES[0]).read_text()
        self.assertNotIn("BEGIN clavis-ai-view", content)

    def test_partial_marker_refused(self):
        self.assertEqual(run(self.tmp).returncode, 0)
        path = self.tmp / ANCHOR_FILES[0]
        text = path.read_text().replace("\n        // END clavis-ai-view", "", 1)
        path.write_text(text)
        r = run(self.tmp)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("marker count mismatch", r.stderr)

    def test_explain_drift_json(self):
        policy = self.tmp / "Common/SidebarPolicy.js"
        policy.write_text(policy.read_text().replace('target === "weather"',
                                                     'target  === "weather"'))
        r = run(self.tmp, "--explain-drift", "--json")
        self.assertEqual(r.returncode, 3, r.stderr)
        report = json.loads(r.stdout)
        self.assertTrue(report["drift"])
        item = report["drift"][0]
        self.assertEqual(item["file"], "Common/SidebarPolicy.js")
        self.assertIsNotNone(item["best_match_line"])
        self.assertIn("target", item["context"])
        self.assertIn("weather", item["context"])


if __name__ == "__main__":
    unittest.main()
