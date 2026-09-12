#!/bin/bash
# test-release-output.sh — prove the release-output contract refuses what it
# claims to refuse.
#
# Usage: test-release-output.sh --release vX.Y.Z --input-lock <f>
#                               --downloads-lock <f> --linux-firmware <f>
#                               --board <board> [--ui-artifact <apk>]
#
# Each case mutates a copy of a collected release directory and requires the
# manifest to be refused. A gate nobody has seen fail is a gate nobody knows
# works: every check here exists because something got through it, or would
# have.
#
# The positive case is not decoration. Without it, a manifest generator that
# refused everything would pass every negative case.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
bad()  { echo -e "${R}✗ $1${N}" >&2; FAILED=$((FAILED+1)); }
die()  { echo -e "${R}✗ $1${N}" >&2; exit 1; }

RELEASE=""; ILOCK=""; DLOCK=""; LFW=""; BOARD=""; UIAPK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --release)        RELEASE="$2"; shift 2 ;;
        --input-lock)     ILOCK="$2"; shift 2 ;;
        --downloads-lock) DLOCK="$2"; shift 2 ;;
        --linux-firmware) LFW="$2"; shift 2 ;;
        --board)          BOARD="$2"; shift 2 ;;
        --ui-artifact)    UIAPK="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$RELEASE" ] && [ -n "$ILOCK" ] && [ -n "$DLOCK" ] && [ -n "$LFW" ] && [ -n "$BOARD" ] \
    || die "usage: test-release-output.sh --release vX.Y.Z --input-lock <f> --downloads-lock <f> --linux-firmware <f> --board <board> [--ui-artifact <apk>]"

