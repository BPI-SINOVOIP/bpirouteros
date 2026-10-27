#!/usr/bin/env python3
"""Bind a prepared OpenWrt tree and its board artifacts to one release lock."""

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path


# One row per build ID. The two R4-Pro SKUs are separate rows with separate
# profiles: bpi-r4-pro means the 8X exactly and is never renamed, and every
# R4-Pro artifact name therefore carries 8x or 4e. A name that says only
# "bpi-r4-pro" cannot be attributed to a SKU and must not reach a release set.
BOARD_BASES = {
    "bpi-r4": "openwrt-mediatek-filogic-bananapi_bpi-r4",
    "bpi-r4-lite": "openwrt-mediatek-filogic-bananapi_bpi-r4-lite",
    "bpi-r4-pro": "openwrt-mediatek-filogic-bananapi_bpi-r4-pro-8x",
    "bpi-r4-pro-4e": "openwrt-mediatek-filogic-bananapi_bpi-r4-pro-4e",
    "bpi-r3": "openwrt-mediatek-filogic-bananapi_bpi-r3",
    "bpi-r3-mini": "openwrt-mediatek-filogic-bananapi_bpi-r3-mini",
    "openwrt-one": "openwrt-mediatek-filogic-openwrt_one",
}
PRODUCT_BASES = set(BOARD_BASES.values())

# An R4-Pro deliverable must name its SKU. The family prefix alone is ambiguous
# between two boards whose DDR size, external PHYs and boot chain differ, and a
# mis-flashed sysupgrade is not recoverable from the file name after the fact.
R4PRO_FAMILY_PREFIX = "openwrt-mediatek-filogic-bananapi_bpi-r4-pro"
R4PRO_SKU_SUFFIXES = ("-8x", "-4e")


def require_sku_qualified(name, where):
    """Reject an R4-Pro artifact whose name does not identify its SKU."""
    rest = name[len(R4PRO_FAMILY_PREFIX):] if name.startswith(R4PRO_FAMILY_PREFIX) else None
    if rest is None:
        return
    if not rest.startswith(R4PRO_SKU_SUFFIXES):
        die(f"{where}: R4-Pro artifact does not name its SKU: {name}")

# These recovery inputs are emitted with SoC-wide names rather than the board
# profile prefix. They are nevertheless formal deliverables for the two NAND
# recovery kits and must participate in clean, sidecar, collection and manifest
# verification just like profile-prefixed images.
EXTRA_ARTIFACTS = {
    BOARD_BASES["bpi-r3-mini"]: {"mt7986-ram-ddr4-bl2.bin": "bootloader"},
    BOARD_BASES["openwrt-one"]: {"mt7981-ram-ddr4-bl2.bin": "bootloader"},
}


def die(message):
    raise SystemExit(message)


def sha_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_git(repo, *args, binary=False):
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return result.stdout if binary else result.stdout.decode("utf-8", "surrogateescape")


def add_value(digest, label, value):
    if isinstance(value, str):
        value = value.encode()
    digest.update(label.encode() + b"\0" + value + b"\0")


def add_path(digest, root, relative):
    path = root / relative
    label = relative.as_posix()
    if path.is_symlink():
        add_value(digest, "symlink:" + label, os.readlink(path))
    elif path.is_file():
        add_value(digest, "mode:" + label, oct(stat.S_IMODE(path.stat().st_mode)))
        add_value(digest, "file:" + label, path.read_bytes())


def repository_state(digest, label, repo):
    add_value(digest, label + ":head", run_git(repo, "rev-parse", "HEAD").strip())
    add_value(digest, label + ":diff", run_git(repo, "diff", "--binary", "HEAD", "--", binary=True))
    others = run_git(repo, "ls-files", "--others", "--exclude-standard", "-z", binary=True)
    for raw in sorted(part for part in others.split(b"\0") if part):
        relative = Path(os.fsdecode(raw))
        if relative.as_posix() in {
            ".bpirouter-prepared-board",
            ".bpirouter-build.lock",
        } or relative.name.startswith(".bpirouter-build-"):
            continue
        add_path(digest, Path(repo), relative)


