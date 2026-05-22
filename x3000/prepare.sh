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

if [[ ! -f "$FEEDS_LIST" ]]; then
    echo "missing $FEEDS_LIST" >&2
    exit 1
fi
for f in "$CONFIG_COMMON" "$CONFIG_VARIANT"; do
    [[ -f "$f" ]] || { echo "missing $f" >&2; exit 1; }
done
for d in "$FILES_COMMON" "$FILES_VARIANT"; do
    [[ -d "$d" ]] || { echo "missing $d" >&2; exit 1; }
done

# --- Clone / refresh custom repos and link them into feeds-local/ ---------

echo "==> Refreshing custom package repos"

process_feed_list() {
    local list="$1"
    while IFS= read -r raw_line; do
        line="${raw_line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"   # ltrim
        line="${line%"${line##*[![:space:]]}"}"   # rtrim
        [[ -z "$line" ]] && continue

        read -r name url ref subdir <<< "$line"
        [[ -z "${subdir:-}" ]] && {
            echo "malformed line in $list: $raw_line" >&2
            exit 1
        }

        repo_basename="$(basename "${url%.git}")"
        clone_dir="$DEPS/$repo_basename"

        if [[ ! -d "$clone_dir/.git" ]]; then
            echo "  cloning $url -> $clone_dir"
            git clone "$url" "$clone_dir"
        fi

        git -C "$clone_dir" fetch --quiet origin
        git -C "$clone_dir" -c advice.detachedHead=false checkout --quiet "$ref"
        if git -C "$clone_dir" rev-parse --verify --quiet "refs/remotes/origin/$ref" >/dev/null; then
            git -C "$clone_dir" reset --hard --quiet "origin/$ref"
        fi

        src_dir="$clone_dir/$subdir"
        if [[ ! -d "$src_dir" ]]; then
            echo "  $repo_basename has no subdir '$subdir' (looking for $src_dir)" >&2
            exit 1
        fi

        link="$LOCAL/$name"
        if [[ -L "$link" || -e "$link" ]]; then
            rm -f "$link"
        fi
        ln -s "$src_dir" "$link"
        echo "  feeds-local/$name -> $src_dir"
    done < "$list"
}

process_feed_list "$FEEDS_LIST"

if [[ -f "$FEEDS_LIST_LOCAL" ]]; then
    echo "==> Refreshing local custom package repos ($FEEDS_LIST_LOCAL)"
    process_feed_list "$FEEDS_LIST_LOCAL"
fi

# --- Drop the build-host feeds.conf in place ------------------------------

echo "==> Installing feeds.conf"
sed "s|^src-link custom feeds-local\$|src-link custom $LOCAL|" \
    "$FEEDS_CONF_SRC" > "$ROOT/feeds.conf"

# --- Compose .config from common + variant --------------------------------
#
# NOTE: make defconfig is intentionally NOT called here. It runs after
# feeds update + install below, so that packages from the luci/telephony/
# routing feeds are known to the build system when defconfig expands the
# config. Running defconfig before feeds install causes it to silently
# drop every feed-side package (luci-*, modemmanager, libmbim, stubby,
# etc.) from .config with no error or warning.

echo "==> Composing .config from config.common + config.$VARIANT$([ -f "$CONFIG_VARIANT_LOCAL" ] && echo " + config.$VARIANT.local")"
{
    cat "$CONFIG_COMMON"
    echo
    echo "# --- variant: $VARIANT ---"
    cat "$CONFIG_VARIANT"
    if [[ -f "$CONFIG_VARIANT_LOCAL" ]]; then
        echo
        echo "# --- variant: $VARIANT.local ---"
        cat "$CONFIG_VARIANT_LOCAL"
    fi
} > "$ROOT/.config"

# --- Compose files/ overlay from files-common + files-<variant> ----------

echo "==> Composing files/ from files-common + files-$VARIANT"
rm -rf "$ROOT/files"
mkdir -p "$ROOT/files"
rsync -a --exclude='.gitkeep' "$FILES_COMMON"/ "$ROOT/files/"
rsync -a --exclude='.gitkeep' "$FILES_VARIANT"/ "$ROOT/files/"

# --- Record the variant ---------------------------------------------------

echo "$VARIANT" > "$VARIANT_MARKER"

# --- feeds update + install -----------------------------------------------

for feeddir in "$ROOT"/feeds/*; do
    [[ -d "$feeddir/.git" ]] || continue
    git -C "$feeddir" checkout --quiet -- . 2>/dev/null || true
done

echo "==> feeds update -a"
./scripts/feeds update -a

echo "==> feeds install -a"
./scripts/feeds install -a

# --- Expand .config now that all feed packages are known ------------------
#
# All feeds are now symlinked into package/feeds/, so luci/telephony/
# routing packages are recognised. Output is no longer suppressed:
# defconfig prints warnings like "PACKAGE_x depends on PACKAGE_y which
# is not selected" whenever it drops a =y line. Those messages are the
# only way to diagnose why a package isn't surviving defconfig, so they
# go into the build log.

echo "==> make defconfig (post-feeds)"
make defconfig FORCE=1

# --- Apply unified-diff patches against feed contents ---------------------

PATCH_DIR="$ROOT/x3000/patches"
if [[ -d "$PATCH_DIR" ]]; then
    for patchfile in "$PATCH_DIR"/*.patch; do
        [[ -f "$patchfile" ]] || continue
        name="$(basename "$patchfile")"
        if patch --reverse --dry-run --silent -F 0 -p1 < "$patchfile" >/dev/null 2>&1; then
            echo "==> patch already applied: $name"
            continue
        fi
        echo "==> applying patch: $name"
        if ! patch --forward -r - -F 0 -p1 < "$patchfile"; then
            echo "FATAL: $name did not apply cleanly. Upstream feed has likely" >&2
            echo "drifted; refresh the patch against the new upstream file." >&2
            exit 1
        fi
    done
fi

echo
echo "Done. variant=$VARIANT"
echo "Run 'make -j\$(nproc)' (add V=s for verbose output)"
echo "or 'x3000/build.sh $VARIANT' to also relocate artifacts to bin-x3000-$VARIANT/."
