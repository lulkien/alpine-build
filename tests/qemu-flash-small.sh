#!/bin/bash
# qemu-flash-small.sh: debug helper. Same chain as tests/qemu-flash-mode.sh but
# against the 16 MiB test artifact, so a full flash-mode cycle takes seconds
# instead of minutes. Prints the guest log and compares the target with the
# reference image afterwards.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=${BH_AGENT_WORKSPACE:-/tmp}/otasrv-$RANDOM
KREL=6.18.53-ophub
SRC=/tmp/otasrv
[ -d "$SRC" ] || { echo "no $SRC with test.img*; create it first" >&2; exit 1; }
mkdir -p "$SCRATCH"
cp "$SRC"/test.img "$SRC"/test.img.gz "$SRC"/test.img.sha256 "$SRC"/test.img.size "$SCRATCH"/
python3 "$REPO/tools/mkbmap.py" "$SCRATCH/test.img" "$SCRATCH/test.img.bmap"
echo "artifact: $(stat -c %s "$SCRATCH/test.img") bytes"

# POISON=1: pre-dirty the whole target, so every block the image does not map is
# non-zero. The guest must refuse before it writes anything, and the installed
# system must survive — this is the "card that already held another image" case.
docker run --rm --privileged -e POISON="${POISON:-0}" -v /dev:/dev -v "$SCRATCH":/srv:ro -v "$REPO/rootfs/boot":/boot:ro \
	-v "$REPO/rootfs/lib/modules/$KREL":/mods:ro -e KREL=$KREL \
	alpine:3.22 sh -euxc '
apk add --no-cache qemu-system-aarch64 python3 cpio gzip coreutils >/dev/null 2>&1
mkdir -p /t/ir/bin /t/ir/dev /t/ir/proc /t/ir/sys /t/ir/tmp /t/ir/lib/modules/$KREL
( cd /t/ir && gzip -dc /boot/ram-initramfs.gz | cpio -idmu --quiet )
for m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk virtio_net; do
  src=$(find /mods -name "$m.ko" | head -1); [ -n "$src" ] && cp "$src" /t/ir/lib/modules/$KREL/
done
awk -v krel="$KREL" "
  /^\\\$BUSYBOX --install -s \\/bin$/ && !done {
    print;
    print \"for m in failover net_failover virtio_pci_modern_dev virtio_pci_legacy_dev virtio_pci virtio_blk virtio_net; do\";
    print \"  insmod /lib/modules/\" krel \"/\\\$m.ko 2>/dev/null || true\";
    print \"done\";
    done = 1; next;
  }
  { print }
" /t/ir/init > /t/ir/init.new
mv /t/ir/init.new /t/ir/init
chmod 755 /t/ir/init
( cd /t/ir && find . | cpio -o -H newc --quiet | gzip -9 ) > /t/test-initramfs.gz

python3 -m http.server 8099 --directory /srv --bind 0.0.0.0 >/dev/null 2>&1 &
sleep 2
SIZE=$(stat -c %s /srv/test.img)
SHA=$(cat /srv/test.img.sha256)
truncate -s 33554432 /t/target.img
[ "${POISON:-0}" = 1 ] && dd if=/dev/urandom of=/t/target.img bs=1M count=32 conv=notrunc 2>/dev/null
true
timeout 600 qemu-system-aarch64 \
  -machine virt -cpu cortex-a53 -m 512 \
  -kernel /boot/vmlinuz-$KREL -initrd /t/test-initramfs.gz \
  -append "rdinit=/init console=ttyAMA0 net.ifnames=0 panic=1 ota_url=http://10.0.2.2:8099/test.img.gz ota_sha256=$SHA ota_size=$SIZE ota_bmap=http://10.0.2.2:8099/test.img.bmap ota_target=/dev/vda ota_rootpart=/dev/vda1 ota_mode=bmap ota_hostname=qemutest" \
  -drive file=/t/target.img,format=raw,if=none,id=d0 -device virtio-blk-pci,drive=d0 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -display none -monitor none -serial stdio -no-reboot 2>&1 | tail -40 || true

echo "=== target vs reference (first 16 MiB, reference patched the way the guest patches it)"
# flash-init hands the rest of a bigger card to the root partition before it
# reboots, so a target larger than the artifact legitimately differs from the
# artifact in those 4 bytes. Patch the reference the same way, and check it.
python3 - <<'PYX'
import struct
ref = bytearray(open("/srv/test.img", "rb").read())
tgt = open("/t/target.img", "rb").read(512)
start, count = struct.unpack("<II", ref[454:462])
new_count = 33554432 // 512 - start
print(f"reference p1: type=0x{tgt[450]:02x} start={start} count={count}; guest should write {new_count}")
if tgt[450] == 0x83 and new_count > count:
    got = struct.unpack("<I", tgt[458:462])[0]
    print("target partition count:", got, "OK" if got == new_count else "MISMATCH (did the extension run?)")
    ref[458:462] = struct.pack("<I", new_count)
else:
    print("no extension expected for this target size")
open("/t/ref-patched.img", "wb").write(bytes(ref))
PYX
dd if=/t/target.img bs=1M count=16 status=none | cmp - /t/ref-patched.img && echo "SMALL_RESULT=IDENTICAL" || echo "SMALL_RESULT=DIFFERS"
if [ "${POISON:-0}" = 1 ]; then
	echo "(POISON=1: DIFFERS is the expected result — look for the refusal line above)"
fi
od -A d -c -N 32 /t/target.img | head -2
'
