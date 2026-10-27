#!/bin/bash
# rebuild-all.sh — build every board in one locked batch and record provenance.
# Usage: rebuild-all.sh (--development | --release-lock <file>) [board ...]
#
# Written after a run where "which source is in this image?" could only be
# answered by calling RPCs one at a time to see which were missing. Timestamps
# are not evidence: files/ is regenerated per board, the .apk is rebuilt or not
# depending on what make decides, and an image can be newer than the source it
# contains. So each board's line records the commits, the package hash and the
# image hash, and the images are hashed AFTER the build rather than assumed.
set -eo pipefail

# This coordinator defines and records one fixed sibling-workspace layout.
# Development-only path overrides accepted by leaf scripts must not redirect a
# child to inputs different from the repositories named in this batch record.
unset BPIR_BUILD_DIR BPIR_WORK_DIR BPIR_UI_DIR BPIR_FEEDS_DIR BPIR_CONFIG_DIR
unset BPIR_RELEASE_LOCK BPIROUTER_UI_PKG_VERSION BPIROUTER_BUILD_TIME

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="$BUILD_DIR/openwrt"
UI_DIR="$(dirname "$BUILD_DIR")/bpirouter-ui"
FEEDS_DIR="$(dirname "$BUILD_DIR")/bpirouter-feeds"
OUT="${BPIR_REBUILD_OUTPUT:-$BUILD_DIR/output}"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
BPIROUTER_BUILD_TIME="$(date -Iseconds)"
export BPIROUTER_BUILD_TIME
LOG_DIR="$OUT/build-logs-$RUN_ID"
PROV="$OUT/provenance-$RUN_ID.tsv"
PROV_PARTIAL="$PROV.partial"
PROV_FINAL_TMP="$PROV.tmp"

RELEASE_LOCK=""
MODE=""
SELECTED_BOARDS=()
usage() {
    echo "usage: rebuild-all.sh (--development | --release-lock <file>) [board ...]" >&2
    exit 2
}
set_mode() {
    [ -z "$MODE" ] || {
        echo "--development and --release-lock are mutually exclusive" >&2
        exit 2
    }
    MODE="$1"
}
while [ $# -gt 0 ]; do
    case "$1" in
        --development) set_mode development; shift ;;
        --release-lock)
            [ $# -ge 2 ] || usage
            set_mode release
            RELEASE_LOCK="$2"
            shift 2
            ;;
        --*) echo "unknown argument: $1" >&2; exit 2 ;;
        *) SELECTED_BOARDS+=("$1"); shift ;;
    esac
done
case "$MODE" in
    development) ;;
    release)
        [ -n "$RELEASE_LOCK" ] && [ -f "$RELEASE_LOCK" ] || usage
        RELEASE_LOCK="$(cd "$(dirname "$RELEASE_LOCK")" && pwd)/$(basename "$RELEASE_LOCK")"
        ;;
    *) usage ;;
esac

source "$SCRIPT_DIR/boards.sh"
if [ "$MODE" = release ]; then
    RELEASE_ID=$("$SCRIPT_DIR/lib/release-lock-contract.py" release-id --input-lock "$RELEASE_LOCK") || exit 1
    bpir_select_release_boards "$RELEASE_ID"
fi
source "$SCRIPT_DIR/lib/pkg-payload-hash.sh"
source "$SCRIPT_DIR/lib/openwrt-build-lock.sh"
source "$SCRIPT_DIR/lib/openwrt-source.sh"
export APK_TOOL="$WORK_DIR/staging_dir/host/bin/apk"
mkdir -p "$LOG_DIR" "$OUT"

# Keep one exclusive descriptor across every prepare -> build transition in the
# batch. The child scripts verify and reuse this inherited descriptor,
# so no other prepare can enter the shared tree between the two commands.
bpir_acquire_openwrt_build_lock "$WORK_DIR" || exit 1

