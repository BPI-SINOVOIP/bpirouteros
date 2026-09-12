#!/bin/bash
# stage-proprietary-ui.sh — unpack a released UI package into the feed.
#
# The trust anchor is the release lock, not the file being staged and not
# anything on the command line. Whoever can substitute an artifact can supply a
# matching hash with it, so a --sha256 flag would prove nothing; the expected
# hash has to come from a lock that was frozen before the artifact was chosen
# and verified against the tree separately.
#
# `apk extract --allow-untrusted` means "do not consult this machine's signature
# store", which a customer's machine has no reason to trust anyway. It is not a
# relaxation of verification -- the hash check above it is the verification, and
# it runs first.
#
# Usage: stage-proprietary-ui.sh --artifact <apk> --lock <lock.json>
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$BUILD_DIR/openwrt"


C='\033[0;36m'; G='\033[0;32m'; R='\033[0;31m'; N='\033[0m'
step() { echo -e "${C}▸ $1${N}"; }
ok()   { echo -e "${G}✓ $1${N}"; }
die()  { echo -e "${R}✗ stage-ui: $1${N}" >&2; exit 1; }

ARTIFACT=""; LOCK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --artifact) ARTIFACT="$2"; shift 2 ;;
        --lock)     LOCK="$2"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[ -f "$ARTIFACT" ] || die "--artifact: no such file: ${ARTIFACT:-<missing>}"
[ -f "$LOCK" ]     || die "--lock is required: the expected hash must come from a frozen lock, not from the caller"

source "$SCRIPT_DIR/boards.sh"
ARCH=$(pkg_arch)
# Resolved from feeds.conf, not assumed: a published tree keeps its feed inside
# itself, and the sibling path this used to hardcode pointed outside it.
FEED_ROOT="$(feed_dir)" || die "cannot resolve the bpirouter feed"
FEED_FILES="$FEED_ROOT/net/bpirouter-ui/files"
[ -d "$FEED_ROOT/net/bpirouter-ui" ] || die "no bpirouter-ui package at $FEED_ROOT"

# apk is a host tool OpenWrt builds itself. A tree that has only just been
# fetched has no staging_dir yet, so the first artifact build on a clean
# checkout has to bootstrap it -- the earlier version simply required it to
# exist, which held only because it was always tested on a tree that had
# already been built once.
APK="$WORK_DIR/staging_dir/host/bin/apk"
TMPLOG=$(mktemp -t bpir-apkboot-XXXXXX)
trap 'rm -f "$TMPLOG"' EXIT
if [ ! -x "$APK" ]; then
    step "Building host tools and the apk tool (first build on this tree; slow)..."
    # </dev/null is not optional. OpenWrt falls back to launching mconf -- the
    # menuconfig ncurses UI -- when it wants configuration input, and with
    # output redirected that appears as a build that never finishes rather than
    # a prompt. Closing stdin turns it into an immediate failure with a reason.
    #
    # The log is kept and shown on failure for the same reason: the previous
    # version sent both streams to /dev/null, so "waiting for a terminal" and
    # "compiling" were indistinguishable from the outside.
    # tools/install first. apk's host build depends on lua/host, which unpacks
    # its source with libdeflate-gzip -- a tool from tools/, absent on a tree
    # that has never been built. Asking for the package target alone skips the
    # tools stage entirely and fails on a missing binary rather than on a
    # missing prerequisite, which reads as a broken package.
    #
    # This is not extra work: build-full.sh needs tools/ regardless, so all
    # this does is pay that cost at prepare instead of a few minutes later.
    if ! ( cd "$WORK_DIR" && make tools/install -j"$(nproc)" \
           </dev/null >"$TMPLOG" 2>&1 ); then
        tail -20 "$TMPLOG" | sed 's/^/    /' >&2
        die "could not build the host tools (log above).
  These are needed before any host package can be built. Run a full build on
  this tree once, or use --without-proprietary-ui."
    fi
    if ! ( cd "$WORK_DIR" && make package/system/apk/host/compile -j"$(nproc)" \
           </dev/null >"$TMPLOG" 2>&1 ); then
        tail -20 "$TMPLOG" | sed 's/^/    /' >&2
        die "could not build the host apk tool (log above).
  Artifact mode needs it to unpack the package. Run a full build on this tree
  once, or use --without-proprietary-ui."
    fi
    [ -x "$APK" ] || die "apk host build reported success but $APK is not there"
    ok "host apk built"
fi

