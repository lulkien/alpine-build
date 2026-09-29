#!/bin/bash
# recipe-build.sh: exercise the whole recipe path offline - fetch a pinned
# commit from a local git repo, run the recipe's install hook in the aarch64
# build chroot, pack the result with tools/mkapk.sh, then install that package
# into a scratch rootfs with the build's public key and run what it installed.
#
# The recipe comes from a fixture directory (RECIPES_DIR), so recipes/ and
# packages/ in the working tree are not touched. Nothing here needs the network
# or the board; it does need docker, qemu-aarch64 binfmt and the minirootfs
# tarball from scripts/00-fetch-inputs.sh.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
# The fixture lives outside the working tree and is mounted into the containers
# as /fixture, so recipes/, packages/ and src/ in the tree are untouched.
SCRATCH=${BH_AGENT_WORKSPACE:-/tmp}/recipe-build-$RANDOM
FIXREPO="$SCRATCH/repo"
FIXRECIPES="$SCRATCH/recipes"
fails=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

[ -f "$REPO/alpine-minirootfs-3.22.6-aarch64.tar.gz" ] ||
  { echo "no minirootfs in $REPO: run scripts/00-fetch-inputs.sh first" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

echo "--- fixture: a local repo with one script, and one recipe for it"
mkdir -p "$FIXREPO/bin" "$FIXRECIPES"
cleanup() {
  # the containers wrote as root, so the host cannot remove their files
  docker run --rm -v "$SCRATCH":/fixture alpine:3.22 rm -rf /fixture >/dev/null 2>&1 ||
    rm -rf "$SCRATCH" 2>/dev/null || true
}
trap cleanup EXIT
cat > "$FIXREPO/bin/fixture-tool" <<'EOF'
#!/bin/sh
echo fixture-tool works
EOF
chmod 755 "$FIXREPO/bin/fixture-tool"
git -C "$FIXREPO" init -q
git -C "$FIXREPO" -c user.email=test@example.invalid -c user.name=test add -A
git -C "$FIXREPO" -c user.email=test@example.invalid -c user.name=test commit -q -m "fixture"
REF=$(git -C "$FIXREPO" rev-parse HEAD)
echo "    fixture commit $REF"

cat > "$FIXRECIPES/fixture-tool.toml" <<EOF
name = "fixture-tool"
version = "1.0.0"
repo = "file:///work/build/fixture/repo"
ref = "$REF"
license = "Unlicense"
maintainer = "test <test@example.invalid>"
install = """
install -Dm755 bin/fixture-tool "\$DESTDIR/usr/bin/fixture-tool"
install -Dm644 bin/fixture-tool "\$DESTDIR/etc/fixture.conf"
"""
EOF

echo "--- 04: fetch the pinned commit, install, package"
# the fixture is mounted inside the workspace, because the recipe hooks run in
# the build chroot where only /work is visible
docker run --rm --privileged -v /dev:/dev -v "$REPO":/work -v "$SCRATCH":/work/build/fixture alpine:3.22 \
  sh -c "apk add --no-cache bash abuild git tar gzip openssl python3 >/dev/null &&
    RECIPES_DIR=/work/build/fixture/recipes SRC_DIR=/work/build/fixture/src \
    BUILD_DIR=/work/build/fixture/build PACKAGES_DIR=/work/build/fixture/packages \
    bash /work/scripts/01-build-recipes.sh --recipe fixture-tool" 2>&1 |
  grep -E "^(===|    |/work)" | tail -14

APK="$SCRATCH/packages/fixture-tool_1.0.0-r0.apk"
if [ -f "$APK" ]; then ok "the package was built: $(basename "$APK")"; else bad "the package was built"; fi
if [ -f "$SCRATCH/build/keys/solovox-build.rsa.pub" ]; then ok "a signing key was generated"; else bad "a signing key was generated"; fi

echo "--- install it into a scratch rootfs and run what it installed"
out=$(docker run --rm --privileged -v "$REPO":/work -v "$SCRATCH":/work/build/fixture debian:trixie bash -c '
set -e
mkdir -p /t/root && tar -xzf /work/alpine-minirootfs-3.22.6-aarch64.tar.gz -C /t/root
mount -t proc proc /t/root/proc; mount --rbind /dev /t/root/dev; mount --rbind /sys /t/root/sys
install -Dm644 /work/build/fixture/build/keys/solovox-build.rsa.pub /t/root/etc/apk/keys/solovox-build.rsa.pub
cp /work/build/fixture/packages/fixture-tool_1.0.0-r0.apk /t/root/tmp/
echo "VERIFY $(chroot /t/root /sbin/apk verify /tmp/fixture-tool_1.0.0-r0.apk 2>&1 | grep -v WARNING | tail -1)"
chroot /t/root /sbin/apk add --no-cache /tmp/fixture-tool_1.0.0-r0.apk 2>&1 | grep -v WARNING | tail -2
echo "RUN $(chroot /t/root /usr/bin/fixture-tool)"
echo "LIST $(chroot /t/root /sbin/apk info -L fixture-tool 2>/dev/null | tr "\n" " ")"
chroot /t/root /sbin/apk del fixture-tool >/dev/null 2>&1
[ -e /t/root/usr/bin/fixture-tool ] && echo "LEFTOVER" || echo "REMOVED"
' 2>&1)

case "$out" in *"0 - OK"*) ok "apk verify accepts the package" ;; *) bad "apk verify accepts the package ($(grep VERIFY <<<"$out" || echo 'no verify line'))" ;; esac
case "$out" in *"fixture-tool works"*) ok "the installed binary runs" ;; *) bad "the installed binary runs" ;; esac
case "$out" in *"usr/bin/fixture-tool"*) ok "the binary is in the package" ;; *) bad "the binary is in the package" ;; esac
case "$out" in *"etc/fixture.conf"*) ok "the config file is in the package" ;; *) bad "the config file is in the package" ;; esac
case "$out" in *"REMOVED"*) ok "apk del removes it cleanly" ;; *) bad "apk del removes it cleanly" ;; esac

echo
if [ "$fails" -eq 0 ]; then
  echo "all recipe build checks passed"
else
  echo "$fails check(s) failed"
  exit 1
fi