# prepare.sh can bootstrap a missing OpenWrt checkout when called directly.
# The coordinator needs the commit before it can write batch identity, so do
# the clone-only part here while already holding the same mutation lock.
if ! bpir_is_exact_openwrt_worktree "$WORK_DIR"; then
    { [ ! -e "$WORK_DIR" ] && [ ! -L "$WORK_DIR" ]; } || {
        echo "OpenWrt path exists but is not an exact OpenWrt checkout root: $WORK_DIR" >&2
        exit 1
    }
    bpir_clone_openwrt "$WORK_DIR" > "$LOG_DIR/openwrt-bootstrap.log" 2>&1 || {
        echo "cannot bootstrap OpenWrt $BPIR_OPENWRT_GIT_REF; see $LOG_DIR/openwrt-bootstrap.log" >&2
        exit 1
    }
    bpir_is_exact_openwrt_worktree "$WORK_DIR" || {
        echo "bootstrapped OpenWrt path is not an exact OpenWrt checkout root: $WORK_DIR" >&2
        exit 1
    }
fi

# Existing development workspaces may still be checked out at the previous
# OpenWrt release. Synchronize before capturing OPENWRT_REV and repository
# fingerprints, otherwise provenance names the stale HEAD and prepare tries to
# apply the new baseline's patches to it. Release mode deliberately never
# repairs this state: the input lock must already match the checkout exactly.
if [ "$MODE" = development ]; then
    bpir_sync_openwrt_development_source "$WORK_DIR" \
        > "$LOG_DIR/openwrt-sync.log" 2>&1 || {
        echo "cannot synchronize OpenWrt to $BPIR_OPENWRT_GIT_REF ($BPIR_OPENWRT_GIT_COMMIT); see $LOG_DIR/openwrt-sync.log" >&2
        exit 1
    }
fi

full_rev() {
    local label="$1"
    local dir="$2"
    local rev
    rev=$(git -C "$dir" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
        echo "cannot identify $label Git commit: $dir" >&2
        return 1
    }
    if [[ ! "$rev" =~ ^[0-9a-f]{40}$ && ! "$rev" =~ ^[0-9a-f]{64}$ ]]; then
        echo "invalid $label Git commit: $rev" >&2
        return 1
    fi
    printf '%s\n' "$rev"
}
repo_dirty() {
    local label="$1"
    local dir="$2"
    local status
    if [ "$label" = openwrt ]; then
        # prepare's kernel-patch digest is build-cache metadata: it decides
        # whether target/linux needs cleaning but is neither source input nor a
        # user edit. The prepared-tree digest independently binds the injected
        # patch set used by each board.
        status=$(git -C "$dir" status --porcelain --untracked-files=all -- \
            . ':(exclude).bpirouter_kpatch.md5' 2>/dev/null)
    else
        status=$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null)
    fi || {
        echo "cannot inspect $label Git worktree: $dir" >&2
        return 1
    }
    if [ -z "$status" ]; then
        echo false
    else
        echo true
    fi
}

# A commit plus a dirty boolean is descriptive metadata, not an immutable input
# identity: a worktree can change from one dirty state to another without either
# field moving. Hash the complete tracked diff and every non-ignored untracked
# file so all boards in this batch can prove they consumed the same three
# project repositories.
repo_fingerprint() {
    local label="$1"
    local dir="$2"
    local commit path mode content
    commit=$(full_rev "$label" "$dir") || return 1
    {
        printf 'commit\0%s\0tracked\0' "$commit"
        git -C "$dir" diff --binary --full-index --no-ext-diff HEAD -- || exit 1
        printf '\0untracked\0'
        git -C "$dir" ls-files --others --exclude-standard -z |
            LC_ALL=C sort -z |
            while IFS= read -r -d '' path; do
                printf 'path\0%s\0' "$path"
                if [ -L "$dir/$path" ]; then
                    content=$(readlink "$dir/$path" | sha256sum | cut -d' ' -f1) \
                        || exit 1
                    printf 'symlink\0%s\0' "$content"
                elif [ -f "$dir/$path" ]; then
                    mode=$(stat -c '%a' "$dir/$path") || exit 1
                    content=$(sha256sum "$dir/$path" | cut -d' ' -f1) || exit 1
                    printf 'file\0%s\0%s\0' "$mode" "$content"
                else
                    echo "cannot fingerprint $label untracked path: $path" >&2
                    exit 1
                fi
            done
    } | sha256sum | cut -d' ' -f1
}

