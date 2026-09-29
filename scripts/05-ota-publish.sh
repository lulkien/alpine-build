#!/bin/bash
# Publish a built image to the NAS as a versioned release folder, which the
# ota-images quadlet (deploy/ota-images.container) serves over HTTP.
#
# Release base on the NAS (NFS-backed, default /srv/remotemount/OTA):
#
#   <image>-<YYYYmmdd-HHMMSS>/<image>.img.gz       transfer artifact
#                            /<image>.img.sha256   sha256 of the raw image
#                            /<image>.img.size     size of the raw image in bytes
#                            /<image>.img.bmap     block map for the sparse write
#                            /SHA256SUMS           every artfact with its sha256
#   latest -> <newest release>                     relative symlink, stable URL
#
# Everything of one build lands in one folder, so releases never overwrite each
# other and an old image stays fetchable. flash mode reads a single URL and
# derives the sidecars by stripping the ".gz", so the four files must stay
# together in the release folder.
#
# Usage: scripts/05-ota-publish.sh [image-file] [--local] [--flat] [--host HOST] [--port N]
#   --local        do not touch the NAS: serve image/ from this host instead
#   --flat         publish straight into the release base, no release folder
#   --host HOST    URL host for the board (default: $OTA_URL_HOST or 10.21.50.12)
#   --port N       port on the host (default: $OTA_URL_PORT or 8080)
#
# Env: OTA_NAS_SSH  (default lunarian@luna)
#      OTA_NAS_BASE (default /srv/remotemount/OTA)
#      OTA_URL_HOST, OTA_URL_PORT
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

NAS_SSH="${OTA_NAS_SSH:-lunarian@luna}"
NAS_BASE="${OTA_NAS_BASE:-/srv/remotemount/OTA}"
LOCAL=0
FLAT=0
URL_HOST="${OTA_URL_HOST:-10.21.50.12}"
URL_PORT="${OTA_URL_PORT:-8080}"
IMG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --local) LOCAL=1; shift ;;
    --flat) FLAT=1; shift ;;
    --host) URL_HOST="$2"; shift 2 ;;
    --port) URL_PORT="$2"; shift 2 ;;
    -*) echo "unknown option: $1" >&2; exit 1 ;;
    *) IMG="$1"; shift ;;
  esac
done

