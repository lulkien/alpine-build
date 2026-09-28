#!/bin/bash
# Build the flashable SD/eMMC image for the X98H: single ext4 partition that
# holds the whole Alpine rootfs (kernel, modules, extlinux.conf under /boot),
# plus the Allwinner bootloader written raw at KiB 8.
#
# u-boot's distro_bootcmd only scans partitions carrying the MBR bootable flag,
# so the partition must be marked bootable or the card boots nothing.
#
# Runs as root inside a privileged throwaway Debian container; writes /work.
set -euo pipefail

WORK=/work
ROOT="$WORK/rootfs"
BUILDDIR="$WORK/build"
UBOOT="$WORK/u-boot-sunxi-with-spl.bin"
IMGDIR="$WORK/image"
KREL=6.18.53-ophub
NAME=alpine-solovox-z8pro-3.22.6-6.18.53
IMG="$IMGDIR/$NAME.img"
SIZE_MB="${SIZE_MB:-4096}"
DISK_ID=abcd1234
ROOTFS_UUID=9f1c7a3e-5b21-4f8d-9a1c-7b2d4e6f8a90
LOOP=""
MOUNTED=0

# The profile is not chosen here: 02 resolved it and wrote exactly what it
# installed. Reading it back is what lets this stage assert the finished image
# against the same lists, instead of a second hardcoded copy of them.
if [ ! -f "$BUILDDIR/profile.env" ]; then
  echo "build/profile.env missing: run scripts/02-configure-rootfs.sh first" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$BUILDDIR/profile.env"
# headless keeps the original filename; every other profile is named after
# itself, so two images in one release folder cannot be confused
if [ "$PROFILE_NAME" != headless ]; then
  NAME="$NAME-$PROFILE_NAME"
  IMG="$IMGDIR/$NAME.img"
fi

[ -d "$ROOT" ] || { echo "rootfs missing: run 01/02 first" >&2; exit 1; }
[ -f "$UBOOT" ] || { echo "u-boot image missing: $UBOOT" >&2; exit 1; }

cleanup() {
  [ "$MOUNTED" = 1 ] && umount /mnt/target || true
  [ -n "$LOOP" ] && losetup -d "$LOOP" || true
}
trap cleanup EXIT

mkdir -p "$IMGDIR" /mnt/target
rm -f "$IMG"
truncate -s "${SIZE_MB}M" "$IMG"

echo "--- partition table"
sfdisk "$IMG" <<EOF
label: dos
label-id: 0x$DISK_ID
unit: sectors

start=2048, size=+, type=83, bootable
EOF

LOOP=$(losetup --find --show --partscan "$IMG")
sleep 1
P1="${LOOP}p1"
[ -b "$P1" ] || { echo "partition node $P1 missing" >&2; exit 1; }

echo "--- mkfs"
mkfs.ext4 -q -L rootfs -U "$ROOTFS_UUID" -m 1 "$P1"

echo "--- copy rootfs"
mount "$P1" /mnt/target
MOUNTED=1
rsync -aHAX --numeric-ids "$ROOT"/ /mnt/target/
sync
umount /mnt/target
MOUNTED=0
losetup -d "$LOOP"
LOOP=""

echo "--- write u-boot at KiB 8"
dd if="$UBOOT" of="$IMG" bs=1024 seek=8 conv=notrunc conv=fsync status=none
sync

echo "--- verify"
sfdisk -d "$IMG"
LOOP=$(losetup --find --show --partscan "$IMG")
sleep 1
P1="${LOOP}p1"
blkid "$P1" || true
fsck.ext4 -fn "$P1" || true
mount -o ro "$P1" /mnt/target
MOUNTED=1
echo "--- boot tree on image"
ls -l /mnt/target/boot /mnt/target/boot/extlinux
# Structural paths only: what the profile brought is asserted below, against the
# profile's own lists, so this list cannot drift from it.
for chk in "/lib/modules/$KREL" "/boot/vmlinuz-$KREL" "/boot/dtbs/allwinner/sun50i-h618-x98h.dtb" "/boot/dtbs/allwinner/sun50i-h618-z8pro-ethfix.dtb" "/boot/dtbs/allwinner/overlay/sun50i-h618-z8pro.dtbo" "/boot/extlinux/extlinux.conf" "/sbin/init" "/usr/sbin/ota-flash" "/bin/busybox.static" "/boot/flash-initramfs.gz"; do
  # -L as well: /sbin/init is an absolute symlink and does not resolve on the host
  [ -e "/mnt/target$chk" ] || [ -L "/mnt/target$chk" ] || { echo "MISSING on image: $chk" >&2; exit 1; }
done
# openssh-server must not be present: dropbear is the ssh server here
if [ -e /mnt/target/usr/sbin/sshd ]; then
  echo "openssh-server present on image (expected dropbear instead)" >&2
  exit 1
fi

echo "--- profile assertions (from build/profile.env, written by 02)"
INSTALLED_DB=/mnt/target/lib/apk/db/installed
if [ ! -f "$INSTALLED_DB" ]; then
  echo "FAIL: $INSTALLED_DB missing on the image" >&2
  exit 1