verify_batch_inputs() {
    local phase="$1"
    local actual
    actual=$(repo_fingerprint bpirouter-ui "$UI_DIR") || return 1
    [ "$actual" = "$UI_FINGERPRINT" ] || {
        echo "bpirouter-ui input drifted $phase" >&2
        return 1
    }
    actual=$(repo_fingerprint bpirouter-feeds "$FEEDS_DIR") || return 1
    [ "$actual" = "$FEEDS_FINGERPRINT" ] || {
        echo "bpirouter-feeds input drifted $phase" >&2
        return 1
    }
    actual=$(repo_fingerprint bpirouter-build "$BUILD_DIR") || return 1
    [ "$actual" = "$BUILD_FINGERPRINT" ] || {
        echo "bpirouter-build input drifted $phase" >&2
        return 1
    }
    bpir_is_exact_openwrt_worktree "$WORK_DIR" || {
        echo "OpenWrt checkout root changed $phase" >&2
        return 1
    }
    actual=$(full_rev openwrt "$WORK_DIR") || return 1
    [ "$actual" = "$OPENWRT_REV" ] || {
        echo "OpenWrt HEAD drifted $phase" >&2
        return 1
    }
}

UI_REV=$(full_rev bpirouter-ui "$UI_DIR")
FEEDS_REV=$(full_rev bpirouter-feeds "$FEEDS_DIR")
BUILD_REV=$(full_rev bpirouter-build "$BUILD_DIR")
OPENWRT_REV=$(full_rev openwrt "$WORK_DIR")
UI_DIRTY=$(repo_dirty bpirouter-ui "$UI_DIR")
FEEDS_DIRTY=$(repo_dirty bpirouter-feeds "$FEEDS_DIR")
BUILD_DIRTY=$(repo_dirty bpirouter-build "$BUILD_DIR")
OPENWRT_DIRTY=$(repo_dirty openwrt "$WORK_DIR")
UI_FINGERPRINT=$(repo_fingerprint bpirouter-ui "$UI_DIR")
FEEDS_FINGERPRINT=$(repo_fingerprint bpirouter-feeds "$FEEDS_DIR")
BUILD_FINGERPRINT=$(repo_fingerprint bpirouter-build "$BUILD_DIR")

if [ "$MODE" = development ]; then
    BUILD_ID="dev-${BUILD_REV:0:12}-${UI_REV:0:12}-${FEEDS_REV:0:12}-${OPENWRT_REV:0:12}"
    if [ "$UI_DIRTY$FEEDS_DIRTY$BUILD_DIRTY$OPENWRT_DIRTY" != falsefalsefalsefalse ]; then
        BUILD_ID="$BUILD_ID-dirty"
    fi
else
    LOCK_SHA=$(sha256sum "$RELEASE_LOCK" | cut -d' ' -f1)
    BUILD_ID="release-${LOCK_SHA:0:12}"
fi

if [ "${#SELECTED_BOARDS[@]}" -gt 0 ]; then
    BOARDS=("${SELECTED_BOARDS[@]}")
else
    read -r -a BOARDS <<< "$VALID_BOARDS"
fi

# Reject unknown/duplicate selections before publishing a batch header, and
# state explicitly whether the requested set is the complete supported set.
for ((i = 0; i < ${#BOARDS[@]}; i++)); do
    case " $VALID_BOARDS " in
        *" ${BOARDS[$i]} "*) ;;
        *)
            # A planned board is a real, frozen identity, so say what is actually
            # missing. "unknown board" would send the reader looking for a typo.
            case " $PLANNED_BOARDS " in
                *" ${BOARDS[$i]} "*)
                    board_init "${BOARDS[$i]}"
                    if [ "$MODE" != development ] || [ "$BOARD_IMPLEMENTED" != yes ]; then
                        echo "board ${BOARDS[$i]} has a frozen identity; this board requires source-complete development builds" >&2
                        exit 2
                    fi ;;
                *) echo "unknown board: ${BOARDS[$i]}" >&2; exit 2 ;;
            esac
            ;;
    esac
    for ((j = 0; j < i; j++)); do
        [ "${BOARDS[$j]}" != "${BOARDS[$i]}" ] || {
            echo "duplicate board: ${BOARDS[$i]}" >&2
            exit 2
        }
    done
