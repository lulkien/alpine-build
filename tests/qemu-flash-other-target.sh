#!/bin/bash
# qemu-flash-other-target.sh: flash mode whose target is NOT the disk holding the
# boot configuration - flashing the eMMC from the SD, the case ota-flash refuses by
# design and a hand-armed flash label allows.
#
# What has to hold: the boot configuration on the disk that is *not* written comes
# back to the installed system before the slow part, so a successful flash (or a
# reset in the middle of one) boots the OS instead of re-entering flash mode. And
# the target still ends up matching the image.
#
# Two virtio disks: vda is the boot disk (its p1 holds extlinux.conf, armed, with
# its backup beside it), vdb is the all-zero target the image gets written to.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=${BH_AGENT_WORKSPACE:-/tmp}/otatarget-$RANDOM
KREL=6.18.53-ophub
SRC=/tmp/otasrv
[ -d "$SRC" ] || { echo "no $SRC with test.img*; create it first" >&2; exit 1; }
mkdir -p "$SCRATCH"
cp "$SRC"/test.img "$SRC"/test.img.gz "$SRC"/test.img.sha256 "$SRC"/test.img.size "$SCRATCH"/
python3 "$REPO/tools/mkbmap.py" "$SCRATCH/test.img" "$SCRATCH/test.img.bmap"
echo "scratch: $SCRATCH"

docker run --rm --privileged -e KREL="$KREL" -v /dev:/dev -v "$SCRATCH":/srv \
	-v "$REPO/rootfs/boot":/boot:ro -v "$REPO/rootfs/lib/modules/$KREL":/mods:ro \
	alpine:3.22 sh -euxc '
apk add --no-cache qemu-system-aarch64 python3 cpio gzip coreutils e2fsprogs e2fsprogs-extra sfdisk util-linux >/dev/null 2>&1
mkdir -p /t

# ------------------------------------------------- the disk that is NOT written
truncate -s 33554432 /t/boot.img
printf "label: dos\nlabel-id: 0xdeadbeef\nunit: sectors\n\nstart=2048, size=+, type=83, bootable\n" |
	sfdisk /t/boot.img >/dev/null
L1=$(losetup --find --show --partscan /t/boot.img)
sleep 1
mkfs.ext4 -q -b 4096 -L rootfs "${L1}p1"
mkdir -p /mnt/b
mount "${L1}p1" /mnt/b
mkdir -p /mnt/b/boot/extlinux
printf "TIMEOUT 30\nDEFAULT flash\nLABEL flash\n  LINUX /boot/vmlinuz-x\n  INITRD /boot/ram-initramfs.gz\n  APPEND rdinit=/init ota_target=/dev/vdb\nLABEL bsp\n  LINUX /boot/vmlinuz-x\n" > /mnt/b/boot/extlinux/extlinux.conf
printf "TIMEOUT 30\nDEFAULT bsp\nLABEL flash\n  LINUX /boot/vmlinuz-x\nLABEL bsp\n  LINUX /boot/vmlinuz-x\n" > /mnt/b/boot/extlinux/extlinux.conf.bak
umount /mnt/b
losetup -d "$L1"

# ----------------------------------------------------------- the all-zero target
truncate -s 33554432 /t/target.img

# ------------------------------------------------------- the initramfs to boot
mkdir -p /t/ir/bin /t/ir/dev /t/ir/proc /t/ir/sys /t/ir/tmp /t/ir/lib/modules/$KREL
( cd /t/ir && gzip -dc /boot/ram-initramfs.gz | cpio -idmu --quiet )
for m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk virtio_net; do
  src=$(find /mods -name "$m.ko" | head -1); [ -n "$src" ] && cp "$src" /t/ir/lib/modules/$KREL/
done
# wrapper, not an edit of the real init: see tests/qemu-grow-mode.sh for why the
# container body must not grow single quotes or multi-level escapes
mv /t/ir/init /t/ir/init.real
printf "#!/bin/busybox sh\nbb=/bin/busybox\nfor m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk virtio_net; do\n  \$bb insmod /lib/modules/$KREL/\$m.ko || echo test-wrapper-insmod-\$m-failed\ndone\nexec \$bb sh /init.real\n" > /t/ir/init
chmod 755 /t/ir/init
( cd /t/ir && find . | cpio -o -H newc --quiet | gzip -9 ) > /t/test-initramfs.gz

python3 -m http.server 8099 --directory /srv --bind 0.0.0.0 >/dev/null 2>&1 &
sleep 2
SIZE=$(stat -c %s /srv/test.img)
SHA=$(cat /srv/test.img.sha256)

echo "=== guest (flash mode, target /dev/vdb, boot config on /dev/vda1)"
timeout 600 qemu-system-aarch64 \
  -machine virt -cpu cortex-a53 -m 512 \
  -kernel /boot/vmlinuz-$KREL -initrd /t/test-initramfs.gz \
  -append "rdinit=/init ram_mode=flash console=ttyAMA0 net.ifnames=0 panic=1 ota_url=http://10.0.2.2:8099/test.img.gz ota_sha256=$SHA ota_size=$SIZE ota_bmap=http://10.0.2.2:8099/test.img.bmap ota_target=/dev/vdb ota_rootpart=/dev/vda1 ota_mode=bmap ota_hostname=qemutest" \
  -drive file=/t/boot.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -drive file=/t/target.img,format=raw,if=none,id=d1 -device virtio-blk-pci,drive=d1 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none -monitor none -serial stdio -no-reboot 2>&1 | tee /t/guest.log | tail -25
echo "=== guest done"

echo "=== the boot configuration on the disk that was not written"
L1=$(losetup --find --show --partscan /t/boot.img)
sleep 1
mount "${L1}p1" /mnt/b
if cmp -s /mnt/b/boot/extlinux/extlinux.conf /mnt/b/boot/extlinux/extlinux.conf.bak; then
	echo "OK: extlinux.conf is back to its backup"
else
	echo "FAIL: the boot configuration on the unwritten disk is still armed:" >&2
	cat /mnt/b/boot/extlinux/extlinux.conf >&2
fi
grep -q "^DEFAULT bsp$" /mnt/b/boot/extlinux/extlinux.conf ||
	echo "FAIL: DEFAULT is not bsp on the unwritten disk" >&2
umount /mnt/b
losetup -d "$L1"
grep -q "putting the installed system back as the boot default" /t/guest.log &&
	echo "OK: the guest logged the disarm" ||
	echo "FAIL: the guest never disarmed the boot configuration" >&2

echo "=== target vs the image (reference patched the way the guest patches it)"
python3 - <<PYX
import struct
ref = bytearray(open("/srv/test.img", "rb").read())
tgt = open("/t/target.img", "rb").read(512)
start, count = struct.unpack("<II", ref[454:462])
new_count = 33554432 // 512 - start
print(f"reference p1: type=0x{tgt[450]:02x} start={start} count={count}; guest should write {new_count}")
if tgt[450] == 0x83 and new_count > count:
    got = struct.unpack("<I", tgt[458:462])[0]
    assert got == new_count, f"guest wrote {got}, wanted {new_count}"
    struct.pack_into("<I", ref, 458, got)
else:
    print("no extension expected for this target size")
open("/t/ref-patched.img", "wb").write(ref)
PYX
if dd if=/t/target.img bs=1M count=16 status=none | cmp - /t/ref-patched.img; then
	echo "OK: the target matches the image"
else
	echo "FAIL: the target does not match the image" >&2
	exit 1
fi
'
echo "=== other-target flash test passed"
