#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
"""manifest 自检：schema、锚点在 fixtu 上游树中的唯一性、哈希一致性、payload 存在性。

这个测试保证「patches/manifest.json 的声明」与「tests/fixtures 里的基线」永远一致——
锚点漂移修复（CONTRIBUTING）改错一处，这里会立刻红。
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


if __name__ == "__main__":
    unittest.main()
