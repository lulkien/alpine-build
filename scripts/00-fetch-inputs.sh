#!/bin/bash
# Download and verify every build input that is too large or too stable
# upstream to commit. Run from the repository root:
#
#   bash scripts/00-fetch-inputs.sh
#
# What to fetch is board data (board/common/board.toml plus the platform file):
# the kernel asset, u-boot and the Alpine minirootfs, each with its checksum.
# Produces: <uboot_file>, alpine-minirootfs-*.tar.gz and
# kernel/{<kernel>.tar.gz, <kernel>/, boot/, dtbs/}.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# The machine's values - kernel and u-boot to fetch, Alpine release, checksums -
# are data: board/common/board.toml plus board/platform/<name>/board.toml,
# resolved by tools/buildcfg.py. Stage 03 writes build/board.env for the
# containers; on a fresh workspace the values are resolved here instead.
mkdir -p build 2>/dev/null || true
if [ -f build/board.env ]; then
  # written by stage 03 on an earlier run of this workspace
  # shellcheck disable=SC1091
  . build/board.env
else
  # Resolved here instead of written: build/ belongs to root once a container has
  # written into it, and this stage runs on the host. The emitted text is quoted,
  # so eval is safe with values that contain spaces.
  eval "$(python3 tools/buildcfg.py board show ${BOARD:+$BOARD} --emit env)"
fi

KREL="$BOARD_KERNEL_RELEASE"
KDIR="$BOARD_KERNEL"
ALPINE_BRANCH="$BOARD_ALPINE_BRANCH"
ALPINE_RELEASE="$BOARD_ALPINE_RELEASE"
ALPINE_MIRROR="$BOARD_ALPINE_MIRROR"
MINIROOTFS=alpine-minirootfs-$ALPINE_RELEASE-aarch64.tar.gz
UBOOT="$BOARD_UBOOT_FILE"

KERNEL_URL="$BOARD_KERNEL_URL"
UBOOT_URL="$BOARD_UBOOT_URL"
MINIROOTFS_URL=$ALPINE_MIRROR/$ALPINE_BRANCH/releases/aarch64/$MINIROOTFS

KERNEL_SHA="$BOARD_KERNEL_SHA256"
UBOOT_SHA="$BOARD_UBOOT_SHA256"
MINIROOTFS_SHA="$BOARD_ALPINE_MINIROOTFS_SHA256"

check() {
  echo "$2  $1" | sha256sum -c -
}

fetch() {
  url=$1 out=$2
  if [ -f "$out" ]; then
    echo "have $out"
  else
    echo "fetch $url"
    curl -sSfL --retry 3 -o "$out.part" "$url"
    mv "$out.part" "$out"
  fi
}

fetch "$UBOOT_URL" "$UBOOT"
check "$UBOOT" "$UBOOT_SHA"

fetch "$MINIROOTFS_URL" "$MINIROOTFS"
check "$MINIROOTFS" "$MINIROOTFS_SHA"

mkdir -p kernel
fetch "$KERNEL_URL" "kernel/$KDIR.tar.gz"
check "kernel/$KDIR.tar.gz" "$KERNEL_SHA"

if [ ! -d "kernel/$KDIR" ]; then
  tar -xzf "kernel/$KDIR.tar.gz" -C kernel
fi

if [ ! -d kernel/boot ]; then
  mkdir -p kernel/boot kernel/dtbs
  tar -xzf "kernel/$KDIR/boot-$KREL.tar.gz" -C kernel/boot
  tar -xzf "kernel/$KDIR/dtb-allwinner-$KREL.tar.gz" -C kernel/dtbs
fi

echo
echo "inputs ready:"
ls -l "$UBOOT" "$MINIROOTFS" kernel/"$KDIR".tar.gz
ls -d kernel/boot kernel/dtbs kernel/"$KDIR" | sed 's/^/  /'
