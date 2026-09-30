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
# The Alpine release is board data (board/common/board.toml). build.sh resolved it
# into build/board.env before this container started; this container has no
# python3, so the file is a hard requirement here.
[ -f "$WORK/build/board.env" ] || {
  echo "build/board.env missing: run build.sh (or scripts/00-fetch-inputs.sh) first" >&2
  exit 1
}
# shellcheck disable=SC1091
. "$WORK/build/board.env"
BRANCH="$BOARD_ALPINE_BRANCH"
RELEASE="$BOARD_ALPINE_RELEASE"
MIRROR="$BOARD_ALPINE_MIRROR"
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
# busybox-static and cpio feed the RAM initramfs, e2fsprogs-extra provides the
# resize2fs grow mode runs from inside it, alpine-base is the rootfs floor.
# Removing one of those does not produce a smaller image, it produces a broken
# build.
chroot "$ROOT" /sbin/apk add --no-cache \
  alpine-base e2fsprogs e2fsprogs-extra busybox-static cpio

cleanup
echo "--- rootfs size"
du -sh "$ROOT"