def prepared_tree_id(work_dir):
    work = Path(work_dir).resolve()
    if not (work / ".git").exists():
        die(f"no git checkout at {work}")
    digest = hashlib.sha256()
    repository_state(digest, "openwrt", work)
    for relative in (Path(".config"), Path("feeds.conf")):
        add_path(digest, work, relative)

    feeds = work / "feeds"
    if feeds.is_dir():
        for entry in sorted(feeds.iterdir(), key=lambda item: item.name):
            resolved = entry.resolve()
            try:
                run_git(resolved, "rev-parse", "--is-inside-work-tree")
            except (subprocess.CalledProcessError, FileNotFoundError):
                continue
            repository_state(digest, "feed:" + entry.name, resolved)
    return digest.hexdigest()


def add_tree(digest, root, relative):
    """Add one preparation input path without following directory symlinks."""
    path = root / relative
    label = relative.as_posix()
    if not path.exists() and not path.is_symlink():
        add_value(digest, "missing:" + label, b"")
        return
    if path.is_symlink() or path.is_file():
        add_path(digest, root, relative)
        return
    if not path.is_dir():
        die(f"unsupported preparation input at {path}")

    add_value(digest, "dir:" + label, b"")
    for current, dirs, files in os.walk(path, followlinks=False):
        dirs.sort()
        files.sort()
        current_path = Path(current)
        for name in list(dirs):
            child = current_path / name
            child_relative = child.relative_to(root)
            if child.is_symlink():
                add_path(digest, root, child_relative)
                dirs.remove(name)
            else:
                add_value(digest, "dir:" + child_relative.as_posix(), b"")
        for name in files:
            add_path(digest, root, (current_path / name).relative_to(root))


def prepare_input_id(build_dir, board):
    """Identify only inputs whose bytes are materialised by prepare.sh."""
    if board not in BOARD_BASES:
        die(f"unsupported board {board}")
    root = Path(build_dir).resolve()
    if not root.is_dir():
        die(f"no build tree at {root}")

    digest = hashlib.sha256()
    add_value(digest, "schema", "bpirouter-prepare-input-v1")
    inputs = (
        Path("feeds.conf"),
        Path("config/common.config"),
        Path("config") / f"{board}.config",
        Path("patches/common"),
        Path("patches") / board,
        Path("scripts/prepare.sh"),
        Path("scripts/boards.sh"),
        Path("scripts/release-build-provenance.py"),
        Path("scripts/lib/kernel-patch-routing.sh"),
        Path("scripts/lib/openwrt-source.sh"),
    )
    for relative in inputs:
        add_tree(digest, root, relative)
    if board == "bpi-r4-pro-4e":
        # prepare imports the shared generic layers and the MxL driver fix,
        # not the 8X DTS.
        for prefix in ("930-", "931-"):
            for path in sorted((root / "patches/bpi-r4-pro/kernel").glob(prefix + "*.patch")):
                add_path(digest, root, path.relative_to(root))
        add_tree(digest, root, Path("patches/bpi-r4-pro/kernel/987-mxl862xx-retry-initial-phy-id.patch"))
    return digest.hexdigest()


def read_json(path):
    try:
        with open(path) as stream:
            return json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        die(f"cannot read JSON {path}: {error}")


def lock_sha(path):
    return sha_file(path)


def lock_config_sha(lock, relative):
    matches = [entry.get("sha256") for entry in lock.get("configs", []) if entry.get("path") == relative]
    if len(matches) != 1 or not matches[0]:
        die(f"release lock does not contain exactly one {relative}")
    return matches[0]


def patch_set_sha(lock):
    digest = hashlib.sha256()
    entries = sorted((entry.get("path", ""), entry.get("sha256", "")) for entry in lock.get("patches", []))
    if any(not path or not sha for path, sha in entries):
        die("release lock has an incomplete patch entry")
    for path, sha in entries:
        add_value(digest, path, sha)
    return digest.hexdigest()


def parse_marker(path):
    values = {}
    try:
        for line in Path(path).read_text().splitlines():
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            values[key] = value
    except OSError as error:
        die(f"cannot read prepared marker {path}: {error}")
    return values


