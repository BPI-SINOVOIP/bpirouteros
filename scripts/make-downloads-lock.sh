#!/bin/bash
# make-downloads-lock.sh — describe every object in source-cache/.
#
# Usage: make-downloads-lock.sh --cache <dir> --tree <openwrt> --release <vX.Y.Z>
#                               --output <file> [--source-cache <dir>]
#
# Input is what collect-source-cache.sh produced: one manifest per board and the
# V=s log of the download that produced it. Provenance is read out of those logs
# rather than out of Makefiles, because the log records the call that actually
# fetched the file -- filename, the hash OpenWrt required, and the upstream URLs
# it was given:
#
#   download.pl "<dir>" "<file>" "<sha256>" "<url-filename>" "<mirror>"...
#
# Licence and package attribution come from the tree's own tmp/.packageinfo.
#
# This file deliberately does NOT carry redistribution conclusions. Those live
# in RELEASE-INPUTS.lock.json's non_source_inputs and only there: two records of
# the same legal question drift, and nothing then decides which one is right.
# Where an object here is also a non-source input, non_source_ref points at that
# entry instead of restating it.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
warn() { echo -e "${Y}! $1${N}"; }
die()  { echo -e "${R}✗ $1${N}" >&2; exit 1; }

CACHE=""; TREE=""; RELEASE=""; OUT=""; SRCCACHE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cache)        CACHE="$2"; shift 2 ;;
        --tree)         TREE="$2"; shift 2 ;;
        --release)      RELEASE="$2"; shift 2 ;;
        --output)       OUT="$2"; shift 2 ;;
        --source-cache) SRCCACHE="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -n "$CACHE" ] && [ -n "$TREE" ] && [ -n "$RELEASE" ] && [ -n "$OUT" ] \
    || die "usage: make-downloads-lock.sh --cache <dir> --tree <openwrt> --release <v> --output <file> [--source-cache <dir>]"
[ -d "$CACHE/manifest" ] || die "no manifests in $CACHE — run collect-source-cache.sh first"

step "Building downloads lock for $RELEASE"
PYTHONPATH="$SCRIPT_DIR/lib" python3 - "$CACHE" "$TREE" "$RELEASE" "$OUT" "$SRCCACHE" \
    "$BUILD_DIR/config/download-decisions.json" <<'PYEOF'
import json, os, re, sys, glob

cache, tree, release, out, srccache, dpath = sys.argv[1:7]
import pkgmeta          # PYTHONPATH is set to scripts/lib by the wrapper

# ── Per-board file sets ───────────────────────────────────────────────────────
boards, files = [], {}          # name -> {sha256, size, boards:set}
for mf in sorted(glob.glob(os.path.join(cache, "manifest", "*.tsv"))):
    board = os.path.basename(mf)[:-4]
    boards.append(board)
    for line in open(mf):
        sha, size, name = line.rstrip("\n").split("\t")
        e = files.setdefault(name, {"sha256": sha, "size": int(size), "boards": set()})
        # Same name, different bytes means one cache path would have to hold two
        # different objects. Nothing downstream can represent that, so it stops
        # here rather than becoming whichever copy was written last.
        if e["sha256"] != sha:
            sys.exit("FATAL: %s differs between boards: %s vs %s" % (name, e["sha256"], sha))
        e["boards"].add(board)

# ── Provenance from the download logs ─────────────────────────────────────────
ALIASES = {}
pm = os.path.join(tree, "scripts", "projectsmirrors.json")
if os.path.exists(pm):
    ALIASES = json.load(open(pm))

def expand(arg):
    """OpenWrt mirror aliases, resolved the way download.pl resolves them."""
    m = re.match(r"^(@[A-Z]+)(?:/(.*))?$", arg)
    if not m:
        return [arg] if "://" in arg else []
    base, sub = m.group(1), m.group(2) or ""
    return [u.rstrip("/") + ("/" + sub if sub else "") for u in ALIASES.get(base, [])]

prov = {}
for log in sorted(glob.glob(os.path.join(cache, "logs", "*.log"))):
    if log.endswith("-prepare.log"):
        continue
    for line in open(log, errors="replace"):
        i = line.find("download.pl ")
        if i < 0:
            continue
        args = re.findall(r'"([^"]*)"', line[i:])
        if len(args) < 3:
            continue
        name, want_hash, rest = args[1], args[2], args[3:]
        urls, raw = [], []
        for a in rest:
            if a.startswith("@") or "://" in a:
                raw.append(a)
                urls.extend(expand(a))
        p = prov.setdefault(name, {"expected_sha256": want_hash, "urls": [], "raw": [],
                                   "git": None, "git_commit": None})
        for u in urls:
            if u not in p["urls"]:
                p["urls"].append(u)
        for a in raw:
            if a not in p["raw"]:
                p["raw"].append(a)
        # Packages fetched from git have no mirror list: download.pl is called
        # with none and the shell falls through to a clone on the same line.
        g = re.search(r"git clone\s+(?:--\S+\s+)*(\S+://\S+?|git@\S+?)\s+\S", line[i:])
        if g and not p["git"]:
            p["git"] = g.group(1)
            c = re.search(r"git checkout ([0-9a-f]{7,40})", line[i:])
            if c:
                p["git_commit"] = c.group(1)

