#!/bin/bash
# Shared exclusive lock for every mutation or build of one OpenWrt work tree.
#
# A coordinator may acquire the lock once and export the inherited descriptor
# across prepare.sh -> build-full.sh. Child scripts verify that the descriptor
# names the expected lock file and re-flock the same open file description. A
# standalone prepare/build opens and holds the same file until process exit.

bpir_acquire_openwrt_build_lock() {
    local work_dir="$1"
    # Anchor the default to the work tree's parent, not to the caller's source
    # checkout. Two wrappers pointing BPIR_WORK_DIR at the same tree must still
    # contend on one inode, including before that tree is first cloned.
    local lock_path="$(dirname "$work_dir")/.bpirouter-build.lock"
    local expected actual fd

    command -v flock >/dev/null 2>&1 || {
        echo "flock is required to serialize OpenWrt prepare/build operations" >&2
        return 1
    }
    mkdir -p "$(dirname "$lock_path")"
    touch "$lock_path"
    expected=$(readlink -f "$lock_path")

    if [ -n "${BPIR_OPENWRT_LOCK_FD:-}" ]; then
        fd="$BPIR_OPENWRT_LOCK_FD"
        [[ "$fd" =~ ^[0-9]+$ ]] && [ -e "/proc/$$/fd/$fd" ] || {
            echo "invalid inherited OpenWrt build lock descriptor: ${fd:-empty}" >&2
            return 1
        }
        actual=$(readlink -f "/proc/$$/fd/$fd" 2>/dev/null || true)
        [ "$actual" = "$expected" ] || {
            echo "inherited OpenWrt build lock names $actual, expected $expected" >&2
            return 1
        }
        flock "$fd"
        return 0
    fi

    exec {BPIR_OPENWRT_LOCK_FD}>"$lock_path"
    flock "$BPIR_OPENWRT_LOCK_FD"
    export BPIR_OPENWRT_LOCK_FD
}
