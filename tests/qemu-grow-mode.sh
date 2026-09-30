#!/bin/bash
# qemu-grow-mode.sh: boot the image's kernel and the RAM initramfs in grow mode on
# QEMU's "virt" machine, against a disk whose root filesystem is smaller than its
# partition, and check what the guest did to it.
#
# This is the mode the growfs service arms for the next boot, and the one that
# replaced the online resize2fs the service used to run (which wedged this board).
# What has to hold when it runs: the unmounted filesystem is grown to fill its
# partition, the boot configuration is restored from extlinux.conf.bak, the arming
# counter is cleared because the resize succeeded, and /var/log/grow.log on the
# card records it.
#
# The guest gets a real partition (MBR, p1 spanning the disk) with a smaller ext4
# filesystem inside it, so resize2fs has something to do: 16 MiB of filesystem in
# a 63.5 MiB partition.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=${BH_AGENT_WORKSPACE:-/tmp}/growqemu-$RANDOM
KREL=6.18.53-ophub
DISK_MIB=64
FS_MIB=16
mkdir -p "$SCRATCH"
echo "scratch: $SCRATCH"

docker run --rm --privileged -e KREL=$KREL -e DISK_MIB=$DISK_MIB -e FS_MIB=$FS_MIB \
	-v /dev:/dev -v "$SCRATCH":/t \
	-v "$REPO/rootfs/boot":/boot:ro -v "$REPO/rootfs/lib/modules/$KREL":/mods:ro \
	alpine:3.22 sh -euxc '
apk add --no-cache qemu-system-aarch64 cpio gzip coreutils e2fsprogs e2fsprogs-extra sfdisk util-linux >/dev/null 2>&1

# ---------------------------------------------------------------- the test disk
truncate -s "$((DISK_MIB * 1048576))" /t/target.img
printf "label: dos\nlabel-id: 0xabcd1234\nunit: sectors\n\nstart=2048, size=+, type=83, bootable\n" |
	sfdisk /t/target.img >/dev/null
LOOP=$(losetup --find --show --partscan /t/target.img)
sleep 1
[ -b "${LOOP}p1" ] || { echo "no partition node for ${LOOP}p1" >&2; exit 1; }
wanted=$((FS_MIB * 256))   # 4 KiB blocks per MiB
# A filesystem smaller than its partition: that is the whole point of the mode.
mkfs.ext4 -q -b 4096 -L rootfs "${LOOP}p1" "$wanted"
mkdir -p /mnt/x
mount "${LOOP}p1" /mnt/x
mkdir -p /mnt/x/boot/extlinux /mnt/x/var/lib/growfs /mnt/x/var/log
printf "TIMEOUT 30\nDEFAULT bsp\nLABEL bsp\n  LINUX /boot/vmlinuz-%s\n" "$KREL" > /mnt/x/boot/extlinux/extlinux.conf
cp /mnt/x/boot/extlinux/extlinux.conf /mnt/x/boot/extlinux/extlinux.conf.bak
printf "1\n" > /mnt/x/var/lib/growfs/attempts
umount /mnt/x
before=$(dumpe2fs -h "${LOOP}p1" 2>/dev/null | awk "/^Block count:/{print \$3}")
echo "--- before: $before block filesystem in a $(( (DISK_MIB - 1) * 256 )) block partition"

# ------------------------------------------------------- the initramfs to boot
mkdir -p /t/ir/bin /t/ir/dev /t/ir/proc /t/ir/sys /t/ir/tmp /t/ir/lib/modules/$KREL
( cd /t/ir && gzip -dc /boot/ram-initramfs.gz | cpio -idmu --quiet )
for m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk; do
  src=$(find /mods -name "$m.ko" | head -1); [ -n "$src" ] && cp "$src" /t/ir/lib/modules/$KREL/
done
# Load the virtio modules by prepending a wrapper to /init rather than editing the
# real one: the container body is inside a host single-quoted string, and quoting
# a pattern through that is exactly the kind of escaping that breaks silently.
# insmod goes through /bin/busybox itself: applet symlinks only exist once the real
# init has run busybox --install, which is after this wrapper.
mv /t/ir/init /t/ir/init.real
printf "#!/bin/busybox sh\nbb=/bin/busybox\nfor m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk; do\n  \$bb insmod /lib/modules/$KREL/\$m.ko || echo test-wrapper-insmod-\$m-failed\ndone\nexec \$bb sh /init.real\n" > /t/ir/init
chmod 755 /t/ir/init
( cd /t/ir && find . | cpio -o -H newc --quiet | gzip -9 ) > /t/test-initramfs.gz

echo "=== guest (grow mode)"
timeout 300 qemu-system-aarch64 \
  -machine virt -cpu cortex-a53 -m 512 \
  -kernel /boot/vmlinuz-$KREL -initrd /t/test-initramfs.gz \
  -append "rdinit=/init ram_mode=grow console=ttyAMA0 panic=1" \
  -drive file=/t/target.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -display none -monitor none -serial stdio -no-reboot 2>&1 | tail -40 || true
echo "=== guest done"

# ---------------------------------------------------------------- what it did
mount "${LOOP}p1" /mnt/x || { echo "FAIL: cannot mount the partition after the guest ran" >&2; exit 1; }
got=$(dumpe2fs -h "${LOOP}p1" 2>/dev/null | awk "/^Block count:/{print \$3}")
want=$(( (DISK_MIB - 1) * 256 ))
fail=0
echo "filesystem blocks: was ${before:-?}, now ${got:-?}, partition holds $want"
[ "${before:-0}" -lt "$want" ] || { echo "FAIL: the test filesystem was already full size, nothing to grow" >&2; fail=1; }
[ "${got:-0}" = "$want" ] || { echo "FAIL: the filesystem did not grow to fill its partition" >&2; fail=1; }
cmp -s /mnt/x/boot/extlinux/extlinux.conf /mnt/x/boot/extlinux/extlinux.conf.bak ||
	{ echo "FAIL: extlinux.conf was not restored from extlinux.conf.bak" >&2; fail=1; }
grep -q "^DEFAULT bsp$" /mnt/x/boot/extlinux/extlinux.conf ||
	{ echo "FAIL: the boot configuration does not default to bsp" >&2; fail=1; }
[ -e /mnt/x/var/lib/growfs/attempts ] &&
	{ echo "FAIL: the arming counter was not cleared after a successful resize" >&2; fail=1; }
grep -q "resize2fs exit 0" /mnt/x/var/log/grow.log 2>/dev/null ||
	{ echo "FAIL: /var/log/grow.log does not record a successful resize" >&2; fail=1; }
echo "--- grow.log:"
tail -12 /mnt/x/var/log/grow.log 2>/dev/null || true
umount /mnt/x
losetup -d "$LOOP"
[ "$fail" = 0 ] || exit 1
echo "grow mode: filesystem grown, boot configuration restored, counter cleared"
'
echo "=== grow mode test passed"
