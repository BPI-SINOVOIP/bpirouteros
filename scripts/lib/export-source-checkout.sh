#!/bin/bash
# Export one upstream revision without private history or local build products.
# Contact: mimallaus@gmail.com

bpir_export_source_checkout() {
    local src="$1" rev="$2" dest="$3" resolved
    [ ! -e "$dest" ] && [ ! -L "$dest" ] || return 1
    resolved=$(git -C "$src" rev-parse --verify "$rev^{commit}") || return 1
    src=$(cd "$src" && pwd -P) || return 1
    git init -q "$dest" || return 1
    git -C "$dest" config core.logAllRefUpdates false || return 1
    git -C "$dest" -c protocol.file.allow=always fetch -q --depth=1 --no-tags --no-write-fetch-head \
        "file://$src" "$resolved" || return 1
    git -C "$dest" -c advice.detachedHead=false checkout -q --detach "$resolved" || return 1
    [ "$(git -C "$dest" rev-parse HEAD)" = "$resolved" ]
}
