#!/bin/bash
# Build the recipes a profile names into signed Alpine packages.
#
#   scripts/01-build-recipes.sh --profile simple-graphics
#   scripts/01-build-recipes.sh --recipe simple-graphics-controller --force
#
# Runs inside an Alpine container (it needs abuild's tools either way). For each
# recipe: fetch the pinned commit (or reuse the cached checkout), install its
# makedepends in a throwaway aarch64 chroot, run the recipe's build hook there,
# then turn the result into packages/<name>_<version>-r0.apk one of two ways:
#
#   apkbuild set   the repository carries its own APKBUILD, so abuild signs and
#                  packages the artifact: one file layout, declared upstream,
#                  and the same APKBUILD a board builds with
#   no apkbuild    the recipe's install hook writes the file tree with DESTDIR,
#                  and tools/mkapk.sh packs and signs it
#
# The caches, all under the workspace and all reusable between runs:
#
#   src/<name>/          git checkout at the recipe's ref
#   build/chroot/        aarch64 Alpine rootfs with the recipes' makedepends
#   build/destdir/<name>/ what a recipe installed (the package's file tree)
#   build/abuild-out/<name>/ abuild's own output dir (apk + index) for one recipe
#   build/keys/          the signing key pair, generated once, never committed
#   packages/            the built .apk files, installed by stage 03
#
# The signing public key is what makes 03 able to install these without
# --allow-untrusted: 03 copies build/keys/*.pub into the image's /etc/apk/keys.
#
# Usage: scripts/01-build-recipes.sh --profile NAME | --recipe NAME... [options]
#   --profile NAME   build every recipe the profile names (from buildcfg.py)
#   --recipe NAME    build one recipe (repeatable); default: the profile's
#   --force          rebuild even if the package already exists
#   --fetch-only     fetch the sources and the chroot, build nothing
#   --keep-chroot    do not remove build/chroot afterwards (it is kept anyway)
set -euo pipefail

WORK=/work
ROOT_DIR="$WORK"
# Overridable so tests can build a fixture recipe without touching recipes/
RECIPES_DIR="${RECIPES_DIR:-$WORK/recipes}"
SRC_DIR="${SRC_DIR:-$WORK/src}"
BUILD_DIR="${BUILD_DIR:-$WORK/build}"
PACKAGES_DIR="${PACKAGES_DIR:-$WORK/packages}"
CHROOT="$BUILD_DIR/chroot"
KEYDIR="$BUILD_DIR/keys"
KEY_NAME=solovox-build.rsa.pub
KEY="$KEYDIR/solovox-build.rsa"
ALPINE_BRANCH=v3.22
MIRROR=https://dl-cdn.alpinelinux.org/alpine
MINIROOTFS=$(ls -1 "$WORK"/alpine-minirootfs-*-aarch64.tar.gz 2>/dev/null | head -1 || true)

PROFILE="${PROFILE:-}"
WANT=()
FORCE=0
FETCH_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --recipe) WANT+=("$2"); shift 2 ;;
    --recipe=*) WANT+=("${1#*=}"); shift ;;
    --force) FORCE=1; shift ;;
    --fetch-only) FETCH_ONLY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

log() { printf '\n=== %s\n' "$*"; }

[ -n "$MINIROOTFS" ] || { echo "FAIL: no alpine-minirootfs-*-aarch64.tar.gz: run scripts/00-fetch-inputs.sh" >&2; exit 1; }

# --- which recipes ----------------------------------------------------------
if [ "${#WANT[@]}" -eq 0 ]; then
  [ -n "$PROFILE" ] || { echo "FAIL: give --profile or --recipe" >&2; exit 1; }
  mapfile -t WANT < <(python3 "$WORK/tools/buildcfg.py" profile show "$PROFILE" --emit json |
    python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["recipes"]))')
  if [ "${#WANT[@]}" -eq 0 ]; then
    echo "profile '$PROFILE' names no recipes: nothing to build"
    exit 0
  fi
fi

log "recipes to build: ${WANT[*]}"

# --- signing key ------------------------------------------------------------
# Generated once and kept in build/ (gitignored): the packages are installed by
# the same build that produced them, so a per-build key would be fine too, but
# reusing one keeps the package bytes stable across rebuilds.
if [ ! -f "$KEY" ]; then
  log "signing key"
  mkdir -p "$KEYDIR"
  openssl genrsa -out "$KEY" 4096 2>/dev/null
  openssl rsa -in "$KEY" -pubout -out "$KEYDIR/$KEY_NAME" 2>/dev/null
  chmod 600 "$KEY"
  echo "    generated $KEY and $KEYDIR/$KEY_NAME"
