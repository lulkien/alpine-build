apk add --no-cache qemu-system-aarch64 python3 cpio gzip coreutils e2fsprogs util-linux >/dev/null 2>&1
mkdir -p /t && cd /t
# Loop devices live in the kernel, not in this container: hand them back on any exit, or
# a run that dies mid-case leaves one busy and every later run fails at the attach.
# Note for anyone editing this block: it is one single-quoted shell argument, so a lone
# quote anywhere inside ends it early and the rest runs on the host instead. bash -n does
# not catch that, because the quote count still balances - count them if you change it.
# Every detach has to tolerate a device that is already free: the cases detach when
# they are done with it, and a failure here is caught by set -e inside the trap, which
# leaves the script exiting 1 with every case passed.
cleanup_loops() {
	[ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
	[ -n "${L2:-}" ] && losetup -d "$L2" 2>/dev/null || true
	return 0
}
trap cleanup_loops EXIT
# The image is a whole disk and the filesystem lives in partition 1 at a 1 MiB offset, so a
# loop on the disk itself mounts with a bad superblock. Give the loop the partition window
# instead; the start is read from the MBR of the target itself.
p1_start() { # $1 = image file; prints the byte offset of the first partition
	s=$(dd if="$1" bs=1 skip=454 count=4 2>/dev/null | od -A n -t u4 | tr -d " ")
	case "${s:-}" in
	[0-9]*) echo $((s * 512)) ;;
	*) echo 0 ;;
	esac
}

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
wget -q -O /dev/null "http://127.0.0.1:$PORT/$GZBASE" && echo "http check: ok" || { echo "http check FAILED"; exit 1; }

# The sidecars follow the flash-init convention: strip the .gz, then the suffix. So
# they sit next to the compressed artifact but carry the size and hash of the raw image,
# which is what the guest verifies the written bytes against.
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
run_qemu /t/log1.txt "http://10.0.2.2:$PORT/$GZBASE" /dev/vda /dev/vda1
echo "--- flash mode log (probe, bmap and write lines)"
grep -E "probe>|flash>|\[bmap\]|\[write\]|\[verify\]|\[error\]|wget" /t/log1.txt | head -40
echo "--- flash mode log: the last lines (the record is written last, so its fate is decided here)"
tail -12 /t/log1.txt
echo "--- host-side target after the run (first 64 bytes and hash)"
od -A d -c -N 64 /t/target.img | head -4
sha256sum /t/target.img | cut -c1-64
sha256sum /img/"$BASE" | cut -c1-64
if ! grep -q "range checksums were verified" /t/log1.txt; then
  echo "CASE1 FAIL: no verification line"; grep -n "error\|die\|failed" /t/log1.txt | head -20; exit 1
fi
grep -q "rebooting into it" /t/log1.txt || { echo "CASE1 FAIL: did not reboot into the new image"; exit 1; }
echo "--- CASE 1: boot area (MBR and gap, first MiB) must match the image exactly"
dd if=/t/target.img bs=1M count=1 of=/t/t.boot status=none
dd if=/img/"$BASE" bs=1M count=1 of=/t/i.boot status=none
if cmp -s /t/t.boot /t/i.boot; then echo "CASE1 boot area IDENTICAL"; else echo "CASE1 FAIL: boot area differs"; exit 1; fi

echo "--- CASE 1: the record the guest left in the written filesystem"
mkdir -p /mnt/t1
# Take whatever loop device is free and give it back on any exit. The container shares
# the host /dev but not the host /sys, and a hardcoded or leaked loop turns the next run
# into a mystery: an earlier run of this test left /dev/loop0 attached to a target that
# no longer existed, and every run after it failed here with "Resource busy".
LOOP=$(losetup -o "$(p1_start /t/target.img)" -f --show /t/target.img) || { echo "CASE1 FAIL: could not attach the target ($LOOP)"; exit 1; }
mount -o ro "$LOOP" /mnt/t1
ls -l /mnt/t1/var/log/ | sed "s/^/  /"
if [ -f /mnt/t1/var/log/flash-attempt.log ]; then
  echo "CASE1 record: $(wc -l < /mnt/t1/var/log/flash-attempt.log) lines"
  head -4 /mnt/t1/var/log/flash-attempt.log | sed "s/^/  /"
  grep -q "flash attempt: target /dev/vda" /mnt/t1/var/log/flash-attempt.log \
    && echo "CASE1 RESULT=RECORD_PRESENT" \
    || { echo "CASE1 FAIL: the record does not name the target"; umount /mnt/t1; exit 1; }
else
  echo "CASE1 FAIL: the guest left no record in the written filesystem"
  echo "  (a successful flash that cannot tell you what it did is the bug this test is for)"
  umount /mnt/t1; exit 1
fi
tune2fs -l "$LOOP" 2>/dev/null | grep -E "^Filesystem state|^Block count" | sed "s/^/  /"
umount /mnt/t1
losetup -d "$LOOP" 2>/dev/null

