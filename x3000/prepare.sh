#!/usr/bin/env bash
#
# x3000/prepare.sh — set up the OpenWrt build tree to produce a GL-X3000
# image. Two variants are supported:
#
#   private  bad.ass fleet image — telegraf-full pushing to
#            metrics.bad.ass, internal CA, signed-feed pubkey.
#            (Default; preserves the historical behaviour.)
#
#   public   no bad.ass extras — same hardware enablement (modem stack,
#            quectel-5g-tools, adb, LuCI bundle) but no internal CA,
#            no internal feed key, no telegraf push.
#
# Usage:  x3000/prepare.sh [private|public]
#
# What it does, idempotently:
#   1. Clones the custom package repos listed in x3000/custom-feeds.txt
#      into .build-deps/ (gitignored). Each repo is fetched + checked out
#      to the pinned ref on every run.
#   2. Creates symlinks under feeds-local/ pointing at the package
#      subdirectory inside each clone. `feeds-local/` is what
#      /feeds.conf's `src-link custom` references.
#   3. Copies x3000/feeds.conf -> /feeds.conf so OpenWrt's `feeds update`
#      sees the standard 25.12 feeds plus our custom symlinks.
#   4. Composes /.config from x3000/config.common + x3000/config.<variant>.
#   5. Wipes /files/ and rebuilds it from x3000/files-common/ +
#      x3000/files-<variant>/, so swapping variants leaves no stale
#      overlay files behind.
#   6. Records the active variant in /.x3000-variant for build.sh and
#      sanity checks.
#   7. Runs `./scripts/feeds update -a && ./scripts/feeds install -a` so
#      every Makefile is symlinked into package/feeds/.
#   8. Runs `make defconfig` NOW, after feeds are installed, so packages
#      from the luci/telephony/routing feeds are known and not silently
#      dropped from .config.
#   9. Applies x3000/patches/*.patch against feed-side files (modemmanager
#      tty hotplug etc.).

set -euo pipefail

VARIANT="${1:-private}"
case "$VARIANT" in
    private|public) ;;
    *)
        echo "usage: $0 [private|public]" >&2
        echo "  unknown variant: $VARIANT" >&2
        exit 2
        ;;
esac

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DEPS="$ROOT/.build-deps"
LOCAL="$ROOT/feeds-local"
FEEDS_LIST="$ROOT/x3000/custom-feeds.txt"
FEEDS_LIST_LOCAL="$ROOT/x3000/custom-feeds.$VARIANT.local"
FEEDS_CONF_SRC="$ROOT/x3000/feeds.conf"
CONFIG_COMMON="$ROOT/x3000/config.common"
CONFIG_VARIANT="$ROOT/x3000/config.$VARIANT"
CONFIG_VARIANT_LOCAL="$ROOT/x3000/config.$VARIANT.local"
FILES_COMMON="$ROOT/x3000/files-common"
FILES_VARIANT="$ROOT/x3000/files-$VARIANT"
VARIANT_MARKER="$ROOT/.x3000-variant"

echo "==> Preparing X3000 build tree (variant=$VARIANT)"

mkdir -p "$DEPS" "$LOCAL"

if
