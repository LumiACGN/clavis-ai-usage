#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
"""manifest 自检：schema、锚点在 fixtu 上游树中的唯一性、哈希一致性、payload 存在性。

这个测试保证「patches/manifest.json 的声明」与「tests/fixtures 里的基线」永远一致——
锚点漂移修复（CONTRIBUTING）改错一处，这里会立刻红。

另含 tests/fixtures/dummy-kit（多 kit 共存彩排用的假组件）的自检：它的锚点同样必须
在基线里恰好命中一次，否则 tests/test_coexist.sh 会以难以定位的方式失败。
"""
import hashlib
import json
import re
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MANIFEST_PATH = REPO / "patches" / "manifest.json"
MANIFEST = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
FIXTURE = REPO / "tests" / "fixtures" / f"upstream-{MANIFEST['upstream']['version']}"

DUMMY_PATH = REPO / "tests" / "fixtures" / "dummy-kit" / "manifest.json"


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class ManifestTests(unittest.TestCase):
    def test_schema_and_shape(self):
        self.assertEqual(MANIFEST["schema"], 1)
        for key in ("tool_version", "upstream", "marker", "files", "payload"):
            self.assertIn(key, MANIFEST)
        for tpl in (MANIFEST["marker"]["begin"], MANIFEST["marker"]["end"]):
            self.assertIn("{group}", tpl)
        self.assertTrue(re.fullmatch(r"\d+\.\d+\.\d+", MANIFEST["tool_version"]))

    def test_kit_section_shape(self):
        """kit 段：引擎靠它注册组件（缺了引擎会直接 die）。"""
        kit = MANIFEST["kit"]
        self.assertIsInstance(kit, dict, "manifest 必须声明 kit 段")
        self.assertIsInstance(kit.get("id"), str)
        self.assertTrue(kit["id"].strip(), "kit.id 不能为空")
        self.assertIsInstance(kit.get("order"), int)
        self.assertNotIsInstance(kit.get("order"), bool, "kit.order 必须是整数")
        self.assertIsInstance(kit.get("post_install_notes"), list)

    def test_gates_section_shape(self):
        """gates 段：overrides 是按路径覆盖门禁工具的映射，smoke 可为 null。"""
        gates = MANIFEST["gates"]
        self.assertIsInstance(gates, dict, "manifest 必须声明 gates 段")
        self.assertIsInstance(gates.get("overrides"), dict)
        self.assertTrue(all(isinstance(k, str) and isinstance(v, str)
                            for k, v in gates["overrides"].items()))
        self.assertIn("smoke", gates)

    def test_no_block_edits_in_this_repo(self):
        """本仓（AI 组件）的 manifest 全部是 exact 锚点。

        block 定位模式的用例在 tests/test_patcher.py 里用自造的迷你 manifest 覆盖，
        不依赖本仓 manifest；这里显式断言「本仓没有 block edit」，防止误改。
        """
        for entry in MANIFEST["files"]:
            for edit in entry["edits"]:
                self.assertEqual(edit.get("mode", "exact"), "exact",
                                 f"{entry['path']} / {edit['id']}: 本仓不应出现 block edit")

    def test_fixture_tree_exists(self):
        self.assertTrue(FIXTURE.is_dir(), f"缺少基线目录：{FIXTURE}")
        for entry in MANIFEST["files"]:
            self.assertTrue((FIXTURE / entry["path"]).is_file(),
                            f"基线缺少锚点文件：{entry['path']}")

    def test_anchors_unique_and_hashed(self):
        for entry in MANIFEST["files"]:
            text = (FIXTURE / entry["path"]).read_text(encoding="utf-8")
            for edit in entry["edits"]:
                self.assertEqual(text.count(edit["anchor"]), 1,
                                 f"{entry['path']} / {edit['id']}: 锚点在基线中不唯一")
                self.assertEqual(sha256(edit["anchor"]), edit["anchor_sha256"],
                                 f"{entry['path']} / {edit['id']}: anchor_sha256 不一致")

    def test_upstream_file_hashes(self):
        for entry in MANIFEST["files"]:
            text = (FIXTURE / entry["path"]).read_text(encoding="utf-8")
            self.assertEqual(sha256(text), entry["upstream_sha256"],
                             f"{entry['path']}: upstream_sha256 与基线不一致")

    def test_replace_contains_markers(self):
        for entry in MANIFEST["files"]:
            begin = MANIFEST["marker"]["begin"].replace("{group}", entry["group"])
            end = MANIFEST["marker"]["end"].replace("{group}", entry["group"])
            for edit in entry["edits"]:
                self.assertIn(begin, edit["replace"],
                              f"{entry['path']} / {edit['id']}: 替换文本缺少 BEGIN 标记")
                self.assertIn(end, edit["replace"],
                              f"{entry['path']} / {edit['id']}: 替换文本缺少 END 标记")

    def test_payload_sources_exist(self):
        for item in MANIFEST["payload"]:
            self.assertTrue((REPO / "qml" / item["src"]).is_file(),
                            f"payload 源文件缺失：qml/{item['src']}")

    def test_group_single_and_marker_group_placeholder(self):
        """本组件的所有 entry 共用同一个 group（引擎按 group 做标记归属与回滚）。"""
        groups = {entry["group"] for entry in MANIFEST["files"]}
        self.assertEqual(groups, {"ai-view"})
        for entry in MANIFEST["files"]:
            self.assertNotIn("{group}", entry["group"])


