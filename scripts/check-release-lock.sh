#!/bin/bash
# Copyright (C) 2026 Ning <mimallaus@gmail.com>
# check-release-lock.sh — verify a lock still describes this tree.
#
# A lock that exists is not a lock that matches. Everything downstream treats it
# as authoritative -- the public tree publishes it, the UI staging trusts its
# hashes -- so it has to be checked against reality at the point of use, not
# assumed correct because a file is present.
#
# Same contract as check-prepared.sh and check-artifacts.sh: report and stop,
# never repair. Regenerating a lock to make it match is how a release ends up
# described by inputs that were never the ones frozen.
#
# Two scopes, because two different places verify a lock and only one of them
# can see everything it names:
#
#   workspace  the internal build workspace, where the three source repositories
#              are present as git checkouts. Verifies everything.
#   tree       a published tree, which has no sibling repositories and no git
#              history -- bpirouter-ui is proprietary and is not in it at all.
#              Verifies what that tree can actually show: the OpenWrt checkout,
#              feeds.conf, and every patch and config by content hash.
#
# Requiring the workspace scope in a published tree would demand private
# repositories a customer will never have, so artifact builds there could never
# start. Dropping the check entirely would hold the customer path to a weaker
# standard than ours. Neither is acceptable; the split is.
#
# Usage: check-release-lock.sh [--scope workspace|tree] [--downloads-lock <file>] <lock.json>
set -eo pipefail

SCOPE=workspace
DLOCK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --scope) SCOPE="$2"; shift 2 ;;
        --downloads-lock) DLOCK="$2"; shift 2 ;;
        *) break ;;
    esac
done
case "$SCOPE" in workspace|tree) ;; *) echo "unknown scope: $SCOPE" >&2; exit 2 ;; esac

LOCK="$1"
[ -n "$LOCK" ] || { echo "usage: check-release-lock.sh [--scope workspace|tree] [--downloads-lock <file>] <lock.json>" >&2; exit 2; }
[ -f "$LOCK" ] || { echo "no such lock: $LOCK" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}"
WORK_DIR="${BPIR_WORK_DIR:-$BUILD_DIR/openwrt}"
UI_DIR="${BPIR_UI_DIR:-$(dirname "$BUILD_DIR")/bpirouter-ui}"
FEEDS_DIR="${BPIR_FEEDS_DIR:-$(dirname "$BUILD_DIR")/bpirouter-feeds}"

G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'
FAILED=0
bad() { echo -e "${R}✗ $1${N}" >&2; FAILED=$((FAILED+1)); }