fi
[ -f "$KEYDIR/$KEY_NAME" ] || openssl rsa -in "$KEY" -pubout -out "$KEYDIR/$KEY_NAME" 2>/dev/null

# --- metadata for every recipe ----------------------------------------------
# One line per recipe: name version repo ref makedepends (space separated)
META="$BUILD_DIR/recipes.meta"
mkdir -p "$BUILD_DIR"
: > "$META"
for recipe in "${WANT[@]}"; do
  python3 "$WORK/tools/buildcfg.py" recipe show "$recipe" --emit json > "$BUILD_DIR/$recipe.json"
  python3 - "$BUILD_DIR/$recipe.json" <<'PY' >> "$META"
import json, sys
r = json.load(open(sys.argv[1]))
print("\t".join([r["name"], r["version"], r["repo"], r["ref"], " ".join(r["makedepends"])]))
PY
done
cat "$META" | sed 's/^/    /'

# --- sources ----------------------------------------------------------------
# One checkout per pinned commit, cached: a repository already at its ref is left
# alone unless --force. Sibling checkouts (a recipe's `sources`) go into the same
# directory, because that is where a crate naming a sibling by path looks.
fetch_repo() { # <dir> <repo> <ref> <label>
  local dir="$1" repo="$2" ref="$3" label="$4" have
  if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" = "$ref" ] && [ "$FORCE" != 1 ]; then
    echo "    $label already at $ref"
    return 0
  fi
  rm -rf "$dir"
  mkdir -p "$(dirname "$dir")"
  git init -q "$dir"
  git -C "$dir" remote add origin "$repo"
  git -C "$dir" fetch -q --depth 1 origin "$ref"
  git -C "$dir" checkout -q FETCH_HEAD
  have=$(git -C "$dir" rev-parse HEAD)
  if [ "$have" != "$ref" ]; then
    echo "FAIL: $label checked out $have, pinned $ref" >&2
    exit 1
  fi
  echo "    $have"
}

while IFS=$'\t' read -r name version repo ref makedeps; do
  log "fetch $name at $ref"
  fetch_repo "$SRC_DIR/$name" "$repo" "$ref" "$name"
  while read -r s_repo s_ref; do
    [ -n "$s_repo" ] || continue
    s_dir=$(basename "${s_repo%.git}")
    log "fetch $s_dir (sibling of $name) at $s_ref"
    fetch_repo "$SRC_DIR/$s_dir" "$s_repo" "$s_ref" "$s_dir"
  done < <(python3 - "$BUILD_DIR/$name.json" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1]))["sources"]:
    repo, ref = item.rsplit("@", 1)
    print(f"{repo} {ref}")
PY
)
done < "$META"

# --- build chroot -----------------------------------------------------------
# throwaway: aarch64 Alpine with the union of the recipes' makedepends. The
# image's own rootfs is never touched by a recipe build.
if [ ! -d "$CHROOT" ]; then
  log "build chroot"
  mkdir -p "$CHROOT"
  tar -xzf "$MINIROOTFS" -C "$CHROOT"
  printf '%s\n' "$MIRROR/$ALPINE_BRANCH/main" "$MIRROR/$ALPINE_BRANCH/community" > "$CHROOT/etc/apk/repositories"
  cp /etc/resolv.conf "$CHROOT/etc/resolv.conf" 2>/dev/null || true
fi
mountpoint -q "$CHROOT/proc" || mount -t proc proc "$CHROOT/proc"
mountpoint -q "$CHROOT/dev" || mount --rbind /dev "$CHROOT/dev"
mountpoint -q "$CHROOT/sys" || mount --rbind /sys "$CHROOT/sys"
# the workspace has to be visible inside the chroot: the recipe hooks run there
# and reference /work/src/<name> and /work/build/destdir/<name>
mkdir -p "$CHROOT/work"
mountpoint -q "$CHROOT/work" || mount --rbind "$WORK" "$CHROOT/work"

