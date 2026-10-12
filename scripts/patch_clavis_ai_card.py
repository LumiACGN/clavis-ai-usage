#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
"""把「AI 用量」看板接入 Clavis shell 树（manifest 驱动的幂等锚点补丁器）。

设计说明：
  * 所有锚点/替换文本/载荷映射都在 patches/manifest.json —— 本脚本只是通用引擎。
    Clavis 升级导致锚点漂移时，只需按 --explain-drift 的指引更新 manifest。
  * 每个文件仅在「无任何标记」时打补丁；已打过补丁的文件会校验并跳过（幂等，
    clavis-shell 每次升级后重跑即可）。
  * 锚点必须精确命中一次；任一锚点不命中立即整体失败（写入前先全量校验），
    绝不产生半打补丁的文件。

用法:
    patch_clavis_ai_card.py [--manifest patches/manifest.json] [--target TREE]
                            [--payload qml/] [--dry-run] [--verify]
                            [--revert [--remove-payload]]
                            [--explain-drift [--json]]
                            [--expect-upstream VERSION]
                            [--group SLUG]... [--list-groups]
"""
import argparse
import difflib
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = REPO_ROOT / "patches" / "manifest.json"
DEFAULT_PAYLOAD = REPO_ROOT / "qml"


def sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def fail(message: str):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def load_manifest(path: Path) -> dict:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot load manifest {path}: {exc}")
    if manifest.get("schema") != 1:
        fail(f"unsupported manifest schema: {manifest.get('schema')!r}")
    for key in ("upstream", "marker", "files", "payload"):
        if key not in manifest:
            fail(f"manifest missing required key: {key}")
    return manifest


def marker_pair(manifest: dict, group: str):
    return (manifest["marker"]["begin"].replace("{group}", group),
            manifest["marker"]["end"].replace("{group}", group))


def atomic_write(path: Path, text: str):
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def anchor_miss_error(path: Path, edit: dict, count: int, upstream_sha: str | None):
    head = edit["anchor"].splitlines()[0][:70]
    lines = [f"{path}: edit {edit['id']} anchor matched {count} times (expected 1): {head!r}"]
    lines.append(f"  anchor sha256:        {edit.get('anchor_sha256', '<unknown>')}")
    current = sha256(path.read_text(encoding="utf-8"))
    lines.append(f"  current file sha256:  {current}")
    if upstream_sha:
        note = "（与已知上游版本一致——这不该发生，请提交 issue）" if current == upstream_sha \
            else "（与已知上游版本不同——上游文本很可能已变化）"
        lines.append(f"  known upstream sha256: {upstream_sha} {note}")
    lines.append("  -> 运行: patch_clavis_ai_card.py --explain-drift --manifest <manifest> --target <tree>"
                 "  查看新版上游的实际文本，然后更新 manifest（见 patches/README.md）")
    return "\n".join(lines)


def patch_file(path: Path, entry: dict, begin: str, end: str,
               dry_run: bool, verify: bool, results: list):
    edits = entry["edits"]
    text = path.read_text(encoding="utf-8")
    begin_count = text.count(begin)
    end_count = text.count(end)

    if begin_count or end_count:
        if begin_count != len(edits) or end_count != len(edits):
            fail(f"{path}: marker count mismatch (BEGIN={begin_count}, END={end_count}, "
                 f"expected={len(edits)}) — refusing to guess a partially patched file")
        results.append({"path": str(path), "status": "already-patched"})
        return

    if verify:
        results.append({"path": str(path), "status": "missing"})
        return

    # 先全量校验（写任何字节之前）
    for edit in edits:
        count = text.count(edit["anchor"])
        if count != 1:
            fail(anchor_miss_error(path, edit, count, entry.get("upstream_sha256")))

    original = text
    for edit in edits:
        text = text.replace(edit["anchor"], edit["replace"])

    if dry_run:
        print(f"--- would patch: {path}")
        for line in difflib.unified_diff(original.splitlines(), text.splitlines(),
                                         fromfile=str(path), tofile=str(path) + " (patched)", lineterm=""):
            print(line)
        results.append({"path": str(path), "status": "would-patch"})
    else:
        atomic_write(path, text)
        results.append({"path": str(path), "status": "patched"})


def revert_file(path: Path, entry: dict, begin: str, end: str,
                dry_run: bool, results: list):
    edits = entry["edits"]
    text = path.read_text(encoding="utf-8")
    begin_count = text.count(begin)
    end_count = text.count(end)
    if begin_count == 0 and end_count == 0:
        results.append({"path": str(path), "status": "not-patched"})
        return
    if begin_count != len(edits) or end_count != len(edits):
        fail(f"{path}: marker count mismatch (BEGIN={begin_count}, END={end_count}, "
             f"expected={len(edits)}) — refusing to revert a partially patched file")

    for edit in edits:
        if text.count(edit["replace"]) != 1:
            fail(f"{path}: cannot revert edit {edit['id']}: replacement text not found exactly once "
                 "— file was modified after patching")

    original = text
    for edit in edits:
        text = text.replace(edit["replace"], edit["anchor"])

    if dry_run:
        print(f"--- would revert: {path}")
        for line in difflib.unified_diff(original.splitlines(), text.splitlines(),
                                         fromfile=str(path), tofile=str(path) + " (reverted)", lineterm=""):
            print(line)
        results.append({"path": str(path), "status": "would-revert"})
    else:
        atomic_write(path, text)
        results.append({"path": str(path), "status": "reverted"})


