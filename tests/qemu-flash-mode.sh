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
# The archive this test boots can be overridden, so a candidate initramfs can be
# tried without rebuilding the image that carries it.
BOOTDIR=${BOOTDIR:-"$REPO/rootfs/boot"}
# The container body lives in its own file. Passed as one single-quoted shell argument it
# silently loses any line containing an apostrophe (and a quoted heredoc loses its quotes),
# which bash -n cannot see because the quote count still balances.
BODY="$REPO/tests/qemu-flash-mode-body.sh"
[ -f "$BODY" ] || { echo "missing $BODY" >&2; exit 1; }
IMG=${1:-$(ls -1t "$REPO"/image/*.img | head -1)}
[ -f "$IMG" ] || { echo "no image: $IMG" >&2; exit 1; }
BASE=$(basename "$IMG")
# The guest fetches the compressed artifact, because that is what the product publishes
# and what ota-flash arms with; a bare .img here dies in the guest's gzip. The byte
# comparisons below still use the raw image this one expands to.
GZBASE="$BASE.gz"
# The image directory is build output. The compressed artifact and the sidecars the
# guest verifies against are produced by the publish, on the NAS, so what sits here
# can be stale or missing altogether. This test serves the current image, so build the
# set it needs from the image itself: the guest checks the decompressed stream against
# the raw size and hash, so a locally-made .gz is a faithful stand-in.
if [ ! -f "$IMG.gz" ] || [ "$IMG" -nt "$IMG.gz" ]; then
	echo "--- compressing $BASE for the guest (missing or older than the image)"
	gzip -c "$IMG" > "$IMG.gz.tmp" && mv "$IMG.gz.tmp" "$IMG.gz"
fi
echo "--- regenerating the sidecars (raw size and hash, next to the compressed artifact)"
sha256sum "$IMG" | awk '{ print $1 }' > "$IMG.sha256"
stat -c %s "$IMG" > "$IMG.size"
KREL=6.18.53-ophub
PORT=8099

echo "image : $IMG"
echo "base  : $BASE"
echo "served: $GZBASE  (the guest fetches this one)"

# flash mode checks the bmap against the image, so it has to describe THIS image
if [ ! -f "$IMG.bmap" ] || [ "$IMG" -nt "$IMG.bmap" ]; then
	echo "--- generating $BASE.bmap"
	python3 "$REPO/tools/mkbmap.py" "$IMG" "$IMG.bmap"
fi

# Everything below runs in one container: qemu, an HTTP server on 10.0.2.2:8099
# (QEMU's slirp gateway is the container itself) and the checks afterwards.
docker run --rm --privileged -v /dev:/dev -v "$REPO":/w:ro \
	-v "$REPO/image":/img:ro -v "$BOOTDIR":/boot:ro \
	-e BASE="$BASE" -e GZBASE="$GZBASE" -e KREL="$KREL" -e PORT="$PORT" \
	-v "$BODY":/body.sh:ro \
	alpine:3.22 sh -eux /body.sh
