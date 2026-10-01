#!/bin/bash
# qemu-grow-mode.sh [fs|dd] - boot the image's kernel and the RAM initramfs in grow
# mode on QEMU's "virt" machine, against a disk that needs growing, and check what
# the guest did to it.
#
# Grow mode has two jobs and the difference is the whole point of the mode:
#
#   fs   the filesystem is smaller than its partition - flash mode extended the
#        partition, and this is what the online resize used to do in the OS
#   dd   the partition is smaller than the disk - a medium installed as a plain
#        image copy: the filesystem fills its partition, and the *partition* is
#        what has to grow first. Nothing running from that medium can do it (the
#        kernel will not re-read a table with a mounted filesystem on it), which is
#        why it happens here, with nothing mounted from the card
#
# Both must end with the filesystem filling everything the disk allows. For dd that
# means the guest writes the partition table *and* gets the kernel to take the new
# size without a reboot. Either way the boot configuration is restored from
# extlinux.conf.bak, the arming counter is cleared, and /var/log/grow.log records it.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCENARIO=${1:-fs}
case "$SCENARIO" in
fs | dd) ;;
*)
	echo "usage: $0 [fs|dd]" >&2
	exit 1
	;;
esac
SCRATCH=${BH_AGENT_WORKSPACE:-/tmp}/growqemu-$SCENARIO-$RANDOM
KREL=6.18.53-ophub
DISK_MIB=64  # the "card"
FS_MIB=16    # the filesystem in the fs case, the whole of p1 in the dd case
mkdir -p "$SCRATCH"
echo "scenario: $SCENARIO   scratch: $SCRATCH"

docker run --rm --privileged -e KREL="$KREL" -e DISK_MIB="$DISK_MIB" -e FS_MIB="$FS_MIB" \
	-e SCENARIO="$SCENARIO" -v /dev:/dev -v "$SCRATCH":/t \
	-v "$REPO/rootfs/boot":/boot:ro -v "$REPO/rootfs/lib/modules/$KREL":/mods:ro \
	alpine:3.22 sh -euxc '
apk add --no-cache qemu-system-aarch64 python3 cpio gzip coreutils e2fsprogs e2fsprogs-extra sfdisk util-linux >/dev/null 2>&1

# ---------------------------------------------------------------- the test disk
truncate -s "$((DISK_MIB * 1048576))" /t/target.img
if [ "$SCENARIO" = dd ]; then
	# p1 is a slice of the disk, exactly what a plain image copy onto a bigger card
	# leaves behind, and the filesystem fills that slice
	printf "label: dos\nlabel-id: 0xabcd1234\nunit: sectors\n\nstart=2048, size=%s, type=83, bootable\n" \
		"$((FS_MIB * 2048))" | sfdisk /t/target.img >/dev/null
else
	# p1 spans the disk and only the filesystem is small
	printf "label: dos\nlabel-id: 0xabcd1234\nunit: sectors\n\nstart=2048, size=+, type=83, bootable\n" |
		sfdisk /t/target.img >/dev/null
fi
LOOP=$(losetup --find --show --partscan /t/target.img)
sleep 1
[ -b "${LOOP}p1" ] || { echo "no partition node for ${LOOP}p1" >&2; exit 1; }
if [ "$SCENARIO" = dd ]; then
	mkfs.ext4 -q -b 4096 -L rootfs "${LOOP}p1"
else
	mkfs.ext4 -q -b 4096 -L rootfs "${LOOP}p1" "$((FS_MIB * 256))"
fi
mkdir -p /mnt/x
mount "${LOOP}p1" /mnt/x
mkdir -p /mnt/x/boot/extlinux /mnt/x/var/lib/growfs /mnt/x/var/log
printf "TIMEOUT 30\nDEFAULT bsp\nLABEL bsp\n  LINUX /boot/vmlinuz-%s\n" "$KREL" > /mnt/x/boot/extlinux/extlinux.conf
cp /mnt/x/boot/extlinux/extlinux.conf /mnt/x/boot/extlinux/extlinux.conf.bak
printf "1\n" > /mnt/x/var/lib/growfs/attempts
before=$(( $(dumpe2fs -h "${LOOP}p1" 2>/dev/null | awk "/^Block count:/{print \$3}") * 4096 / 1048576 ))
before_p1=$(( $(cat "/sys/class/block/$(basename "$LOOP")p1/size") * 512 / 1048576 ))
umount /mnt/x
echo "--- before: a ${before} MiB filesystem in a ${before_p1} MiB partition on a ${DISK_MIB} MiB disk"
[ "$before" -lt "$((DISK_MIB - 1))" ] || { echo "FAIL: nothing for the guest to grow" >&2; exit 1; }

