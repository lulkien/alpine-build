#!/bin/bash
# Bootstrap an aarch64 Alpine (v3.22 stable) rootfs for the X98H (Allwinner H618).
# Runs as root inside a throwaway Debian container; the host registers
# qemu-aarch64 binfmt with the F flag, so aarch64 binaries in the chroot run
# without copying qemu into it. Writes only into /work.
#
# Why a chroot instead of `apk.static --root`: apk-tools 3.x rejected every
# APKINDEX fetched through --root as UNTRUSTED even with the signing key in
# place, so the chroot path (native apk, minirootfs keys) is used instead.
set -euo pipefail

WORK=/work
ROOT="$WORK/rootfs"
BRANCH=v3.22
RELEASE=3.22.6
MIRROR=https://dl-cdn.alpinelinux.org/alpine
TARBALL=alpine-minirootfs-${RELEASE}-aarch64.tar.gz

mkdir -p "$ROOT"
if [ ! -f "$WORK/$TARBALL" ]; then
  curl -sSfLo "$WORK/$TARBALL" "$MIRROR/$BRANCH/releases/aarch64/$TARBALL"
fi
tar -xzf "$WORK/$TARBALL" -C "$ROOT"

printf '%s\n' "$MIRROR/$BRANCH/main" "$MIRROR/$BRANCH/community" > "$ROOT/etc/apk/repositories"
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"

cleanup() {
  for m in proc dev sys; do
    mountpoint -q "$ROOT/$m" && umount -R "$ROOT/$m" || true
  done
}
trap cleanup EXIT

mount -t proc proc "$ROOT/proc"
mount --rbind /dev "$ROOT/dev"
mount --rbind /sys "$ROOT/sys"
mkdir -p "$ROOT/dev/pts"

echo "--- apk update"
chroot "$ROOT" /sbin/apk update

echo "--- apk add"
# Only what the BUILD needs, not what the image is: the image's own packages
# (ssh server and clients, DHCP client, tzdata, dosfstools, alpine-conf,
# linux-lts, the mesa userspace) come from the profile in stage 2.
#
# busybox-static and cpio feed the flash initramfs, e2fsprogs-extra provides the
# resize2fs the growfs service runs, alpine-base is the rootfs floor. Removing
# one of those does not produce a smaller image, it produces a broken build.
chroot "$ROOT" /sbin/apk add --no-cache \
  alpine-base e2fsprogs e2fsprogs-extra busybox-static cpio

cleanup
echo "--- rootfs size"
du -sh "$ROOT"
