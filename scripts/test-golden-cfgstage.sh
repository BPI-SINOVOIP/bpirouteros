#!/bin/bash
# eMMC golden restore and the NAND-side eMMC install must clear cfgstage, or the
# last keep-settings archive (old keys and password hashes) survives a restore
# to factory. Both erase the partition by its GPT name after both slots are
# written; a missing partition warns instead of aborting the recovery.
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ERASE='emmc_erase_cfgstage=if part start mmc 0 cfgstage part_addr && part size mmc 0 cfgstage part_size && mmc erase 0x$part_addr 0x$part_size ; then else echo "*** cfgstage not erased ***" ; fi'

check_emmc() {
    grep -Fxq "$ERASE" <<<"$1" || return 1
    grep -q '^golden_restore=.* && run gr_slots && run emmc_erase_cfgstage && echo "\*\*\* restored - rebooting \*\*\*" ; reset$' <<<"$1"
}

check_snand() {
    grep -Fxq "$ERASE" <<<"$1" || return 1
    grep -q '^emmc_init=.* && run emmc_init_openwrt && run emmc_erase_cfgstage$' <<<"$1"
}

# r3-mini's archetype-2 NAND env is hand-maintained: its emmc_install reuses
# gr_slots inside one success condition instead of the template's emmc_init.
check_r3mini_snand() {
    grep -Fxq "$ERASE" <<<"$1" || return 1
    grep -q '^emmc_install=.* && run gr_slots && run emmc_erase_cfgstage ; then ' <<<"$1"
}

emmc=$(cat "$BUILD_DIR/env-templates/media/emmc.env.in")
snand=$(cat "$BUILD_DIR/env-templates/media/snand.env.in")
check_emmc "$emmc"
check_snand "$snand"

# Single-point regressions must be rejected.
reject() {
    if "$1" "$2" 2>/dev/null; then
        echo "mutation accepted: $3" >&2
        exit 1
    fi
}
reject check_emmc "${emmc/' && run emmc_erase_cfgstage'/}" 'golden restore without the erase'
reject check_snand "${snand/' && run emmc_erase_cfgstage'/}" 'eMMC install without the erase'
reject check_emmc "${emmc/'part start mmc 0 cfgstage part_addr && part size mmc 0 cfgstage part_size && mmc erase 0x$part_addr 0x$part_size'/'mmc erase 0x10000 0x8000'}" 'fixed-offset erase'
reject check_emmc "${emmc/' ; then else echo "*** cfgstage not erased ***" ; fi'/}" 'erase failure aborting the restore'

# Every committed eMMC board patch carries the same contract.
for board in bpi-r3 bpi-r3-mini bpi-r4 bpi-r4-lite bpi-r4-pro bpi-r4-pro-4e; do
    "$BUILD_DIR/env-templates/gen-defenv.sh" --board "$board" --verify >/dev/null
    check_emmc "$(sed -n 's/^+//p' "$BUILD_DIR/patches/$board/uboot/z06-bpirouter-defenv-emmc.patch")"
    snand_patch="$BUILD_DIR/patches/$board/uboot/z06-bpirouter-defenv-snand.patch"
    if [ "$board" = bpi-r3-mini ]; then
        check_r3mini_snand "$(sed -n 's/^+//p' "$snand_patch")"
    else
        check_snand "$(sed -n 's/^+//p' "$snand_patch")"
    fi
done

echo "golden restore and eMMC install cfgstage erase: PASS"
