#!/bin/sh

set -eu

: "${ARCH:?ARCH is required}"
: "${OUTPUT:?OUTPUT is required}"

ROOTFS_SIZE_MB=${ROOTFS_SIZE_MB:-8192}
ALPINE_MIRROR_ROOT=${ALPINE_MIRROR_ROOT:-http://mirrors.tuna.tsinghua.edu.cn/alpine}
ALPINE_VERSION=${ALPINE_VERSION:-v3.23}
ALPINE_COMPAT_VERSION=${ALPINE_COMPAT_VERSION:-v3.20}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
packages_file="$script_dir/packages.txt"
overlay_dir="$script_dir/overlay"
cache_dir="$project_root/build/cache/alpine/$(uname -m)"
output_dir=$(dirname -- "$OUTPUT")
# Build rootfs on a native Linux filesystem to avoid NTFS shared-lib extraction issues
# Then copy the final image back to the output directory
rootfs_dir="${TMPDIR:-/tmp}/naos-alpine-rootfs.$$"
image_tmp="$OUTPUT.tmp.$$"
rootfs_cleanup() {
  rm -rf "$rootfs_dir"
}
trap rootfs_cleanup EXIT INT TERM

case "$ARCH" in
  x86_64)
    apk_arch=x86_64
    ;;
  aarch64)
    apk_arch=aarch64
    ;;
  riscv64)
    apk_arch=riscv64
    ;;
  loongarch64)
    apk_arch=loongarch64
    ;;
  *)
    echo "Alpine Linux rootfs is unsupported for architecture: $ARCH" >&2
    exit 2
    ;;
esac
package_cache_dir="$project_root/build/cache/alpine/packages/$apk_arch"

case "$ROOTFS_SIZE_MB" in
  ''|*[!0-9]*)
    echo "ROOTFS_SIZE_MB must be a positive integer" >&2
    exit 2
    ;;
esac
if [ "$ROOTFS_SIZE_MB" -le 1024 ]; then
  echo "ROOTFS_SIZE_MB is too small: $ROOTFS_SIZE_MB" >&2
  exit 2
fi

if [ "$(id -u)" -eq 0 ]; then
  sudo=
else
  sudo=${SUDO:-sudo}
fi

cleanup() {
  rm -f "$image_tmp"
}
trap cleanup EXIT INT TERM

mkdir -p "$cache_dir" "$package_cache_dir" "$output_dir"

# --- Download apk-tools-static ---
apk_static_path="$cache_dir/apk-tools-static.apk"
apk_extract_dir="$cache_dir/apk"
apk_url="https://dl-cdn.alpinelinux.org/alpine/edge/main/x86_64/apk-tools-static-3.0.6-r0.apk"

if [ ! -f "$apk_static_path" ]; then
  curl -L --fail -o "$apk_static_path.tmp" "$apk_url"
  mv "$apk_static_path.tmp" "$apk_static_path"
fi

if [ ! -d "$apk_extract_dir" ]; then
  rm -rf "$apk_extract_dir.tmp"
  mkdir -p "$apk_extract_dir.tmp"
  tar -xf "$apk_static_path" -C "$apk_extract_dir.tmp"
  mv "$apk_extract_dir.tmp" "$apk_extract_dir"
fi

apk_static="$apk_extract_dir/sbin/apk.static"
if [ ! -x "$apk_static" ]; then
  echo "apk.static not found in extracted archive" >&2
  exit 1
fi

ALPINE_MIRROR="$ALPINE_MIRROR_ROOT/$ALPINE_VERSION"
ALPINE_EDGE_MIRROR="$ALPINE_MIRROR_ROOT/edge"

$sudo mkdir -p "$rootfs_dir"

# --- Step 1: Install packages from stable repos ---
packages=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$packages_file")
# shellcheck disable=SC2086
$sudo "$apk_static" \
  --arch "$apk_arch" \
  -U \
  --allow-untrusted \
  --root "$rootfs_dir" \
  --cache-dir "$package_cache_dir" \
  --cache-packages \
  -X "$ALPINE_MIRROR/main" \
  -X "$ALPINE_MIRROR/community" \
  --initdb add \
  $packages

