#!/bin/sh
# pkg-payload-hash.sh — hash what a package DELIVERS, not the file it arrives in.
#
# Why this exists: rebuild-all recorded only the .apk's own sha256, and that
# hash changes on every repack even when the payload is byte-identical. Measured
# on a six-board run where all six boards built from one source tree: the Go
# binary inside was the same 32 bytes of hash every time, and no two .apk hashes
# matched. So the column meant to answer "is this the same software?" answered
# "no" six times in a row, for six identical builds.
#
# The payload hash is over a canonical listing of the extracted tree:
#
#     <mode> <type> <path> <content-or-target-hash>
#
# sorted by path. Paths, permissions, file types and symlink targets are all
# part of it -- a package that moves a file or drops the executable bit is a
# different package even when every byte of content is the same. Directories
# carry no content hash. Nothing from the container (signature, build time,
# member order) is in scope, which is the whole point.
#
# Usage: pkg_payload_hash <file.apk>   → prints sha256, or nothing on failure.
pkg_payload_hash() {
    _pph_apk="$1"
    [ -f "$_pph_apk" ] || return 1
    _pph_tmp=$(mktemp -d) || return 1

    # OpenWrt's apk v3 is not a tar a plain `tar -xzf` can read -- it produces
    # an empty directory and exits 0. Use the host apk tool, and judge by
    # ARTIFACTS rather than exit status: this tool has been seen to report
    # success on stderr while extracting nothing at all.
    _pph_tool="${APK_TOOL:-$(dirname "$0")/../openwrt/staging_dir/host/bin/apk}"
    if [ -x "$_pph_tool" ]; then
        "$_pph_tool" extract --allow-untrusted --destination "$_pph_tmp" \
            "$_pph_apk" >/dev/null 2>&1
    fi
    if [ -z "$(find "$_pph_tmp" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        # Last resort for a plain gzipped tar, so the helper still works on a
        # package built by an older toolchain.
        tar -xzf "$_pph_apk" -C "$_pph_tmp" 2>/dev/null
    fi
    if [ -z "$(find "$_pph_tmp" -mindepth 1 -print -quit 2>/dev/null)" ]; then
        rm -rf "$_pph_tmp"
        return 1
    fi

    _pph_hash=$(
        cd "$_pph_tmp" || exit 1
        find . -mindepth 1 \( -type f -o -type d -o -type l \) -print |
        LC_ALL=C sort |
        while IFS= read -r p; do
            _m=$(stat -c%a "$p" 2>/dev/null)
            if [ -L "$p" ]; then
                printf '%s l %s %s\n' "$_m" "$p" \
                    "$(readlink "$p" | sha256sum | cut -d' ' -f1)"
            elif [ -d "$p" ]; then
                printf '%s d %s -\n' "$_m" "$p"
            else
                printf '%s f %s %s\n' "$_m" "$p" \
                    "$(sha256sum "$p" | cut -d' ' -f1)"
            fi
        done | sha256sum | cut -d' ' -f1
    )
    rm -rf "$_pph_tmp"
    [ -n "$_pph_hash" ] && printf '%s' "$_pph_hash"
}

# pkg_file_hash <file.apk> <path-inside-payload> — sha256 of one delivered file.
# Diagnostic only: it says which PART changed once payload_sha256 says something
# did. It is not a substitute for the payload hash, which also covers paths,
# modes and symlink targets.
pkg_file_hash() {
    _pfh_apk="$1"; _pfh_path="$2"
    [ -f "$_pfh_apk" ] || return 1
    _pfh_tmp=$(mktemp -d) || return 1
    _pfh_tool="${APK_TOOL:-$(dirname "$0")/../openwrt/staging_dir/host/bin/apk}"
    [ -x "$_pfh_tool" ] && "$_pfh_tool" extract --allow-untrusted \
        --destination "$_pfh_tmp" "$_pfh_apk" >/dev/null 2>&1
    _pfh_out=""
    [ -f "$_pfh_tmp/$_pfh_path" ] && \
        _pfh_out=$(sha256sum "$_pfh_tmp/$_pfh_path" | cut -d' ' -f1)
    rm -rf "$_pfh_tmp"
    [ -n "$_pfh_out" ] && printf '%s' "$_pfh_out"
}
