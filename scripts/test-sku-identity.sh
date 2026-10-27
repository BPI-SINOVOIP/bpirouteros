#!/bin/bash
# Guards the R4-Pro two-SKU identity contract. Reject an R4-Pro
# deliverable whose name does not say which board it is for, or a seventh SKU that
# joins the release set before it can be built. Both look like success.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d -t bpir-sku-identity-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

fail() { echo -e "\033[0;31m✗ $1\033[0m" >&2; exit 1; }
ok()   { echo "ok: $1"; }

PROV="$SCRIPT_DIR/release-build-provenance.py"

# ── 1. Frozen identities ──
# bpi-r4-pro keeps meaning the 8X exactly. Renaming it would silently re-point
# every historical artifact name, lock row and acceptance result at another SKU.
eval "$(
    . "$SCRIPT_DIR/boards.sh"
    board_init bpi-r4-pro
    printf 'EIGHT_PROFILE=%q\nEIGHT_IMPL=%q\n' "$PROFILE" "$BOARD_IMPLEMENTED"
    board_init bpi-r4-pro-4e
    printf 'FOURE_PROFILE=%q\nFOURE_IMPL=%q\nFOURE_FILES=%q\n' \
        "$PROFILE" "$BOARD_IMPLEMENTED" "$RELEASE_REQUIRED_FILES"
    printf 'VALID=%q\nPLANNED=%q\n' "$VALID_BOARDS" "$PLANNED_BOARDS"
)"
[ "$EIGHT_PROFILE" = bananapi_bpi-r4-pro-8x ] \
    || fail "bpi-r4-pro no longer maps to the 8X profile: $EIGHT_PROFILE"
[ "$FOURE_PROFILE" = bananapi_bpi-r4-pro-4e ] \
    || fail "bpi-r4-pro-4e maps to $FOURE_PROFILE, not bananapi_bpi-r4-pro-4e"
[ "$EIGHT_IMPL" = yes ] || fail "bpi-r4-pro is marked unimplemented"
ok "R4-Pro SKU identities are frozen and distinct"

# ── 1a. Implementation status matches what is actually on disk ──
# Asserting "4E is unimplemented" alone would pin today's state and have to be
# deleted at graduation -- the moment the checking matters most. Assert the
# invariant instead: a board may claim an implementation only if its config and
# patches exist, and a board in the release set must declare a deliverable set.
# Both survive graduation and both fail on a half-finished one.
# A config may exist while step 6 build admission is still closed; its mere
# presence is not a build result and must not force premature graduation.
BUILD_ROOT="$(dirname "$SCRIPT_DIR")"
while read -r board impl files; do
    [ -n "$board" ] || continue
    if [ "$impl" = yes ]; then
        [ -f "$BUILD_ROOT/config/$board.config" ] \
            || fail "$board claims an implementation but has no config/$board.config"
        [ -d "$BUILD_ROOT/patches/$board" ] \
            || fail "$board claims an implementation but has no patches/$board"
    fi
    case " $VALID " in
        *" $board "*)
            [ "$impl" = yes ] || fail "$board is in the release set but is not implemented"
            [ "$files" = has-files ] \
                || fail "$board is in the release set but declares no required artifacts" ;;
    esac
done <<REPORT
$(
    . "$SCRIPT_DIR/boards.sh"
    for b in $VALID_BOARDS $PLANNED_BOARDS; do
        board_init "$b" >/dev/null
        printf '%s %s %s\n' "$b" "$BOARD_IMPLEMENTED" \
            "$([ -n "$(printf '%s' "$RELEASE_REQUIRED_FILES" | tr -d '[:space:]')" ] \
                && echo has-files || echo no-files)"
    done
)
REPORT
ok "every board's implementation claim matches its config, patches and contract"

# ── 2. A planned board is not a release board ──
# VALID_BOARDS is written into the release lock and built by rebuild-all. An
# unbuildable member would make the release set unsatisfiable; a planned board
# that leaked into it would make a six-SKU release satisfy a seven-SKU lock.
case " $VALID " in
    *" bpi-r4-pro-4e "*)
        [ "$FOURE_IMPL" = yes ] \
            || fail "bpi-r4-pro-4e is in the release set but is not implemented" ;;
