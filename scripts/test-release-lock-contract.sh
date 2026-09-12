#!/bin/bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL="$SCRIPT_DIR/lib/release-lock-contract.py"
TMP=$(mktemp -d -t bpir-release-lock-contract-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
BOARDS=(bpi-r4 bpi-r4-lite bpi-r4-pro bpi-r3 bpi-r3-mini openwrt-one)

write_downloads() {
    local path="$1" release="$2" marker="$3"
    python3 - "$path" "$release" "$marker" "${BOARDS[@]}" <<'PY'
import json, sys
path, release, marker, *boards = sys.argv[1:]
json.dump({"schema": 1, "release": release, "boards": boards, "objects": [
    {"path": "source-cache/" + marker, "sha256": "0" * 64, "size": 0}
]}, open(path, "w"), indent=2)
PY
}

write_input() {
    local path="$1" release="$2" downloads="$3"
    python3 - "$path" "$release" "$downloads" "${BOARDS[@]}" <<'PY'
import hashlib, json, sys
path, release, downloads, *boards = sys.argv[1:]
digest = hashlib.sha256(open(downloads, "rb").read()).hexdigest()
json.dump({"schema": 1, "release": release, "boards": boards,
           "test_only": False, "downloads_lock_sha256": digest}, open(path, "w"), indent=2)
PY
}

refuses() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo "FAIL: $name was accepted" >&2
        exit 1
    fi
}

write_downloads "$TMP/downloads.json" v1.5.0-rc2 original
write_input "$TMP/inputs.json" v1.5.0-rc2 "$TMP/downloads.json"
"$TOOL" validate-binding --input-lock "$TMP/inputs.json" \
    --downloads-lock "$TMP/downloads.json" --release v1.5.0-rc2 \
    --boards "${BOARDS[@]}" >/dev/null

write_downloads "$TMP/replaced.json" v1.5.0-rc2 replacement
refuses "same-release replacement downloads lock" "$TOOL" validate-binding \
    --input-lock "$TMP/inputs.json" --downloads-lock "$TMP/replaced.json" \
    --release v1.5.0-rc2 --boards "${BOARDS[@]}"
write_downloads "$TMP/wrong-release.json" v1.5.0-rc3 original
refuses "wrong-release downloads lock" "$TOOL" validate-binding \
    --input-lock "$TMP/inputs.json" --downloads-lock "$TMP/wrong-release.json" \
    --release v1.5.0-rc2 --boards "${BOARDS[@]}"
python3 - "$TMP/replaced.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["boards"].pop()
json.dump(data, open(path, "w"))
PY
refuses "incomplete board set" "$TOOL" validate-downloads \
    --downloads-lock "$TMP/replaced.json" --release v1.5.0-rc2 --boards "${BOARDS[@]}"

cat >"$TMP/duplicate-downloads.json" <<'JSON'
{"schema":1,"release":"v1.5.0-rc2","release":"v1.5.0-rc3",
 "boards":["bpi-r4","bpi-r4-lite","bpi-r4-pro","bpi-r3","bpi-r3-mini","openwrt-one"]}
JSON
refuses "downloads lock duplicate release key" "$TOOL" validate-downloads \
    --downloads-lock "$TMP/duplicate-downloads.json" --release v1.5.0-rc2 \
    --boards "${BOARDS[@]}"
cat >"$TMP/duplicate-input.json" <<'JSON'
{"schema":1,"release":"v1.5.0-rc2","test_only":false,"test_only":true,
 "downloads_lock_sha256":"0000000000000000000000000000000000000000000000000000000000000000",
 "boards":["bpi-r4","bpi-r4-lite","bpi-r4-pro","bpi-r3","bpi-r3-mini","openwrt-one"]}
JSON
refuses "input lock duplicate test_only key" "$TOOL" validate-input \
    --input-lock "$TMP/duplicate-input.json" --boards "${BOARDS[@]}"

[ "$("$TOOL" release-version --release v1.5.0-rc2 --format package)" = 1.5.0_rc2 ]
[ "$("$TOOL" release-version --release v1.5.0-rc2 --format apk)" = 1.5.0_rc2-r1 ]
[ "$("$TOOL" release-version --release v1.5.0 --format apk)" = 1.5.0-r1 ]
[ "$("$TOOL" release-version --release v1.5.0-rc1 --format package)" = 1.5.0_rc1 ]
[ "$("$TOOL" release-version --release v1.5.0-rc12 --format apk)" = 1.5.0_rc12-r1 ]
"$TOOL" validate-apk --release v1.5.0-rc1 --name bpirouter-ui --version 1.5.0_rc1-r1 >/dev/null
refuses "stable artifact in RC release" "$TOOL" validate-apk --release v1.5.0-rc1 \
    --name bpirouter-ui --version 1.5.0-r1