def artifact_role(name, base):
    """Return the one release role for a profile artifact, or None for a sibling.

    The target directory contains outputs for several profiles, and the R4/R3
    profile names are prefixes of their siblings. Known longer product bases
    are therefore excluded before interpreting the suffix. Any other file that
    starts with this exact base is a new, unclassified product output and fails
    closed instead of being silently omitted from release provenance.
    """
    extra_role = EXTRA_ARTIFACTS.get(base, {}).get(name)
    if extra_role:
        return extra_role
    for sibling in PRODUCT_BASES - {base}:
        if len(sibling) > len(base) and name.startswith(sibling):
            return None
    if not name.startswith(base):
        return None
    rest = name[len(base) :]
    if rest == "-squashfs-sysupgrade.itb":
        return "sysupgrade"
    if rest in ("-initramfs-kernel.bin", "-initramfs.itb"):
        return "initramfs"
    if rest == "-sdcard.img.gz":
        return "sdcard"
    if rest == "-flashkit.tar.gz":
        return "flashkit"
    if re.fullmatch(r"-(?:(?:snand|nor)-)?factory\.(?:bin|ubi|img(?:\..+)?)", rest):
        return "factory"
    if re.fullmatch(r"-(?:emmc|snand|nor|ram)-.+", rest) and (
        rest.endswith("-preloader.bin")
        or rest.endswith("-gpt.bin")
        or rest.endswith(".fip")
    ):
        return "bootloader"
    if rest in (".manifest", ".buildinfo"):
        return "metadata"
    die(f"unclassified release output for {base}: {name}")


def artifact_files(source_dir, base):
    source = Path(source_dir)
    selected = []
    names = {path.name for path in source.glob(base + "*")}
    names.update(EXTRA_ARTIFACTS.get(base, {}))
    for name in sorted(names):
        path = source / name
        if not path.is_file():
            continue
        role = artifact_role(path.name, base)
        if role:
            selected.append((path, role))
    return selected


def artifact_records(source_dir, base):
    files = artifact_files(source_dir, base)
    if not files:
        die(f"no artifacts matching {base}* under {source_dir}")
    return [
        {"file": path.name, "role": role, "sha256": sha_file(path), "size": path.stat().st_size}
        for path, role in files
    ]


def payload_records(feed_files):
    root = Path(feed_files).resolve()
    if not root.is_dir():
        die(f"no UI feed payload at {root}")
    records = []
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        # .manifest is excluded from its own legacy `art` digest, but it does
        # not contain this canonical payload id. Include it here so an
        # artifact-mode stage cannot rewrite src/art provenance after prepare
        # while leaving the expected payload identity unchanged.
        if not (path.is_file() or path.is_symlink()):
            continue
        relative = path.relative_to(root).as_posix()
        record = {
            "path": relative,
            "mode": oct(stat.S_IMODE(path.lstat().st_mode)),
        }
        if path.is_symlink():
            record.update({"type": "symlink", "target": os.readlink(path)})
        else:
            record.update({"type": "file", "sha256": sha_file(path), "size": path.stat().st_size})
        records.append(record)
    if not records:
        die(f"UI feed payload is empty at {root}")
    return records


