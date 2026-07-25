#!/bin/sh

set -eu
export PATH=/bin:/sbin

mkdir -p /dev /proc /sys /sysroot
mount -t devtmpfs devtmpfs /dev
mount -t proc proc /proc
mount -t sysfs sysfs /sys

root_device=""
stage2_init=""
for arg in $(cat /proc/cmdline); do
  case "$arg" in
    root=*) root_device="${arg#root=}" ;;
    init=*) stage2_init="${arg#init=}" ;;
    rd.break=1) exec sh ;;
  esac
done

try_mount() {
  device="$1"
  [ -b "$device" ] || return 1
  echo "initramfs: trying rootfs on $device"
  # na-kernel registers its ext2/3/4-compatible driver as filesystem "ext".
  mount -t ext "$device" /sysroot 2>/dev/null
}

if [ -n "$root_device" ]; then
  try_mount "$root_device" || root_device=""
fi

if [ -z "$root_device" ]; then
  # Try partitions first for NixOS disk images, then whole disks for raw
  # filesystems such as the Void Linux rootfs image.
  for device in \
    /dev/nvme*n*p* /dev/vd*[0-9] /dev/sd*[0-9] /dev/*part* \
    /dev/nvme*n* /dev/vd[a-z] /dev/sd[a-z]; do
    if try_mount "$device"; then
      root_device="$device"
      break
    fi
  done
fi

if [ -z "$root_device" ]; then
  echo "initramfs: unable to mount a rootfs"
  exec sh
fi

if [ -z "$stage2_init" ]; then
  for candidate in \
    /usr/lib/aether/init \
    /sbin/init; do
    if [ -x "/sysroot$candidate" ]; then
      stage2_init=$candidate
      break
    fi
  done
fi

if [ -z "$stage2_init" ] || [ ! -x "/sysroot$stage2_init" ]; then
  stage2_init=/nix/var/nix/profiles/system/init
fi

mkdir -p /sysroot/dev /sysroot/proc /sysroot/sys /sysroot/run
mount --move /dev /sysroot/dev
mount --move /proc /sysroot/proc
mount --move /sys /sysroot/sys
mount -t tmpfs tmpfs /sysroot/run
echo "initramfs: switching root ($stage2_init)"
exec switch_root /sysroot "$stage2_init"
