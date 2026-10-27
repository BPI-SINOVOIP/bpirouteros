#!/bin/bash
# Share committed customer guides between public trees and recovery kits.
bpir_export_user_guides() {
    local repo="$1" revision="$2" destination="$3" guide
    local guides=(FEATURES.md FEATURES.zh-CN.md INSTALLATION.md INSTALLATION.zh-CN.md)
    for guide in "${guides[@]}"; do
        git -C "$repo" cat-file -e "$revision:docs/user/$guide" \
            && git -C "$repo" diff --quiet "$revision" -- "docs/user/$guide" \
            && git -C "$repo" diff --cached --quiet "$revision" -- "docs/user/$guide" || {
            echo "user guide must match committed revision: $guide" >&2
            return 1
        }
    done
    for guide in "${guides[@]}"; do
        git -C "$repo" show "$revision:docs/user/$guide" > "$destination/$guide" || return 1
    done
}
