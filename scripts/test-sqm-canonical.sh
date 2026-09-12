#!/bin/bash
# Executable development/build gate for the sqm canonical takeover.
#
# Symmetric to test-mwan3-canonical.sh.  sqm and mwan3 are the only two configs
# the product manages as a whole file, and both must satisfy the same contract:
# a product state is never rewritten, and anything else is reset to canonical
# rather than preserved into a subsystem the backend refuses to serve.
#
# The embedded stock fixture below is a TEST INPUT, not a fingerprint the
# takeover matches against.  The decision is "is this ours"; upstream is free to
# change its example without breaking any board's first boot.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}
FEEDS_DIR=${BPIR_FEEDS_DIR:-$(dirname "$BUILD_DIR")/bpirouter-feeds}
INIT_SCRIPT="$FEEDS_DIR/net/bpirouter-base/files/etc/uci-defaults/12-bpirouter-sqm-canonical"
BASE_MAKEFILE="$FEEDS_DIR/net/bpirouter-base/Makefile"
STRICT_AWK="$FEEDS_DIR/net/bpirouter-base/files/usr/libexec/bpirouter-sqm-strict.awk"

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -x "$INIT_SCRIPT" ] || fail "missing executable canonicalizer: $INIT_SCRIPT"
[ -f "$STRICT_AWK" ] || fail "missing strict reader: $STRICT_AWK"

canonical_hash=$(sed -n "s/^CANONICAL_SHA256='\([^']*\)'$/\1/p" "$INIT_SCRIPT")
[ -n "$canonical_hash" ] || fail "canonicalizer canonical hash constant is missing"
if grep -q "^STOCK_SHA256=" "$INIT_SCRIPT"; then
	fail "canonicalizer pins an upstream fingerprint; the decision must be 'is this ours'"
fi

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/etc/config"
CONFIG="$TEST_ROOT/etc/config/sqm"

run_script() {
	BPIR_SQM_CONFIG="$CONFIG" BPIR_LOGGER_BIN=true \
		BPIR_SQM_STRICT_AWK="$STRICT_AWK" "$INIT_SCRIPT"
}

