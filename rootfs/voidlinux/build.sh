#!/bin/sh

set -eu

: "${ARCH:?ARCH is required}"
: "${OUTPUT:?OUTPUT is required}"

ROOTFS_SIZE_MB=${ROOTFS_SIZE_MB:-8192}
VOID_MIRROR=${VOID_MIRROR:-http://mirrors.tuna.tsinghua.edu.cn/voidlinux/current}
VOID_PACKAGES=${VOID_PACKAGES:-}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
packages_file="$script_dir/packages.txt"
overlay_dir="$script_dir/overlay"
cache_dir="$project_root/build/cache/voidlinux/$(uname -m)"
output_dir=$(dirname -- "$OUTPUT")
rootfs_dir="$output_dir/rootfs"
image_tmp="$OUTPUT.tmp.$$"

case "$ARCH" in
  x86_64)
    xbps_arch=x86_64
    repository=$VOID_MIRROR
    ;;
  aarch64)
    xbps_arch=aarch64
    repository=$VOID_MIRROR/aarch64
    ;;
  *)
    echo "Void Linux rootfs is unsupported for architecture: $ARCH" >&2
    exit 2
    ;;
esac
package_cache_dir="$project_root/build/cache/voidlinux/packages/$xbps_arch"

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

xbps_archive="$cache_dir/xbps-static-latest.tar.xz"
xbps_root="$cache_dir/xbps"
xbps_url="http://repo-default.voidlinux.org/static/xbps-static-latest.$(uname -m)-musl.tar.xz"

if [ ! -f "$xbps_archive" ]; then
  curl -L --fail -o "$xbps_archive.tmp" "$xbps_url"
  mv "$xbps_archive.tmp" "$xbps_archive"
fi

if [ ! -d "$xbps_root" ]; then
  rm -rf "$xbps_root.tmp"
  mkdir -p "$xbps_root.tmp"
  tar -xJf "$xbps_archive" -C "$xbps_root.tmp"
  mv "$xbps_root.tmp" "$xbps_root"
fi

xbps_install=
xbps_reconfigure=
for candidate in \
  "$xbps_root/usr/bin/xbps-install.static" \
  "$xbps_root/usr/bin/xbps-install"; do
  if [ -x "$candidate" ]; then
    xbps_install=$candidate
    break
  fi
done
for candidate in \
  "$xbps_root/usr/bin/xbps-reconfigure.static" \
  "$xbps_root/usr/bin/xbps-reconfigure"; do
  if [ -x "$candidate" ]; then
    xbps_reconfigure=$candidate
    break
  fi
done
if [ -z "$xbps_install" ] || [ -z "$xbps_reconfigure" ]; then
  echo "the XBPS static archive does not contain the required tools" >&2
  exit 1
fi

$sudo mkdir -p "$rootfs_dir"

packages=$(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$packages_file")
# Package names intentionally undergo word splitting here.
# shellcheck disable=SC2086
$sudo env XBPS_ARCH="$xbps_arch" "$xbps_install" \
  --cachedir="$package_cache_dir" \
  --repository="$repository" --rootdir="$rootfs_dir" --sync --yes \
  $packages $VOID_PACKAGES

$sudo cp -a "$overlay_dir/." "$rootfs_dir/"
$sudo mkdir -p "$rootfs_dir/usr/share/xbps.d"
printf 'repository=%s\n' "$repository" | \
  $sudo tee "$rootfs_dir/usr/share/xbps.d/00-repository-main.conf" >/dev/null
$sudo chmod 0755 \
  "$rootfs_dir/usr/lib/aether/init" \
  "$rootfs_dir/usr/lib/aether/start-xfce4-session" \
  "$rootfs_dir/etc/sv/aether-xfce/run"
$sudo chmod 0440 "$rootfs_dir/etc/sudoers"
$sudo chmod 0400 "$rootfs_dir/etc/shadow"

$sudo ln -snf /usr/share/zoneinfo/Asia/Shanghai "$rootfs_dir/etc/localtime"
$sudo mkdir -p \
  "$rootfs_dir/dev" "$rootfs_dir/proc" "$rootfs_dir/sys" \
  "$rootfs_dir/run" "$rootfs_dir/tmp" \
  "$rootfs_dir/etc/runit/runsvdir/default"
$sudo chmod 01777 "$rootfs_dir/tmp"

for service in seatd udevd dbus elogind polkitd aether-xfce; do
  $sudo ln -snf "/etc/sv/$service" \
    "$rootfs_dir/etc/runit/runsvdir/default/$service"
done
$sudo ln -snf /run/runit/runsvdir/current "$rootfs_dir/var/service"

$sudo env XBPS_ARCH="$xbps_arch" "$xbps_reconfigure" \
  --rootdir="$rootfs_dir" --force glibc-locales
$sudo rm -rf "$rootfs_dir/var/cache/xbps"/*

truncate -s "${ROOTFS_SIZE_MB}M" "$image_tmp"
$sudo mkfs.ext4 -q -F -b 1024 -I 256 \
  -O extent,64bit,flex_bg,huge_file,dir_nlink,extra_isize,dir_index,metadata_csum,^has_journal,^quota,^metadata_csum_seed,^orphan_file,^project,^encrypt,^verity,^casefold,^inline_data,^ea_inode,^bigalloc,^mmp,^fast_commit,^sparse_super2 \
  -E lazy_itable_init=0 \
  -L naos-rootfs -d "$rootfs_dir" "$image_tmp"

chmod 0644 "$image_tmp"
mv -f "$image_tmp" "$OUTPUT"

trap - EXIT INT TERM