# ── Licence and package attribution ───────────────────────────────────────────
# Prefer the snapshot taken while the board was collected. The tree's own copy
# is rewritten by the next prepare, so using it makes attribution depend on what
# else happens to be running.
snaps = sorted(glob.glob(os.path.join(cache, "packageinfo", "*.packageinfo")))
by_source = {}
for s in snaps:
    for k, v in pkgmeta.from_packageinfo_file(s).items():
        e = by_source.setdefault(k, {"packages": set(), "licences": set(),
                                     "urls": set(), "makefiles": set(), "versions": set()})
        for f in e:
            e[f] |= v[f]
if not by_source:
    by_source = pkgmeta.from_packageinfo(tree)
by_prefix = pkgmeta.from_makefiles(tree)

# Decisions for objects no package claims. OpenWrt registers some Download
# rules unconditionally -- mac80211 fetches Broadcom firmware whether or not a
# b43 package is selected -- so being in the cache is not evidence that anything
# needs it. Which of those to publish cannot be derived, so it is recorded.
decisions = {}
if os.path.exists(dpath):
    for d in json.load(open(dpath)).get("objects", []):
        decisions[d["file"]] = d

objects, unattributed, nolicence, nourl, undecided, excluded = [], [], [], [], [], []
for name in sorted(files):
    f = files[name]
    p = prov.get(name, {})
    meta = pkgmeta.lookup(name, by_source, by_prefix)
    # The hash OpenWrt demanded and the hash the file has. They agree or the
    # build would have refused the file; recording both makes that checkable by
    # someone who was not here when it ran.
    want = p.get("expected_sha256") or None
    if want and want != f["sha256"]:
        sys.exit("FATAL: %s: build expected %s, cache holds %s" % (name, want, f["sha256"]))
    licences = sorted(meta["licences"]) if meta else []
    urls = p.get("urls") or []
    # An object no package claims needs a recorded decision. Not derivable:
    # usb-modeswitch-data arrives the same way the Broadcom firmware does, and
    # one of them is needed by something we build.
    dec = decisions.get(name)
    if not meta and not dec:
        undecided.append(name)
    if dec and not licences and dec.get("licence"):
        licences = [dec["licence"]]
    obj = {
        "path": "source-cache/" + name,
        "sha256": f["sha256"],
        "size": f["size"],
        "urls": urls,
        "url_aliases": p.get("raw") or [],
        "git_url": p.get("git"),
        "git_commit": p.get("git_commit"),
        "packages": sorted(meta["packages"]) if meta else [],
        "licence": licences[0] if len(licences) == 1 else (licences or None),
        "used_by_boards": sorted(f["boards"]),
        # Set only for objects whose redistribution is not settled by their own
        # licence; the conclusion itself stays in non_source_inputs.
        "non_source_ref": None,
        # include / exclude, for objects no package claims. Absent means the
        # object is claimed and needs no decision.
        "decision": (dec or {}).get("decision"),
        "decision_reason": (dec or {}).get("reason"),
    }
    if (dec or {}).get("decision") == "exclude":
        excluded.append(name)
        continue
    objects.append(obj)
    if not obj["packages"]:
        unattributed.append(name)
    if not licences:
        nolicence.append(name)
    if not urls and not obj["git_url"]:
        nourl.append(name)

json.dump({
    "schema": 1,
    "release": release,
    "boards": sorted(boards),
    "note": ("Every object in source-cache/, with the upstream it came from and "
             "the boards that needed it. Redistribution conclusions are not here: "
             "they live in RELEASE-INPUTS.lock.json non_source_inputs, referenced "
             "by non_source_ref."),
    "objects": objects,
}, open(out, "w"), indent=2, ensure_ascii=False)

# An unattributed object with no recorded decision stops the run. It means the
# build started pulling something new, and a release is the wrong place to
# notice that.
if undecided:
    sys.exit("FATAL: %d downloaded object(s) no package claims and no decision covers:\n  %s\n"
             "Record each in config/download-decisions.json (include or exclude, with the reason)."
             % (len(undecided), "\n  ".join(undecided)))
if excluded:
    sys.stderr.write("  excluded by decision (%d): %s\n" % (len(excluded), ", ".join(excluded)))
print("%d %d %d %d %d" % (len(objects), len(boards), len(unattributed), len(nolicence), len(nourl)))
for label, lst in (("no package", unattributed), ("no licence", nolicence), ("no url", nourl)):
    if lst:
        sys.stderr.write("  %s (%d): %s\n" % (label, len(lst), ", ".join(lst[:6])))

# ── Assemble the deduplicated cache ──────────────────────────────────────────
if srccache:
    os.makedirs(srccache, exist_ok=True)
    linked = 0
    keep = {os.path.basename(o["path"]) for o in objects}
    for name in sorted(files):
        if name not in keep:
            continue
        dst = os.path.join(srccache, name)
        if os.path.exists(dst):
            continue
        for b in sorted(files[name]["boards"]):
            src = os.path.join(cache, "dl-" + b, name)
            if os.path.exists(src):
                try:
                    os.link(src, dst)
                except OSError:
                    import shutil; shutil.copy2(src, dst)
                linked += 1
                break
    sys.stderr.write("  assembled %d objects into %s\n" % (linked, srccache))
PYEOF
