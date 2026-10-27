#!/bin/bash
# Executable development/build gate for the mwan3 canonical takeover.
#
# The takeover decides "is this state OURS", not "is this one known upstream
# file", so this gate no longer pins an upstream fingerprint.  It proves the
# two properties that matter instead: a product state is never rewritten, and
# anything else -- stock, foreign, partial, or a one-field mutation of either --
# is reset to the canonical state rather than preserved into an unserviceable
# multi-WAN.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
BUILD_DIR=${BPIR_BUILD_DIR:-$(dirname "$SCRIPT_DIR")}
FEEDS_DIR=${BPIR_FEEDS_DIR:-$(dirname "$BUILD_DIR")/bpirouter-feeds}
INIT_SCRIPT="$FEEDS_DIR/net/bpirouter-base/files/etc/uci-defaults/11-bpirouter-mwan3-canonical"
BASE_MAKEFILE="$FEEDS_DIR/net/bpirouter-base/Makefile"
STRICT_AWK="$FEEDS_DIR/net/bpirouter-base/files/usr/libexec/bpirouter-mwan3-strict.awk"
STOCK_CONFIG=${BPIR_MWAN3_STOCK:-$BUILD_DIR/openwrt/feeds/packages/net/mwan3/files/etc/config/mwan3}

fail() { echo "FAIL: $*" >&2; exit 1; }
[ -x "$INIT_SCRIPT" ] || fail "missing executable canonicalizer: $INIT_SCRIPT"
[ -f "$STOCK_CONFIG" ] || fail "missing frozen mwan3 stock config: $STOCK_CONFIG"

canonical_hash=$(sed -n "s/^CANONICAL_SHA256='\([^']*\)'$/\1/p" "$INIT_SCRIPT")
[ -n "$canonical_hash" ] || fail "canonicalizer canonical hash constant is missing"
# An upstream fingerprint must NOT come back: pinning one makes a single
# upstream byte change fail every board's first boot, and still preserves every
# other source of foreign state.
if grep -q "^STOCK_SHA256=" "$INIT_SCRIPT"; then
	fail "canonicalizer pins an upstream fingerprint again; the decision must be 'is this ours'"
fi

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/etc/config"
CONFIG="$TEST_ROOT/etc/config/mwan3"

run_script() {
	BPIR_MWAN3_CONFIG="$CONFIG" BPIR_LOGGER_BIN=true \
		BPIR_MWAN3_STRICT_AWK="$STRICT_AWK" "$INIT_SCRIPT"
}