q() { python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    d = d[int(k)] if k.isdigit() else d.get(k, '')
print(d if not isinstance(d,(list,dict)) else json.dumps(d))
" "$LOCK" "$2" 2>/dev/null || echo ""; }

# ── Schema ──
[ "$(q "$LOCK" schema)" = "1" ] || bad "unsupported lock schema '$(q "$LOCK" schema)'"
RELEASE=$(q "$LOCK" release)
[ -n "$RELEASE" ] || bad "lock has no release id"
DOWNLOADS_SHA=$(q "$LOCK" downloads_lock_sha256)
[[ "$DOWNLOADS_SHA" =~ ^[0-9a-f]{64}$ ]] || bad "lock has no valid downloads_lock_sha256"
if [ -n "$(q "$LOCK" source_delivery)" ]; then
    [ "$SCOPE" = tree ] || bad "a public source delivery lock is not firmware build provenance"
    python3 "$SCRIPT_DIR/lib/public-source-lock.py" --tree "$BUILD_DIR" --check "$LOCK" \
        || bad "public source delivery does not match its original firmware lock"
fi
source "$SCRIPT_DIR/boards.sh"
bpir_select_release_boards "$RELEASE"
read -r -a RELEASE_BOARDS <<<"$VALID_BOARDS"
"$SCRIPT_DIR/lib/release-lock-contract.py" validate-input \
    --input-lock "$LOCK" --boards "${RELEASE_BOARDS[@]}" >/dev/null \
    || bad "input lock violates the release/download/APK contract"
if [ -n "$DLOCK" ]; then
    "$SCRIPT_DIR/lib/release-lock-contract.py" validate-binding \
        --input-lock "$LOCK" --downloads-lock "$DLOCK" --release "$RELEASE" \
        --boards "${RELEASE_BOARDS[@]}" >/dev/null \
        || bad "downloads lock is not the one frozen by the input lock"
fi

# ── Repositories (workspace scope only) ──
# Compared against the full revision. A tree that has moved on is not the tree
# the lock describes, however small the difference looks.
[ "$SCOPE" = workspace ] && for pair in "bpirouter-build:$BUILD_DIR" "bpirouter-ui:$UI_DIR" "bpirouter-feeds:$FEEDS_DIR"; do
    name=${pair%%:*}; dir=${pair#*:}
    want=$(q "$LOCK" "repos.$name")
    got=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")
    [ -n "$want" ] || { bad "lock does not record $name"; continue; }
    [ "$want" = "$got" ] || bad "$name is at ${got:0:12}, lock says ${want:0:12}"
    [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ] || \
        bad "$name has uncommitted changes; the lock cannot describe it"
done || true

# ── OpenWrt ──
if [ -d "$WORK_DIR/.git" ]; then
    want=$(q "$LOCK" openwrt.commit)
    got=$(git -C "$WORK_DIR" rev-parse HEAD)
    [ "$want" = "$got" ] || bad "openwrt is at ${got:0:12}, lock says ${want:0:12}"
else
    bad "no OpenWrt checkout to compare against"
fi

# ── Feeds ──
# feeds.conf is what prepare.sh installs from, so a drift here changes the
# packages in the image while every other input still matches.
python3 "$SCRIPT_DIR/lib/check-feed-inputs.py" "$LOCK" "$BUILD_DIR/feeds.conf" "$SCOPE" \
    || FAILED=$((FAILED+1))

# ── Patches and configs ──
# Content hashes, not just paths: an edited patch keeps its name.
python3 - "$LOCK" "$BUILD_DIR" "$SCOPE" <<'PY' || FAILED=$((FAILED+1))
import json,sys,hashlib,os
lock=json.load(open(sys.argv[1])); base=sys.argv[2]; scope=sys.argv[3]; ok=True
def sha(p):
    h=hashlib.sha256()
    with open(p,'rb') as f:
        for b in iter(lambda: f.read(65536), b''): h.update(b)
    return h.hexdigest()
# A non-source input whose redistribution rights are unconfirmed is REMOVED
# from a published tree on purpose, so in tree scope its absence is the correct
# state and its presence is the error. Merely relaxing "must exist" would have
# hidden a genuinely missing input; inverting it makes the lock the authority on
# what may be published, and catches the more serious mistake -- a blob that
# went out despite unconfirmed rights.
for key,label in (("patches","patch"),("configs","config"),("non_source_inputs","input")):
    for e in lock.get(key,[]):
        p=os.path.join(base,e["path"])
        withheld = key=="non_source_inputs" and e.get("redistribution")!="confirmed"
        if scope=="tree" and withheld:
            if os.path.exists(p):
                print(f"\033[0;31m✗ {e['path']} is published but its redistribution rights are unconfirmed\033[0m",file=sys.stderr); ok=False
            continue
        if not os.path.exists(p):
            print(f"\033[0;31m✗ {label} in lock is missing: {e['path']}\033[0m",file=sys.stderr); ok=False
        elif sha(p)!=e["sha256"]:
            print(f"\033[0;31m✗ {label} changed since the lock: {e['path']}\033[0m",file=sys.stderr); ok=False
    if key=="patches":
        onlock={e["path"] for e in lock.get(key,[])}
        ondisk={os.path.relpath(os.path.join(r,f),base)
                for r,_,fs in os.walk(os.path.join(base,"patches")) for f in fs if f.endswith(".patch")}
        for extra in sorted(ondisk-onlock):
            print(f"\033[0;31m✗ patch present but not in the lock: {extra}\033[0m",file=sys.stderr); ok=False
sys.exit(0 if ok else 1)
PY

if [ "$FAILED" -gt 0 ]; then
    echo -e "${R}✗ lock does not describe this tree ($FAILED problem(s))${N}" >&2
    echo "  Regenerating the lock to make it match would defeat its purpose." >&2
    echo "  Either check out what the lock names, or freeze a new release." >&2
    exit 1
fi
echo -e "${G}✓ lock matches the tree ($RELEASE, scope=$SCOPE)${N}"
