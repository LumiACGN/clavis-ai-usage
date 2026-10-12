#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
"""补丁器测试：在纯净上游 fixture 上验证 应用 / 幂等 / 校验 / 回滚 / 漂移拒绝。

无需 Clavis 环境（CI 也能跑）——fixture 是 2026.9.25 发行树中的 4 个锚点文件。

期望值（锚点文件清单、payload 清单、marker 串、各项计数）全部**从
patches/manifest.json 派生**，不再硬编码：manifest 增删一处锚点，这里自动跟上。

block 定位模式（`mode: "block"`）的用例用测试自己生成的迷你 QML 树 + 迷你 manifest
（写在 tmp 目录，完全自包含）——因为本仓的 manifest 里没有任何 block edit，
而 block 恰恰是最需要边界覆盖的分支（容忍块内漂移、sanity 兜底、花括号陷阱、
顺序契约、回滚、explain-drift）。
"""
import copy
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
PATCHER = REPO / "scripts" / "patch_clavis_kit.py"
MANIFEST = REPO / "patches" / "manifest.json"
PAYLOAD = REPO / "qml"
FIXTURE = REPO / "tests" / "fixtures" / "upstream-2026.9.25"

MANIFEST_DATA = json.loads(MANIFEST.read_text(encoding="utf-8"))
ANCHOR_FILES = [entry["path"] for entry in MANIFEST_DATA["files"]]
PAYLOAD_FILES = [item["dest"] for item in MANIFEST_DATA["payload"]]
GROUPS = sorted({entry["group"] for entry in MANIFEST_DATA["files"]})
BEGIN_MARKER = MANIFEST_DATA["marker"]["begin"].replace("{group}", GROUPS[0])


def run(target, *args, manifest=MANIFEST, payload=PAYLOAD):
    return subprocess.run(
        [sys.executable, str(PATCHER), "--manifest", str(manifest),
         "--payload", str(payload), "--target", str(target), *args],
        capture_output=True, text=True)


def count_status(stdout, status):
    """数结果行里的状态词（结果行形如 '       patched  /path/file.qml'）。"""
    return sum(1 for line in stdout.splitlines() if line.split()[:1] == [status])


class PatcherTests(unittest.TestCase):
    """真实 manifest（exact 模式）+ 上游基线 fixture。"""

    def setUp(self):
        self.assertTrue(PATCHER.is_file(), f"补丁器不存在：{PATCHER}")
        self.tmp = Path(tempfile.mkdtemp(prefix="patcher-test-"))
        shutil.copytree(FIXTURE, self.tmp, dirs_exist_ok=True)
        (self.tmp / "README.md").unlink(missing_ok=True)
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def snapshot(self):
        return {rel: (self.tmp / rel).read_bytes() for rel in ANCHOR_FILES + PAYLOAD_FILES}

    def test_apply_then_idempotent_then_verify(self):
        r = run(self.tmp)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(count_status(r.stdout, "patched"), len(ANCHOR_FILES))
        self.assertEqual(count_status(r.stdout, "installed"), len(PAYLOAD_FILES))

        # 每个锚点文件里的 BEGIN 标记数 == manifest 登记的 edit 数
        for entry in MANIFEST_DATA["files"]:
            begin = MANIFEST_DATA["marker"]["begin"].replace("{group}", entry["group"])
            text = (self.tmp / entry["path"]).read_text(encoding="utf-8")
            self.assertEqual(text.count(begin), len(entry["edits"]),
                             f"{entry['path']}: BEGIN 标记数应等于其 edit 数")

        before = self.snapshot()
        r2 = run(self.tmp)
        self.assertEqual(r2.returncode, 0, r2.stderr)
        self.assertEqual(count_status(r2.stdout, "already-patched"), len(ANCHOR_FILES))
        self.assertEqual(count_status(r2.stdout, "unchanged"), len(PAYLOAD_FILES))
        self.assertEqual(before, self.snapshot(), "重跑不应改变任何字节")

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
        self.assertNotIn(BEGIN_MARKER, content)

    def test_partial_marker_refused(self):
        self.assertEqual(run(self.tmp).returncode, 0)
        path = self.tmp / ANCHOR_FILES[0]
        text = path.read_text().replace(f"\n        {MANIFEST_DATA['marker']['end'].replace('{group}', GROUPS[0])}",
                                        "", 1)
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
        self.assertEqual(item["mode"], "exact")
        self.assertIsNotNone(item["best_match_line"])
        self.assertIn("target", item["context"])
        self.assertIn("weather", item["context"])