assert_unchanged_success() {
	local fixture=$1 before inode meta
	cp "$fixture" "$CONFIG"
	before=$(sha256sum "$CONFIG" | awk '{print $1}')
	inode=$(stat -c %i "$CONFIG")
	meta=$(stat -c '%s:%a:%Y:%Z' "$CONFIG")
	run_script
	[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$before" ] || \
		fail "canonical active fixture was modified"
	[ "$(stat -c %i "$CONFIG")" = "$inode" ] || fail "canonical active fixture was replaced"
	[ "$(stat -c '%s:%a:%Y:%Z' "$CONFIG")" = "$meta" ] || fail "canonical active fixture was written"
}

# Anything that is not a product state must END UP canonical.  Preserving it
# would leave multi-WAN permanently unserviceable with no in-product way out,
# which is the failure this gate exists to prevent.
assert_reset() {
	local fixture=$1
	cp "$fixture" "$CONFIG"
	run_script >"$TEST_ROOT/reset.out" 2>"$TEST_ROOT/reset.err" || \
		fail "canonicalizer errored on non-product fixture: $(basename "$fixture")"
	[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$canonical_hash" ] || \
		fail "non-product fixture was not reset to canonical: $(basename "$fixture")"
	[ "$(stat -c %a "$CONFIG")" = 600 ] || \
		fail "reset config is not mode 0600: $(basename "$fixture")"
}

# Exact frozen stock is replaced by one exact globals-only state.
cp "$STOCK_CONFIG" "$CONFIG"
run_script
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$canonical_hash" ] || \
	fail "stock example did not become the canonical state"
[ "$(stat -c %a "$CONFIG")" = 600 ] || fail "canonical config is not mode 0600"
[ "$(grep -Ec '^config globals .globals.$' "$CONFIG")" -eq 1 ] || fail "canonical globals section is missing"
[ "$(grep -Ec '^config (interface|member|policy|rule)' "$CONFIG")" -eq 0 ] || \
	fail "canonical state retained a managed mwan3 object"
grep -Fq "option mmx_mask '0x3F00'" "$CONFIG"
grep -Fq "option bpir_managed '1'" "$CONFIG"

# A second invocation must not rewrite or rename the already-canonical file.
canonical_inode=$(stat -c %i "$CONFIG")
canonical_meta=$(stat -c '%s:%a:%Y:%Z' "$CONFIG")
run_script
[ "$(stat -c %i "$CONFIG")" = "$canonical_inode" ] || fail "second run replaced canonical config"
[ "$(stat -c '%s:%a:%Y:%Z' "$CONFIG")" = "$canonical_meta" ] || fail "second run wrote canonical config"
[ "$(sha256sum "$CONFIG" | awk '{print $1}')" = "$canonical_hash" ] || fail "second run changed canonical config"

# A complete product-active state is a zero-write success.  An incomplete
# product-looking state and arbitrary foreign state remain rejected.
cat >"$TEST_ROOT/active" <<'EOF'
config globals 'globals'
	option mmx_mask '0x3F00'
	option bpir_managed '1'
config interface 'wan'
	option enabled '1'
	option family 'ipv4'
	list track_ip '1.1.1.1'
	option track_method 'ping'
	option reliability '1'
	option count '1'
	option timeout '2'
	option interval '5'
	option down '3'
	option up '3'
	option bpir_managed '1'
config member 'wan_m1_w1'
	option interface 'wan'
	option metric '1'
	option weight '1'
	option bpir_managed '1'
config policy 'bpi_policy'
	list use_member 'wan_m1_w1'
	option last_resort 'unreachable'
	option bpi_mode 'failover'
config rule 'bpi_default'
	option dest_ip '0.0.0.0/0'
	option use_policy 'bpi_policy'
	option family 'ipv4'
EOF
cat >"$TEST_ROOT/partial-active" <<'EOF'
config globals 'globals'
	option mmx_mask '0x3F00'
	option bpir_managed '1'
config interface 'wan'
	option enabled '1'
config policy 'bpi_policy'
	option bpi_mode 'failover'
	list use_member 'wan_m1_w1'
config rule 'bpi_default'
	option use_policy 'bpi_policy'
EOF
cat >"$TEST_ROOT/foreign" <<'EOF'
config globals 'globals'
	option mmx_mask '0x3F00'
config interface 'operator_owned'
	option enabled '1'
EOF
sed -e "s/option enabled '1'/option enabled '0'/" \
	-e "/list use_member/d" "$TEST_ROOT/active" >"$TEST_ROOT/all-disabled-active"
assert_unchanged_success "$TEST_ROOT/active"
assert_reset "$TEST_ROOT/all-disabled-active"
assert_reset "$TEST_ROOT/partial-active"
assert_reset "$TEST_ROOT/foreign"

# A product state that merely looks complete must not survive: mutate every
# semantic field of the ACTIVE fixture and require each one to be reset.  This
# is the direction that matters -- a reader too loose here would hand the
# backend a state it cannot serve.
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
        # A space is illegal in every field; appending a word could still yield
        # a legal identifier and silently weaken the assertion.
        replacement = token[:-1] + " mutated'" if token.startswith("'") else token + " mutated"
        mutant = source.copy()
        mutant[idx] = line[:match.start()] + replacement + line[match.end():]
        n += 1
        (out / f"active-{n:03d}-line-{idx + 1}-part-{field}").write_text("".join(mutant))
if n == 0:
    raise SystemExit("active fixture contained no semantic fields")
PY
active_mutation_count=0
for mutant in "$TEST_ROOT"/active-mutations/*; do
	assert_reset "$mutant"
	active_mutation_count=$((active_mutation_count + 1))
done
[ "$active_mutation_count" -gt 50 ] || \
	fail "active mutation coverage unexpectedly small: $active_mutation_count"

# Mutate every semantic line of the upstream stock fixture.  No drift of it may
# ever be mistaken for a product state; every one must be reset.
mkdir -p "$TEST_ROOT/mutations"
python3 - "$STOCK_CONFIG" "$TEST_ROOT/mutations" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[1]).read_text().splitlines(keepends=True)
out = Path(sys.argv[2])
n = 0
for idx, line in enumerate(source):
    if not re.match(r"^\s*(config|option|list)\s", line):
        continue
    tokens = list(re.finditer(r"'[^']*'|[^\s]+", line.rstrip("\n")))
    if len(tokens) < 3:
        raise SystemExit(f"semantic stock line has incomplete fields: {idx + 1}")
    for field, match in enumerate(tokens, 1):
        token = match.group(0)
        if token.startswith("'"):
            replacement = token[:-1] + "__mutated'"
        else:
            replacement = token + "__mutated"
        changed = line[:match.start()] + replacement + line[match.end():]
        mutant = source.copy()
        mutant[idx] = changed
        n += 1
        (out / f"field-{n:03d}-line-{idx + 1}-part-{field}").write_text("".join(mutant))
if n == 0:
    raise SystemExit("stock fixture contained no semantic fields")
PY
mutation_count=0
for mutant in "$TEST_ROOT"/mutations/*; do
	assert_reset "$mutant"
	mutation_count=$((mutation_count + 1))
done
[ "$mutation_count" -gt 50 ] || fail "mutation coverage unexpectedly small: $mutation_count"

# Packaging and board-selection checks bind the source test to every rootfs.
grep -Fq '11-bpirouter-mwan3-canonical $(1)/etc/uci-defaults/' "$BASE_MAKEFILE" || \
	fail "bpirouter-base does not install the canonicalizer"
grep -Eq '^  DEPENDS:=\+mwan3([[:space:]]|$)' "$BASE_MAKEFILE" || \
	fail "bpirouter-base does not bind the mwan3 payload dependency"
for board in bpi-r3-mini bpi-r3 bpi-r4-lite bpi-r4-pro bpi-r4 openwrt-one; do
	config="$BUILD_DIR/config/$board.config"
	[ -f "$config" ] || fail "missing board config: $board.config"
	grep -Eq '^CONFIG_PACKAGE_bpirouter-base=y$' "$config" || fail "$(basename "$config") omits bpirouter-base"
	grep -Eq '^CONFIG_PACKAGE_mwan3=y$' "$config" || fail "$(basename "$config") omits mwan3"
	# Exclusive ownership is what makes resetting foreign state legitimate: a
	# second management plane over the same whole-file config would both create
	# states the backend refuses to serve AND have them silently reset later.
	if grep -Eq '^CONFIG_PACKAGE_luci-app-mwan3=y$' "$config"; then
		fail "$(basename "$config") ships the LuCI mwan3 app; it is a second writer over a product-owned config"
	fi
done
for gate in "$BUILD_DIR/scripts/build-full.sh" "$BUILD_DIR/scripts/build-image.sh"; do
	grep -Fq '"$SCRIPT_DIR/test-mwan3-canonical.sh"' "$gate" || \
		fail "$(basename "$gate") does not run the mwan3 build gate"
done

echo "PASS: mwan3 product-state takeover, zero-write idempotence, exclusive ownership, and six-board payload contract ($mutation_count stock + $active_mutation_count active field mutations)"