# ------------------------------------------------------- the initramfs to boot
mkdir -p /t/ir/bin /t/ir/dev /t/ir/proc /t/ir/sys /t/ir/tmp /t/ir/lib/modules/$KREL
( cd /t/ir && gzip -dc /boot/ram-initramfs.gz | cpio -idmu --quiet )
for m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk; do
  src=$(find /mods -name "$m.ko" | head -1); [ -n "$src" ] && cp "$src" /t/ir/lib/modules/$KREL/
done
# Load the virtio modules by prepending a wrapper to /init rather than editing the
# real one: the container body is inside a host single-quoted string, and quoting a
# pattern through that is exactly the kind of escaping that breaks silently.
# insmod goes through /bin/busybox itself: applet symlinks only exist once the real
# init has run busybox --install, which is after this wrapper.
mv /t/ir/init /t/ir/init.real
printf "#!/bin/busybox sh\nbb=/bin/busybox\nfor m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk; do\n  \$bb insmod /lib/modules/$KREL/\$m.ko || echo test-wrapper-insmod-\$m-failed\ndone\nexec \$bb sh /init.real\n" > /t/ir/init
chmod 755 /t/ir/init
( cd /t/ir && find . | cpio -o -H newc --quiet | gzip -9 ) > /t/test-initramfs.gz

echo "=== guest (grow mode, $SCENARIO)"
timeout 300 qemu-system-aarch64 \
  -machine virt -cpu cortex-a53 -m 512 \
  -kernel /boot/vmlinuz-$KREL -initrd /t/test-initramfs.gz \
  -append "rdinit=/init ram_mode=grow console=ttyAMA0 panic=1" \
  -drive file=/t/target.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -display none -monitor none -serial stdio -no-reboot 2>&1 | tail -30 || true
echo "=== guest done"

# ---------------------------------------------------------------- what it did
# The table is read from the file: the guest wrote it there, and the loop device
# still carries the table it was attached with.
python3 - "$SCENARIO" "$DISK_MIB" <<PY
import struct, sys
scenario, disk_mib = sys.argv[1], int(sys.argv[2])
f = open("/t/target.img", "rb")
f.seek(446)
e = f.read(16)
ptype, start, count = e[4], int.from_bytes(e[8:12], "little"), int.from_bytes(e[12:16], "little")
want = disk_mib * 2048 - 2048
print(f"p1 after: type=0x{ptype:02x} start={start} count={count} sectors = {count*512//1048576} MiB (want {want*512//1048576} MiB)")
if ptype != 0x83 or start != 2048 or count != want:
    print(f"FAIL: the root partition was not given the rest of the disk (scenario {scenario})")
    sys.exit(1)
PY
# re-attach so the host sees the table the guest wrote
losetup -d "$LOOP"
LOOP=$(losetup --find --show --partscan /t/target.img)
sleep 1
mount "${LOOP}p1" /mnt/x || { echo "FAIL: cannot mount the partition after the guest ran" >&2; exit 1; }
got=$(( $(dumpe2fs -h "${LOOP}p1" 2>/dev/null | awk "/^Block count:/{print \$3}") * 4096 / 1048576 ))
want=$((DISK_MIB - 1))
fail=0
echo "filesystem: was ${before} MiB, now ${got} MiB, partition and disk allow ${want} MiB"
[ "$got" = "$want" ] || { echo "FAIL: the filesystem did not grow to fill what the disk allows" >&2; fail=1; }
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
echo "grow mode ($SCENARIO): filesystem grown, partition correct, boot configuration restored, counter cleared"
'
echo "=== grow-mode test ($SCENARIO) passed"
