#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 LumiACGN
# SPDX-License-Identifier: GPL-3.0-or-later
"""clavis-ai-usage overlay 安装引擎。

原理：Clavis（Quickshell 外壳）没有插件系统，唯一的官方用户扩展机制是
Quickshell 的 XDG 覆盖——`~/.config/quickshell/clavis/` 存在时整体优先于
`/etc/xdg/quickshell/clavis/`。本引擎：

  install  把系统 Clavis 树镜像到 overlay 目录，叠加锚点补丁与新增文件
  sync     Clavis 升级后重新对齐（失败时恢复旧 overlay——绝不把你的桌面炸掉）
  verify   检查补丁在位 / overlay 是否陈旧 / 文件是否被手改
  uninstall 移除 overlay，回到系统原生 Clavis（默认保留用户数据）

状态记录在 `$XDG_STATE_HOME/clavis-ai-usage/state.json`，备份在同目录 backups/。
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PATCHER = REPO_ROOT / "scripts" / "patch_clavis_ai_card.py"
MANIFEST = REPO_ROOT / "patches" / "manifest.json"
PAYLOAD = REPO_ROOT / "qml"
BIN_NAME = "clavis-ai-usage"
SERVICE = "clavis-shell.service"
QMLFORMAT_CANDIDATES = ("qmlformat", "/usr/lib/qt6/bin/qmlformat")
NODE_JS_SNIPPET = (
    'const fs=require("fs"); const src=fs.readFileSync(process.argv[1],"utf8")'
    '.replace(/^\\.pragma library\\s*$/m,"").replace(/^Qt\\.include\\(.*\\);?\\s*$/gm,"");'
    "new Function(src);"
)
KEEP_OVERLAY_BACKUPS = 3


def log(msg):
    print(f"== {msg}")


def warn(msg):
    print(f"WARN: {msg}", file=sys.stderr)


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_manifest() -> dict:
    try:
        return json.loads(MANIFEST.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        die(f"无法读取 manifest {MANIFEST}: {exc}")


def xdg_paths():
    home = Path(os.environ.get("HOME") or Path.home())
    config_home = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
    state_home = Path(os.environ.get("XDG_STATE_HOME") or home / ".local" / "state")
    cache_home = Path(os.environ.get("XDG_CACHE_HOME") or home / ".cache")
    return {
        "home": home,
        "overlay_default": config_home / "quickshell" / "clavis",
        "config_dir": config_home / "clavis-ai-usage",
        "legacy_config": config_home / "clavis" / "ai-usage.json",
        "state_dir": state_home / "clavis-ai-usage",
        "cache_dir": cache_home / "clavis-ai-usage",
        "bin_dir": home / ".local" / "bin",
    }


def load_state(state_dir: Path):
    path = state_dir / "state.json"
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        die(f"state.json 损坏（{path}）：{exc}")


def save_state(state_dir: Path, state: dict, dry_run: bool):
    if dry_run:
        print(f"[dry-run] 将写入 {state_dir / 'state.json'}")
        return
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "state.json").write_text(
        json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def detect_source_tree(explicit: str | None, manifest: dict) -> Path:
    candidate = Path(explicit or manifest["upstream"]["tree_hint"])
    if not (candidate / "shell.qml").is_file():
        die(f"Clavis 源码树不存在或缺少 shell.qml: {candidate}（用 --tree 指定）")
    return candidate


def detect_version(source_tree: Path):
    try:
        out = subprocess.run(["pacman", "-Q", "clavis-shell"], capture_output=True,
                             text=True, timeout=10, check=False)
        if out.returncode == 0 and out.stdout.strip():
            ver = out.stdout.split()[1]
            return ver.rsplit("-", 1)[0], "pacman"
    except (OSError, subprocess.TimeoutExpired, IndexError):
        pass
    release = source_tree / "RELEASE.json"
    if release.is_file():
        try:
            data = json.loads(release.read_text(encoding="utf-8"))
            ver = data.get("version") or data.get("release")
            if ver:
                return str(ver), "RELEASE.json"
        except json.JSONDecodeError:
            pass
    return "unknown", "unknown"


def have(cmd: str) -> bool:
    return shutil.which(cmd) is not None


def service_active() -> bool:
    if not have("systemctl"):
        return False
    out = subprocess.run(["systemctl", "--user", "is-active", SERVICE],
                         capture_output=True, text=True, check=False)
    return out.stdout.strip() == "active"


def stop_service(dry_run: bool, skip: bool) -> bool:
    """返回 was_active（供恢复用）。"""
    if skip:
        log("--skip-service：跳过停服务")
        return False
    if not have("systemctl"):
        warn("未找到 systemctl，跳过服务控制（请自行重启 clavis-shell）")
        return False
    was = service_active()
    if not was:
        log("clavis-shell 当前未运行，无需停")
        return False
    if dry_run:
        print(f"[dry-run] 将停止 {SERVICE}")
        return True
    log(f"停止 {SERVICE}（避免热重载读到半成品树）")
    subprocess.run(["systemctl", "--user", "stop", SERVICE], check=False)
    return True


def start_service(was_active: bool, dry_run: bool, skip: bool):
    if skip or not have("systemctl"):
        return
    if dry_run:
        print(f"[dry-run] 将启动 {SERVICE}")
        return
    if not was_active and service_active():
        return
    log(f"启动 {SERVICE}")
    subprocess.run(["systemctl", "--user", "reset-failed", SERVICE], check=False)
    subprocess.run(["systemctl", "--user", "start", SERVICE], check=False)
    time.sleep(2)
    if service_active():
        log("clavis-shell 已运行")
    else:
        warn(f"{SERVICE} 未能进入 active 状态——请查看 journalctl --user -u {SERVICE}")


def mirror_tree(src: Path, dst: Path, dry_run: bool):
    excludes = ("__pycache__", ".git", "*.tmp")
    if have("rsync"):
        cmd = ["rsync", "-a", "--delete"]
        for e in excludes:
            cmd += ["--exclude", e]
        if dry_run:
            cmd.append("-n")
        cmd += [str(src) + "/", str(dst) + "/"]
        log(f"镜像 Clavis 树：{src} → {dst}" + ("（dry-run）" if dry_run else ""))
        if not dry_run:
            dst.mkdir(parents=True, exist_ok=True)
        out = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if out.returncode != 0:
            die(f"rsync 失败：{out.stderr.strip()}")
        if dry_run:
            changed = [l for l in out.stdout.splitlines() if l and not l.startswith(("sending", "sent"))]
            print(f"[dry-run] rsync 将同步 {len(changed)} 项")
    else:
        warn("未安装 rsync，改用整体复制（较慢）")
        if dry_run:
            print(f"[dry-run] 将重建 {dst}")
            return
        if dst.exists():
            shutil.rmtree(dst)
        shutil.copytree(src, dst, symlinks=True,
                        ignore=shutil.ignore_patterns(*excludes))


def tarball(src: Path, out: Path, arcname: str, dry_run: bool) -> Path | None:
    if dry_run:
        print(f"[dry-run] 将备份 {src} → {out}")
        return None
    out.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(out, "w:gz") as tar:
        tar.add(src, arcname=arcname)
    return out


def backup_etc_anchors(source_tree: Path, state_dir: Path, manifest: dict, dry_run: bool):
    ts = time.strftime("%Y%m%d-%H%M%S")
    out = state_dir / "backups" / f"etc-anchors-{ts}.tar.gz"
    if dry_run:
        print(f"[dry-run] 将备份源码树的 4 个锚点文件 → {out}")
        return str(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(out, "w:gz") as tar:
        for entry in manifest["files"]:
            path = source_tree / entry["path"]
            if path.is_file():
                tar.add(path, arcname=f"{source_tree.name}/{entry['path']}")
    return str(out)


def backup_overlay(overlay: Path, state_dir: Path, tag: str, dry_run: bool) -> Path | None:
    ts = time.strftime("%Y%m%d-%H%M%S")
    out = state_dir / "backups" / f"overlay-{tag}-{ts}.tar.gz"
    result = tarball(overlay, out, overlay.name, dry_run)
    if not dry_run:
        backups = sorted((state_dir / "backups").glob("overlay-*.tar.gz"))
        for old in backups[:-KEEP_OVERLAY_BACKUPS]:
            old.unlink(missing_ok=True)
    return result


def restore_overlay(backup: Path, overlay: Path, dry_run: bool):
    log(f"恢复旧 overlay：{backup} → {overlay}")
    if dry_run:
        return
    if overlay.exists():
        shutil.rmtree(overlay)
    overlay.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(backup, "r:gz") as tar:
        tar.extractall(path=overlay.parent, filter="data")


def run_patcher(target: Path, extra=(), dry_run=False, stream=True) -> int:
    cmd = [sys.executable, str(PATCHER), "--manifest", str(MANIFEST),
           "--payload", str(PAYLOAD), "--target", str(target), *extra]
    if dry_run:
        cmd.append("--dry-run")
    out = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if stream:
        sys.stdout.write(out.stdout)
        sys.stderr.write(out.stderr)
    return out.returncode


def run_gate(overlay: Path, manifest: dict) -> bool:
    ok = True
    js_files = [e["path"] for e in manifest["files"] if e["path"].endswith(".js")]
    qml_files = ([e["path"] for e in manifest["files"] if e["path"].endswith(".qml")]
                 + [p["dest"] for p in manifest["payload"] if p["dest"].endswith(".qml")])

    if js_files:
        if have("node"):
            for rel in js_files:
                out = subprocess.run(["node", "-e", NODE_JS_SNIPPET, str(overlay / rel)],
                                     capture_output=True, text=True, check=False)
                if out.returncode != 0:
                    print(f"  门禁 FAIL (node) {rel}\n{out.stderr.strip()}", file=sys.stderr)
                    ok = False
        else:
            warn("未找到 node，跳过 JS 语法门禁")

    qmlformat = next((c for c in QMLFORMAT_CANDIDATES
                      if (have(c) if "/" not in c else Path(c).is_file())), None)
    if qmlformat:
        for rel in qml_files:
            out = subprocess.run([qmlformat, str(overlay / rel)],
                                 capture_output=True, text=True, check=False)
            if out.returncode != 0:
                print(f"  门禁 FAIL (qmlformat) {rel}\n{out.stderr.strip()}", file=sys.stderr)
                ok = False
    else:
        warn("未找到 qmlformat（qt6-declarative），跳过 QML 语法门禁")
    if ok:
        log("语法门禁通过")
    return ok


def install_bin(paths: dict, state: dict | None, dry_run: bool, skip: bool) -> tuple[bool, str | None]:
    if skip:
        log("--skip-bin：跳过安装后端脚本")
        return False, None
    src = REPO_ROOT / "bin" / BIN_NAME
    dest = paths["bin_dir"] / BIN_NAME
    content = src.read_bytes()
    digest = hashlib.sha256(content).hexdigest()
    if dest.is_file() and dest.read_bytes() == content:
        log(f"后端脚本已是最新：{dest}")
        return True, digest
    if dest.is_file() and dry_run:
        print(f"[dry-run] 将更新后端脚本 {dest}")
        return True, digest
    if dest.is_file():
        bak = dest.with_name(dest.name + f".bak-{time.strftime('%Y%m%d-%H%M%S')}")
        log(f"已存在的 {dest} 与仓库版本不同，先备份到 {bak.name}")
        shutil.copy2(dest, bak)
    if not dry_run:
        paths["bin_dir"].mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content)
        dest.chmod(0o755)
    else:
        print(f"[dry-run] 将安装 {dest}")
    log(f"后端脚本：{dest}")
    return True, digest


def migrate_config(paths: dict, dry_run: bool, skip: bool):
    if skip:
        return
    old = paths["legacy_config"]
    new = paths["config_dir"] / "config.json"
    if new.is_file():
        log(f"配置文件已存在：{new}")
        return
    if old.is_file():
        if dry_run:
            print(f"[dry-run] 将迁移 {old} → {new}（保留旧文件）")
            return
        paths["config_dir"].mkdir(parents=True, exist_ok=True)
        shutil.copy2(old, new)
        new.chmod(0o600)
        log(f"已迁移配置 {old} → {new}（旧文件保留；如需重新发行请检查内容）")


def local_modification_check(overlay: Path, state: dict, manifest: dict) -> list[str]:
    modified = []
    for rel, digest in {**state.get("patched_digest", {}), **state.get("payload_digest", {})}.items():
        path = overlay / rel
        if not path.is_file() or sha256_file(path) != digest:
            modified.append(rel)
    return modified


def collect_digests(overlay: Path, manifest: dict) -> tuple[dict, dict]:
    patched = {e["path"]: sha256_file(overlay / e["path"]) for e in manifest["files"]
               if (overlay / e["path"]).is_file()}
    payload = {p["dest"]: sha256_file(overlay / p["dest"]) for p in manifest["payload"]
               if (overlay / p["dest"]).is_file()}
    return patched, payload


def make_state(overlay: Path, source_tree: Path, version: str, version_src: str,
               etc_backup: str | None, manifest: dict, patched: dict, payload: dict,
               bin_digest: str | None) -> dict:
    return {
        "schema": 1,
        "tool_version": manifest["tool_version"],
        "installed_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "mode": "overlay",
        "overlay_dir": str(overlay),
        "source_tree": str(source_tree),
        "upstream_version": version,
        "upstream_version_source": version_src,
        "etc_backup": etc_backup,
        "patched_digest": patched,
        "payload_digest": payload,
        "binary_digest": bin_digest,
    }


# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------

def cmd_install(args, paths, manifest):
    overlay = Path(args.overlay_dir or paths["overlay_default"])
    source = detect_source_tree(args.tree, manifest)
    version, version_src = detect_version(source)
    state = load_state(paths["state_dir"])

    if state:
        log("检测到已安装（state.json 存在）→ 转为 --sync 语义重新对齐")
        return cmd_sync(args, paths, manifest)

    if overlay.exists():
        if not args.adopt:
            die(f"overlay 目录已存在且不是本工具创建的：{overlay}\n"
                "  - 若那是你自己的配置/开发目录：请先移走，或使用 --overlay-dir <其它路径>\n"
                "  - 若确认可以被本工具接管（会先整体备份）：加 --adopt 重试")
        backup_overlay(overlay, paths["state_dir"], "adopted", args.dry_run)

    log(f"源树：{source}（Clavis {version}，via {version_src}）")
    log(f"overlay：{overlay}")

    if args.dry_run:
        print(f"[dry-run] 将：停 clavis-shell → 备份锚点 → 镜像整树 → 打补丁 → 语法门禁"
              f" → 安装后端脚本 → 迁移配置 → 写状态")
        print("[dry-run] 以下为补丁器在源树上的预览：")
        run_patcher(source, dry_run=True)
        return 0

    was_active = stop_service(args.dry_run, args.skip_service)
    try:
        etc_backup = backup_etc_anchors(source, paths["state_dir"], manifest, args.dry_run)
        mirror_tree(source, overlay, args.dry_run)
        if run_patcher(overlay) != 0:
            die("补丁失败——overlay 已保留原始镜像，可自行检查；未改动系统任何文件")
        if not run_gate(overlay, manifest):
            die("语法门禁失败——请提交 issue 并附上上方门禁输出（overlay 未启用）")
        _, bin_digest = install_bin(paths, state, args.dry_run, args.skip_bin)
        migrate_config(paths, args.dry_run, getattr(args, "no_config_migrate", False))
        patched, payload = collect_digests(overlay, manifest)
        save_state(paths["state_dir"], make_state(overlay, source, version, version_src,
                                                  etc_backup, manifest, patched, payload,
                                                  bin_digest), args.dry_run)
    finally:
        start_service(was_active, args.dry_run, args.skip_service)

    log("安装完成 🎉")
    print("""