if [ -z "$IMG" ]; then
  IMG=$(ls -1t image/*.img 2>/dev/null | head -1 || true)
  [ -n "$IMG" ] || { echo "no image/*.img found: run scripts/04-build-image.sh first" >&2; exit 1; }
fi
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 1; }

IMG_GZ="$IMG.gz"
IMG_SHA="$IMG.sha256"
IMG_SIZE="$IMG.size"
IMG_BMAP="$IMG.bmap"
BASE=$(basename "$IMG_GZ")
NAME=$(basename "$IMG" .img)
RELEASE="$NAME-$(date +%Y%m%d-%H%M%S)"

if [ ! -f "$IMG_GZ" ] || [ "$IMG" -nt "$IMG_GZ" ]; then
  echo "--- compressing $IMG (gzip -1: fast to stream, small on the wire)"
  gzip -1 -c "$IMG" > "$IMG_GZ.part"
  mv "$IMG_GZ.part" "$IMG_GZ"
fi

echo "--- bmap (block map for sparse writes)"
# lists the blocks that hold data, ~27% of a 4 GiB image here, so flash mode
# writes ~1.1 GiB instead of 4 GiB. Unmapped blocks must already be zero on the
# target: true for a fresh card and for one written from a full image.
python3 "$ROOT_DIR/tools/mkbmap.py" "$IMG" "$IMG_BMAP.tmp" >/dev/null || { echo "FAIL: mkbmap failed" >&2; exit 1; }
mv "$IMG_BMAP.tmp" "$IMG_BMAP"

echo "--- sidecars"
# write via temp + rename: the image dir may hold root-owned leftovers from the
# containerised build, and only the directory needs to be writable for that
sha256sum "$IMG" | awk '{ print $1 }' > "$IMG_SHA.tmp"
mv "$IMG_SHA.tmp" "$IMG_SHA"
stat -c '%s' "$IMG" > "$IMG_SIZE.tmp"
mv "$IMG_SIZE.tmp" "$IMG_SIZE"
cat "$IMG_SHA" "$IMG_SIZE" | sed 's/^/    /'
grep -c '<Range' "$IMG_BMAP" | sed 's/^/    bmap ranges: /'

if [ "$LOCAL" = 1 ]; then
  URL="http://${URL_HOST}:${URL_PORT}/${BASE}"
  cat <<EOF

serving $ROOT_DIR/image on 0.0.0.0:$URL_PORT (Ctrl-C to stop)

On the board:

  ota-flash $URL
EOF
  exec python3 -m http.server "$URL_PORT" --bind 0.0.0.0 --directory image
fi

if [ "$FLAT" = 1 ]; then
  DEST="$NAS_BASE"
  URL_PATH="$BASE"
else
  DEST="$NAS_BASE/$RELEASE"
  URL_PATH="$RELEASE/$BASE"
fi
URL="http://${URL_HOST}:${URL_PORT}/${URL_PATH}"
LATEST_URL="http://${URL_HOST}:${URL_PORT}/latest/${BASE}"

# manifest over the files that actually live in the release folder (the raw
# image stays on the build host), checked on the NAS with sha256sum -c
SHA256SUMS="$ROOT_DIR/image/SHA256SUMS.tmp"
# subshell, not a brace group: the cd must not leak into this shell, or every
# relative path below (the scp, mainly) resolves against image/
(
  cd "$ROOT_DIR/image"
  sha256sum "$BASE" "$(basename "$IMG_SHA")" "$(basename "$IMG_SIZE")" "$(basename "$IMG_BMAP")"
) > "$SHA256SUMS"

echo "--- publishing to $NAS_SSH:$DEST"
ssh "$NAS_SSH" "mkdir -p '$DEST'"
scp -q "$IMG_GZ" "$IMG_SHA" "$IMG_SIZE" "$IMG_BMAP" "$NAS_SSH:$DEST/"
# the local manifest keeps a .tmp name, so it needs its remote name spelled out
scp -q "$SHA256SUMS" "$NAS_SSH:$DEST/SHA256SUMS"

echo "--- verifying what landed on the NAS"
ssh "$NAS_SSH" "cd '$DEST' && sha256sum -c --quiet SHA256SUMS && echo '    checksums match' && ls -l" | sed 's/^/    /'

if [ "$FLAT" = 0 ]; then
  # relative symlink: stable URL for scripts, and it survives a rename of the base
  ssh "$NAS_SSH" "cd '$NAS_BASE' && ln -sfn '$RELEASE' latest && ls -ld latest" | sed 's/^/    /'
fi

echo "--- verifying over HTTP (what the board will fetch)"
check_url() {
  code=$(ssh "$NAS_SSH" "curl -s -o /dev/null -w '%{http_code}' '$1'" 2>/dev/null || echo 000)
  printf '    %s  %s\n' "$code" "$1"
  if [ "$code" != 200 ]; then
    echo "FAIL: $1 is not served (is the mount up? systemctl --user restart ota-images.service on the NAS)" >&2
    exit 1
  fi
}
check_url "$URL"
check_url "${URL%.gz}.sha256"
check_url "${URL%.gz}.size"
check_url "${URL%.gz}.bmap"
[ "$FLAT" = 1 ] || check_url "$LATEST_URL"

SERVED_SHA=$(ssh "$NAS_SSH" "curl -s '${URL%.gz}.sha256' | awk '{ print \$1; exit }'")
[ "$SERVED_SHA" = "$(cat "$IMG_SHA")" ] || { echo "FAIL: the served sha256 sidecar differs from the published image" >&2; exit 1; }
echo "    served sha256 sidecar matches the image"

cat <<EOF

published $RELEASE to $NAS_SSH:$DEST

On the board, this arms flash mode and reboots:

  ota-flash $URL

The next boot is the RAM-only flasher: DHCP, fetch the .bmap, stream the .gz and
write only the mapped ranges, verify every range plus the bootloader magic, then
reboot into the new image. Anything that fails before the first byte restores
the previous boot configuration and reboots into the untouched system; a failure
after the first byte needs a card reader and a fresh flash.

  ota-flash --status    show what is armed
  ota-flash --cancel    disarm, stay on the installed system

Stable URL for scripts ($RELEASE is what it points at today):

  $LATEST_URL
EOF
