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
IMGDIR="$WORK/image"

# Board data: build/board.env is written by 03 (and by build.py before any
# container runs). The image name, its size, the disk and filesystem IDs, the
# kernel release and the devicetree file names all come from there - this stage
# names none of them itself.
[ -f "$BUILDDIR/board.env" ] || {
  echo "build/board.env missing: run scripts/03-configure-rootfs.sh first" >&2
  exit 1
}
# shellcheck disable=SC1090
. "$BUILDDIR/board.env"
UBOOT="$WORK/$BOARD_UBOOT_FILE"
KREL="$BOARD_KERNEL_RELEASE"
NAME="$BOARD_IMAGE_NAME"
IMG="$IMGDIR/$NAME.img"
SIZE_MB="${SIZE_MB:-$BOARD_IMAGE_SIZE_MB}"
DISK_ID="$BOARD_DISK_ID"
ROOTFS_UUID="$BOARD_ROOTFS_UUID"
LOOP=""
MOUNTED=0

# The profile is not chosen here: 02 resolved it and wrote exactly what it
# installed. Reading it back is what lets this stage assert the finished image
# against the same lists, instead of a second hardcoded copy of them.
if [ ! -f "$BUILDDIR/profile.env" ]; then
  echo "build/profile.env missing: run scripts/03-configure-rootfs.sh first" >&2
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

[ -d "$ROOT" ] || { echo "rootfs missing: run 02/03 first" >&2; exit 1; }
[ -f "$UBOOT" ] || { echo "u-boot image missing: $UBOOT" >&2; exit 1; }

cleanup() {
  [ "$MOUNTED" = 1 ] && umount /mnt/target || true
  [ -n "$LOOP" ] && losetup -d "$LOOP" || true
}
trap cleanup EXIT

# The image only has to hold the rootfs until the filesystem is grown to the card
# on the first boot, so its size is a real cost rather than a free round number:
# every block the image leaves unmapped has to be read and hashed to prove it holds
# zeros before a sparse flash may write, and a full flash writes all of it. Content
# plus headroom, asserted here with both numbers, so a fatter profile fails the
# build with a reason instead of failing mid-rsync with ENOSPC.
ROOT_MB=$(du -sm "$ROOT" | awk '{ print $1 }')
HEADROOM_MB="${HEADROOM_MB:-256}"
if [ "$((ROOT_MB + HEADROOM_MB))" -gt "$SIZE_MB" ]; then
  echo "FAIL: the rootfs is ${ROOT_MB} MiB and image_size_mb is ${SIZE_MB} MiB: that leaves less" >&2
  echo "      than the ${HEADROOM_MB} MiB headroom this needs (filesystem metadata, the journal," >&2
  echo "      and a first boot's writes). Raise image_size_mb in board/common/board.toml, or trim" >&2
  echo "      the profile." >&2
  exit 1
fi
echo "--- image: ${SIZE_MB} MiB for a ${ROOT_MB} MiB rootfs (${HEADROOM_MB} MiB headroom)"

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
# Structural paths only, and the board's names come from build/board.env: what the
# profile brought is asserted below against the profile's own lists, so neither
# list can drift from the files it describes.
CHECKS=("/lib/modules/$KREL" "/boot/vmlinuz-$KREL" "/boot/dtbs/allwinner/$BOARD_DTB"
        "/boot/dtbs/allwinner/$BOARD_BOOT_DTB" "/boot/extlinux/extlinux.conf"
        "/sbin/init" "/bin/busybox.static" "/boot/ram-initramfs.gz")
for overlay in "${BOARD_OVERLAYS[@]}"; do
  CHECKS+=("/boot/dtbs/allwinner/overlay/$(basename "${overlay%.dtso}").dtbo")
done
for chk in "${CHECKS[@]}"; do
  # -L as well: /sbin/init is an absolute symlink and does not resolve on the host
  [ -e "/mnt/target$chk" ] || [ -L "/mnt/target$chk" ] || { echo "MISSING on image: $chk" >&2; exit 1; }
done
# Everything the runtime trees carry has to be at the same path in the image: the
# trees mirror the target, so no file has to be listed here by name.
for tree in "${BOARD_RUNTIME_ROOTS[@]}"; do
  while IFS= read -r rel; do
    [ -e "/mnt/target/$rel" ] || [ -L "/mnt/target/$rel" ] ||
      { echo "MISSING on image: /$rel (from $tree)" >&2; exit 1; }
  done < <(cd "$WORK/$tree" && find . \( -type f -o -type l \) -printf '%P\n')
done
# The private files are the ones whose mode matters beyond git's executable bit:
# an authorized_keys that is not 0600 and root-owned is a key sshd/dropbear
# refuses, and the failure looks like the key itself being wrong.
for item in "${BOARD_PRIVATE_FILES[@]}"; do
  read -r mode owner group <<<"$(stat -c '%a %u %g' "/mnt/target/$item")"
  [ "$mode" = 600 ] || { echo "FAIL: /$item is mode $mode on the image, expected 600" >&2; exit 1; }
  [ "$owner" = 0 ] && [ "$group" = 0 ] ||
    { echo "FAIL: /$item is owned by $owner:$group on the image, expected 0:0" >&2; exit 1; }