MAKEDEPS=$(cut -f5 "$META" | tr ' ' '\n' | sort -u | tr '\n' ' ')
# A recipe that packages with its own APKBUILD needs abuild in the chroot. Added
# here and not listed in the recipe: it belongs to the packaging path.
ABUILD_RECIPES=$(python3 - "$BUILD_DIR" "${WANT[@]}" <<'PY'
import json, pathlib, sys
build_dir = pathlib.Path(sys.argv[1])
names = [n for n in sys.argv[2:] if json.load(open(build_dir / f"{n}.json"))["apkbuild"]]
print(" ".join(names))
PY
)
if [ -n "$ABUILD_RECIPES" ]; then
  MAKEDEPS="$MAKEDEPS abuild file tar gzip"
fi
if [ -n "${MAKEDEPS// /}" ]; then
  log "makedepends in the chroot: $MAKEDEPS"
  chroot "$CHROOT" /sbin/apk add --no-cache $MAKEDEPS
fi

# abuild signs with the single key in $HOME/.abuild. The public half has to be
# trusted where the package is verified (the chroot's index step) and where it is
# installed (stage 03 copies the same file into the image's /etc/apk/keys), so
# the one build key goes into both places.
if [ -n "$ABUILD_RECIPES" ]; then
  log "signing key into the chroot for: $ABUILD_RECIPES"
  install -Dm600 "$KEY" "$CHROOT/root/.abuild/$(basename "$KEY")"
  # abuild-sign wants the public half beside the private key, and apk wants it
  # trusted here (the index step verifies what it indexes)
  install -Dm644 "$KEYDIR/$KEY_NAME" "$CHROOT/root/.abuild/$KEY_NAME"
  install -Dm644 "$KEYDIR/$KEY_NAME" "$CHROOT/etc/apk/keys/$KEY_NAME"
  echo "    $(basename "$KEY") signs, $KEY_NAME is trusted"
fi

# --- rust toolchains --------------------------------------------------------
# A recipe can name a rustc the mirror does not ship: Alpine v3.22 is 1.87, and a
# crate using let-chains (stable in 1.88) does not build with it. rustup brings a
# host toolchain for this architecture, and the chroot is a cache, so the download
# is paid once per fresh chroot. The Alpine package ships rustup-init only, so the
# first toolchain is installed by running it; HOME picks where it all lives.
RUST_TOOLCHAINS=$(python3 - "$BUILD_DIR" "${WANT[@]}" <<'PY'
import json, pathlib, sys
build_dir = pathlib.Path(sys.argv[1])
wanted = {json.load(open(build_dir / f"{n}.json"))["rust_toolchain"] for n in sys.argv[2:]}
print(" ".join(sorted(t for t in wanted if t)))
PY
)
if [ -n "$RUST_TOOLCHAINS" ]; then
  log "rust toolchains in the chroot: $RUST_TOOLCHAINS"
  chroot "$CHROOT" /sbin/apk add --no-cache rustup
  if [ ! -x "$CHROOT/root/.cargo/bin/rustup" ]; then
    default_tc=$(printf '%s' "$RUST_TOOLCHAINS" | awk '{print $1}')
    chroot "$CHROOT" /bin/sh -c \
      "export HOME=/root && /usr/bin/rustup-init -y --no-modify-path --profile minimal --default-toolchain $default_tc"
  fi
  for tc in $RUST_TOOLCHAINS; do
    chroot "$CHROOT" /bin/sh -c \
      "export HOME=/root && /root/.cargo/bin/rustup toolchain install $tc --profile minimal"
  done
fi

if [ "$FETCH_ONLY" = 1 ]; then
  log "fetch-only: sources and chroot ready, nothing built"
  exit 0
fi