def install_payload_file(target_root: Path, dest_rel: str, payload_path: Path,
                         dry_run: bool, verify: bool, results: list,
                         remove: bool = False):
    dest = target_root / dest_rel
    if remove:
        if not dest.is_file():
            results.append({"path": str(dest), "status": "absent"})
            return
        if not payload_path.is_file():
            fail(f"payload file missing: {payload_path}")
        if dest.read_text(encoding="utf-8") != payload_path.read_text(encoding="utf-8"):
            results.append({"path": str(dest), "status": "kept (modified)"})
            return
        if dry_run:
            print(f"--- would remove: {dest}")
            results.append({"path": str(dest), "status": "would-remove"})
        else:
            dest.unlink()
            results.append({"path": str(dest), "status": "removed"})
        return

    if not payload_path.is_file():
        fail(f"payload file missing: {payload_path}")
    content = payload_path.read_text(encoding="utf-8")
    if dest.is_file():
        if dest.read_text(encoding="utf-8") == content:
            results.append({"path": str(dest), "status": "unchanged"})
            return
        if verify:
            results.append({"path": str(dest), "status": "differs"})
            return
        print(f"  ! overwriting existing file with payload content: {dest}")
    elif verify:
        results.append({"path": str(dest), "status": "missing"})
        return
    if dry_run:
        print(f"--- would install: {dest}")
        results.append({"path": str(dest), "status": "would-install"})
        return
    dest.parent.mkdir(parents=True, exist_ok=True)
    atomic_write(dest, content)
    results.append({"path": str(dest), "status": "installed"})


def best_match(anchor_lines, file_lines):
    """在 file_lines 中找与 anchor 开头最相似的窗口，返回 (ratio, start_index)。"""
    probe = anchor_lines[:3]
    m = len(probe)
    best = (0.0, -1)
    for i in range(0, max(1, len(file_lines) - m + 1)):
        ratio = difflib.SequenceMatcher(None, probe, file_lines[i:i + m]).ratio()
        if ratio > best[0]:
            best = (ratio, i)
    return best


