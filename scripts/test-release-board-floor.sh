#!/bin/bash
set -eu
source "$(dirname "$0")/boards.sh"
six='bpi-r4 bpi-r4-lite bpi-r3 bpi-r3-mini openwrt-one bpi-r4-pro'
for release in v1.5.0-rc1 v1.5.0 v1.6.1 v1.10.0 v2.0.0; do
    bpir_select_release_boards "$release"
    test "$VALID_BOARDS" = "$six bpi-r4-pro-4e" && test -z "$PLANNED_BOARDS" || exit 1
done
for release in v1.4.99 v1.05.0 v1.6.1-rc0 ''; do
    bpir_select_release_boards "$release"
    test "$VALID_BOARDS" = "$six" && test "$PLANNED_BOARDS" = bpi-r4-pro-4e || exit 1
done