# --- build and package ------------------------------------------------------
mkdir -p "$PACKAGES_DIR"
for json in "$BUILD_DIR"/*.json; do
  name=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$json")
  version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$json")
  repo=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repo"])' "$json")
  ref=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ref"])' "$json")
  license_=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("license",""))' "$json")
  maintainer=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("maintainer",""))' "$json")
  depends=$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1]))["depends"]))' "$json")
  build=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"])' "$json")
  install=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["install"])' "$json")
  apkbuild=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["apkbuild"])' "$json")
  rust_toolchain=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("rust_toolchain", ""))' "$json")

  DESTDIR="$BUILD_DIR/destdir/$name"
  APK_OUT="$PACKAGES_DIR/${name}_${version}-r0.apk"
  # The package is reused only when it was built from this exact recipe file: the
  # file carries the commit, the siblings and the build hook, so hashing it is what
  # makes a bumped pin (or an edited hook) rebuild instead of silently shipping the
  # old binary under the new commit's name in the manifest.
  STAMP_DIR="$BUILD_DIR/built"
  STAMP="$STAMP_DIR/$name"
  stamp_now=$(sha256sum "$RECIPES_DIR/$name.toml" | cut -d' ' -f1)
  if [ -f "$APK_OUT" ] && [ "$FORCE" != 1 ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$stamp_now" ]; then
    log "$name: $APK_OUT is up to date with $(basename "$RECIPES_DIR/$name.toml") (--force to rebuild)"
    continue
  fi

  log "$name: build"
  rm -rf "$DESTDIR"
  mkdir -p "$DESTDIR"
  # the hooks run inside the chroot, which sees the workspace at the same paths
  # it has outside (05 binds $WORK into $CHROOT/work)
  if [ -n "${build// /}" ]; then
    if [ -n "$rust_toolchain" ]; then
      # a rustup toolchain: HOME decides where it lives, the shims under
      # ~/.cargo/bin are what the hook's plain `cargo` resolves through, and the
      # default is set here so two recipes wanting different rustcs cannot
      # depend on which one was installed last
      chroot "$CHROOT" /bin/sh -c \
        "export HOME=/root && /root/.cargo/bin/rustup default $rust_toolchain >/dev/null && export PATH=/root/.cargo/bin:\$PATH && cd $SRC_DIR/$name && $build"
    else
      chroot "$CHROOT" /bin/sh -c "cd $SRC_DIR/$name && $build"
    fi
  else
    echo "    (files-only recipe)"
  fi

  if [ -n "$apkbuild" ]; then
    # The upstream APKBUILD owns the file layout, the dependencies and the
    # metadata. abuild wants its own repository directory - it writes the .apk
    # and an index there - which is kept out of packages/ so stage 03 keeps
    # seeing a flat directory of .apk files.
    #
    # -F: abuild refuses to run as root otherwise, and in the chroot root is the
    # only user there is. -d: the dependency check insists on an implicit
    # build-base, and this APKBUILD compiles nothing (it packages the artifact
    # the build hook above produced). PACKAGER carries the recipe's maintainer
    # into the package metadata. PACKAGER_PRIVKEY: abuild looks for a key named
    # by its config or that variable, not for "the one .rsa in ~/.abuild", and
    # this is the build key stage 03 trusts in the image.
    log "$name: package with $apkbuild (abuild)"
    ABUILD_OUT="$BUILD_DIR/abuild-out/$name"
    rm -rf "$ABUILD_OUT"
    mkdir -p "$ABUILD_OUT"
    chroot "$CHROOT" /bin/sh -c \
      "cd $SRC_DIR/$name && PACKAGER='$maintainer' PACKAGER_PRIVKEY=/root/.abuild/$(basename "$KEY") abuild -F -d -P $ABUILD_OUT"
    built=$(find "$ABUILD_OUT" -name '*.apk' | head -1)
    if [ -z "$built" ]; then
      echo "FAIL: abuild produced no .apk in $ABUILD_OUT" >&2
      exit 1
    fi
    install -m 644 "$built" "$APK_OUT"
    echo "    $(basename "$built") -> $(basename "$APK_OUT")"
  else
    log "$name: install into the package tree"
    chroot "$CHROOT" /bin/sh -c "cd $SRC_DIR/$name && export DESTDIR=$DESTDIR && $install"

    log "$name: package"
    sh "$WORK/tools/mkapk.sh" --name "$name" --version "$version" --destdir "$DESTDIR" \
      --out "$APK_OUT" --key "$KEY" --key-name "$KEY_NAME" \
      --license "$license_" --maintainer "$maintainer" --url "$repo" \
      --description "built from $(basename "$repo")@${ref:0:12}" \
      ${depends:+$(for d in $depends; do printf ' --depend %s' "$d"; done)}
  fi

  # what this package was built from, for the next run's reuse decision
  mkdir -p "$STAMP_DIR"
  printf '%s\n' "$stamp_now" > "$STAMP"
done

log "done"
ls -l "$PACKAGES_DIR"
cat <<EOF

Packages are installed by stage 03, which copies $KEYDIR/$KEY_NAME into the
image's /etc/apk/keys so apk treats them as trusted:

  bash build.sh --profile $PROFILE

On the board, /etc/solovox/image-manifest records the commit each package was
built from.
EOF