def explain_drift(target: Path, manifest: dict, as_json: bool) -> int:
    drift = []
    for entry in manifest["files"]:
        path = target / entry["path"]
        if not path.is_file():
            fail(f"expected file missing: {path}")
        text = path.read_text(encoding="utf-8")
        file_lines = text.splitlines()
        group = entry["group"]
        begin, _end = marker_pair(manifest, group)
        if text.count(begin) == len(entry["edits"]):
            continue  # 已打过补丁，跳过
        for edit in entry["edits"]:
            count = text.count(edit["anchor"])
            if count == 1:
                continue
            anchor_lines = edit["anchor"].splitlines()
            ratio, start = best_match(anchor_lines, file_lines)
            lo = max(0, start - 3)
            hi = min(len(file_lines), start + len(anchor_lines) + 3)
            drift.append({
                "file": entry["path"],
                "edit": edit["id"],
                "matched": count,
                "anchor_sha256": edit.get("anchor_sha256"),
                "best_match_ratio": round(ratio, 3),
                "best_match_line": start + 1 if start >= 0 else None,
                "context": "\n".join(file_lines[lo:hi]),
            })

    if as_json:
        print(json.dumps({"schema": 1, "upstream_version": manifest["upstream"]["version"],
                          "drift": drift}, ensure_ascii=False, indent=2))
    else:
        if not drift:
            print("no drift: all anchors match")
        for item in drift:
            print(f"\n=== {item['file']}  edit {item['edit']}  (matched {item['matched']} times) ===")
            print(f"  anchor sha256: {item['anchor_sha256']}")
            print(f"  最相似的窗口在第 {item['best_match_line']} 行（相似度 {item['best_match_ratio']}），"
                  "新版上游的实际文本如下（±3 行）：")
            for line in item["context"].splitlines():
                print(f"    | {line}")
    return 0 if not drift else 3


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--manifest", default=str(DEFAULT_MANIFEST),
                        help="补丁清单（默认: %(default)s）")
    parser.add_argument("--target", default=None,
                        help="Clavis shell 源码树（默认取 manifest.upstream.tree_hint）")
    parser.add_argument("--payload", default=str(DEFAULT_PAYLOAD),
                        help="新增文件目录（默认: %(default)s）")
    parser.add_argument("--dry-run", action="store_true", help="只打印 diff，不写文件")
    parser.add_argument("--verify", action="store_true", help="只校验补丁是否在位")
    parser.add_argument("--revert", action="store_true", help="把补丁还原回上游原文")
    parser.add_argument("--remove-payload", action="store_true",
                        help="配合 --revert：同时删除与 payload 一致的已安装文件")
    parser.add_argument("--explain-drift", action="store_true",
                        help="诊断锚点漂移：打印新版上游在锚点附近的实际文本")
    parser.add_argument("--expect-upstream", default=None,
                        help="期望的 Clavis 版本（不符仅告警；锚点匹配才是判据）")
    parser.add_argument("--group", action="append", default=None, help="只处理某组（可重复）")
    parser.add_argument("--list-groups", action="store_true", help="列出补丁组")
    parser.add_argument("--json", action="store_true", help="输出机器可读 JSON")
    args = parser.parse_args()

    manifest = load_manifest(Path(args.manifest))
    payload_dir = Path(args.payload)
    target = Path(args.target or manifest["upstream"]["tree_hint"])
    groups = sorted({entry["group"] for entry in manifest["files"]})

    if args.list_groups:
        for slug in groups:
            files = [e["path"] for e in manifest["files"] if e["group"] == slug]
            print(f"{slug}: {', '.join(files)}")
        return

    if not target.is_dir():
        fail(f"target tree not found: {target}")

    if args.expect_upstream and args.expect_upstream != manifest["upstream"]["version"]:
        print(f"WARN: 期望的上游版本 {args.expect_upstream} 与 manifest 记录的 "
              f"{manifest['upstream']['version']} 不同（仅提示；以锚点匹配为准）", file=sys.stderr)

    if args.explain_drift:
        sys.exit(explain_drift(target, manifest, args.json))

    selected = set(args.group) if args.group else set(groups)
    results: list = []

    # 全树预校验：写任何字节之前，确保所有目标文件要么已打补丁、要么全部锚点可精确命中
    if not args.verify:
        for entry in manifest["files"]:
            if entry["group"] not in selected:
                continue
            path = target / entry["path"]
            text = path.read_text(encoding="utf-8")
            begin, _end = marker_pair(manifest, entry["group"])
            bc, ec = text.count(begin), text.count(_end)
            if args.revert:
                if bc == 0 and ec == 0:
                    continue
                if bc != len(entry["edits"]) or ec != len(entry["edits"]):
                    fail(f"{path}: marker count mismatch (BEGIN={bc}, END={ec}, "
                         f"expected={len(entry['edits'])}) — refusing to revert a partially patched file")
                for edit in entry["edits"]:
                    if text.count(edit["replace"]) != 1:
                        fail(f"{path}: cannot revert edit {edit['id']}: replacement text not found "
                             "exactly once — file was modified after patching")
            else:
                if bc or ec:
                    if bc != len(entry["edits"]) or ec != len(entry["edits"]):
                        fail(f"{path}: marker count mismatch (BEGIN={bc}, END={ec}, "
                             f"expected={len(entry['edits'])}) — refusing to guess a partially patched file")
                    continue
                for edit in entry["edits"]:
                    count = text.count(edit["anchor"])
                    if count != 1:
                        fail(anchor_miss_error(path, edit, count, entry.get("upstream_sha256")))

    for entry in manifest["files"]:
        if entry["group"] not in selected:
            continue
        path = target / entry["path"]
        if not path.is_file():
            fail(f"expected file missing: {path}")
        begin, end = marker_pair(manifest, entry["group"])
        if args.revert:
            revert_file(path, entry, begin, end, args.dry_run, results)
        else:
            patch_file(path, entry, begin, end, args.dry_run, args.verify, results)

    for item in manifest["payload"]:
        if args.revert and not args.remove_payload:
            continue
        install_payload_file(target, item["dest"], payload_dir / item["src"],
                             args.dry_run, args.verify, results, remove=args.revert)

    if args.json:
        ok = all(r["status"] in ("already-patched", "unchanged", "reverted", "removed",
                                 "not-patched", "absent", "kept (modified)") for r in results)
        print(json.dumps({"schema": 1, "target": str(target),
                          "upstream_version": manifest["upstream"]["version"],
                          "ok": ok, "results": results}, ensure_ascii=False, indent=2))
    else:
        for item in results:
            print(f"{item['status']:>14}  {item['path']}")

    if args.verify:
        good = ("already-patched", "unchanged")
        bad = [r["path"] for r in results if r["status"] not in good]
        if bad:
            fail("verify failed: " + ", ".join(bad))
        print("verify ok: patch present")
    if args.revert and not args.dry_run:
        leftover = [r["path"] for r in results
                    if r["status"] in ("patched", "installed", "differs", "missing")]
        if leftover:
            fail("revert incomplete: " + ", ".join(leftover))


if __name__ == "__main__":
    main()
