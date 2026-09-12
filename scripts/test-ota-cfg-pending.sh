#!/bin/bash
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"

check_contract_text() {
    local text=$1 helper alt
    helper=$(grep '^ab_verify_rollback=' <<<"$text")
    alt=$(grep '^altbootcmd=' <<<"$text")
    [ "$helper" = 'ab_verify_rollback=env load && test "$active_slot" = "$ab_expected_slot" && test "$altcount" = "$ab_expected_altcount" && test -z "$cfg_pending" && test "$upgrade_available" = 0 && test "$bootcount" = 0' ] || return 1
    # Both normal-switch and exhausted branches must gate every target boot on
    # save success followed by a reload from persistent storage and semantic
    # verification. A mere in-memory setenv or saveenv exit code is not enough.
    [ "$(grep -o 'setenv cfg_pending' <<<"$alt" | wc -l)" -eq 2 ] || return 1
    [ "$(grep -o 'if saveenv && run ab_verify_rollback ; then' <<<"$alt" | wc -l)" -eq 2 ] || return 1
    [ "$(grep -o 'rollback env verify failed - halting' <<<"$alt" | wc -l)" -eq 2 ] || return 1
    grep -Fq 'setenv ab_expected_slot $active_slot ; setenv ab_expected_altcount $altcount' <<<"$alt" || return 1
    grep -Fq 'if test "$active_slot" = b ; then setenv ab_expected_slot a ; setenv active_slot a ; else setenv ab_expected_slot b ; setenv active_slot b ; fi' <<<"$alt" || return 1
    grep -Fq 'setexpr ab_expected_altcount $altcount + 1 ; setexpr altcount $altcount + 1' <<<"$alt" || return 1
    ! grep -q 'setenv cfg_pending ; saveenv ; run' <<<"$alt" || return 1
}

check_contract_file() {
    check_contract_text "$(cat "$1")"
}

check_contract_file "$BUILD_DIR/env-templates/media/emmc.env.in"
check_contract_file "$BUILD_DIR/env-templates/media/spi-nand.env.in"

# Single-point regressions must be rejected: saveenv failure may not fall
# through to boot, and a successful return without persistent reload/cfg check
# may not authenticate the deletion.
emmc=$(cat "$BUILD_DIR/env-templates/media/emmc.env.in")
mutated=${emmc/'if saveenv && run ab_verify_rollback ; then'/'if saveenv ; then'}
if check_contract_text "$mutated" 2>/dev/null; then
    echo 'mutation accepted: saveenv-only branch' >&2
    exit 1
fi
mutated=${emmc/'test -z "$cfg_pending" && '/}
if check_contract_text "$mutated" 2>/dev/null; then
    echo 'mutation accepted: no persistent cfg_pending readback' >&2
    exit 1
fi
mutated=${emmc/'setenv active_slot a ;'/}
if check_contract_text "$mutated" 2>/dev/null; then
    echo 'mutation accepted: target toggle removed' >&2
    exit 1
fi
mutated=${emmc/'setenv active_slot a ;'/'setenv active_slot b ;'}
if check_contract_text "$mutated" 2>/dev/null; then
    echo 'mutation accepted: wrong target slot' >&2
    exit 1
fi
mutated=${emmc/'setexpr altcount $altcount + 1 ;'/}
if check_contract_text "$mutated" 2>/dev/null; then
    echo 'mutation accepted: altcount increment removed' >&2
    exit 1
fi
mutated=${emmc/'setexpr altcount $altcount + 1 ;'/'setexpr altcount $altcount + 2 ;'}
if check_contract_text "$mutated" 2>/dev/null; then
    echo 'mutation accepted: wrong altcount increment' >&2
    exit 1
fi

grep -q '^+.*default y$' "$BUILD_DIR/patches/common/uboot/z09-bpirouter-env-reload.patch"

for board in bpi-r3 bpi-r3-mini bpi-r4 bpi-r4-lite bpi-r4-pro openwrt-one; do
    "$BUILD_DIR/env-templates/gen-defenv.sh" --board "$board" --verify >/dev/null
    patch=$(find "$BUILD_DIR/patches/$board/uboot" -maxdepth 1 -name 'z06-bpirouter-defenv-*.patch' \
        -exec grep -l '^+altbootcmd=' {} + | head -n 1)
    [ -n "$patch" ]
    generated=$(sed -n 's/^+//p' "$patch")
    check_contract_text "$generated"
done

r3mini="$BUILD_DIR/patches/bpi-r3-mini/uboot/z06-bpirouter-defenv-emmc.patch"
grep -Fq '+golden_restore=echo "*** GOLDEN RESTORE from NAND ***" ; mmc dev 0 && mmc bootbus 0 0 0 0 && ubi part ubi && run gr_bl && run gr_en8811h && run gr_env && run gr_slots' "$r3mini"
grep -Fq '+gr_en8811h=ubi read $loadaddr en8811h-fw && setenv fileaddr $loadaddr && run emmc_write_en8811h_fw' "$r3mini"
grep -Fq '+emmc_write_en8811h_fw=mmc partconf 0 1 2 2 && mmc erase 0x0 0x120 && mmc write $fileaddr 0x0 0x120 ; mmc partconf 0 1 1 0' "$r3mini"

echo "OTA cfg_pending rollback tests: PASS"