# ── 1. What the lock says this architecture should have ──
# File name last: it is the one field that could contain a space, and read's
# final variable absorbs the remainder. Absent fields are emitted as "-" rather
# than empty, because an empty field would shift every later one along.
read -r WANT_SHA WANT_NAME WANT_VER WANT_FILE <<<"$(python3 - "$LOCK" "$ARCH" <<'PY'
import json,sys
lock=json.load(open(sys.argv[1])); arch=sys.argv[2]
for a in lock.get("ui_artifacts",[]):
    if a.get("arch")==arch:
        print(a.get("sha256","-"), a.get("name","-") or "-",
              a.get("version","-") or "-", a.get("file",""))
        break
PY
)"
[ -n "$WANT_SHA" ] || die "the lock records no UI artifact for $ARCH.
  Artifact mode is unavailable for this release. Either use a release whose lock
  carries one, or build with --without-proprietary-ui."

# ── 2. Hash first, before the file is opened by anything else ──
GOT_SHA=$(sha256sum "$ARTIFACT" | cut -d' ' -f1)
[ "$GOT_SHA" = "$WANT_SHA" ] || die "artifact does not match the lock
  expected  $WANT_SHA  ($WANT_FILE)
  actual    $GOT_SHA  ($(basename "$ARTIFACT"))"
ok "artifact matches the lock ($ARCH)"

# ── 2b. What the package says about itself ──
# The hash proves this is the file the lock names. It cannot show that the lock
# names it correctly: whoever edits an entry to file a package under another
# architecture edits the hash in the same pass. Reading the package settles that
# independently of the lock. Locks written before these fields existed record
# "-" and are only checked for architecture.
GOT_ARCH=$("$APK" adbdump "$ARTIFACT" 2>/dev/null | sed -n 's/^  arch: //p' | head -1)
[ -n "$GOT_ARCH" ] || die "cannot read the architecture out of $(basename "$ARTIFACT")"
[ "$GOT_ARCH" = "$ARCH" ] \
    || die "the lock files this artifact under $ARCH, but the package declares $GOT_ARCH"
if [ "$WANT_NAME" != "-" ]; then
    GOT_NAME=$("$APK" adbdump "$ARTIFACT" 2>/dev/null | sed -n 's/^  name: //p' | head -1)
    GOT_VER=$("$APK" adbdump "$ARTIFACT" 2>/dev/null | sed -n 's/^  version: //p' | head -1)
    [ "$GOT_NAME" = "$WANT_NAME" ] && [ "$GOT_VER" = "$WANT_VER" ] \
        || die "the lock records $WANT_NAME $WANT_VER, but the package is $GOT_NAME $GOT_VER"
    ok "package identifies as $GOT_NAME $GOT_VER ($GOT_ARCH)"
fi

# ── 3. Extract to a temporary directory ──
TMP=$(mktemp -d -t bpir-ui-XXXXXX)
trap 'rm -rf "$TMP"' EXIT
step "Extracting..."
# apk does not create the destination, and reports the failure on stderr while
# exiting 0 -- so a redirect that hides stderr turns "nothing was extracted"
# into a silent success. Create it, and judge the result by what landed rather
# than by the exit code.
mkdir -p "$TMP/payload"
"$APK" extract --allow-untrusted --destination "$TMP/payload" "$ARTIFACT" >"$TMP/extract.log" 2>&1 || true
[ -n "$(find "$TMP/payload" -type f -print -quit 2>/dev/null)" ] || {
    sed 's/^/    /' "$TMP/extract.log" >&2
    die "apk extract produced nothing"
}

# ── 4. Payload allowlist ──
# Checked in both directions. Asserting that the two obvious files are present
# says nothing about what else came along, and a package that also drops an
# init script or a uci-default would change the device in ways nothing here
# reviewed.
step "Checking the payload..."
BAD=$(cd "$TMP/payload" && find . -type l 2>/dev/null || true)
[ -z "$BAD" ] || { echo "$BAD"; die "payload contains symlinks"; }
BAD=$(cd "$TMP/payload" && find . -mindepth 1 \
    -not -path './usr' -not -path './usr/bin' -not -path './usr/bin/*' \
    -not -path './usr/libexec' -not -path './usr/libexec/*' \
    -not -path './www' -not -path './www/bpirouter' -not -path './www/bpirouter/*' \
    -not -path './etc' -not -path './etc/init.d' -not -path './etc/init.d/*' \
    -not -path './etc/nginx' -not -path './etc/nginx/*' \
    -not -path './etc/uci-defaults' -not -path './etc/uci-defaults/*' \
    -not -path './usr/share' -not -path './usr/share/bpirouter' -not -path './usr/share/bpirouter/*' \
    -not -path './lib' -not -path './lib/upgrade' -not -path './lib/upgrade/*' \
    -not -path './lib/apk' -not -path './lib/apk/packages' -not -path './lib/apk/packages/*' \
    -not -path './etc/bpirouter-version' \
    -not -path './etc/bpirouter-ui-build.manifest' \
    -not -path './etc/bpirouter-product-payload.manifest' 2>/dev/null || true)
