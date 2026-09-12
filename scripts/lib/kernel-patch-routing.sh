#!/bin/bash

# Classify a kernel patch by the OpenWrt layer that owns it.
#
# Generic 930/931 series are valid only in a board kernel directory because
# prepare.sh injects that same directory into generic backport/pending after
# preserving the upstream order. Returning failure for any other source
# directory prevents a same-named common patch from being silently skipped.
bpir_kernel_patch_route() {
    local source_dir="$1"
    local board_kernel_dir="$2"
    local basename="$3"

    case "$basename" in
        930-*)
            [ "$source_dir" = "$board_kernel_dir" ] || return 2
            printf '%s\n' backport
            ;;
        931-*)
            [ "$source_dir" = "$board_kernel_dir" ] || return 2
            printf '%s\n' pending
            ;;
        *)
            printf '%s\n' target
            ;;
    esac
}
