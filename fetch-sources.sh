#!/bin/bash
# fetch-sources.sh — clone the upstream this release was built against.
#
# The pinned versions live in RELEASE-INPUTS.lock.json. They are pinned rather
# than tracked: OpenWrt's branches move, and a build against whatever is current
# is not the build this tree describes.
set -eo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TAG=$(sed -n 's/.*"tag"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$HERE/RELEASE-INPUTS.lock.json" | head -1)
[ -n "$TAG" ] || { echo "cannot read OpenWrt tag from RELEASE-INPUTS.lock.json" >&2; exit 1; }

if [ -d "$HERE/openwrt/.git" ]; then
    echo "openwrt/ already present — leaving it alone"
else
    echo "Cloning OpenWrt $TAG ..."
    git clone --branch "$TAG" --depth 1 https://github.com/openwrt/openwrt.git "$HERE/openwrt"
fi

# feeds.conf in the OpenWrt tree pins every feed to an exact commit, and
# prepare.sh points the bpirouter feed at ./feeds/bpirouter.
echo
# A UI mode is mandatory -- prepare.sh refuses without one, on purpose, because
# an image silently missing its management interface looks fine until it is
# flashed. Printing the bare command sent the customer straight into that
# refusal, one line after this script told them it had succeeded.
echo "Next:"
echo "  ./scripts/prepare.sh --board <board> --ui-artifact ./proprietary-artifacts/bpirouter-ui.apk"
echo
echo "  ./scripts/build-full.sh --board <board>"
echo "See the README for a build without the proprietary UI package."