assert_unchanged_success() {
	local fixture=$1 before inode meta
	cp "$fixture" "$CONFIG"
	before=$(sha256sum "$CONFIG" | awk '{print $1}')
	inode=$(stat -c %i "$CONFIG")
	meta=$(stat -c '%s:%a:%Y:%Z' "$CONFIG")
	run_script
	[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$before" ] || \
		fail "product fixture was modified: $(basename "$fixture")"
	[ "$(stat -c %i "$CONFIG")" = "$inode" ] || \
		fail "product fixture was replaced: $(basename "$fixture")"
	[ "$(stat -c '%s:%a:%Y:%Z' "$CONFIG")" = "$meta" ] || \
		fail "product fixture was written: $(basename "$fixture")"
}

assert_reset() {
	local fixture=$1
	cp "$fixture" "$CONFIG"
	run_script >"$TEST_ROOT/reset.out" 2>"$TEST_ROOT/reset.err" || \
		fail "canonicalizer errored on non-product fixture: $(basename "$fixture")"
	[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$canonical_hash" ] || \
		fail "non-product fixture was not reset to canonical: $(basename "$fixture")"
	if [ -s "$CONFIG" ]; then
		fail "canonical sqm state is not empty: $(basename "$fixture")"
	fi
	[ "$(stat -c %a "$CONFIG")" = 600 ] || \
		fail "reset config is not mode 0600: $(basename "$fixture")"
}

# The exact bytes sqm-scripts 1.7.2 installs, as measured on a v1.5 release
# image.  This is the state that took QoS down before the takeover existed.
cat >"$TEST_ROOT/stock" <<'EOF'

config queue 'eth1'
        option enabled '0'
        option interface 'eth1'
        option download '85000'
        option upload '10000'
        option qdisc 'cake'
        option script 'piece_of_cake.qos'
        option qdisc_advanced '0'
        option ingress_ecn 'ECN'
        option egress_ecn 'ECN'
        option qdisc_really_really_advanced '0'
        option itarget 'auto'
        option etarget 'auto'
        option linklayer 'none'
        option use_mq '0'
EOF

cat >"$TEST_ROOT/active" <<'EOF'
config queue 'bpir_sqm_wan'
	option interface 'br-wan'
	option enabled '1'
	option download '30000'
	option upload '10000'
	option qdisc 'cake'
	option script 'piece_of_cake.qos'
	option linklayer 'ethernet'
	option overhead '44'
	option bpir_managed '1'
EOF

cat >"$TEST_ROOT/active-disabled" <<'EOF'
config queue 'bpir_sqm_wan'
	option interface 'usb0'
	option enabled '0'
	option download '1'
	option upload '1'
	option qdisc 'fq_codel'
	option script 'simple.qos'
	option linklayer 'ethernet'
	option overhead '44'
	option bpir_managed '1'
EOF

# A product queue plus a hand/LuCI-added second queue: the exact shape that
# makes the tc plane undefined, and the reason this config is owned whole-file.
{ cat "$TEST_ROOT/active"; printf "\nconfig queue 'eth0'\n\toption enabled '1'\n\toption interface 'eth0'\n"; } \
	>"$TEST_ROOT/second-queue"

: >"$TEST_ROOT/empty"
chmod 0600 "$TEST_ROOT/empty"

# Stock becomes the canonical empty state.
assert_reset "$TEST_ROOT/stock"

# A second invocation must not rewrite or rename the already-canonical file.
canonical_inode=$(stat -c %i "$CONFIG")
canonical_meta=$(stat -c '%s:%a:%Y:%Z' "$CONFIG")
run_script
[ "$(stat -c %i "$CONFIG")" = "$canonical_inode" ] || fail "second run replaced canonical config"
[ "$(stat -c '%s:%a:%Y:%Z' "$CONFIG")" = "$canonical_meta" ] || fail "second run wrote canonical config"

# Product states are zero-write successes.
assert_unchanged_success "$TEST_ROOT/empty"
assert_unchanged_success "$TEST_ROOT/active"
assert_unchanged_success "$TEST_ROOT/active-disabled"

# Foreign and partial states are reset.
assert_reset "$TEST_ROOT/second-queue"

# Every semantic field of the ACTIVE fixture must be load-bearing: a reader too
# loose here would hand the backend a state qos.get cannot serve.
mkdir -p "$TEST_ROOT/active-mutations"
python3 - "$TEST_ROOT/active" "$TEST_ROOT/active-mutations" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text().splitlines(keepends=True)
out = Path(sys.argv[2])
n = 0
for idx, line in enumerate(source):
    if not re.match(r"^\s*(config|option|list)\s", line):
        continue
    for field, match in enumerate(re.finditer(r"'[^']*'|[^\s]+", line.rstrip("\n")), 1):
        token = match.group(0)
        # A space is illegal in every field: quoted values reject it by regex
        # or vocabulary, and bare tokens split into an extra field.  Appending
        # a word instead would produce a still-legal interface name.
        replacement = token[:-1] + " mutated'" if token.startswith("'") else token + " mutated"
        mutant = source.copy()
        mutant[idx] = line[:match.start()] + replacement + line[match.end():]
        n += 1
        (out / f"active-{n:03d}-line-{idx + 1}-part-{field}").write_text("".join(mutant))
    # A dropped option must not be readable as a product state either.
    dropped = source.copy()
    del dropped[idx]
    n += 1
    (out / f"drop-{n:03d}-line-{idx + 1}").write_text("".join(dropped))
if n == 0:
    raise SystemExit("active fixture contained no semantic fields")
PY
active_mutation_count=0
for mutant in "$TEST_ROOT"/active-mutations/*; do
	assert_reset "$mutant"
	active_mutation_count=$((active_mutation_count + 1))
done
[ "$active_mutation_count" -gt 30 ] || \
	fail "active mutation coverage unexpectedly small: $active_mutation_count"

# Mutating the stock fixture must never produce something mistaken for ours.
mkdir -p "$TEST_ROOT/stock-mutations"
python3 - "$TEST_ROOT/stock" "$TEST_ROOT/stock-mutations" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text().splitlines(keepends=True)
out = Path(sys.argv[2])
n = 0
for idx, line in enumerate(source):
    if not re.match(r"^\s*(config|option|list)\s", line):
        continue
    for field, match in enumerate(re.finditer(r"'[^']*'|[^\s]+", line.rstrip("\n")), 1):
        token = match.group(0)
        # A space is illegal in every field: quoted values reject it by regex
        # or vocabulary, and bare tokens split into an extra field.  Appending
        # a word instead would produce a still-legal interface name.
        replacement = token[:-1] + " mutated'" if token.startswith("'") else token + " mutated"
        mutant = source.copy()
        mutant[idx] = line[:match.start()] + replacement + line[match.end():]
        n += 1
        (out / f"stock-{n:03d}-line-{idx + 1}-part-{field}").write_text("".join(mutant))
if n == 0:
    raise SystemExit("stock fixture contained no semantic fields")
PY
stock_mutation_count=0
for mutant in "$TEST_ROOT"/stock-mutations/*; do
	assert_reset "$mutant"
	stock_mutation_count=$((stock_mutation_count + 1))
done
[ "$stock_mutation_count" -gt 30 ] || \
	fail "stock mutation coverage unexpectedly small: $stock_mutation_count"

# If the real upstream file is available, it must behave exactly like the
# embedded copy.  Its bytes are never required to match.
REAL_STOCK=${BPIR_SQM_STOCK:-}
if [ -n "$REAL_STOCK" ] && [ -f "$REAL_STOCK" ]; then
	assert_reset "$REAL_STOCK"
fi

# Unsafe inputs fail closed rather than being replaced.
ln -sf /etc/passwd "$TEST_ROOT/etc/config/sqm.link"
if BPIR_SQM_CONFIG="$TEST_ROOT/etc/config/sqm.link" BPIR_LOGGER_BIN=true \
	BPIR_SQM_STRICT_AWK="$STRICT_AWK" "$INIT_SCRIPT" 2>/dev/null; then
	fail "symlinked config was accepted"
fi
[ "$(readlink "$TEST_ROOT/etc/config/sqm.link")" = /etc/passwd ] || fail "symlink was followed"

cp "$TEST_ROOT/stock" "$CONFIG"
if BPIR_SQM_CONFIG="$CONFIG" BPIR_LOGGER_BIN=true \
	BPIR_SQM_STRICT_AWK="$TEST_ROOT/absent.awk" "$INIT_SCRIPT" 2>/dev/null; then
	fail "missing strict reader was accepted"
fi
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$(sha256sum "$TEST_ROOT/stock" | awk '{print $1}')" ] || \
	fail "config was modified without a usable strict reader"

rm -f "$CONFIG"
if run_script 2>/dev/null; then
	fail "missing config was accepted"
fi

# Packaging and board-selection checks bind the source test to every rootfs.
grep -Fq '12-bpirouter-sqm-canonical $(1)/etc/uci-defaults/' "$BASE_MAKEFILE" || \
	fail "bpirouter-base does not install the sqm canonicalizer"
grep -Fq 'bpirouter-sqm-strict.awk $(1)/usr/libexec/' "$BASE_MAKEFILE" || \
	fail "bpirouter-base does not install the strict sqm reader"
for board in bpi-r3-mini bpi-r3 bpi-r4-lite bpi-r4-pro bpi-r4 openwrt-one; do
	config="$BUILD_DIR/config/$board.config"
	[ -f "$config" ] || fail "missing board config: $board.config"
	grep -Eq '^CONFIG_PACKAGE_bpirouter-base=y$' "$config" || fail "$(basename "$config") omits bpirouter-base"
	grep -Eq '^CONFIG_PACKAGE_sqm-scripts=y$' "$config" || fail "$(basename "$config") omits sqm-scripts"
	# Exclusive ownership is what makes resetting foreign state legitimate.
	if grep -Eq '^CONFIG_PACKAGE_luci-app-sqm=y$' "$config"; then
		fail "$(basename "$config") ships the LuCI SQM app; it is a second writer over a product-owned config"
	fi
done
for gate in "$BUILD_DIR/scripts/build-full.sh" "$BUILD_DIR/scripts/build-image.sh"; do
	grep -Fq '"$SCRIPT_DIR/test-sqm-canonical.sh"' "$gate" || \
		fail "$(basename "$gate") does not run the sqm build gate"
done

echo "PASS: sqm product-state takeover, zero-write idempotence, exclusive ownership, and six-board payload contract ($stock_mutation_count stock + $active_mutation_count active field mutations)"