done
# openssh-server must not be present: dropbear is the ssh server here
if [ -e /mnt/target/usr/sbin/sshd ]; then
  echo "openssh-server present on image (expected dropbear instead)" >&2
  exit 1
fi

echo "--- profile assertions (from build/profile.env, written by 03)"
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
if ! grep -qx "board: $BOARD_MACHINE  hostname $BOARD_HOSTNAME" /mnt/target/etc/solovox/image-manifest; then
  echo "FAIL: the image manifest does not name board '$BOARD_MACHINE'" >&2
  exit 1
fi
if ! grep -q "^  kernel: $KREL " /mnt/target/etc/solovox/image-manifest; then
  echo "FAIL: the image manifest does not record kernel '$KREL'" >&2
  exit 1
fi
echo "    board '$BOARD_MACHINE' (kernel $KREL): ${#PROFILE_APK_ADD[@]} packages installed, ${#PROFILE_APK_REMOVE[@]} removed, ${#PROFILE_RECIPES[@]} recipes, ${#PROFILE_SERVICES[@]} services enabled"
echo "--- required paths present"
grep -q '^LABEL debug$' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: debug label missing from extlinux.conf"; exit 1; }
grep -q '^LABEL flash$' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: flash label missing from extlinux.conf"; exit 1; }
grep -q '^LABEL grow$' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: grow label missing from extlinux.conf"; exit 1; }
grep -q '^DEFAULT bsp$' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: the image must boot bsp, not flash or grow"; exit 1; }
# Both modes boot the same RAM initramfs; the labels are what select the mode, so
# a drift between them is a boot that does the wrong thing rather than a failure.
flash_initrd=$(awk '$1 == "LABEL" { inl = ($2 == "flash") } inl && $1 == "INITRD" { print $2; exit }' "$WORK/rootfs/boot/extlinux/extlinux.conf")
grow_initrd=$(awk '$1 == "LABEL" { inl = ($2 == "grow") } inl && $1 == "INITRD" { print $2; exit }' "$WORK/rootfs/boot/extlinux/extlinux.conf")
[ -n "$flash_initrd" ] && [ "$flash_initrd" = "$grow_initrd" ] ||
  { echo "FAIL: flash and grow labels boot different initramfs ('$flash_initrd' vs '$grow_initrd')"; exit 1; }
[ -f "/mnt/target$flash_initrd" ] || { echo "FAIL: $flash_initrd (both labels) is not on the image"; exit 1; }
grep -q 'ram_mode=flash' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: the flash label does not ask for flash mode"; exit 1; }
grep -q 'ram_mode=grow' "$WORK/rootfs/boot/extlinux/extlinux.conf" || { echo "FAIL: the grow label does not ask for grow mode"; exit 1; }
# Both RAM labels must keep the kernel from disabling unused clocks and power
# domains: the eMMC controller's are among them, and with them off every write to
# the device stalls the CPU for seconds.
for _label in flash grow; do
  awk -v l="$_label" '$1 == "LABEL" { inl = ($2 == l); next } inl && $1 == "APPEND" { print; exit }' \
    "$WORK/rootfs/boot/extlinux/extlinux.conf" | grep -q 'clk_ignore_unused' || {
    echo "FAIL: the $_label label does not carry clk_ignore_unused (the RAM boot would stall on eMMC writes)"; exit 1; }
  awk -v l="$_label" '$1 == "LABEL" { inl = ($2 == l); next } inl && $1 == "APPEND" { print; exit }' \
    "$WORK/rootfs/boot/extlinux/extlinux.conf" | grep -q 'pm_genpd_ignore_unused' || {
    echo "FAIL: the $_label label does not carry pm_genpd_ignore_unused"; exit 1; }
done
ir_listing=$'\n'$(gzip -dc "$WORK/rootfs$flash_initrd" | cpio -t 2>/dev/null)$'\n'
for entry in init bin/grow-rootfs sbin/e2fsck usr/sbin/resize2fs; do
  case "$ir_listing" in
    *$'\n'"$entry"$'\n'*) ;;
    *) echo "FAIL: the RAM initramfs has no $entry" >&2; exit 1 ;;
  esac
done
{ [ -x "$WORK/rootfs/usr/sbin/resize2fs" ] || [ -x "$WORK/rootfs/sbin/resize2fs" ]; } || { echo "FAIL: resize2fs missing from the rootfs (grow mode runs it from the initramfs)"; exit 1; }
[ -x "$WORK/rootfs/etc/init.d/growfs" ] || { echo "FAIL: growfs service missing from the rootfs"; exit 1; }
[ -L "$WORK/rootfs/etc/runlevels/default/growfs" ] || { echo "FAIL: growfs is not enabled in the default runlevel"; exit 1; }
[ -x "$WORK/rootfs/etc/init.d/mdev-hotplug" ] || { echo "FAIL: mdev-hotplug service missing (hotplug would be dead)"; exit 1; }
[ -L "$WORK/rootfs/etc/runlevels/boot/mdev-hotplug" ] || { echo "FAIL: mdev-hotplug is not enabled in the boot runlevel"; exit 1; }
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