下一步：
  1. 首次使用请在配置里填入 API key（没有 key 也能跑，只是看不到对应数据）：
       ~/.config/clavis-ai-usage/config.json   （模板见 docs/CONFIGURATION.md）
  2. 侧边栏第 4 页「AI 用量」/ 顶栏 AI 按钮即可查看
  3. Clavis 升级后运行：./install.sh --sync
""")
    return 0


def cmd_sync(args, paths, manifest):
    overlay = Path(args.overlay_dir or paths["overlay_default"])
    source = detect_source_tree(args.tree, manifest)
    version, version_src = detect_version(source)
    state = load_state(paths["state_dir"])
    if not state:
        die("尚未安装（无 state.json）——请先运行 install")

    overlay_state = Path(state["overlay_dir"])
    if overlay_state != overlay:
        warn(f"state 记录的 overlay（{overlay_state}）与当前参数（{overlay}）不同，以 state 为准")
        overlay = overlay_state

    if overlay.exists() and not args.dry_run:
        modified = local_modification_check(overlay, state, manifest)
        if modified and not args.force:
            die("overlay 中以下文件被改动过（不是本工具写入的版本）：\n  - "
                + "\n  - ".join(modified)
                + "\n  --force 才会覆盖（覆盖前仍会整体备份）")

    log(f"源树：{source}（Clavis {version}，via {version_src}）")
    if state.get("upstream_version") not in (None, version):
        log(f"上游版本变化：{state.get('upstream_version')} → {version}")

    if args.dry_run:
        print("[dry-run] 将：停 clavis-shell → 备份旧 overlay → 重新镜像源树 → 重打补丁"
              " → 门禁 → 更新后端脚本 → 更新状态")
        print("[dry-run] 补丁器对当前源树的预览：")
        run_patcher(source, dry_run=True, extra=("--expect-upstream", version))
        return 0

    was_active = stop_service(False, args.skip_service)
    backup = None
    if overlay.exists():
        backup = backup_overlay(overlay, paths["state_dir"], "pre-sync", False)

    try:
        mirror_tree(source, overlay, False)
        rc = run_patcher(overlay, extra=("--expect-upstream", version))
        gate_ok = rc == 0 and run_gate(overlay, manifest)
        if not gate_ok:
            if backup:
                restore_overlay(backup, overlay, False)
                warn("sync 失败：已恢复 sync 前的 overlay（你的桌面继续可用）")
                warn("补丁失败通常意味着 Clavis 改动了上游文本——请看上方错误提示，"
                     "按 patches/README.md 更新锚点后再试")
            else:
                warn("sync 失败且没有旧 overlay 可恢复；overlay 保持在镜像状态（未启用补丁）")
            start_service(was_active, False, args.skip_service)
            return 1
        _, bin_digest = install_bin(paths, state, False, args.skip_bin)
        patched, payload = collect_digests(overlay, manifest)
        save_state(paths["state_dir"], make_state(overlay, source, version, version_src,
                                                  state.get("etc_backup"), manifest,
                                                  patched, payload, bin_digest), False)
    finally:
        start_service(was_active, False, args.skip_service)

    log("sync 完成")
    return 0


def cmd_verify(args, paths, manifest):
    overlay = Path(args.overlay_dir or paths["overlay_default"])
    state = load_state(paths["state_dir"])
    problems = []
    if not state:
        print("未安装（无 state.json）——运行 ./install.sh 安装")
        return 1
    overlay = Path(state["overlay_dir"])
    print(f"overlay      {overlay}  {'存在' if overlay.exists() else '缺失!'}")
    print(f"state        {paths['state_dir'] / 'state.json'}")
    if not (overlay / "shell.qml").is_file():
        problems.append("overlay 缺少 shell.qml")

    rc = run_patcher(overlay, extra=("--verify",), stream=False)
    print(f"补丁         {'在位' if rc == 0 else '缺失/异常'}")
    if rc != 0:
        problems.append("补丁不完整（运行 ./install.sh --sync 修复）")

    bin_dest = paths["bin_dir"] / BIN_NAME
    if bin_dest.is_file():
        digest = sha256_file(bin_dest)
        if state.get("binary_digest") and digest != state["binary_digest"]:
            warn(f"{bin_dest} 与安装时不一致（你或其它工具改过它？）")
        print(f"后端脚本     {bin_dest}（在位）")
    else:
        problems.append(f"后端脚本缺失：{bin_dest}")

    try:
        source = Path(state["source_tree"])
        version, _src = detect_version(source)
        if version != "unknown" and version != state.get("upstream_version"):
            warn(f"Clavis 已升级（{state.get('upstream_version')} → {version}）："
                 f"overlay 仍是旧代码，请运行 ./install.sh --sync 对齐")
        print(f"上游版本     {version}（安装时 {state.get('upstream_version')}）")
    except OSError:
        pass

    modified = local_modification_check(overlay, state, manifest)
    if modified:
        warn("以下 overlay 文件被改动过（sync 时需 --force）：\n  - " + "\n  - ".join(modified))

    if problems:
        for p in problems:
            print(f"问题：{p}")
        return 1
    print("verify ok")
    return 0


def cmd_uninstall(args, paths, manifest):
    state = load_state(paths["state_dir"])
    if not state:
        die("未安装（无 state.json）；若残留 overlay 请手动处理")

    overlay = Path(state["overlay_dir"])
    dry = args.dry_run

    if args.restore_etc:
        backups = sorted((paths["state_dir"] / "backups").glob("etc-anchors-*.tar.gz"))
        if not backups:
            die("没有 etc 备份可恢复")
        target_root = Path(state["source_tree"]).parent
        log(f"从 {backups[-1].name} 恢复源码树锚点文件到 {target_root}（可能需要写权限）")
        if not dry:
            with tarfile.open(backups[-1], "r:gz") as tar:
                tar.extractall(path=target_root, filter="data")
        note = "（dry-run）" if dry else ""
        print(f"已恢复锚点文件{note}")

    if overlay.exists():
        backup_overlay(overlay, paths["state_dir"], "uninstall", dry)
        log(f"移除 overlay：{overlay}" + ("（dry-run）" if dry else ""))
        if not dry:
            shutil.rmtree(overlay)
            parent = overlay.parent
            if parent.is_dir() and not any(parent.iterdir()):
                parent.rmdir()

    was_active = stop_service(dry, args.skip_service) if not dry else False
    bin_dest = paths["bin_dir"] / BIN_NAME
    if bin_dest.is_file():
        if state.get("binary_digest") and sha256_file(bin_dest) != state["binary_digest"]:
            warn(f"{bin_dest} 已被修改，保留不删")
        else:
            log(f"移除后端脚本：{bin_dest}" + ("（dry-run）" if dry else ""))
            if not dry:
                bin_dest.unlink()

    if args.purge:
        targets = [paths["config_dir"], paths["cache_dir"]]
        print("--purge 将删除（配置里有 API key，请确认）：")
        for t in targets:
            print(f"  - {t}")
        print(f"  - {paths['state_dir']}（含所有备份）")
        if not args.yes:
            die("如需继续请加 --yes")
        if not dry:
            for t in targets + [paths["state_dir"]]:
                shutil.rmtree(t, ignore_errors=True)
    else:
        log(f"已保留：配置 {paths['config_dir']} / 缓存 {paths['cache_dir']} / 状态与备份 {paths['state_dir']}")

    if not dry:
        start_service(True, dry, args.skip_service)
    log("卸载完成（Clavis 已回到系统原生版本）")
    return 0


def main():
    parser = argparse.ArgumentParser(
        prog="clavis-ai-usage-overlay",
        description="clavis-ai-usage 的 overlay 安装引擎（详见 README）")
    sub = parser.add_subparsers(dest="mode", required=True)

    def common(p):
        p.add_argument("--dry-run", action="store_true", help="只演示，不写任何文件、不停 shell")
        p.add_argument("--tree", default=None, help="Clavis 源码树（默认取 manifest 记录）")
        p.add_argument("--overlay-dir", default=None, help="overlay 目录（默认 ~/.config/quickshell/clavis）")
        p.add_argument("--skip-service", action="store_true", help="不控制 clavis-shell 服务")
        p.add_argument("--skip-bin", action="store_true", help="不安装后端脚本")

    p_install = sub.add_parser("install", help="首次安装")
    common(p_install)
    p_install.add_argument("--adopt", action="store_true", help="接管已存在的 overlay 目录（先整体备份）")
    p_install.add_argument("--no-config-migrate", action="store_true", help="不从旧路径迁移配置")

    p_sync = sub.add_parser("sync", help="Clavis 升级后重新对齐")
    common(p_sync)
    p_sync.add_argument("--force", action="store_true", help="覆盖被手改过的 overlay（先整体备份）")

    p_verify = sub.add_parser("verify", help="检查安装状态")
    common(p_verify)

    p_uninstall = sub.add_parser("uninstall", help="卸载并回到系统原生 Clavis")
    common(p_uninstall)
    p_uninstall.add_argument("--restore-etc", action="store_true",
                             help="同时从备份恢复源码树的 4 个锚点文件（若当初也改过它）")
    p_uninstall.add_argument("--purge", action="store_true", help="同时删除配置/缓存/状态与备份")
    p_uninstall.add_argument("--yes", action="store_true", help="与 --purge 搭配确认")

    args = parser.parse_args()
    manifest = load_manifest()
    paths = xdg_paths()

    modes = {"install": cmd_install, "sync": cmd_sync,
             "verify": cmd_verify, "uninstall": cmd_uninstall}
    sys.exit(modes[args.mode](args, paths, manifest))


if __name__ == "__main__":
    main()
