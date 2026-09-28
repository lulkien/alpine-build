#!/bin/bash
# build.sh: one command for the whole image build.
#
#   bash build.sh                        # the headless image, everything
#   bash build.sh --profile simple-graphics
#   bash build.sh --clean                # wipe the rootfs first
#   bash build.sh --no-tests --skip-fetch
#
# It runs the stages in order and stops at the first failure, so a partially
# built image is never left behind: 00 fetch/verify inputs, the profile and
# recipe checks, 05 build the profile's recipes into packages (skipped when the
# profile names none), 01 bootstrap the rootfs, 02 configure it for the profile,
# 03 assemble the image and assert it against the profile.
#
# The rootfs directory is reused between runs, and packages a previous profile
# installed are not removed by a later one, so switching profiles wipes it: a
# `simple-graphics` build followed by a `headless` build would otherwise ship
# mesa userspace in the headless image.
#
# Requirements: docker (with the daemon reachable), qemu-aarch64 binfmt for the
# chroot stage, and python3 on the host is NOT needed (stage 02 installs it in
# its container). Roughly two minutes end to end on a warm cache.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

PROFILE="${PROFILE:-headless}"
CLEAN=0
RUN_TESTS=1
FETCH=1
# installed in every stage container; 02 additionally needs python3
APT_PACKAGES="rsync e2fsprogs fdisk dosfstools device-tree-compiler cpio"
ALPINE_IMAGE=debian:trixie

die() {
  printf 'build: %s\n' "$*" >&2
  exit 1
}

usage() {
  # the leading comment block, minus the shebang and the leading "# "
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --clean) CLEAN=1; shift ;;
    --no-tests) RUN_TESTS=0; shift ;;
    --skip-fetch) FETCH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"

# Everything the container stages need is mounted from the workspace; they write
# back as root, so cleaning the rootfs has to happen inside a container too.
run_container() { # <docker args...>
  docker run --rm --privileged -v /dev:/dev -v "$ROOT_DIR":/work "$ALPINE_IMAGE" "$@"
}

stage() { printf '\n=== %s\n' "$1"; }

# --- inputs -----------------------------------------------------------------
if [ "$FETCH" = 1 ]; then
  stage "00: fetch and verify build inputs"
  bash scripts/00-fetch-inputs.sh
fi

# --- profiles and recipes ---------------------------------------------------
# Cheap and offline: catches a broken profile or recipe before any container runs
if [ "$RUN_TESTS" = 1 ]; then
  stage "profiles and recipes"
  bash tests/buildcfg.sh | tail -1
fi

# --- recipes ----------------------------------------------------------------
# Packages built from recipes/ are needed before 02 installs them. Only a
# profile that names recipes pays for this: headless has none.
RECIPES=$(python3 tools/buildcfg.py profile show "$PROFILE" --emit json |
  python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["recipes"]))')
if [ -n "$RECIPES" ]; then
  stage "05: build the profile's recipes ($RECIPES)"
  # alpine, not debian: the packer uses abuild's own tools (abuild-tar,
  # abuild-sign), which is what makes the packages apk accepts.
  #
  # --network host: the container fetches the recipes' git repositories, and
  # docker's default bridge on this workstation cannot reach github (it resets
  # the connection; the Alpine mirrors are fine). The container is privileged and
  # mounts /dev already, so it is not a new boundary - and the fetch is the only
  # thing that needs it.
  docker run --rm --privileged --network host -v /dev:/dev -v "$ROOT_DIR":/work alpine:3.22 \
    sh -c "apk add --no-cache bash abuild git tar gzip openssl python3 >/dev/null && bash /work/scripts/05-build-recipes.sh --profile $PROFILE"
else
  echo "profile '$PROFILE' names no recipes: nothing to build from source"
fi

# --- rootfs -----------------------------------------------------------------
ROOTFS="$ROOT_DIR/rootfs"
STATE="$ROOT_DIR/build/profile.env"
BOOTSTRAP=0

if [ -f "$STATE" ]; then
  previous=$(sed -n 's/^PROFILE_NAME=//p' "$STATE" | head -1)
  if [ "$previous" != "$PROFILE" ]; then
    echo "rootfs holds profile '$previous', building '$PROFILE': wiping it"
    CLEAN=1
  fi
fi

if [ "$CLEAN" = 1 ] && [ -d "$ROOTFS" ]; then
  stage "clean: removing rootfs/ (it is root-owned, so a container does it)"
  run_container rm -rf /work/rootfs
fi

[ -d "$ROOTFS" ] || BOOTSTRAP=1

if [ "$BOOTSTRAP" = 1 ]; then
  stage "01: bootstrap the Alpine rootfs (build-time packages only)"
  run_container bash /work/scripts/01-bootstrap-rootfs.sh
else
  echo "rootfs/ already holds profile '$PROFILE': keeping it (--clean to rebuild)"
fi

# --- configure for the profile ----------------------------------------------
stage "02: profile '$PROFILE' (packages, services, BSP kernel, flash initramfs)"
run_container bash -c "apt-get update -qq && apt-get install -y -qq $APT_PACKAGES python3 >/dev/null && bash /work/scripts/02-configure-rootfs.sh --profile $PROFILE"

# --- image ------------------------------------------------------------------
stage "03: assemble the image and assert it against the profile"
run_container bash -c "apt-get update -qq && apt-get install -y -qq $APT_PACKAGES >/dev/null && bash /work/scripts/03-build-image.sh"

# --- result -----------------------------------------------------------------
IMG=$(ls -1t "$ROOT_DIR"/image/*.img 2>/dev/null | head -1 || true)
[ -n "$IMG" ] || die "no image in image/ after stage 03"

stage "done"
printf 'profile : %s\n' "$PROFILE"
printf 'image   : %s (%s bytes)\n' "$IMG" "$(stat -c %s "$IMG")"
printf 'sha256  : %s\n' "$(sha256sum "$IMG" | awk '{ print $1 }')"
cat <<EOF

What is in it (on the board):

  cat /etc/solovox/image-manifest

Flash it whole to a card, e.g.:

  sudo dd if=$IMG of=/dev/sdX bs=4M conv=fsync status=progress

Publish a release for OTA (regenerates the .gz/.bmap/.size sidecars):

  scripts/04-ota-publish.sh
EOF