TMP=$(mktemp -d -t bpir-relout-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
FAILED=0

UIARGS=(); [ -n "$UIAPK" ] && UIARGS=(--ui-artifact "$UIAPK")

step "Collecting a reference release directory..."
"$SCRIPT_DIR/collect-release-artifacts.sh" --release "$RELEASE" --input-lock "$ILOCK" \
    --downloads-lock "$DLOCK" --board "$BOARD" "${UIARGS[@]}" --output-root "$TMP/ref" \
    >"$TMP/collect.log" 2>&1 || { cat "$TMP/collect.log"; die "collection failed"; }
REF=$(ls -d "$TMP/ref/$RELEASE"/*)
ok "reference at $(basename "$REF")"

# manifest <dir> [extra args...] — returns 0 if a manifest was produced.
manifest() {
    local d="$1"; shift
    rm -f "$TMP/out.json"
    "$SCRIPT_DIR/make-firmware-manifest.sh" --release "$RELEASE" --build-output "$d" \
        --input-lock "$ILOCK" --downloads-lock "$DLOCK" --linux-firmware "$LFW" \
        --output "$TMP/out.json" --allow-partial-development "$@" >"$TMP/m.log" 2>&1
    [ -f "$TMP/out.json" ]
}

# refuses <name> <dir> [extra args...] — the case passes when no manifest appears.
refuses() {
    local name="$1"; shift
    if manifest "$@"; then
        bad "$name: a manifest was written when it should have been refused"
    else
        ok "$name: refused — $(grep -m1 '✗\|FATAL\|Error' "$TMP/m.log" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-64)"
    fi
}

fresh() { rm -rf "$TMP/case"; cp -a "$REF" "$TMP/case"; echo "$TMP/case"; }

echo
step "Formal completeness gate"
rm -f "$TMP/formal.json"
if "$SCRIPT_DIR/make-firmware-manifest.sh" --release "$RELEASE" --build-output "$REF" \
    --input-lock "$ILOCK" --downloads-lock "$DLOCK" --linux-firmware "$LFW" \
    --output "$TMP/formal.json" "${UIARGS[@]}" >"$TMP/formal.log" 2>&1; then
    bad "formal manifest accepted a release with only one collected board"
else
    grep -Eq 'formal release is missing locked boards|formal release lock must name exactly the supported boards|has no release file contract yet' "$TMP/formal.log" \
        && ok "formal manifest refused the non-six-board release set" \
        || bad "formal manifest failed before proving the board-set gate"
fi

echo
step "Positive case"
if manifest "$REF" "${UIARGS[@]}"; then
    # The described set and the checked set have to be the same set, not merely
    # the same size: this compares paths.
    python3 - "$TMP/out.json" "$REF/BUILD-INPUTS.json" <<'PY' && ok "manifest written; described set == declared set" || bad "described set != declared set"
import json, sys
m = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
described = {i["path"] for i in m["images"]}
declared = {a["path"] for _, i in b["boards"].items() for a in i["artifacts"]}
sys.exit(0 if described == declared else 1)
PY
else
    bad "positive case: no manifest was written"
fi

echo
step "Negative cases"

# ── inputs ──
D=$(fresh); python3 - "$D/BUILD-INPUTS.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["input_lock_sha256"]="0"*64; json.dump(d,open(p,"w"),indent=2)
PY
refuses "wrong input-lock hash" "$D"

D=$(fresh); python3 - "$D/BUILD-INPUTS.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["downloads_lock_sha256"]="0"*64; json.dump(d,open(p,"w"),indent=2)
PY
refuses "wrong downloads-lock hash" "$D"

if [ -n "$UIAPK" ]; then
    D=$(fresh); python3 - "$D/BUILD-INPUTS.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["ui_artifact_sha256"]="0"*64; json.dump(d,open(p,"w"),indent=2)
PY
    refuses "wrong UI artifact hash" "$D" "${UIARGS[@]}"
fi

# ── the artifact list ──
D=$(fresh); python3 - "$D/BUILD-INPUTS.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p))
list(d["boards"].values())[0]["artifacts"][0]["sha256"]="0"*64
json.dump(d,open(p,"w"),indent=2)
PY
refuses "declared hash tampered" "$D"

D=$(fresh); python3 - "$D/BUILD-INPUTS.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p))
list(d["boards"].values())[0]["artifacts"][0]["path"]="somewhere/else.bin"
json.dump(d,open(p,"w"),indent=2)
PY
refuses "declared path tampered" "$D"

D=$(fresh); python3 - "$D/BUILD-INPUTS.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p))
a=list(d["boards"].values())[0]["artifacts"]; a.append(dict(a[0]))
json.dump(d,open(p,"w"),indent=2)
PY
refuses "duplicate path declared" "$D"

D=$(fresh); python3 - "$D/BUILD-INPUTS.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p))
items=list(d["boards"].values())[0]["artifacts"]
next(a for a in items if a["role"] != "metadata")["role"]="metadata"
json.dump(d,open(p,"w"),indent=2)
PY
refuses "outer role relabelled after collection" "$D"

D=$(fresh); python3 - "$D/BUILD-INPUTS.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p))
items=list(d["boards"].values())[0]["artifacts"]
left,right=next((a,b) for a in items for b in items if a["role"] != b["role"])
left["role"],right["role"]=right["role"],left["role"]
json.dump(d,open(p,"w"),indent=2)
PY
refuses "outer artifact roles swapped after collection" "$D"

D=$(fresh); python3 - "$D/BUILD-INPUTS.json" <<'PY'
import json,sys; p=sys.argv[1]; d=json.load(open(p))
info=list(d["boards"].values())[0]
outer=next(a for a in info["artifacts"] if a["role"] != "metadata")
inner=next(a for a in info["build_provenance"]["artifacts"] if a["file"] == outer["file"])
replacement="metadata" if outer["role"] != "metadata" else "bootloader"
outer["role"]=inner["role"]=replacement
json.dump(d,open(p,"w"),indent=2)
PY
refuses "outer and embedded roles consistently relabelled" "$D"

D=$(fresh)
if python3 - "$D/BUILD-INPUTS.json" "$D" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); root=pathlib.Path(sys.argv[2]); d=json.loads(p.read_text())
info=list(d["boards"].values())[0]
if not any(a["role"] == "factory" for a in info["artifacts"]):
    raise SystemExit(3)
kept=[]
for item in info["artifacts"]:
    if item["role"] == "bootloader":
        (root/item["path"]).unlink()
    else:
        kept.append(item)
next(a for a in kept if a["role"] == "factory")["role"]="bootloader"
info["artifacts"]=kept
p.write_text(json.dumps(d,indent=2)+"\n")
PY
then
    refuses "factory relabelled after deleting true bootloaders" "$D"
else
    rc=$?
    [ "$rc" -eq 3 ] || bad "could not construct factory-as-bootloader mutation"
fi

D=$(fresh); echo "stowaway" > "$D/$BOARD/undeclared.bin"
refuses "undeclared file present" "$D"

D=$(fresh); rm -f "$D/$BOARD/"*squashfs-sysupgrade.itb
refuses "declared file missing" "$D"

D=$(fresh); F=$(ls "$D/$BOARD/"*squashfs-sysupgrade.itb); printf 'x' >> "$F"
refuses "artifact content changed after collection" "$D"

D=$(fresh)
python3 - "$D/BUILD-INPUTS.json" "$D" <<'PY'
import hashlib, json, pathlib, sys
inputs, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
data = json.loads(inputs.read_text())
board, info = next(iter(data["boards"].items()))
outer = next(a for a in info["artifacts"]
             if a["role"] == "metadata" and a["file"].endswith(".manifest"))
path = root / outer["path"]
with path.open("a") as f:
    f.write("umbim - 2025.05.11-r1\n")
content = path.read_bytes()
outer["sha256"], outer["size"] = hashlib.sha256(content).hexdigest(), len(content)
inner = next(a for a in info["build_provenance"]["artifacts"] if a["file"] == outer["file"])
inner["sha256"], inner["size"] = outer["sha256"], outer["size"]
inputs.write_text(json.dumps(data, indent=2) + "\n")
PY
refuses "unsupported MBIM package present in image manifest" "$D"

# ── the firmware policy, per role ──
# The blob appended raw is enough: the kernel check searches the decompressed
# component, and the raw scan searches the file, so each role is exercised with
# the same mutation rather than six different ones.
BLOBTMP=$(mktemp -d)
tar -xf "$LFW" -C "$BLOBTMP" --wildcards "*/aeonsemi/as21x1x_fw.bin" 2>/dev/null || true
BLOB=$(find "$BLOBTMP" -name as21x1x_fw.bin | head -1)
[ -n "$BLOB" ] || die "no reference firmware in $LFW"

for role in bootloader flashkit metadata; do
    D=$(fresh)
    F=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for b,i in d['boards'].items():
    for a in i['artifacts']:
        if a['role']==sys.argv[2]: print(a['path']); break
    else: continue
    break" "$D/BUILD-INPUTS.json" "$role")
    [ -n "$F" ] || continue
    cat "$BLOB" >> "$D/$F"
    # Re-declare so the mutation is tested by the policy check rather than
    # stopped by the hash check that runs first.
    python3 - "$D/BUILD-INPUTS.json" "$D" "$F" <<'PY'
import hashlib,json,os,sys
p,root,rel=sys.argv[1:4]; d=json.load(open(p))
h=hashlib.sha256(open(os.path.join(root,rel),"rb").read()).hexdigest()
for b,i in d["boards"].items():
    for a in i["artifacts"]:
        if a["path"]==rel:
            a["sha256"]=h; a["size"]=os.path.getsize(os.path.join(root,rel))
            for side in i["build_provenance"]["artifacts"]:
                if side["file"]==a["file"]:
                    side["sha256"]=a["sha256"]; side["size"]=a["size"]
json.dump(d,open(p,"w"),indent=2)
PY
    refuses "firmware appended to a $role artifact" "$D"
done

echo
if [ "$FAILED" -eq 0 ]; then
    ok "every case behaved as required"
else
    die "$FAILED case(s) did not"
fi
