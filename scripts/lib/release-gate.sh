#!/bin/bash
# Shared identity boundary for release-producing scripts.
#
# A release command must authenticate the checkout that contains the script
# being executed.  BPIR_BUILD_DIR may redirect development output paths, but it
# must never make code from checkout B claim checkout A's locked commit.

bpir_require_release_workspace() {
    local script_dir="$1"
    local configured_build_dir="$2"
    local input_lock="$3"
    local actual_build_dir configured_physical actual_physical canonical_lock release_id
    local -a release_boards

    [ -n "$script_dir" ] && [ -n "$configured_build_dir" ] && [ -f "$input_lock" ] || {
        echo "release gate requires script directory, build directory and input lock" >&2
        return 1
    }

    actual_build_dir=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || {
        echo "release gate scripts are not running from a git checkout" >&2
        return 1
    }
    actual_physical=$(cd "$actual_build_dir" && pwd -P) || return 1
    [ "$(cd "$script_dir/.." && pwd -P)" = "$actual_physical" ] || {
        echo "release gate scripts are not rooted in their authenticated bpirouter-build checkout" >&2
        return 1
    }

    [ -d "$configured_build_dir" ] || {
        echo "configured bpirouter-build directory does not exist: $configured_build_dir" >&2
        return 1
    }
    configured_physical=$(cd "$configured_build_dir" && pwd -P) || return 1
    [ "$configured_physical" = "$actual_physical" ] || {
        echo "release BPIR_BUILD_DIR must name the checkout containing the executing scripts" >&2
        return 1
    }

    # Unset the redirect for the verifier itself. The directory it derives from
    # its own SCRIPT_DIR is the directory whose code is about to run.
    env -u BPIR_BUILD_DIR "$script_dir/check-release-lock.sh" \
        --scope workspace "$input_lock" || return 1
    # Content validity and repository identity are not enough: only the lock
    # atomically published at the generator-owned canonical path may authorize
    # a formal operation. A read-only copied lock is allowed, but its bytes must
    # be identical to that authority.
    source "$script_dir/boards.sh"
    release_id=$("$script_dir/lib/release-lock-contract.py" release-id --input-lock "$input_lock") || return 1
    bpir_select_release_boards "$release_id"
    read -r -a release_boards <<<"$VALID_BOARDS"
    canonical_lock=$("$script_dir/lib/release-lock-contract.py" validate-formal \
        --input-lock "$input_lock" --canonical-dir "$actual_physical/dist" \
        --boards "${release_boards[@]}") || return 1

    BPIR_RELEASE_GATE_ROOT="$actual_physical"
    BPIR_RELEASE_CANONICAL_INPUT_LOCK="$canonical_lock"
}

# Collector and manifest serialize on one inode for the whole release ID.  A
# lock per input hash allowed two different hashes to create sibling batches
# concurrently while both called themselves the same RC.
bpir_release_collection_lock_path() {
    local release_dir="$1"
    [ -n "$release_dir" ] || return 1
    printf '%s/.collection.lock\n' "$release_dir"
}

# Called while holding the release-wide collection lock. Only one 12/64-char
# input-lock namespace may exist below a release ID, even if somebody bypassed
# the canonical lock generator and supplied a hand-written input lock.
bpir_require_single_release_batch() {
    local release_dir="$1"
    local expected="$2"
    local entry listing
    [ -d "$release_dir" ] && [ -n "$expected" ] || return 1
    listing=$(find "$release_dir" -mindepth 1 -maxdepth 1 -printf '%f\n') || {
        echo "cannot enumerate existing release batches: $release_dir" >&2
        return 1
    }
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        case "$entry" in
            "$expected") ;;
            *)
                if [[ "$entry" =~ ^[0-9a-f]{12}([0-9a-f]{52})?$ ]]; then
                    echo "release already contains another input-lock batch: $entry" >&2
                    return 1
                fi
                ;;
        esac
    done <<<"$listing"
}
