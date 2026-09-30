#!/bin/bash
# qemu-flash-mode.sh: end-to-end test of flash mode without the board.
#
# Boots the image's own kernel and the RAM initramfs (ram-initramfs.gz) in flash
# mode on QEMU's "virt" machine
# with a serial console, a NIC that comes up as eth0, and a disk file standing in
# for the SD card. It then lets flash mode do the real thing: fetch the image and
# its bmap over HTTP, write the target, verify. Two cases:
#
#   1. flash succeeds  -> the target must end up byte-identical to the image
#   2. abort before the first byte (metadata 404) -> flash mode must restore
#      /boot/extlinux/extlinux.conf from extlinux.conf.bak, leave the rest of the
#      target alone, and boot the installed system again
#
# Why this exists: the board has no serial console and one dead card, and flash
# mode is the code path that writes the boot medium. QEMU is the only place the
# whole chain can be exercised for real before it runs on hardware.
#
# The kernel here is the board's BSP kernel, which has virtio as modules, so the
# test initramfs gets those modules copied in and insmod'ed by a wrapper /init.
#
# Usage: tests/qemu-flash-mode.sh [image]
# Runs on the host, executes everything inside a throwaway Alpine container.

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
IMG=${1:-$(ls -1t "$REPO"/image/*.img | head -1)}
[ -f "$IMG" ] || { echo "no image: $IMG" >&2; exit 1; }
BASE=$(basename "$IMG")
KREL=6.18.53-ophub
PORT=8099

echo "image : $IMG"
echo "base  : $BASE"

# flash mode checks the bmap against the image, so it has to describe THIS image
if [ ! -f "$IMG.bmap" ] || [ "$IMG" -nt "$IMG.bmap" ]; then
	echo "--- generating $BASE.bmap"
	python3 "$REPO/tools/mkbmap.py" "$IMG" "$IMG.bmap"
fi

# Everything below runs in one container: qemu, an HTTP server on 10.0.2.2:8099
# (QEMU's slirp gateway is the container itself) and the checks afterwards.
docker run --rm --privileged -v /dev:/dev -v "$REPO":/w:ro \
	-v "$REPO/image":/img:ro -v "$REPO/rootfs/boot":/boot:ro \
	-e BASE="$BASE" -e KREL="$KREL" -e PORT="$PORT" \
	alpine:3.22 sh -euxc '
apk add --no-cache qemu-system-aarch64 python3 cpio gzip coreutils e2fsprogs >/dev/null 2>&1
mkdir -p /t && cd /t

echo "=== test initramfs: shipped flash-init plus the virtio modules"
mkdir -p /t/ir
( cd /t/ir && gzip -dc /boot/ram-initramfs.gz | cpio -idmu --quiet )
ls /t/ir
mkdir -p /t/ir/lib/modules/$KREL
for m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk virtio_net; do
  src=$(find /w/rootfs/lib/modules/$KREL -name "$m.ko" | head -1)
  [ -n "$src" ] || { echo "note: $m.ko not in the module tree, skipping"; continue; }
  cp "$src" /t/ir/lib/modules/$KREL/
done
# load them before the real init runs: virtio-blk gives /dev/vda, virtio-net eth0
awk -v krel="$KREL" "
  /^\\\$BUSYBOX --install -s \/bin$/ && !done {
    print;
    print \"for m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk virtio_net; do\";
    print \"  insmod /lib/modules/\" krel \"/\\\$m.ko 2>/dev/null || true\";
    print \"done\";
    done = 1;
    next;
  }
  { print }
" /t/ir/init > /t/ir/init.new
mv /t/ir/init.new /t/ir/init
chmod 755 /t/ir/init
grep -n "insmod" /t/ir/init | head -3
cat > /t/ir/probe.sh <<"EOS"
#!/bin/busybox sh
# test-only: measure what this guest really receives before flash mode writes
url=$(awk "{ for (i = 1; i <= NF; i++) if ($i ~ /^ota_url=/) { sub(/^ota_url=/, \"\", $i); print $i; exit } }" /proc/cmdline)
want=$(awk "{ for (i = 1; i <= NF; i++) if ($i ~ /^ota_size=/) { sub(/^ota_size=/, \"\", $i); print $i; exit } }" /proc/cmdline)
echo "probe> url [$url] expecting [$want] raw bytes"
n=$(wget -q -T 30 -O - "$url" | gzip -dc | wc -c)
echo "probe> received and decompressed: [$n] bytes"
if [ "$n" = "$want" ]; then echo "probe> STREAM OK"; else echo "probe> STREAM SHORT"; fi
true
EOS
chmod 755 /t/ir/probe.sh
awk "/Writing .*OTA_TARGET now/ { print \". /probe.sh\" } { print }" \
  /t/ir/init > /t/ir/init.new2
mv /t/ir/init.new2 /t/ir/init
# awk wrote a fresh file: the exec bit has to come back or the kernel refuses /init
chmod 755 /t/ir/init
ls -l /t/ir/init
grep -n "probe.sh" /t/ir/init
( cd /t/ir && find . | cpio -o -H newc --quiet | gzip -9 ) > /t/test-initramfs.gz
ls -l /t/test-initramfs.gz

echo "=== serving the published artifacts on 0.0.0.0:$PORT (guest sees 10.0.2.2)"
python3 -m http.server "$PORT" --directory /img --bind 0.0.0.0 >/dev/null 2>&1 &
SRV=$!
sleep 2
wget -q -O /dev/null "http://127.0.0.1:$PORT/$BASE" && echo "http check: ok" || { echo "http check FAILED"; exit 1; }

IMG_SIZE=$(stat -c %s /img/"$BASE")
IMG_SHA=$(cat /img/"$BASE".sha256)
echo "image size $IMG_SIZE sha $IMG_SHA"

run_qemu() { # $1 = log file, $2 = ota_url, $3 = target device, $4 = rootpart
  # sidecars follow the flash-init convention: strip the .gz, then .sha256/.size/.bmap
  bmap_url="${2%.gz}.bmap"
  timeout 900 qemu-system-aarch64 \
    -machine virt -cpu cortex-a53 -m 1024 \
    -kernel /boot/vmlinuz-$KREL \
    -initrd /t/test-initramfs.gz \
    -append "rdinit=/init console=ttyAMA0 net.ifnames=0 panic=1 ota_url=$2 ota_sha256=$IMG_SHA ota_size=$IMG_SIZE ota_bmap=$bmap_url ota_target=$3 ota_rootpart=$4 ota_mode=bmap ota_hostname=qemutest" \
    -drive file=/t/target.img,format=raw,if=none,id=d0 \
    -device virtio-blk-pci,drive=d0 \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -display none -monitor none -serial stdio -no-reboot \
    > "$1" 2>&1 || true
}

echo
echo "=== CASE 1: flash succeeds (target starts zeroed)"
truncate -s "$IMG_SIZE" /t/target.img
run_qemu /t/log1.txt "http://10.0.2.2:$PORT/$BASE" /dev/vda /dev/vda1
echo "--- flash mode log (probe, bmap and write lines)"
grep -E "probe>|flash>|\[bmap\]|\[write\]|\[verify\]|\[error\]|wget" /t/log1.txt | head -40
echo "--- host-side target after the run (first 64 bytes and hash)"
od -A d -c -N 64 /t/target.img | head -4
sha256sum /t/target.img | cut -c1-64
sha256sum /img/"$BASE" | cut -c1-64
if ! grep -q "range checksums were verified" /t/log1.txt; then
  echo "CASE1 FAIL: no verification line"; grep -n "error\|die\|failed" /t/log1.txt | head -20; exit 1
fi
grep -q "rebooting into it" /t/log1.txt || { echo "CASE1 FAIL: did not reboot into the new image"; exit 1; }
if cmp -s /t/target.img /img/"$BASE"; then echo "CASE1 RESULT=IDENTICAL"; else echo "CASE1 RESULT=DIFFERS"; exit 1; fi

echo
echo "=== CASE 2: abort before the first byte (metadata 404) must restore the backup"
truncate -s "$IMG_SIZE" /t/target.img
dd if=/img/"$BASE" of=/t/target.img bs=4M status=none conv=fsync
mkdir -p /mnt/t2
mount /dev/loop0 /mnt/t2 2>/dev/null || { losetup /dev/loop0 /t/target.img; mount /dev/loop0 /mnt/t2; }
printf "DEFAULT debug\n" > /mnt/t2/boot/extlinux/extlinux.conf.bak
echo "abort-marker" > /mnt/t2/root/abort-marker
cat /mnt/t2/boot/extlinux/extlinux.conf | head -2
sync
umount /mnt/t2
losetup -d /dev/loop0 2>/dev/null || true

run_qemu /t/log2.txt "http://10.0.2.2:$PORT/does-not-exist.img.gz" /dev/vda /dev/vda1
echo "--- flash mode log (last 25 lines)"
tail -25 /t/log2.txt
grep -q "restoring the boot configuration" /t/log2.txt || { echo "CASE2 FAIL: no restore attempt"; exit 1; }

mount /dev/loop0 /mnt/t2 2>/dev/null || { losetup /dev/loop0 /t/target.img; mount /dev/loop0 /mnt/t2; }
head -2 /mnt/t2/boot/extlinux/extlinux.conf
if head -1 /mnt/t2/boot/extlinux/extlinux.conf | grep -q "DEFAULT debug"; then
  echo "CASE2 RESULT=RESTORED_FROM_BACKUP"
else
  echo "CASE2 RESULT=NOT_RESTORED"; umount /mnt/t2; exit 1
fi
[ -f /mnt/t2/root/abort-marker ] && echo "CASE2 RESULT=UNTOUCHED_OTHERWISE" || { echo "CASE2 FAIL: target lost files"; exit 1; }
umount /mnt/t2
losetup -d /dev/loop0 2>/dev/null || true

kill $SRV 2>/dev/null || true
echo
echo "=== ALL CASES PASSED"
'