refuses "non-release version" "$TOOL" release-version --release test-deadbeef --format apk
for invalid_release in v1.5.0-beta v1.5.0-beta.1 v1.5.0-test v1.5.0-r2 \
    v01.5.0 v1.05.0 v1.5.00 v1.5.0-rc0 v1.5.0-rc01; do
    refuses "invalid release $invalid_release" "$TOOL" release-version \
        --release "$invalid_release" --format apk
done
"$TOOL" validate-apk --release v1.5.0-rc2 --name bpirouter-ui \
    --version 1.5.0_rc2-r1 >/dev/null
refuses "legacy UI APK version" "$TOOL" validate-apk --release v1.5.0-rc2 \
    --name bpirouter-ui --version 1.0.0-r1
refuses "wrong APK package" "$TOOL" validate-apk --release v1.5.0-rc2 \
    --name another-package --version 1.5.0_rc2-r1
python3 - "$TMP/inputs.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["ui_artifacts"] = [{"name": "bpirouter-ui", "version": "1.0.0-r1"}]
json.dump(data, open(path, "w"), indent=2)
PY
refuses "input lock with legacy APK version" "$TOOL" validate-input \
    --input-lock "$TMP/inputs.json" --boards "${BOARDS[@]}"

# Publication is an atomic no-replace claim on the canonical pathname. A
# concurrent or repeated generator cannot replace the first lock, and a failed
# claimant retains its staged material for diagnosis/cleanup.
mkdir "$TMP/publish"
printf 'first\n' >"$TMP/publish/staged-first"
printf 'second\n' >"$TMP/publish/staged-second"
"$TOOL" publish --staged "$TMP/publish/staged-first" \
    --output "$TMP/publish/RELEASE-INPUTS.v1.5.0-rc2.lock.json" >/dev/null
[ "$(cat "$TMP/publish/RELEASE-INPUTS.v1.5.0-rc2.lock.json")" = first ]
[ ! -e "$TMP/publish/staged-first" ]
refuses "second publication for one release ID" "$TOOL" publish \
    --staged "$TMP/publish/staged-second" \
    --output "$TMP/publish/RELEASE-INPUTS.v1.5.0-rc2.lock.json"
[ "$(cat "$TMP/publish/RELEASE-INPUTS.v1.5.0-rc2.lock.json")" = first ]
[ -f "$TMP/publish/staged-second" ]
mkdir "$TMP/other-publish"
refuses "cross-directory staged publication" "$TOOL" publish \
    --staged "$TMP/publish/staged-second" --output "$TMP/other-publish/lock.json"

mkdir "$TMP/formal"
write_input "$TMP/formal-source.json" v1.5.0-rc2 "$TMP/downloads.json"
cp "$TMP/formal-source.json" "$TMP/formal/RELEASE-INPUTS.v1.5.0-rc2.lock.json"
cp "$TMP/formal-source.json" "$TMP/formal-copy.json"
"$TOOL" validate-formal --input-lock "$TMP/formal-copy.json" \
    --canonical-dir "$TMP/formal" --boards "${BOARDS[@]}" >/dev/null
python3 - "$TMP/formal-copy.json" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
data["manual_nonce"] = True
json.dump(data, open(path, "w"), indent=2)
PY
refuses "hand-written noncanonical input lock" "$TOOL" validate-formal \
    --input-lock "$TMP/formal-copy.json" --canonical-dir "$TMP/formal" \
    --boards "${BOARDS[@]}"
cp "$TMP/formal/RELEASE-INPUTS.v1.5.0-rc2.lock.json" "$TMP/formal/backing.json"
unlink "$TMP/formal/RELEASE-INPUTS.v1.5.0-rc2.lock.json"
ln -s backing.json "$TMP/formal/RELEASE-INPUTS.v1.5.0-rc2.lock.json"
refuses "symlink canonical input lock" "$TOOL" validate-formal \
    --input-lock "$TMP/formal/backing.json" --canonical-dir "$TMP/formal" \
    --boards "${BOARDS[@]}"

for alternate_output in "$TMP/a.json" "$TMP/b.json"; do
    set +e
    "$SCRIPT_DIR/make-release-lock.sh" --release v1.5.0-rc2 \
        --downloads-lock "$TMP/downloads.json" --output "$alternate_output" \
        >"$TMP/noncanonical.out" 2>&1
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || {
        echo "FAIL: formal lock accepted noncanonical output $alternate_output" >&2
        exit 1
    }
    grep -Fq 'formal release lock output must be' "$TMP/noncanonical.out" || {
        cat "$TMP/noncanonical.out" >&2
        echo "FAIL: noncanonical output was not rejected by the path gate" >&2
        exit 1
    }
done

echo "ok: release input/download binding and APK version contract"