# ---------------------------------------------------------------------------
# block 模式：迷你 QML 树 + 迷你 manifest（自包含）
# ---------------------------------------------------------------------------

MINI_QML = '''Item {
    id: root

    component DayButton: RippleButton {
        id: dayButton

        property int todayState: 0

        contentItem: Text {
            text: qsTr("day")
            font.pixelSize: 14
            color: "#ffffff"
        }
    }

    property int alpha: 1
    property int beta: 2
}
'''

MINI_BLOCK_ANCHOR = '''    component DayButton: RippleButton {
        id: dayButton

        property int todayState: 0

        contentItem: Text {
            text: qsTr("day")
            font.pixelSize: 14
            color: "#ffffff"
        }
    }'''

MINI_BLOCK_REPLACE = '''    component DayButton: RippleButton {
        id: dayButton

        property int todayState: 0

        // BEGIN clavis-mini
        contentItem: Text {
            text: qsTr("day")
            font.pixelSize: 14
            color: "#ffffff"
        }
        // END clavis-mini
    }'''

MINI_EXACT_ANCHOR = "    property int alpha: 1"
MINI_EXACT_REPLACE = ("    // BEGIN clavis-mini\n"
                      "    property int alpha: 1\n"
                      "    property int miniProbe: 1\n"
                      "    // END clavis-mini")

MINI_EDITS = [
    {
        "id": "edit-1",
        "mode": "block",
        "block": {
            "unique_line": "    component DayButton: RippleButton {",
            "sanity": ["id: dayButton", "contentItem: Text {", "font.pixelSize:"],
        },
        "anchor": MINI_BLOCK_ANCHOR,
        "replace": MINI_BLOCK_REPLACE,
    },
    {
        "id": "edit-2",
        "mode": "exact",
        "anchor": MINI_EXACT_ANCHOR,
        "replace": MINI_EXACT_REPLACE,
    },
]


def mini_manifest(edits):
    return {
        "schema": 1,
        "tool_version": "0.0.0",
        "kit": {"id": "clavis-mini-fixture", "name": "迷你夹具", "order": 50},
        "gates": {"overrides": {}, "smoke": None},
        "upstream": {"name": "clavis-shell", "version": "2026.9.25",
                     "tree_hint": "/nonexistent/never-used"},
        "marker": {"begin": "// BEGIN clavis-{group}", "end": "// END clavis-{group}"},
        "files": [{"group": "mini", "path": "Mini.qml", "edits": edits}],
        "payload": [],
    }