[ -z "$BAD" ] || { echo "$BAD" | head -10; die "payload has paths outside the allowlist"; }

# The required list is DERIVED from the package Makefile, not written out here.
# The hand-maintained version claimed to cover every unconditional install and
# missed five of eleven -- /etc/bpirouter-version, both init.d scripts and both
# uci-defaults -- so a truncated or hostile artifact passed staging and failed
# later at package compile, where it reads as a packaging fault. A list kept in
# step by hand drifts the moment the Makefile changes; one read from the
# Makefile cannot.
MK="$FEED_ROOT/net/bpirouter-ui/Makefile"
[ -f "$MK" ] || die "no package Makefile at $MK"
REQUIRED=$(python3 - "$MK" "$TMP/payload" <<'PYEOF'
import glob, os, re, sys
mk, payload = sys.argv[1:3]
req = []
for line in open(mk):
    m = re.match(r'\s*\$\(INSTALL_(?:BIN|DATA)\)\s+\./files/(\S+)\s+\$\(1\)/(\S+)', line)
    if not m:
        continue
    src, dest = m.group(1), m.group(2)
    # A destination ending in / takes the source's basename; otherwise it names
    # the file, which is how ./files/version becomes /etc/bpirouter-version.
    target = dest + src.split('/')[-1] if dest.endswith('/') else dest
    if '*' in target:
        matches = glob.glob(os.path.join(payload, target))
        if not matches:
            req.append(target)
        else:
            for match in sorted(matches):
                req.append(os.path.relpath(match, payload))
    else:
        req.append(target)
print('\n'.join(req))
PYEOF
)
[ -n "$REQUIRED" ] || die "could not read the install list from $MK"

while IFS= read -r req; do
    [ -n "$req" ] || continue
    [ -f "$TMP/payload/$req" ] || die "payload is missing $req, which the package installs unconditionally"
done <<<"$REQUIRED"

# www/ is copied wholesale by the Makefile rather than file by file, so it is
# checked separately.
[ -f "$TMP/payload/www/bpirouter/index.html" ] || die "payload has no www/bpirouter/index.html"

