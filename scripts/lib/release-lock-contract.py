#!/usr/bin/env python3
"""Shared, fail-closed release/download-lock and APK-version contract."""

import argparse
import hashlib
import json
import os
import pathlib
import re
import stat
import sys


SHA256_RE = re.compile(r"[0-9a-f]{64}")
RELEASE_RE = re.compile(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-rc([1-9]\d*))?")


def die(message: str) -> None:
    raise SystemExit(message)


def load(path: str) -> dict:
    def object_without_duplicates(pairs: list[tuple[str, object]]) -> dict:
        result = {}
        for key, value in pairs:
            if key in result:
                die(f"{path} repeats JSON key {key!r}")
            result[key] = value
        return result

    try:
        value = json.loads(pathlib.Path(path).read_text(), object_pairs_hook=object_without_duplicates)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        die(f"cannot read strict JSON {path}: {exc}")
    if not isinstance(value, dict):
        die(f"{path} is not a JSON object")
    return value


def sha256(path: str) -> str:
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        die(f"cannot hash {path}: {exc}")
    return digest.hexdigest()


def find_input(build_dir: str, explicit: str) -> str:
    root = pathlib.Path(build_dir)
    if explicit:
        selected = pathlib.Path(explicit)
    elif (root / "RELEASE-INPUTS.lock.json").is_file():
        selected = root / "RELEASE-INPUTS.lock.json"
    else:
        candidates = sorted((root / "dist").glob("*.lock.json"))
        if not candidates:
            return ""
        if len(candidates) != 1:
            die("more than one release lock under dist/; set BPIR_RELEASE_LOCK explicitly")
        selected = candidates[0]
    if not selected.is_file():
        die(f"no such release lock: {selected}")
    return str(selected.resolve())


def exact_boards(value: object, expected: list[str], label: str) -> None:
    if not isinstance(value, list) or any(not isinstance(v, str) for v in value):
        die(f"{label} boards must be a string array")
    if len(value) != len(set(value)):
        die(f"{label} repeats a board")
    if set(value) != set(expected) or len(value) != len(expected):
        die(f"{label} must name exactly: {' '.join(expected)}")


def validate_downloads(path: str, release: str, boards: list[str]) -> str:
    data = load(path)
    if data.get("schema") != 1:
        die(f"downloads lock has unsupported schema {data.get('schema')!r}")
    if data.get("release") != release:
        die(f"downloads lock is for {data.get('release')!r}, not {release!r}")
    exact_boards(data.get("boards"), boards, "downloads lock")
    return sha256(path)


def expected_versions(release: str) -> tuple[str, str]:
    match = RELEASE_RE.fullmatch(release)
    if not match:
        die("release ID must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rcN")
    major, minor, patch, rc = match.groups()
    package = f"{major}.{minor}.{patch}" + (f"_rc{rc}" if rc else "")
    return package, f"{package}-r1"