done
read -r -a SUPPORTED_BOARDS <<< "$VALID_BOARDS"
BATCH_SCOPE=partial
if [ "${#BOARDS[@]}" -eq "${#SUPPORTED_BOARDS[@]}" ]; then
    BATCH_SCOPE=six-board
    [ "${#SUPPORTED_BOARDS[@]}" -ne 7 ] || BATCH_SCOPE=seven-sku
    for supported in "${SUPPORTED_BOARDS[@]}"; do
        found=0
        for requested in "${BOARDS[@]}"; do
            [ "$requested" != "$supported" ] || found=1
        done
        [ "$found" = 1 ] || BATCH_SCOPE=partial
    done
fi
REQUESTED_BOARDS=$(IFS=,; echo "${BOARDS[*]}")

write_provenance_header() {
  local output="$1"
  local complete="$2"
  local success="$3"
  {
  echo "# schema=2"
  echo "# generated_at=$(date -Iseconds)"
  echo "# mode=$MODE"
  # Only the downstream six-board manifest may claim release eligibility. A
  # coordinator TSV remains a build record even when it used formal inputs.
  echo "# release_eligible=false"
  echo "# build_id=$BUILD_ID"
  echo "# requested_boards=$REQUESTED_BOARDS"
  echo "# scope=$BATCH_SCOPE"
  echo "# batch_complete=$complete"
  echo "# batch_success=$success"
  echo "# bpirouter-ui.commit=$UI_REV"
  echo "# bpirouter-ui.dirty=$UI_DIRTY"
  echo "# bpirouter-ui.fingerprint=$UI_FINGERPRINT"
  echo "# bpirouter-feeds.commit=$FEEDS_REV"
  echo "# bpirouter-feeds.dirty=$FEEDS_DIRTY"
  echo "# bpirouter-feeds.fingerprint=$FEEDS_FINGERPRINT"
  echo "# bpirouter-build.commit=$BUILD_REV"
  echo "# bpirouter-build.dirty=$BUILD_DIRTY"
  echo "# bpirouter-build.fingerprint=$BUILD_FINGERPRINT"
  echo "# openwrt.commit=$OPENWRT_REV"
  echo "# openwrt.dirty=$OPENWRT_DIRTY"
  [ "$MODE" != release ] || echo "# input_lock_sha256=$LOCK_SHA"
  # apk_sha256 is the integrity of the file that was downloaded; it is NOT an
  # identity for the software. Six boards built from one source tree produced
  # six different .apk hashes and one identical payload -- the container carries
  # packaging metadata that changes on every repack. payload_sha256 is the
  # canonical hash of what the package DELIVERS (paths, modes, types, symlink
  # targets, contents), and is the column to compare across boards and runs.
  # apid_sha256 is diagnostic: it says whether a payload difference is the
  # backend binary or something else (UI assets, scripts, config).
  printf "board\tprofile\tresult\tprepared_tree_sha256\tapk_sha256\tpayload_sha256\tapid_sha256\timage_sha256\timage\n"
  } > "$output"
}

# Publish the primary image only after the build and all of its board-local
# evidence gates have succeeded. The OpenWrt bin directory is mutable build
# state; callers use OUT as the coordinator result. Copying to a same-directory
# temporary file, checking its exact digest, and renaming it prevents an old
# image from surviving a successful new provenance record and prevents readers
# from observing a partially copied replacement.
publish_primary_image() {
    local board="$1"
    local source="$2"
    local expected_sha="$3"
    local board_out="$OUT/$board"
    local name destination temporary actual_sha published_sha

    name=$(basename "$source")
    if [ -L "$board_out" ] || { [ -e "$board_out" ] && [ ! -d "$board_out" ]; }; then
        echo "board output is not a real directory: $board_out" >&2
        return 1
    fi
    mkdir -p "$board_out" || return 1
    destination="$board_out/$name"
    temporary=$(mktemp "$board_out/.image.XXXXXX") || return 1
    if ! cp -- "$source" "$temporary" || ! chmod 0644 "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    actual_sha=$(sha256sum "$temporary" | cut -d' ' -f1) || {
        rm -f -- "$temporary"
        return 1
    }
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "copied primary image hash mismatch for $board" >&2
        rm -f -- "$temporary"
        return 1
    fi
    if ! mv -fT -- "$temporary" "$destination"; then
        rm -f -- "$temporary"
        return 1
    fi
    published_sha=$(sha256sum "$destination" | cut -d' ' -f1) || return 1
    if [ "$published_sha" != "$expected_sha" ]; then
        echo "published primary image hash mismatch for $board" >&2
        return 1
    fi
    printf '%s/%s\n' "$board" "$name"
}