def payload_id(feed_files):
    canonical = json.dumps(payload_records(feed_files), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def manifest_values(path):
    values = {}
    try:
        for line in Path(path).read_text().splitlines():
            parts = line.split(None, 1)
            if len(parts) == 2:
                values.setdefault(parts[0], []).append(parts[1])
    except OSError as error:
        die(f"cannot read UI payload manifest {path}: {error}")
    for key in ("src", "art"):
        if len(values.get(key, [])) != 1:
            die(f"UI payload manifest must contain exactly one {key} entry")
    return {key: items[0] for key, items in values.items() if len(items) == 1}


def run_hash_script(source_dir, mode, path):
    script = Path(source_dir) / "deploy" / "artifact-hash.sh"
    if not script.is_file():
        die(f"UI source has no artifact hash script at {script}")
    try:
        return subprocess.check_output([str(script), mode, str(path)], text=True).strip()
    except subprocess.CalledProcessError as error:
        die(f"UI {mode} hash failed with exit {error.returncode}")


def acceptance_bundle_sha(source_dir):
    """Identity of the formal acceptance tool bundle built from this UI source.

    The tools are delivered beside the image, so the on-device preflight binds
    them to the build through this value rather than through the rootfs.
    """
    script = Path(source_dir) / "scripts" / "acceptance-bundle.sh"
    if not script.is_file():
        die(f"UI source has no acceptance bundle script at {script}")
    try:
        value = subprocess.check_output(
            [str(script), "--sha", str(Path(source_dir) / "scripts")], text=True
        ).strip()
    except subprocess.CalledProcessError as error:
        die(f"UI acceptance bundle identity failed with exit {error.returncode}")
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        die("UI acceptance bundle identity is malformed")
    return value


def validate_ui_proof(proof, marker, feed_files=None):
    mode = proof.get("mode")
    if mode not in ("source", "artifact", "none"):
        die(f"UI proof has unsupported mode {mode!r}")
    if marker.get("ui_mode") != mode:
        die("UI proof mode does not match the prepared marker")
    if mode != "none":
        for key in ("source_sha256", "manifest_artifact_sha256", "payload_sha256",
                    "payload_inventory_sha256", "apid_sha256"):
            if not proof.get(key):
                die(f"{mode} UI proof has no {key}")
    if mode == "source":
        if proof.get("source_commit") != marker.get("ui_commit"):
            die("UI proof source commit does not match the prepared marker")
        if not re.fullmatch(r"[0-9a-f]{64}", str(proof.get("acceptance_bundle_sha256", ""))):
            die("source UI proof has no acceptance_bundle_sha256")
    elif mode == "artifact":
        if proof.get("artifact_sha256") != marker.get("ui_artifact_sha256"):
            die("UI proof artifact does not match the prepared marker")
        if proof.get("payload_sha256") != marker.get("ui_payload_sha256"):
            die("UI proof payload does not match the prepared marker")
        if proof.get("apid_sha256") != marker.get("ui_apid_sha256"):
            die("UI proof apid does not match the prepared marker")
    if mode != "none" and feed_files:
        if payload_id(feed_files) != proof.get("payload_sha256"):
            die("live UI feed payload changed after its proof was created")
        apid = Path(feed_files) / "bpirouter-apid"
        if not apid.is_file() or sha_file(apid) != proof.get("apid_sha256"):
            die("live bpirouter-apid changed after its UI proof was created")
        inventory = Path(feed_files) / ".payload-inventory"
        if not inventory.is_file() or sha_file(inventory) != proof.get("payload_inventory_sha256"):
            die("live UI payload inventory changed after its proof was created")


def cmd_clean(args):
    files = artifact_files(args.source_dir, args.base)
    for path, _ in files:
        path.unlink()
    print(f"removed {len(files)} pre-existing release artifact(s) for {args.base}")


def cmd_classify(args):
    role = artifact_role(Path(args.file).name, args.base)
    if not role:
        die(f"{Path(args.file).name} belongs to another product profile")
    print(role)


def cmd_inventory(args):
    print(json.dumps(artifact_records(args.source_dir, args.base), indent=2))


def checked_artifact_record(record, expected_keys, context):
    if not isinstance(record, dict) or set(record) != set(expected_keys):
        die(f"{context} has fields other than {', '.join(expected_keys)}")
    name = record.get("file")
    role = record.get("role")
    digest = record.get("sha256")
    size = record.get("size")
    if not isinstance(name, str) or Path(name).name != name or any(c in name for c in "\t\r\n"):
        die(f"{context} has unsafe artifact file {name!r}")
    if not isinstance(role, str) or not role:
        die(f"{context} has invalid role {role!r}")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        die(f"{context} has invalid SHA-256")
    if not isinstance(size, int) or isinstance(size, bool) or size < 0:
        die(f"{context} has invalid size")
    return name


def cmd_verify_collection(args):
    """Rebind collected declarations to the classifier and embedded sidecars."""
    inputs = read_json(args.inputs)
    boards = inputs.get("boards")
    if not isinstance(boards, dict) or not boards:
        die("BUILD-INPUTS.json has no board artifacts")
    for board, info in sorted(boards.items()):
        base = BOARD_BASES.get(board)
        if not base:
            die(f"BUILD-INPUTS.json has unsupported board {board!r}")
        if not isinstance(info, dict):
            die(f"BUILD-INPUTS.json board {board} is not an object")
        provenance = info.get("build_provenance")
        if not isinstance(provenance, dict):
            die(f"BUILD-INPUTS.json board {board} has no embedded build provenance")
        if provenance.get("schema") != 2:
            die(f"embedded build provenance for {board} has unsupported schema")
        if provenance.get("board") != board or provenance.get("base") != base:
            die(f"embedded build provenance identity does not match board {board}")
        if provenance.get("target") != "mediatek/filogic":
            die(f"embedded build provenance target does not match board {board}")
        if provenance.get("release") != inputs.get("release"):
            die(f"embedded build provenance release does not match BUILD-INPUTS.json for {board}")
        if provenance.get("input_lock_sha256") != inputs.get("input_lock_sha256"):
            die(f"embedded build provenance input lock does not match BUILD-INPUTS.json for {board}")
        if info.get("profile") != provenance.get("profile"):
            die(f"collected profile does not match embedded build provenance for {board}")
        ui = provenance.get("ui")
        if not isinstance(ui, dict) or ui.get("mode") != provenance.get("ui_mode"):
            die(f"embedded build provenance has no valid UI identity for {board}")
        ui_identity = {"mode": ui.get("mode")}
        if ui.get("mode") == "source":
            ui_identity.update(
                source_commit=ui.get("source_commit"),
                source_sha256=ui.get("source_sha256"),
                manifest_artifact_sha256=ui.get("manifest_artifact_sha256"),
                payload_sha256=ui.get("payload_sha256"),
                payload_inventory_sha256=ui.get("payload_inventory_sha256"),
                apid_sha256=ui.get("apid_sha256"),
            )
        elif ui.get("mode") == "artifact":
            ui_identity.update(
                artifact_sha256=ui.get("artifact_sha256"),
                source_sha256=ui.get("source_sha256"),
                manifest_artifact_sha256=ui.get("manifest_artifact_sha256"),
                payload_sha256=ui.get("payload_sha256"),
                payload_inventory_sha256=ui.get("payload_inventory_sha256"),
                apid_sha256=ui.get("apid_sha256"),
            )
        elif ui.get("mode") != "none":
            die(f"embedded build provenance has unsupported UI mode for {board}")
        if inputs.get("ui_identity") != ui_identity:
            die(f"embedded build provenance UI identity does not match BUILD-INPUTS.json for {board}")

        sidecar_items = provenance.get("artifacts")
        outer_items = info.get("artifacts")
        if not isinstance(sidecar_items, list) or not sidecar_items:
            die(f"embedded build provenance for {board} has no artifacts")
        if not isinstance(outer_items, list) or not outer_items:
            die(f"BUILD-INPUTS.json board {board} has no artifacts")

        expected_outer = []
        seen = set()
        for index, item in enumerate(sidecar_items):
            name = checked_artifact_record(
                item, ("file", "role", "sha256", "size"),
                f"embedded build provenance {board} artifact {index}",
            )
            if name in seen:
                die(f"embedded build provenance for {board} repeats {name}")
            seen.add(name)
            require_sku_qualified(name, f"embedded build provenance for {board}")
            classified = artifact_role(name, base)
            if classified != item["role"]:
                die(
                    f"embedded build provenance role for {board}/{name} is "
                    f"{item['role']!r}, classifier requires {classified!r}"
                )
            expected_outer.append({
                "file": name,
                "path": f"{board}/{name}",
                "role": item["role"],
                "sha256": item["sha256"],
                "size": item["size"],
            })

        seen = set()
        for index, item in enumerate(outer_items):
            name = checked_artifact_record(
                item, ("file", "path", "role", "sha256", "size"),
                f"BUILD-INPUTS.json {board} artifact {index}",
            )
            if name in seen:
                die(f"BUILD-INPUTS.json board {board} repeats {name}")
            seen.add(name)
            require_sku_qualified(name, f"BUILD-INPUTS.json board {board}")
            if item.get("path") != f"{board}/{name}":
                die(f"BUILD-INPUTS.json path is not canonical for {board}/{name}")

        if sorted(outer_items, key=lambda item: item["file"]) != sorted(
            expected_outer, key=lambda item: item["file"]
        ):
            die(
                f"collected artifact declarations for {board} do not exactly match "
                "the embedded build provenance"
            )
    print(f"verified classifier and embedded provenance for {len(boards)} collected board(s)")


def cmd_payload_id(args):
    print(payload_id(args.feed_files))


def cmd_ui_proof(args):
    data = {"schema": 1, "mode": args.mode}
    if args.mode == "none":
        Path(args.output).write_text(json.dumps(data, indent=2) + "\n")
        return
    if not args.feed_files:
        die(f"{args.mode} UI proof requires --feed-files")
    feed_files = Path(args.feed_files).resolve()
    apid = feed_files / "bpirouter-apid"
    if not apid.is_file():
        die(f"UI feed payload has no bpirouter-apid at {apid}")
    manifest = manifest_values(feed_files / ".manifest")
    inventory = feed_files / ".payload-inventory"
    if not inventory.is_file():
        die(f"UI feed payload has no product inventory at {inventory}")
    inventory_sha = sha_file(inventory)
    if manifest.get("inventory") != inventory_sha:
        die("UI feed manifest does not bind the product payload inventory")
    data.update({
        "source_sha256": manifest["src"],
        "manifest_artifact_sha256": manifest["art"],
        "payload_sha256": payload_id(feed_files),
        "payload_inventory_sha256": inventory_sha,
        "apid_sha256": sha_file(apid),
    })
    if args.mode == "artifact":
        if not args.artifact_sha256 or not args.expected_payload_sha256 or not args.expected_apid_sha256:
            die("artifact UI proof requires artifact, payload and apid SHA-256 values from prepare")
        if data["payload_sha256"] != args.expected_payload_sha256:
            die("staged artifact payload changed after prepare")
        if data["apid_sha256"] != args.expected_apid_sha256:
            die("staged artifact apid changed after prepare")
        data["artifact_sha256"] = args.artifact_sha256
    else:
        if not args.source_dir or not args.source_commit:
            die("source UI proof requires --source-dir and --source-commit")
        source = Path(args.source_dir).resolve()
        head = run_git(source, "rev-parse", "HEAD").strip()
        if head != args.source_commit:
            die("UI source checkout no longer matches the release lock")
        if run_git(source, "status", "--porcelain").strip():
            die("UI source checkout has uncommitted changes")
        source_hash = run_hash_script(source, "src", source)
        artifact_hash = run_hash_script(source, "art", feed_files)
        if manifest["src"] != source_hash or manifest["art"] != artifact_hash:
            die("UI feed manifest does not describe the source and payload actually used")
        data.update({
            "source_commit": head,
            "source_sha256": source_hash,
            "manifest_artifact_sha256": artifact_hash,
            "acceptance_bundle_sha256": acceptance_bundle_sha(source),
        })
    Path(args.output).write_text(json.dumps(data, indent=2) + "\n")


def cmd_prepared_id(args):
    print(prepared_tree_id(args.work_dir))


def cmd_prepare_input_id(args):
    print(prepare_input_id(args.build_dir, args.board))


def cmd_lock_metadata(args):
    lock = read_json(args.lock)
    if args.board not in lock.get("boards", []):
        die(f"release lock does not include board {args.board}")
    data = {
        "release": lock.get("release"),
        "input_lock_sha256": lock_sha(args.lock),
        "openwrt_commit": lock.get("openwrt", {}).get("commit"),
        "build_commit": lock.get("repos", {}).get("bpirouter-build"),
        "ui_commit": lock.get("repos", {}).get("bpirouter-ui"),
        "feeds_commit": lock.get("repos", {}).get("bpirouter-feeds"),
        "common_config_sha256": lock_config_sha(lock, "config/common.config"),
        "board_config_sha256": lock_config_sha(lock, f"config/{args.board}.config"),
        "patch_set_sha256": patch_set_sha(lock),
    }
    for key, value in data.items():
        if not value:
            die(f"release lock has no {key}")
        print(f"{key}={value}")


def cmd_write(args):
    lock = read_json(args.lock)
    if args.board not in lock.get("boards", []):
        die(f"release lock does not include board {args.board}")
    marker = parse_marker(args.marker)
    expected_lock_sha = lock_sha(args.lock)
    if marker.get("release_bound") != "1":
        die("prepared marker is not release-bound")
    if marker.get("input_lock_sha256") != expected_lock_sha:
        die("prepared marker belongs to another input lock")
    if marker.get("release_id") != lock.get("release"):
        die("prepared marker release ID does not match the lock")
    tree_id = marker.get("prepared_tree_sha256")
    if not tree_id:
        die("prepared marker has no prepared_tree_sha256")
    if prepared_tree_id(args.work_dir) != tree_id:
        die("prepared OpenWrt tree changed before build provenance was written")
    ui = read_json(args.ui_proof)
    validate_ui_proof(ui, marker, args.feed_files)
    data = {
        "schema": 2,
        "release": lock.get("release"),
        "input_lock_sha256": expected_lock_sha,
        "board": args.board,
        "profile": args.profile,
        "target": args.target,
        "base": args.base,
        "ui_mode": marker.get("ui_mode"),
        "ui": ui,
        "prepared_marker_sha256": sha_file(args.marker),
        "prepared_tree_sha256": tree_id,
        "openwrt_commit": marker.get("openwrt_commit"),
        "build_commit": marker.get("build_commit"),
        "ui_commit": marker.get("ui_commit"),
        "feeds_commit": marker.get("feeds_commit"),
        "common_config_sha256": marker.get("common_config_sha256"),
        "board_config_sha256": marker.get("board_config_sha256"),
        "patch_set_sha256": marker.get("patch_set_sha256"),
        "artifacts": artifact_records(args.source_dir, args.base),
    }
    missing = [key for key, value in data.items() if key != "artifacts" and value in (None, "")]
    if missing:
        die("prepared marker is missing provenance fields: " + ", ".join(missing))
    Path(args.output).write_text(json.dumps(data, indent=2) + "\n")


def cmd_verify(args):
    lock = read_json(args.lock)
    if args.board not in lock.get("boards", []):
        die(f"release lock does not include board {args.board}")
    sidecar = read_json(args.sidecar)
    expected = {
        "schema": 2,
        "release": args.release,
        "input_lock_sha256": lock_sha(args.lock),
        "board": args.board,
        "profile": args.profile,
        "target": args.target,
        "base": args.base,
    }
    if lock.get("release") != args.release:
        die(f"input lock is for {lock.get('release')!r}, not {args.release!r}")
    for key, value in expected.items():
        if sidecar.get(key) != value:
            die(f"build provenance {key} is {sidecar.get(key)!r}, expected {value!r}")
    for key in (
        "prepared_marker_sha256",
        "prepared_tree_sha256",
        "openwrt_commit",
        "build_commit",
        "ui_commit",
        "feeds_commit",
        "common_config_sha256",
        "board_config_sha256",
        "patch_set_sha256",
    ):
        if not sidecar.get(key):
            die(f"build provenance has no {key}")
    ui = sidecar.get("ui")
    if not isinstance(ui, dict) or ui.get("mode") != sidecar.get("ui_mode"):
        die("build provenance has no valid UI identity")
    if ui["mode"] == "source":
        if ui.get("source_commit") != lock.get("repos", {}).get("bpirouter-ui"):
            die("build provenance UI source does not match the input lock")
        for key in ("source_sha256", "manifest_artifact_sha256", "payload_sha256",
                    "payload_inventory_sha256", "apid_sha256"):
            if not ui.get(key):
                die(f"build provenance source UI has no {key}")
    elif ui["mode"] == "artifact":
        locked_artifacts = {entry.get("sha256") for entry in lock.get("ui_artifacts", [])}
        if ui.get("artifact_sha256") not in locked_artifacts:
            die("build provenance UI artifact is not in the input lock")
        for key in ("payload_sha256", "payload_inventory_sha256", "apid_sha256"):
            if not ui.get(key):
                die(f"build provenance artifact UI has no {key}")
    elif ui["mode"] != "none":
        die(f"build provenance has unsupported UI mode {ui.get('mode')!r}")
    metadata = {
        line.split("=", 1)[0]: line.split("=", 1)[1]
        for line in metadata_lines(lock, args.lock, args.board)
    }
    comparisons = {
        "openwrt_commit": metadata["openwrt_commit"],
        "build_commit": metadata["build_commit"],
        "ui_commit": metadata["ui_commit"],
        "feeds_commit": metadata["feeds_commit"],
        "common_config_sha256": metadata["common_config_sha256"],
        "board_config_sha256": metadata["board_config_sha256"],
        "patch_set_sha256": metadata["patch_set_sha256"],
    }
    for key, value in comparisons.items():
        if sidecar.get(key) != value:
            die(f"build provenance {key} does not match the input lock")
    current = artifact_records(args.source_dir, args.base)
    if sidecar.get("artifacts") != current:
        die("build artifacts do not match the release-bound provenance sidecar")
    print(f"verified release-bound build provenance for {args.board}")


def metadata_lines(lock, lock_path, board):
    data = {
        "release": lock.get("release"),
        "input_lock_sha256": lock_sha(lock_path),
        "openwrt_commit": lock.get("openwrt", {}).get("commit"),
        "build_commit": lock.get("repos", {}).get("bpirouter-build"),
        "ui_commit": lock.get("repos", {}).get("bpirouter-ui"),
        "feeds_commit": lock.get("repos", {}).get("bpirouter-feeds"),
        "common_config_sha256": lock_config_sha(lock, "config/common.config"),
        "board_config_sha256": lock_config_sha(lock, f"config/{board}.config"),
        "patch_set_sha256": patch_set_sha(lock),
    }
    for key, value in data.items():
        if not value:
            die(f"release lock has no {key}")
    return [f"{key}={value}" for key, value in data.items()]


def parser():
    root = argparse.ArgumentParser()
    commands = root.add_subparsers(dest="command", required=True)

    prepared = commands.add_parser("prepared-id")
    prepared.add_argument("--work-dir", required=True)
    prepared.set_defaults(func=cmd_prepared_id)

    prepare_input = commands.add_parser("prepare-input-id")
    prepare_input.add_argument("--build-dir", required=True)
    prepare_input.add_argument("--board", required=True)
    prepare_input.set_defaults(func=cmd_prepare_input_id)

    metadata = commands.add_parser("lock-metadata")
    metadata.add_argument("--lock", required=True)
    metadata.add_argument("--board", required=True)
    metadata.set_defaults(func=cmd_lock_metadata)

    clean = commands.add_parser("clean")
    clean.add_argument("--source-dir", required=True)
    clean.add_argument("--base", required=True)
    clean.set_defaults(func=cmd_clean)

    classify = commands.add_parser("classify")
    classify.add_argument("--file", required=True)
    classify.add_argument("--base", required=True)
    classify.set_defaults(func=cmd_classify)

    inventory = commands.add_parser("inventory")
    inventory.add_argument("--source-dir", required=True)
    inventory.add_argument("--base", required=True)
    inventory.set_defaults(func=cmd_inventory)

    collection = commands.add_parser("verify-collection")
    collection.add_argument("--inputs", required=True)
    collection.set_defaults(func=cmd_verify_collection)

    payload = commands.add_parser("payload-id")
    payload.add_argument("--feed-files", required=True)
    payload.set_defaults(func=cmd_payload_id)

    ui = commands.add_parser("ui-proof")
    ui.add_argument("--mode", required=True, choices=("source", "artifact", "none"))
    ui.add_argument("--feed-files")
    ui.add_argument("--source-dir")
    ui.add_argument("--source-commit")
    ui.add_argument("--artifact-sha256")
    ui.add_argument("--expected-payload-sha256")
    ui.add_argument("--expected-apid-sha256")
    ui.add_argument("--output", required=True)
    ui.set_defaults(func=cmd_ui_proof)

    write = commands.add_parser("write")
    for option in ("lock", "board", "profile", "target", "base", "source-dir", "work-dir", "marker", "ui-proof", "feed-files", "output"):
        write.add_argument("--" + option, required=True)
    write.set_defaults(func=cmd_write)

    verify = commands.add_parser("verify")
    for option in ("lock", "release", "board", "profile", "target", "base", "source-dir", "sidecar"):
        verify.add_argument("--" + option, required=True)
    verify.set_defaults(func=cmd_verify)
    return root


if __name__ == "__main__":
    arguments = parser().parse_args()
    arguments.func(arguments)