echo "--- CASE 1: how much the record itself accounts for"
delta=$(cmp -l /t/target.img /img/"$BASE" 2>/dev/null | wc -l)
echo "CASE1 differing bytes: $delta (one small file plus the metadata for it)"
[ "$delta" -lt 1048576 ] && echo "CASE1 RESULT=DELTA_BOUNDED" \
  || { echo "CASE1 FAIL: target differs from the image by $delta bytes"; exit 1; }

echo
echo "=== CASE 2: abort before the first byte (metadata 404) must restore the backup"
truncate -s "$IMG_SIZE" /t/target.img
dd if=/img/"$BASE" of=/t/target.img bs=4M status=none conv=fsync
mkdir -p /mnt/t2
L2=$(losetup -o "$(p1_start /t/target.img)" -f --show /t/target.img) || { echo "CASE2 FAIL: could not attach the target ($L2)"; exit 1; }
mount "$L2" /mnt/t2
printf "DEFAULT debug\n" > /mnt/t2/boot/extlinux/extlinux.conf.bak
echo "abort-marker" > /mnt/t2/root/abort-marker
cat /mnt/t2/boot/extlinux/extlinux.conf | head -2
sync
umount /mnt/t2
losetup -d "$L2" 2>/dev/null || true

run_qemu /t/log2.txt "http://10.0.2.2:$PORT/does-not-exist.img.gz" /dev/vda /dev/vda1
echo "--- flash mode log (last 25 lines)"
tail -25 /t/log2.txt
grep -q "restoring the boot configuration" /t/log2.txt || { echo "CASE2 FAIL: no restore attempt"; exit 1; }

# The guest wrote this file underneath us: re-attach so the loop reads what is actually
# on the target now, rather than whatever the kernel cached for the old attachment.
# Nothing may be attached at this point (the detach above is the usual outcome), and
# detaching a device that is already gone is a no-op, not a failure.
losetup -d "$L2" 2>/dev/null || true
L2=$(losetup -o "$(p1_start /t/target.img)" -f --show /t/target.img)
mount "$L2" /mnt/t2
head -2 /mnt/t2/boot/extlinux/extlinux.conf
if head -1 /mnt/t2/boot/extlinux/extlinux.conf | grep -q "DEFAULT debug"; then
  echo "CASE2 RESULT=RESTORED_FROM_BACKUP"
else
  echo "CASE2 RESULT=NOT_RESTORED"; umount /mnt/t2; exit 1
fi
[ -f /mnt/t2/root/abort-marker ] && echo "CASE2 RESULT=UNTOUCHED_OTHERWISE" || { echo "CASE2 FAIL: target lost files"; exit 1; }
# the refusal writes its own record too: this is the path whose log we could
# already read on hardware, so it must not regress while fixing the other one
if [ -f /mnt/t2/var/log/flash-attempt.log ]; then
  echo "CASE2 record: $(wc -l < /mnt/t2/var/log/flash-attempt.log) lines (the abort left one too)"
else
  echo "CASE2 FAIL: the abort left no record"; umount /mnt/t2; exit 1
fi
umount /mnt/t2
losetup -d "$L2" 2>/dev/null || true

echo
echo "=== CASE 3: a stream that dies mid-write must not claim it wrote everything"
mkdir -p /t/trunc
cp /img/"$GZBASE" /t/full.gz
# A truncated artifact served with the real sidecars: the guest plans the whole bmap and
# then runs out of stream. That is the failure that used to announce 100% written and
# then, two lines later, announce that it had failed.
head -c 8388608 /t/full.gz > /t/trunc/"$GZBASE"
cp /img/"$BASE".sha256 /img/"$BASE".size /img/"$BASE".bmap /t/trunc/ 2>/dev/null || true
python3 -m http.server 8098 --directory /t/trunc --bind 0.0.0.0 >/dev/null 2>&1 &
TSRV=$!
sleep 2
# Case 2 left the image on this file, plus the record the guest wrote into it, and a
# sparse write needs the gaps to be zero: empty the file (which discards every block)
# so it comes back as a hole of the right size.
truncate -s 0 /t/target.img
truncate -s "$IMG_SIZE" /t/target.img
run_qemu /t/log3.txt "http://10.0.2.2:8098/$GZBASE" /dev/vda /dev/vda1
echo "--- CASE 3: the write lines, then the tail"
grep -nE "^\[write\]|write failed|download failed" /t/log3.txt | sed "s/^/  /"
tail -8 /t/log3.txt | sed "s/^/  /"
if ! grep -q "write failed" /t/log3.txt; then
  echo "CASE3 FAIL: a truncated stream did not report a write failure"
  kill $TSRV 2>/dev/null; exit 1
fi
if grep -qE "^\[write\] +100%" /t/log3.txt; then
  echo "CASE3 FAIL: the log claims 100% written after a failed write - the bug this case exists for"
  kill $TSRV 2>/dev/null; exit 1
fi
echo "CASE3 RESULT=NO_FALSE_COMPLETION"
kill $TSRV 2>/dev/null || true

kill $SRV 2>/dev/null || true
echo
echo "=== ALL CASES PASSED"
