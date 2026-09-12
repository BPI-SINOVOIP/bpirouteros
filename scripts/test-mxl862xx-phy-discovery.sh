#!/bin/bash
# Execute the actual MDIO callbacks and registration function with a fake bus.
set -euo pipefail
BUILD_DIR=$(cd -- "$(dirname -- "$0")/.." && pwd)
PATCH_DIR="$BUILD_DIR/patches/bpi-r4-pro/kernel"
scratch_dir=$(mktemp -d)
trap 'rm -r -- "$scratch_dir"' EXIT

for patch in "$PATCH_DIR"/930-*.patch "$PATCH_DIR"/931-*.patch; do
    git -C "$scratch_dir" apply --include='drivers/net/dsa/mxl862xx/*' "$patch"
done
source_file="$scratch_dir/drivers/net/dsa/mxl862xx/mxl862xx.c"
host_file="$scratch_dir/drivers/net/dsa/mxl862xx/mxl862xx-host.c"
extract_callbacks() {
    awk '/^static int mxl862xx_phy_read_mmd\(/ ||
         /^static int mxl862xx_phy_read_mii_bus\(/ ||
         /^static int mxl862xx_phy_write_mmd\(/ ||
         /^static int mxl862xx_phy_write_mii_bus\(/ ||
         /^static int mxl862xx_phy_read_c45_mii_bus\(/ ||
         /^static int mxl862xx_setup_mdio\(/ {copy=1}
         copy {print}
         copy && /^}/ {copy=0}' "$source_file" > "$scratch_dir/driver.inc"
}
run_crc_fixture() {
    awk '/^static int mxl862xx_issue_cmd\(/ ||
         /^static int mxl862xx_send_cmd\(/ ||
         /^int mxl862xx_api_wrap\(/ {copy=1}
         copy {print}
         copy && /^}/ {copy=0}' "$host_file" > "$scratch_dir/host.inc"
    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"$scratch_dir" \
        "$BUILD_DIR/scripts/tests/mxl862xx-crc-result.c" -o "$scratch_dir/crc-test" || return 1
    "$scratch_dir/crc-test"
}
run_fixture() {
    extract_callbacks
    "${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"$scratch_dir" \
        "$BUILD_DIR/scripts/tests/mxl862xx-phy-discovery.c" -o "$scratch_dir/test" || return 1
    "$scratch_dir/test"
}

# A baseline failure is required: the test must catch the observed omission,
# not merely execute the successful reads used by the patched driver.
if run_fixture > "$scratch_dir/baseline.log" 2>&1; then
    echo 'FAIL: the unpatched driver unexpectedly passes transient-failure discovery' >&2
    exit 1
fi
grep -Fq 'FAIL: transient PHY identity read must recover' "$scratch_dir/baseline.log" || {
    cat "$scratch_dir/baseline.log" >&2
    exit 1
}
if run_crc_fixture > "$scratch_dir/crc-baseline.log" 2>&1; then
    echo 'FAIL: the unpatched host unexpectedly preserves CRC classification' >&2
    exit 1
fi
grep -Fq 'FAIL: CRC result must survive worker completion' "$scratch_dir/crc-baseline.log" || {
    cat "$scratch_dir/crc-baseline.log" >&2
    exit 1
}
patch --batch --fuzz=0 -p1 -d "$scratch_dir" < "$PATCH_DIR/987-mxl862xx-retry-initial-phy-id.patch"
run_fixture
run_crc_fixture
echo 'PASS: unpatched PHY discovery fails; patched discovery is bounded and scoped'