# --- Step 2: Upgrade key desktop packages from edge ---
if [ "$ARCH" = x86_64 ]; then
  $sudo "$apk_static" \
    --arch "$apk_arch" \
    -U \
    --allow-untrusted \
    --root "$rootfs_dir" \
    --cache-dir "$package_cache_dir" \
    --cache-packages \
    -X "$ALPINE_MIRROR/main" \
    -X "$ALPINE_MIRROR/community" \
    -X "$ALPINE_EDGE_MIRROR/main" \
    -X "$ALPINE_EDGE_MIRROR/community" \
    add \
    labwc=0.20.1-r0 \
    libxfce4windowing=4.20.6-r0 \
    xfdesktop=4.20.2-r0
fi

# --- Step 3: Downgrade gdk-pixbuf to avoid Glycin+bwrap dependency ---
ALPINE_COMPAT_MIRROR="$ALPINE_MIRROR_ROOT/$ALPINE_COMPAT_VERSION"
compat_cache_dir="$project_root/build/cache/alpine/packages/$apk_arch/compat"
mkdir -p "$compat_cache_dir"

$sudo "$apk_static" \
  --arch "$apk_arch" \
  -U \
  --allow-untrusted \
  --root "$rootfs_dir" \
  --cache-dir "$compat_cache_dir" \
  --cache-packages \
  -X "$ALPINE_COMPAT_MIRROR/main" \
  -X "$ALPINE_COMPAT_MIRROR/community" \
  add \
  gdk-pixbuf=2.42.12-r0

# --- Step 4: Apply overlay ---
$sudo cp -a "$overlay_dir/." "$rootfs_dir/"

# Write apk repositories
printf '%s\n' "$ALPINE_MIRROR/main" "$ALPINE_MIRROR/community" | \
  $sudo tee "$rootfs_dir/etc/apk/repositories" >/dev/null

# Set permissions
$sudo chmod 0755 \
  "$rootfs_dir/usr/lib/aether/init" \
  "$rootfs_dir/usr/lib/aether/start-xfce4-session"
$sudo chmod 0440 "$rootfs_dir/etc/sudoers"
$sudo chmod 0400 "$rootfs_dir/etc/shadow"

# Symlink init
$sudo ln -snf /usr/lib/aether/init "$rootfs_dir/sbin/init"

# Symlink lua
$sudo ln -snf lua5.4 "$rootfs_dir/usr/bin/lua"

# Timezone
$sudo ln -snf /usr/share/zoneinfo/Asia/Shanghai "$rootfs_dir/etc/localtime"

# Ensure /etc/passwd exists (apk.static may not create it)
if [ ! -f "$rootfs_dir/etc/passwd" ]; then
  printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/:/bin/false\n' | \
    $sudo tee "$rootfs_dir/etc/passwd" >/dev/null
fi

# Set root shell to bash
$sudo chroot "$rootfs_dir" /usr/sbin/usermod -s /bin/bash root 2>/dev/null || \
  $sudo sed -i 's|^root:.*:/bin/sh$|root:x:0:0:root:/root:/bin/bash|' "$rootfs_dir/etc/passwd"

# Create essential directories
$sudo mkdir -p \
  "$rootfs_dir/dev" "$rootfs_dir/proc" "$rootfs_dir/sys" \
  "$rootfs_dir/run" "$rootfs_dir/tmp"
$sudo chmod 01777 "$rootfs_dir/tmp"

# Clear apk cache
$sudo rm -rf "$rootfs_dir/var/cache/apk"/*

# --- Step 5: Build ext4 image ---
truncate -s "${ROOTFS_SIZE_MB}M" "$image_tmp"
$sudo mkfs.ext4 -q -F -b 1024 -I 256 \
  -O extent,64bit,flex_bg,huge_file,dir_nlink,extra_isize,dir_index,metadata_csum,^has_journal,^quota,^metadata_csum_seed,^orphan_file,^project,^encrypt,^verity,^casefold,^inline_data,^ea_inode,^bigalloc,^mmp,^fast_commit,^sparse_super2 \
  -E lazy_itable_init=0 \
  -L naos-rootfs -d "$rootfs_dir" "$image_tmp"

chmod 0644 "$image_tmp"
mv -f "$image_tmp" "$OUTPUT"

trap - EXIT INT TERM