esac
case " $PLANNED $VALID " in
    *" bpi-r4-pro-4e "*) ;;
    *) fail "bpi-r4-pro-4e is registered nowhere" ;;
esac
ok "the planned SKU is registered without joining the release set"

# ── 3. Every R4-Pro artifact names its SKU ──
# The family prefix alone is ambiguous between two boards with different DDR
# size, external PHYs and boot chain, and a mis-flash is not recoverable from
# the file name afterwards.
python3 - "$PROV" <<'PY' || exit 1
import importlib.util, sys
spec = importlib.util.spec_from_file_location("rbp", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

base = "openwrt-mediatek-filogic-bananapi_bpi-r4-pro"
accept = [
    base + "-8x-squashfs-sysupgrade.itb",
    base + "-4e-squashfs-sysupgrade.itb",
    base + "-8x.manifest",
    "openwrt-mediatek-filogic-bananapi_bpi-r4-squashfs-sysupgrade.itb",
    "mt7986-ram-ddr4-bl2.bin",
]
reject = [
    base + "-squashfs-sysupgrade.itb",
    base + ".manifest",
    base + "-emmc-bl31-uboot.fip",
    base + "-8X-squashfs-sysupgrade.itb",   # case matters: profiles are lowercase
]
for name in accept:
    try:
        mod.require_sku_qualified(name, "test")
    except SystemExit as exc:
        sys.exit("rejected a well-formed name: %s (%s)" % (name, exc))
for name in reject:
    try:
        mod.require_sku_qualified(name, "test")
    except SystemExit:
        continue
    sys.exit("accepted an R4-Pro artifact that does not name its SKU: " + name)

if mod.BOARD_BASES["bpi-r4-pro"] != base + "-8x":
    sys.exit("bpi-r4-pro is no longer bound to the 8X artifact base")
if mod.BOARD_BASES["bpi-r4-pro-4e"] != base + "-4e":
    sys.exit("bpi-r4-pro-4e is no longer bound to the 4E artifact base")
if len(set(mod.BOARD_BASES.values())) != len(mod.BOARD_BASES):
    sys.exit("two build IDs share one artifact base")
PY
ok "R4-Pro artifacts without an 8x/4e SKU tag are refused"

# ── 4. The firmware policy dispatch fails closed ──
# board_init already rejects an unknown board, so the old default arm could only
# ever answer for a board that IS registered but was forgotten here -- and it
# answered "no firmware needed", which is indistinguishable from a real verdict.
grep -q 'NEEDS_FW=yes' "$SCRIPT_DIR/check-firmware-policy.sh" \
    || fail "check-firmware-policy no longer decides firmware need per board"
awk '/^case "\$BOARD" in/,/^esac/' "$SCRIPT_DIR/check-firmware-policy.sh" \
    | grep -Eq '^\s*\*\)\s*die ' \
    || fail "check-firmware-policy board dispatch has no fail-closed default"
awk '/^case "\$BOARD" in/,/^esac/' "$SCRIPT_DIR/check-firmware-policy.sh" \
    | grep -Eq '^\s*\*\)\s*NEEDS_FW=no' \
    && fail "check-firmware-policy default still answers 'no firmware' for an unlisted board"
grep -q 'bpi-r4-pro-4e) *NEEDS_FW=no' "$SCRIPT_DIR/check-firmware-policy.sh" \
    || fail "the 4E firmware verdict is not registered explicitly"
ok "firmware policy names every board and fails closed on the rest"

# ── 5. The release-file contract has no silent empty default ──
# A board registered above but forgotten in the second case used to get an empty
# required-file set, and an empty set accepts any output, including none.
# Anchor on RELEASE_BASE: board_init contains two `case "$BOARD"` blocks and the
# identity one always had a default arm, so a range starting at the first match
# would pass while the contract block below it had none.
awk '/^[[:space:]]*RELEASE_BASE=/{found=1} found' "$SCRIPT_DIR/boards.sh" \
    | awk '/^    esac/{exit} {print}' \
    | grep -Eq '^\s*\*\)' \
    || fail "boards.sh release-file contract has no default arm"
( . "$SCRIPT_DIR/boards.sh"; board_init not-a-board ) >/dev/null 2>&1 \
    && fail "board_init accepted an unknown board"
ok "an unregistered board cannot obtain an empty release-file contract"

# ── 6. The refusal reaches the operator, at the real entry points ──
# A guard that exits non-zero is not enough: the point is that the reason names
# the missing build prerequisites. An undefined helper would still block the build while
# printing "die: command not found", and a status-only assertion would call that
# a pass. So each entry point is run for real and its text is checked.
#
# prepare and build-full are pointed at a scratch tree through BPIR_BUILD_DIR /
# BPIR_WORK_DIR. Not for tidiness: if the guard ever regresses, prepare runs on
# past it and rewrites whatever tree it was given -- the very regression this
# checks for would otherwise clear the prepare marker of the working tree. Only
# an isolated target makes the negative case safe to assert. build-image derives
# its tree from its own location and needs none: it reaches the guard before it
# touches anything.
SCRATCH="$TMP/scratch-build"
mkdir -p "$SCRATCH/openwrt" "$SCRATCH/config"
printf 'board=bpi-r4-pro-4e\nui_mode=none\nrelease_bound=0\ndevelopment_bound=0\n' \
    >"$SCRATCH/openwrt/.bpirouter-prepared-board"

entry_refusal() {
    local entry="$1"; shift
    local out rc
    set +e
    out=$(BPIR_BUILD_DIR="$SCRATCH" BPIR_WORK_DIR="$SCRATCH/openwrt" \
          bash "$SCRIPT_DIR/$entry" "$@" 2>&1)
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$entry accepted a board with no implementation"
    printf '%s' "$out" | grep -q 'command not found' \
        && fail "$entry refused via an undefined helper: $(printf '%s' "$out" | tail -1)"
    printf '%s' "$out" | grep -Fq 'frozen identity' \
        || fail "$entry did not say the identity is frozen but unimplemented: $(printf '%s' "$out" | tail -1)"
    printf '%s' "$out" | grep -Fq 'development' \
        || fail "$entry refusal does not point at the required development mode"
}

entry_refusal prepare.sh --board bpi-r4-pro-4e --without-proprietary-ui
entry_refusal build-full.sh --board bpi-r4-pro-4e
entry_refusal build-image.sh --board bpi-r4-pro-4e
ok "prepare, build-full and build-image each refuse 4E with the reason"

echo "PASS: R4-Pro two-SKU identity, artifact SKU tagging and fail-closed board dispatch"

# Run the actual coordinator selection block without its source-sync/build
# side effects. Planned SKUs may be named once in development, never release.
python3 - "$SCRIPT_DIR" <<'PY'
import pathlib, shlex, subprocess, sys
scripts = pathlib.Path(sys.argv[1])
source = (scripts / 'rebuild-all.sh').read_text()
block = 'for ((i = 0; i < ${#BOARDS[@]}; i++)); do' + source.split('for ((i = 0; i < ${#BOARDS[@]}; i++)); do', 1)[1].split('read -r -a SUPPORTED_BOARDS', 1)[0]
for mode, boards, accepted in [('development', ['bpi-r4-pro-4e'], True),
                              ('release', ['bpi-r4-pro-4e'], False),
                              ('development', ['bpi-r4-pro-4e'] * 2, False)]:
    setup = f'source {shlex.quote(str(scripts / "boards.sh"))}; MODE={mode}; BOARDS=({" ".join(boards)}); '
    result = subprocess.run(['bash', '-ec', setup + block], capture_output=True)
    assert (result.returncode == 0) == accepted, (mode, boards, result.stderr)
print('PASS: planned 4E development admission, release exclusion and duplicate refusal')
PY