fi
for pkg in "${PROFILE_APK_ADD[@]}"; do
  if ! grep -qx "P:$pkg" "$INSTALLED_DB"; then
    echo "FAIL: '$pkg' is in profile '$PROFILE_NAME' but not installed on the image" >&2
    exit 1
  fi
done
for pkg in "${PROFILE_APK_REMOVE[@]}"; do
  if grep -qx "P:$pkg" "$INSTALLED_DB"; then
    echo "FAIL: '$pkg' was removed by profile '$PROFILE_NAME' but is on the image" >&2
    exit 1
  fi
done
for recipe in "${PROFILE_RECIPES[@]}"; do
  if ! grep -qx "P:$recipe" "$INSTALLED_DB"; then
    echo "FAIL: recipe package '$recipe' is not installed on the image" >&2
    exit 1
  fi
done
for entry in "${PROFILE_SERVICES[@]}"; do
  level=${entry%%:*}
  svc=${entry#*:}
  if [ "$level" = "$entry" ]; then level=default; fi
  if [ ! -x "/mnt/target/etc/init.d/$svc" ]; then
    echo "FAIL: profile enables service '$svc' but the image has no /etc/init.d/$svc" >&2
    exit 1
  fi
  if [ ! -L "/mnt/target/etc/runlevels/$level/$svc" ]; then
    echo "FAIL: service '$svc' is not enabled in the $level runlevel on the image" >&2
    exit 1
  fi
done
# the mainline entry has to match whether linux-lts is actually installed: the
# graphics profile removes it, and a label pointing at an absent kernel is a boot
# failure that only shows up on the board
if grep -qx "P:linux-lts" "$INSTALLED_DB"; then
  if ! grep -q '^LABEL mainline$' "$WORK/rootfs/boot/extlinux/extlinux.conf"; then
    echo "FAIL: linux-lts is installed but the mainline label is missing" >&2
    exit 1
  fi
else
  if grep -q '^LABEL mainline$' "$WORK/rootfs/boot/extlinux/extlinux.conf"; then
    echo "FAIL: linux-lts is not installed but the mainline label is still there" >&2
    exit 1
  fi
fi
# the manifest is what makes an installed box auditable: profile, recipe commits,
# package versions
if [ ! -f /mnt/target/etc/solovox/image-manifest ]; then
  echo "FAIL: no /etc/solovox/image-manifest on the image" >&2
  exit 1
fi
if ! grep -qx "profile: $PROFILE_NAME" /mnt/target/etc/solovox/image-manifest; then
  echo "FAIL: the image manifest does not name profile '$PROFILE_NAME'" >&2
  exit 1
fi
echo "    profile '$PROFILE_NAME': ${#PROFILE_APK_ADD[@]} packages installed, ${#PROFILE_APK_REMOVE[@]} removed, ${#PROFILE_RECIPES[@]} recipes, ${#PROFILE_SERVICES[@]} services enabled"
echo "--- required paths present"
grep -q '^LABEL debug$' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: debug label missing from extlinux.conf"; exit 1; }
grep -q '^LABEL flash$' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: flash label missing from extlinux.conf"; exit 1; }
grep -q '^DEFAULT bsp$' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: the image must boot bsp, not flash"; exit 1; }
ir_listing=$'\n'$(gzip -dc "$WORK/rootfs/boot/flash-initramfs.gz" | cpio -t 2>/dev/null)$'\n'
case "$ir_listing" in
  *$'\n'init$'\n'*) ;;
  *) echo "FAIL: flash-initramfs.gz has no /init" >&2; exit 1 ;;
esac
{ [ -x "$WORK/rootfs/usr/sbin/resize2fs" ] || [ -x "$WORK/rootfs/sbin/resize2fs" ]; } || { echo "FAIL: resize2fs missing from the rootfs (no card expansion possible)"; exit 1; }
[ -x "$WORK/rootfs/etc/init.d/growfs" ] || { echo "FAIL: growfs service missing from the rootfs"; exit 1; }
[ -L "$WORK/rootfs/etc/runlevels/boot/growfs" ] || { echo "FAIL: growfs is not enabled in the boot runlevel"; exit 1; }
[ -x "$WORK/rootfs/etc/init.d/mdev-hotplug" ] || { echo "FAIL: mdev-hotplug service missing (hotplug would be dead)"; exit 1; }
[ -L "$WORK/rootfs/etc/runlevels/boot/mdev-hotplug" ] || { echo "FAIL: mdev-hotplug is not enabled in the boot runlevel"; exit 1; }
grep -q 'read_mbr_entry' "$WORK/rootfs/boot/flash-initramfs.gz" 2>/dev/null || true
echo "--- extlinux.conf"
cat /mnt/target/boot/extlinux/extlinux.conf
echo "--- u-boot magic on image"
od -A d -t x1 -N 16 -j 8192 "$IMG"
umount /mnt/target
MOUNTED=0
losetup -d "$LOOP"
LOOP=""

echo "--- image"
ls -lh "$IMG"
sha256sum "$IMG" | tee "$IMG.sha256"
# The build runs as root inside the container; hand the artifacts to whoever
# owns the workspace so later steps (publish) can rewrite the sidecars.
chown "$(stat -c '%u:%g' "$WORK")" "$IMG" "$IMG.sha256"