class DummyKitFixtureTests(unittest.TestCase):
    """tests/fixtures/dummy-kit：多 kit 彩排夹具的 manifest 自检。"""

    def setUp(self):
        self.manifest = json.loads(DUMMY_PATH.read_text(encoding="utf-8"))
        self.fixture = FIXTURE

    def test_shape(self):
        self.assertEqual(self.manifest["schema"], 1)
        kit = self.manifest["kit"]
        self.assertEqual(kit["id"], "clavis-dummy-kit")
        self.assertIsInstance(kit["order"], int)
        self.assertIsNone(kit["bin_name"], "夹具刻意不带后端脚本（覆盖无 bin 分支）")
        self.assertEqual(self.manifest["marker"], MANIFEST["marker"],
                         "夹具的 marker 模板应与本仓一致")
        self.assertEqual(self.manifest["upstream"]["version"],
                         MANIFEST["upstream"]["version"])

    def test_anchor_hits_fixture_exactly_once(self):
        for entry in self.manifest["files"]:
            text = (self.fixture / entry["path"]).read_text(encoding="utf-8")
            for edit in entry["edits"]:
                self.assertEqual(text.count(edit["anchor"]), 1,
                                 f"{entry['path']} / {edit['id']}: 锚点在基线中不唯一")
                self.assertEqual(sha256(edit["anchor"]), edit["anchor_sha256"])

    def test_shared_file_with_ai_kit(self):
        """夹具刻意与 AI 组件打同一个文件（共享文件是最难场景）。"""
        self.assertIn(self.manifest["files"][0]["path"],
                      [entry["path"] for entry in MANIFEST["files"]])

    def test_replace_markers_and_payload(self):
        for entry in self.manifest["files"]:
            begin = self.manifest["marker"]["begin"].replace("{group}", entry["group"])
            end = self.manifest["marker"]["end"].replace("{group}", entry["group"])
            for edit in entry["edits"]:
                self.assertEqual(edit["replace"].count(begin), 1)
                self.assertEqual(edit["replace"].count(end), 1)
        for item in self.manifest["payload"]:
            self.assertTrue((DUMMY_PATH.parent / "qml" / item["src"]).is_file(),
                            f"夹具 payload 缺失：{item['src']}")


if __name__ == "__main__":
    unittest.main()