class BlockModeTests(unittest.TestCase):
    """block 定位模式的边界用例（迷你树 + 迷你 manifest，与真实 manifest 无关）。"""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="patcher-block-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.tree = self.tmp / "tree"
        self.tree.mkdir()
        self.payload = self.tmp / "payload"
        self.payload.mkdir()
        self.manifest = self.tmp / "manifest.json"
        self.write_tree(MINI_QML)
        self.write_manifest(MINI_EDITS)

    def write_tree(self, text):
        (self.tree / "Mini.qml").write_text(text, encoding="utf-8")

    def read_tree(self):
        return (self.tree / "Mini.qml").read_text(encoding="utf-8")

    def write_manifest(self, edits):
        self.manifest.write_text(json.dumps(mini_manifest(edits), ensure_ascii=False),
                                 encoding="utf-8")

    def patch(self, *args):
        return run(self.tree, *args, manifest=self.manifest, payload=self.payload)

    def test_block_apply_tolerates_drift_inside_block(self):
        """块内 font.pixelSize 被上游/本机全局字号补丁改动 —— block 模式仍应成功。"""
        self.write_tree(MINI_QML.replace("font.pixelSize: 14", "font.pixelSize: 15"))
        r = self.patch()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(count_status(r.stdout, "patched"), 1)  # 结果按文件计（本文件 2 个 edit）
        text = self.read_tree()
        self.assertEqual(text.count("// BEGIN clavis-mini"), 2)
        # 漂移过的块被 manifest 里的 replace 整体换掉（BEGIN/END 落在花括号内）
        self.assertIn(MINI_BLOCK_REPLACE, text)
        self.assertNotIn("font.pixelSize: 15", text, "漂移版本应被替换掉")
        self.assertEqual(self.patch("--verify").returncode, 0)

    def test_block_sanity_failure_writes_nothing(self):
        """块内 sanity 子串被改名 —— 拒绝猜测，且一个字节都不写。"""
        broken = MINI_QML.replace("id: dayButton", "id: dayCell")
        self.write_tree(broken)
        r = self.patch()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("sanity", r.stderr)
        self.assertEqual(self.read_tree(), broken, "sanity 失败时不应写入任何字节")

    def test_block_unique_line_missing(self):
        """unique_line 那一行被删 —— 报「命中 0 次」。"""
        broken = MINI_QML.replace("    component DayButton: RippleButton {\n", "")
        self.write_tree(broken)
        r = self.patch()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("命中 0 次", r.stderr)
        self.assertEqual(self.read_tree(), broken)

    def test_block_brace_trap(self):
        """块内插入带 '{' 的字符串 —— 朴素养花括号配对会错配，必须报错而不是写坏文件。"""
        broken = MINI_QML.replace("        property int todayState: 0\n",
                                  "        property int todayState: 0\n"
                                  "        property string x: \"{\"\n")
        self.write_tree(broken)
        r = self.patch()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("花括号", r.stderr)
        self.assertEqual(self.read_tree(), broken, "花括号错配时不应写入任何字节")

    def test_block_revert_roundtrip(self):
        self.assertEqual(self.patch().returncode, 0)
        r = self.patch("--revert")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.read_tree(), MINI_QML, "block 模式回滚后应与原文逐字节一致")

    def test_partial_marker_refused(self):
        self.assertEqual(self.patch().returncode, 0)
        path = self.tree / "Mini.qml"
        path.write_text(self.read_tree().replace("        // END clavis-mini\n", "", 1))
        r = self.patch()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("marker count mismatch", r.stderr)

    def test_edit_order_contract(self):
        """同一文件内的 edit 必须按文件位置升序登记（manifest 倒序 → 响亮失败）。"""
        self.write_manifest(list(reversed(copy.deepcopy(MINI_EDITS))))
        r = self.patch()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("升序", r.stderr)
        self.assertEqual(self.read_tree(), MINI_QML, "顺序契约失败时不应写入任何字节")

    def test_explain_drift_json_block_mode(self):
        self.write_tree(MINI_QML.replace("    component DayButton: RippleButton {\n", ""))
        r = self.patch("--explain-drift", "--json")
        self.assertEqual(r.returncode, 3, r.stderr)
        report = json.loads(r.stdout)
        blocks = [item for item in report["drift"] if item["edit"] == "edit-1"]
        self.assertEqual(len(blocks), 1, report)
        self.assertEqual(blocks[0]["mode"], "block")
        self.assertEqual(blocks[0]["matched"], 0)
        self.assertEqual(blocks[0]["file"], "Mini.qml")
        self.assertIn("unique_line", blocks[0].get("detail", ""))

    def test_explain_drift_json_block_sanity_failure(self):
        """unique_line 仍命中 1 次、但 sanity 失配 → 报告要给出 mode/诊断而不是退出。"""
        self.write_tree(MINI_QML.replace("id: dayButton", "id: dayCell"))
        r = self.patch("--explain-drift", "--json")
        self.assertEqual(r.returncode, 3, r.stderr)
        report = json.loads(r.stdout)
        item = report["drift"][0]
        self.assertEqual(item["mode"], "block")
        self.assertEqual(item["matched"], 1)
        self.assertEqual(item["edit"], "edit-1")
        self.assertIn("detail", item)


if __name__ == "__main__":
    unittest.main()