def publish(staged: str, output: str) -> None:
    """Atomically publish a validated lock without ever replacing an RC."""
    staged_path = pathlib.Path(staged)
    output_path = pathlib.Path(output)
    try:
        staged_parent = staged_path.parent.resolve(strict=True)
        output_parent = output_path.parent.resolve(strict=True)
        staged_stat = staged_path.lstat()
    except OSError as exc:
        die(f"cannot inspect staged release lock: {exc}")
    if staged_parent != output_parent:
        die("staged and published release locks must share one directory")
    if not stat.S_ISREG(staged_stat.st_mode) or staged_path.is_symlink():
        die("staged release lock must be a regular, non-symlink file")

    file_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        file_fd = os.open(staged_path, file_flags)
        try:
            os.fsync(file_fd)
        finally:
            os.close(file_fd)
        # link(2), unlike rename(2), is an atomic no-replace publication: only
        # one concurrent generator can claim the canonical RC pathname.
        os.link(staged_path, output_path, follow_symlinks=False)
        directory_fd = os.open(output_parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
            staged_path.unlink()
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except FileExistsError:
        die("release lock already exists; release IDs are immutable, create a new RC")
    except OSError as exc:
        die(f"cannot durably publish release lock: {exc}")
    print(output_path)


def validate_input(data: dict, boards: list[str]) -> tuple[str, str]:
    if data.get("schema") != 1:
        die(f"input lock has unsupported schema {data.get('schema')!r}")
    release = data.get("release")
    if not isinstance(release, str) or not release:
        die("input lock has no release ID")
    _, expected_apk = expected_versions(release)
    if "test_only" in data and not isinstance(data["test_only"], bool):
        die("input lock test_only must be boolean")
    exact_boards(data.get("boards"), boards, "input lock")
    frozen = data.get("downloads_lock_sha256")
    if not isinstance(frozen, str) or not SHA256_RE.fullmatch(frozen):
        die("input lock has no valid downloads_lock_sha256")
    artifacts = data.get("ui_artifacts", [])
    if not isinstance(artifacts, list):
        die("input lock ui_artifacts must be an array")
    for index, artifact in enumerate(artifacts):
        if not isinstance(artifact, dict):
            die(f"input lock UI artifact {index} is not an object")
        if artifact.get("name") != "bpirouter-ui":
            die(f"input lock UI artifact {index} has the wrong package name")
        if artifact.get("version") != expected_apk:
            die(f"input lock UI artifact {index} version does not match {release}")
    return release, frozen


def validate_formal_input(path: str, canonical_dir: str, boards: list[str]) -> pathlib.Path:
    """Bind a formal consumer to the one generator-owned lock for its RC."""
    supplied = pathlib.Path(path)
    directory = pathlib.Path(canonical_dir)
    try:
        supplied_stat = supplied.lstat()
        directory_stat = directory.lstat()
    except OSError as exc:
        die(f"cannot inspect formal release-lock authority: {exc}")
    if not stat.S_ISREG(supplied_stat.st_mode) or supplied.is_symlink():
        die("supplied input lock must be a regular, non-symlink file")
    if not stat.S_ISDIR(directory_stat.st_mode) or directory.is_symlink():
        die("canonical release-lock directory must be a real directory")

    supplied_data = load(path)
    release, _ = validate_input(supplied_data, boards)
    if supplied_data.get("test_only") is not False:
        die("test-only or legacy input lock cannot authorize a formal release operation")
    canonical = directory / f"RELEASE-INPUTS.{release}.lock.json"
    try:
        canonical_stat = canonical.lstat()
    except OSError as exc:
        die(f"canonical input lock is unavailable: {canonical}: {exc}")
    if not stat.S_ISREG(canonical_stat.st_mode) or canonical.is_symlink():
        die("canonical input lock must be a regular, non-symlink file")
    canonical_data = load(str(canonical))
    canonical_release, _ = validate_input(canonical_data, boards)
    if canonical_release != release or canonical_data.get("test_only") is not False:
        die("canonical input lock is not a formal lock for the supplied release")
    try:
        if supplied.read_bytes() != canonical.read_bytes():
            die("supplied input lock differs from the canonical release lock")
    except OSError as exc:
        die(f"cannot compare supplied and canonical input locks: {exc}")
    return canonical


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    fi = sub.add_parser("find-input")
    fi.add_argument("--build-dir", required=True)
    fi.add_argument("--explicit", default="")

    ri = sub.add_parser("release-id")
    ri.add_argument("--input-lock", required=True)

    vd = sub.add_parser("validate-downloads")
    vd.add_argument("--downloads-lock", required=True)
    vd.add_argument("--release", required=True)
    vd.add_argument("--boards", nargs="+", required=True)

    vb = sub.add_parser("validate-binding")
    vb.add_argument("--input-lock", required=True)
    vb.add_argument("--downloads-lock", required=True)
    vb.add_argument("--release")
    vb.add_argument("--boards", nargs="+", required=True)

    vi = sub.add_parser("validate-input")
    vi.add_argument("--input-lock", required=True)
    vi.add_argument("--boards", nargs="+", required=True)

    rv = sub.add_parser("release-version")
    rv.add_argument("--release", required=True)
    rv.add_argument("--format", choices=("package", "apk"), required=True)

    av = sub.add_parser("validate-apk")
    av.add_argument("--release", required=True)
    av.add_argument("--name", required=True)
    av.add_argument("--version", required=True)

    pub = sub.add_parser("publish")
    pub.add_argument("--staged", required=True)
    pub.add_argument("--output", required=True)

    vf = sub.add_parser("validate-formal")
    vf.add_argument("--input-lock", required=True)
    vf.add_argument("--canonical-dir", required=True)
    vf.add_argument("--boards", nargs="+", required=True)

    args = parser.parse_args()
    if args.command == "find-input":
        print(find_input(args.build_dir, args.explicit))
        return
    if args.command == "release-id":
        release = load(args.input_lock).get("release")
        if not isinstance(release, str):
            die("input lock has no string release ID")
        expected_versions(release)
        print(release)
        return
    if args.command == "validate-downloads":
        print(validate_downloads(args.downloads_lock, args.release, args.boards))
        return
    if args.command == "validate-binding":
        inputs = load(args.input_lock)
        locked_release, frozen = validate_input(inputs, args.boards)
        release = args.release or locked_release
        if inputs.get("release") != release:
            die(f"input lock is for {inputs.get('release')!r}, not {release!r}")
        actual = validate_downloads(args.downloads_lock, release, args.boards)
        if frozen != actual:
            die(f"downloads lock differs from the input lock\n  frozen {frozen}\n  actual {actual}")
        print(actual)
        return
    if args.command == "validate-input":
        release, frozen = validate_input(load(args.input_lock), args.boards)
        print(f"{release} {frozen}")
        return
    if args.command == "publish":
        publish(args.staged, args.output)
        return
    if args.command == "validate-formal":
        print(validate_formal_input(args.input_lock, args.canonical_dir, args.boards))
        return
    package, apk = expected_versions(args.release)
    if args.command == "validate-apk":
        if args.name != "bpirouter-ui":
            die(f"APK declares package name {args.name!r}, expected 'bpirouter-ui'")
        if args.version != apk:
            die(f"APK declares version {args.version!r}, release {args.release!r} requires {apk!r}")
        print(apk)
        return
    print(package if args.format == "package" else apk)


if __name__ == "__main__":
    main()