# apk records the package's own file list. Comparing the extraction against it
# catches a truncated or partially-written artifact that still hashed correctly
# on disk -- the hash proves the file is the one the lock names, not that
# extracting it produced everything the package declares.
LIST="$TMP/payload/lib/apk/packages/bpirouter-ui.list"
if [ -f "$LIST" ]; then
    MISSING=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$entry" in /*) rel="${entry#/}" ;; *) rel="$entry" ;; esac
        [ -e "$TMP/payload/$rel" ] || { echo "  declared but not extracted: $entry"; MISSING=$((MISSING+1)); }
    done < <(grep -E '^/?(usr|etc|www|lib)/' "$LIST" 2>/dev/null || true)
    [ "$MISSING" -eq 0 ] || die "$MISSING file(s) the package declares are not in the extraction"
fi
ok "payload within allowlist ($(find "$TMP/payload" -type f | wc -l) files)"

# ── 5. Replace the staging directory wholesale ──
# Emptied rather than overwritten: a file from a previous stage that this
# artifact does not carry would otherwise survive into the image, and the
# manifest below would not notice because it only lists what should be there.
step "Staging into $FEED_FILES ..."
rm -rf "$FEED_FILES"
mkdir -p "$FEED_FILES"
cp -a "$TMP/payload/usr/bin/bpirouter-apid"           "$FEED_FILES/"
cp -a "$TMP/payload/usr/bin/bpirouter-gen-cert"        "$FEED_FILES/"
[ -f "$TMP/payload/usr/bin/bpirouter-reboot-handoff" ] && cp -a "$TMP/payload/usr/bin/bpirouter-reboot-handoff" "$FEED_FILES/"
[ -d "$TMP/payload/usr/libexec" ] && { mkdir -p "$FEED_FILES/libexec"; cp -a "$TMP/payload/usr/libexec/." "$FEED_FILES/libexec/"; }
mkdir -p "$FEED_FILES/www"
cp -a "$TMP/payload/www/bpirouter/." "$FEED_FILES/www/"
for d in etc/init.d etc/uci-defaults; do
    [ -d "$TMP/payload/$d" ] && { mkdir -p "$FEED_FILES/$(basename "$d")"; cp -a "$TMP/payload/$d/." "$FEED_FILES/$(basename "$d")/"; }
done
[ -d "$TMP/payload/etc/nginx" ] && { mkdir -p "$FEED_FILES/nginx"; cp -a "$TMP/payload/etc/nginx/." "$FEED_FILES/nginx/"; }
[ -d "$TMP/payload/usr/share/bpirouter/nginx" ] && cp -a "$TMP/payload/usr/share/bpirouter/nginx/." "$FEED_FILES/nginx/"
[ -d "$TMP/payload/usr/share/bpirouter/gcom" ] && { mkdir -p "$FEED_FILES/gcom"; cp -a "$TMP/payload/usr/share/bpirouter/gcom/." "$FEED_FILES/gcom/"; }
[ -d "$TMP/payload/usr/share/bpirouter/acceptance" ] && { mkdir -p "$FEED_FILES/acceptance"; cp -a "$TMP/payload/usr/share/bpirouter/acceptance/." "$FEED_FILES/acceptance/"; }
[ -d "$TMP/payload/lib/upgrade/keep.d" ] && { mkdir -p "$FEED_FILES/keep.d"; cp -a "$TMP/payload/lib/upgrade/keep.d/." "$FEED_FILES/keep.d/"; }
cp -a "$TMP/payload/etc/bpirouter-version" "$FEED_FILES/version"
[ -f "$TMP/payload/etc/bpirouter-ui-build.manifest" ] && cp -a "$TMP/payload/etc/bpirouter-ui-build.manifest" "$FEED_FILES/.manifest"
[ -f "$TMP/payload/etc/bpirouter-product-payload.manifest" ] && cp -a "$TMP/payload/etc/bpirouter-product-payload.manifest" "$FEED_FILES/.payload-inventory"

# ── 6. Verify what actually landed ──
# Per file, against the payload it came from. "The directory is non-empty" is
# what a truncated copy also looks like.
step "Verifying staged files..."
MISMATCH=0
while IFS= read -r f; do
    rel=${f#"$FEED_FILES/"}
    src=""
    case "$rel" in
        bpirouter-apid|bpirouter-gen-cert|bpirouter-reboot-handoff) src="$TMP/payload/usr/bin/$rel" ;;
        libexec/*)  src="$TMP/payload/usr/$rel" ;;
        www/*)      src="$TMP/payload/www/bpirouter/${rel#www/}" ;;
        init.d/*)   src="$TMP/payload/etc/${rel}" ;;
        uci-defaults/*) src="$TMP/payload/etc/${rel}" ;;
        version)    src="$TMP/payload/etc/bpirouter-version" ;;
        .manifest)  src="$TMP/payload/etc/bpirouter-ui-build.manifest" ;;
        .payload-inventory) src="$TMP/payload/etc/bpirouter-product-payload.manifest" ;;
        nginx/nginx.conf) src="$TMP/payload/etc/nginx/nginx.conf" ;;
        nginx/*)    src="$TMP/payload/usr/share/bpirouter/${rel}" ;;
        gcom/*)     src="$TMP/payload/usr/share/bpirouter/${rel}" ;;
        acceptance/*) src="$TMP/payload/usr/share/bpirouter/${rel}" ;;
        keep.d/*)   src="$TMP/payload/lib/upgrade/${rel}" ;;
        *) echo "  staged file with no payload mapping: $rel"; MISMATCH=$((MISMATCH+1)); continue ;;
    esac
    [ -f "$src" ] || { echo "  staged but not in payload: $rel"; MISMATCH=$((MISMATCH+1)); continue; }
    cmp -s "$f" "$src" || { echo "  differs from payload: $rel"; MISMATCH=$((MISMATCH+1)); }
done < <(find "$FEED_FILES" -type f)
[ "$MISMATCH" -eq 0 ] || die "$MISMATCH staged file(s) do not match the payload"

ok "staged $(find "$FEED_FILES" -type f | wc -l) files from $(basename "$ARTIFACT")"