write_provenance_header "$PROV_PARTIAL" false false
FAILED_BOARDS=()
for b in "${BOARDS[@]}"; do
    echo "══════ $b ══════"
    board_init "$b"
    ok=fail
    PREPARE_ARGS=(--board "$b" --ui-source "$UI_DIR")
    BUILD_ARGS=(--board "$b")
    if [ "$MODE" = release ]; then
        PREPARE_ARGS+=(--release-lock "$RELEASE_LOCK")
        BUILD_ARGS+=(--release-lock "$RELEASE_LOCK")
    else
        PREPARE_ARGS+=(--development)
    fi
    if verify_batch_inputs "before preparing $b" > "$LOG_DIR/$b.prepare.log" 2>&1 \
       && "$SCRIPT_DIR/prepare.sh" "${PREPARE_ARGS[@]}" >> "$LOG_DIR/$b.prepare.log" 2>&1 \
       && "$SCRIPT_DIR/check-prepared.sh" "$b" >> "$LOG_DIR/$b.prepare.log" 2>&1 \
       && verify_batch_inputs "after preparing $b" >> "$LOG_DIR/$b.prepare.log" 2>&1 \
       && "$SCRIPT_DIR/build-full.sh" "${BUILD_ARGS[@]}" > "$LOG_DIR/$b.build.log" 2>&1 \
       && verify_batch_inputs "after building $b" >> "$LOG_DIR/$b.build.log" 2>&1; then
        ok=ok
        if [ "$MODE" = development ] \
           && { [ -e "$WORK_DIR/bin/targets/$TARGET/.bpirouter-build-$b.json" ] \
                || [ -e "$WORK_DIR/bin/targets/$TARGET/.bpirouter-ui-$b.json" ]; }; then
            echo "development build left formal release sidecars" >> "$LOG_DIR/$b.build.log"
            ok=fail
        fi
    fi
    prepared=-
    marker="$WORK_DIR/.bpirouter-prepared-board"
    if [ -f "$marker" ] \
       && [ "$(sed -n 's/^board=//p' "$marker" | head -1)" = "$b" ]; then
        prepared=$(sed -n 's/^prepared_tree_sha256=//p' "$marker" | head -1)
        prepared=${prepared:--}
    fi

    # `|| true` on both: a board's profile may legitimately produce no sdcard
    # image, and `ls` on a glob that matches nothing exits 1 -- which under
    # `set -eo pipefail` killed this script AFTER a successful build, so the
    # row it exists to write was the one thing that did not get written.
    apk=$(ls -t "$WORK_DIR/bin/packages/$(pkg_arch)/bpirouter/bpirouter-ui-"*.apk 2>/dev/null | head -1 || true)
    # Exact name, not a glob around $PROFILE: bananapi_bpi-r4 is a prefix of
    # bananapi_bpi-r4-lite and bananapi_bpi-r4-pro-8x, so `*$PROFILE*` matches
    # its own siblings and `ls -t` then records a NEIGHBOUR's hash. The rows
    # written so far happen to be right only because each was captured
    # immediately after that board's own build, when its file was the newest --
    # timing, not design, and exactly the kind of thing this record exists to
    # stop relying on.
    base="$WORK_DIR/bin/targets/$TARGET/openwrt-mediatek-filogic-$PROFILE"
    img=""
    for cand in "$base-squashfs-sysupgrade.itb" "$base-sdcard.img.gz"; do
        [ -f "$cand" ] && { img="$cand"; break; }
    done
    apk_sha=-; payload=-; apid=-; image_sha=-
    if [ -n "$apk" ]; then
        apk_sha_full=$(sha256sum "$apk" | cut -d' ' -f1)
        payload_full=$(pkg_payload_hash "$apk" 2>/dev/null || true)
        apid_full=$(pkg_file_hash "$apk" usr/bin/bpirouter-apid 2>/dev/null || true)
        apk_sha=${apk_sha_full:0:16}; apk_sha=${apk_sha:--}
        payload=${payload_full:0:16}; payload=${payload:--}
        apid=${apid_full:0:16}; apid=${apid:--}
    else
        apk_sha_full=""; payload_full=""; apid_full=""
    fi
    if [ -n "$img" ]; then
        image_sha_full=$(sha256sum "$img" | cut -d' ' -f1)
        image_sha=${image_sha_full:0:16}; image_sha=${image_sha:--}
    else
        image_sha_full=""
    fi

    # A zero exit from the compiler is necessary but insufficient. Do not let a
    # stale/misconfigured build become an "ok" row unless the artifacts needed
    # to identify and test the resulting software all exist and are hashable.
    if [ "$ok" = ok ]; then
        evidence_errors=()
        [[ "$prepared" =~ ^[0-9a-f]{64}$ ]] \
            || evidence_errors+=("missing or invalid prepared-tree hash")
        [[ "$apk_sha_full" =~ ^[0-9a-f]{64}$ ]] \
            || evidence_errors+=("missing or invalid bpirouter-ui APK")
        [[ "$payload_full" =~ ^[0-9a-f]{64}$ ]] \
            || evidence_errors+=("missing or invalid UI payload hash")
        [[ "$apid_full" =~ ^[0-9a-f]{64}$ ]] \
            || evidence_errors+=("missing or invalid bpirouter-apid hash")
        [[ "$image_sha_full" =~ ^[0-9a-f]{64}$ ]] \
            || evidence_errors+=("missing or invalid primary image")
        if [ "${#evidence_errors[@]}" -gt 0 ]; then
            {
                echo "artifact evidence incomplete for $b:"
                printf '  - %s\n' "${evidence_errors[@]}"
            } >> "$LOG_DIR/$b.build.log"
            ok=fail
        fi
    fi
    published_image=-
    if [ "$ok" = ok ]; then
        if ! published_image=$(publish_primary_image "$b" "$img" "$image_sha_full" \
                2>>"$LOG_DIR/$b.build.log"); then
            echo "could not publish the verified primary image" >>"$LOG_DIR/$b.build.log"
            ok=fail
        fi
    fi
    if [ "$ok" != ok ]; then
        FAILED_BOARDS+=("$b")
        image_sha=-
        published_image=-
    fi
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$b" "$PROFILE" "$ok" "$prepared" \
        "$apk_sha" "$payload" "$apid" "$image_sha" \
        "$published_image" >> "$PROV_PARTIAL"
    echo "  → $ok"
done

BATCH_SUCCESS=true
[ "${#FAILED_BOARDS[@]}" -eq 0 ] || BATCH_SUCCESS=false
INPUTS_STABLE=true
verify_batch_inputs "before batch finalization" > "$LOG_DIR/batch-inputs.log" 2>&1 \
    || { INPUTS_STABLE=false; BATCH_SUCCESS=false; }
write_provenance_header "$PROV_FINAL_TMP" true "$BATCH_SUCCESS"
awk 'rows { print } $1 == "board" && $2 == "profile" { rows=1 }' \
    "$PROV_PARTIAL" >> "$PROV_FINAL_TMP"
mv "$PROV_FINAL_TMP" "$PROV"
rm -f "$PROV_PARTIAL"

echo; echo "── provenance ──"; column -t "$PROV" 2>/dev/null || cat "$PROV"
echo "logs: $LOG_DIR"
if [ "${#FAILED_BOARDS[@]}" -gt 0 ]; then
    echo "$MODE build failed for: ${FAILED_BOARDS[*]}" >&2
    exit 1
fi
if [ "$INPUTS_STABLE" != true ]; then
    echo "$MODE build inputs drifted; see $LOG_DIR/batch-inputs.log" >&2
    exit 1
fi
