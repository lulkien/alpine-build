#!/bin/bash
# buildcfg.sh: exercise tools/buildcfg.py without a board, a container or the
# network. Covers the real profiles and recipe, and fixtures that must be
# rejected rather than silently resolved to something wrong.
#
# Run this whenever the profile or recipe format, or the resolver, changes.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=${BH_AGENT_WORKSPACE:-/tmp}/buildcfg-test-$RANDOM
TOOL="$REPO/tools/buildcfg.py"
PFIX="$SCRATCH/profiles"
RFIX="$SCRATCH/recipes"
fails=0

mkdir -p "$PFIX" "$RFIX"
trap 'rm -rf "$SCRATCH"' EXIT

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

# assert_eq <description> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# assert_match <description> <text> <pattern>
assert_match() {
  if grep -q -- "$3" <<<"$2"; then ok "$1"; else bad "$1 (no match for: $3)"; fi
}

# assert_no_match <description> <text> <pattern>
assert_no_match() {
  if grep -q -- "$3" <<<"$2"; then bad "$1 (unexpected match for: $3)"; else ok "$1"; fi
}

# expect_fail <description> <profiles-dir> <recipes-dir> <args...>
expect_fail() {
  local what=$1 pdir=$2 rdir=$3 pattern=$4
  shift 4
  local out
  if out=$(PROFILES_DIR="$pdir" RECIPES_DIR="$rdir" python3 "$TOOL" "$@" 2>&1); then
    bad "$what (succeeded, output: $out)"
    return
  fi
  if grep -q -- "$pattern" <<<"$out"; then ok "$what"; else bad "$what (message was: $out)"; fi
}

echo "--- profiles"

assert_eq "profile list" "headless
simple-graphics" "$(python3 "$TOOL" profile list)"

headless=$(python3 "$TOOL" profile show headless)
assert_match "headless carries linux-lts" "$headless" '^  linux-lts$'
assert_match "headless enables growfs" "$headless" '^  boot:growfs$'
assert_no_match "headless has no mesa" "$headless" '^  mesa-'
assert_no_match "headless builds nothing" "$headless" '^  simple-graphics-controller$'

# the emitted env is what the build scripts source: prove it is sourceable bash
env_out=$(python3 "$TOOL" profile show simple-graphics --emit env)
# shellcheck disable=SC1090
eval "$env_out"
assert_eq "env: profile name" "simple-graphics" "$PROFILE_NAME"
assert_eq "env: 14 packages (9 common + 6 mesa - linux-lts)" "14" "${#PROFILE_APK_ADD[@]}"
assert_eq "env: one removal" "linux-lts" "${PROFILE_APK_REMOVE[0]}"
assert_eq "env: 20 services" "20" "${#PROFILE_SERVICES[@]}"
assert_eq "env: one recipe" "simple-graphics-controller" "${PROFILE_RECIPES[0]}"
if printf '%s\n' "${PROFILE_APK_ADD[@]}" | grep -qx 'linux-lts'; then
  bad "env: linux-lts is not installed in this profile"
else
  ok "env: linux-lts is not installed in this profile"
fi

json=$(python3 "$TOOL" profile show simple-graphics --emit json)
assert_match "json: mesa-gbm is in the package set" "$json" '"mesa-gbm"'
assert_match "json: the daemon service is enabled" "$json" 'default:simple-graphics-controller'

echo "--- recipes"

assert_eq "recipe list" "simple-graphics-controller" "$(python3 "$TOOL" recipe list)"
python3 "$TOOL" recipe validate >/dev/null && ok "the real recipe validates" ||
  bad "the real recipe validates"

recipe=$(python3 "$TOOL" recipe show simple-graphics-controller)
assert_match "recipe pins a full sha" "$recipe" '^ref: [0-9a-f]\{40\}$'
assert_match "recipe uses the https remote" "$recipe" '^repo: https://'
assert_match "recipe packages with the repository's own APKBUILD" "$recipe" '^apkbuild: APKBUILD$'
assert_no_match "recipe has no install hook of its own then" "$recipe" '^install:'
assert_match "recipe builds with --locked" "$recipe" 'cargo build --release --locked'
assert_match "recipe builds an artifact the APKBUILD can package" "$recipe" '^  install -Dm755 target/release/simple-graphics-controller dist/simple-graphics-controller$'
assert_match "recipe declares its sibling checkout" "$recipe" '^  https://github.com/sgc-project/simple-graphics-protocol.git@[0-9a-f]\{40\}$'
assert_match "recipe names the rustc the mirror does not have" "$recipe" '^rust_toolchain: 1.88.0$'

rjson=$(python3 "$TOOL" recipe show simple-graphics-controller --emit json)
assert_match "recipe json: the apkbuild path is emitted" "$rjson" '"apkbuild": "APKBUILD"'
# the json is what 04 reads, so it has to agree with the file rather than with a
# sha hardcoded here that goes stale the next time the pin is bumped
toml_ref=$(sed -n 's/^ref = "\([0-9a-f]\{40\}\)"$/\1/p' "$REPO/recipes/simple-graphics-controller.toml")
assert_match "recipe json: ref is the pinned commit" "$rjson" "\"ref\": \"$toml_ref\""

echo "--- profile fixtures"

cat > "$PFIX/common.toml" <<'EOF'
name = "common"
apk_add = ["bluez", "linux-lts"]
services = ["default:networking"]
apk_remove = []
EOF

cat > "$PFIX/tiny.toml" <<'EOF'
name = "tiny"
apk_add = ["nano"]
EOF
PROFILES_DIR="$PFIX" RECIPES_DIR="$RFIX" python3 "$TOOL" profile show tiny >/dev/null &&
  ok "a profile with one delta resolves" || bad "a profile with one delta resolves"

cat > "$PFIX/dupe.toml" <<'EOF'
name = "dupe"
apk_add = ["bluez"]
EOF
count=$(PROFILES_DIR="$PFIX" RECIPES_DIR="$RFIX" python3 "$TOOL" profile show dupe |
  grep -c '^  bluez$' || true)
assert_eq "a repeated common entry is deduplicated" "1" "$count"

cat > "$PFIX/rm.toml" <<'EOF'
name = "rm"
apk_remove = ["linux-lts"]
services_remove = ["default:networking"]
EOF
rmout=$(PROFILES_DIR="$PFIX" RECIPES_DIR="$RFIX" python3 "$TOOL" profile show rm)
# scope to the installed set: the dump also lists what was subtracted
section() { sed -n "/^$2 (/,/^[a-z_]* (/p" <<<"$1" | sed '$d'; }
assert_no_match "a removed package leaves the set" "$(section "$rmout" apk_add)" '^  linux-lts$'
assert_no_match "a removed service leaves the set" "$rmout" '^  default:networking$'

echo "--- profile rejections"

cat > "$PFIX/badkey.toml" <<'EOF'
name = "badkey"
apk_addd = ["nano"]
EOF
expect_fail "an unknown key is refused" "$PFIX" "$RFIX" 'unknown key' profile show badkey

cat > "$PFIX/wrongtype.toml" <<'EOF'
name = "wrongtype"
apk_add = [1, 2]
EOF
expect_fail "a non-string array item is refused" "$PFIX" "$RFIX" 'array of strings' profile show wrongtype

cat > "$PFIX/tabled.toml" <<'EOF'
name = "tabled"
[section]
key = "value"
EOF
expect_fail "a TOML table is refused" "$PFIX" "$RFIX" 'unknown key' profile show tabled

cat > "$PFIX/misnamed.toml" <<'EOF'
name = "other"
apk_add = ["nano"]
EOF
expect_fail "name must match the filename" "$PFIX" "$RFIX" 'declares name' profile show misnamed

cat > "$PFIX/noname.toml" <<'EOF'
apk_add = ["nano"]
EOF
expect_fail "a nameless profile is refused" "$PFIX" "$RFIX" 'has no name' profile show noname

cat > "$PFIX/noremove.toml" <<'EOF'
name = "noremove"
apk_remove = ["linux-ltsx"]
EOF
expect_fail "removing a package that is not in the set is refused" "$PFIX" "$RFIX" \
  'not in the merged package set' profile show noremove

cat > "$PFIX/noservice.toml" <<'EOF'
name = "noservice"
services_remove = ["default:nope"]
EOF
expect_fail "removing a service that is not in the set is refused" "$PFIX" "$RFIX" \
  'not in the merged service set' profile show noservice

cat > "$PFIX/empty.toml" <<'EOF'
name = "empty"
apk_remove = ["bluez", "linux-lts"]
EOF
expect_fail "an empty merged package set is refused" "$PFIX" "$RFIX" 'package set is empty' \
  profile show empty

cat > "$PFIX/norecipe.toml" <<'EOF'
name = "norecipe"
recipes = ["does-not-exist"]
EOF
expect_fail "a profile naming a missing recipe is refused" "$PFIX" "$RFIX" \
  'has no recipes/does-not-exist.toml' profile show norecipe

expect_fail "the common layer is not a profile" "$PFIX" "$RFIX" "'common' is the shared" \
  profile show common
expect_fail "a missing profile is reported" "$PFIX" "$RFIX" 'no such file' profile show nosuch

echo "--- board"

assert_eq "board list" "solovox-z8pro" "$(python3 "$TOOL" board list)"
python3 "$TOOL" board validate >/dev/null && ok "the real platform validates" ||
  bad "the real platform validates"

board=$(python3 "$TOOL" board show)
assert_match "board: the image name is derived from the layer" "$board" \
  '^board: solovox-z8pro  (image alpine-solovox-z8pro-3.22.6-6.18.53)$'
assert_match "board: the kernel asset is data" "$board" '^kernel: 6\.18\.53$'
assert_match "board: the vendor dtb is data" "$board" '^dtb: sun50i-h618-x98h\.dtb$'
assert_match "board: the tree the image boots is data" "$board" '^boot_dtb: sun50i-h618-z8pro-ethfix\.dtb$'
assert_match "board: the overlay source is in the platform dir" "$board" \
  '^  devicetree/sun50i-h618-z8pro-ethfix\.dtso$'
assert_match "board: the runtime tree is named" "$board" '^  board/common/runtime/root$'
assert_match "board: the key is not world-readable" "$board" '^  root/\.ssh/authorized_keys$'

# the stage scripts source (or eval) this text: prove it is valid bash and that a
# value containing spaces survives the round trip
env_out=$(python3 "$TOOL" board show --emit env)
# shellcheck disable=SC1090
eval "$env_out"
assert_eq "board env: machine" "solovox-z8pro" "$BOARD_MACHINE"
assert_eq "board env: image name" "alpine-solovox-z8pro-3.22.6-6.18.53" "$BOARD_IMAGE_NAME"
assert_eq "board env: kernel release" "6.18.53-ophub" "$BOARD_KERNEL_RELEASE"
assert_eq "board env: one overlay" "devicetree/sun50i-h618-z8pro-ethfix.dtso" "${BOARD_OVERLAYS[0]}"
assert_eq "board env: one private file" "root/.ssh/authorized_keys" "${BOARD_PRIVATE_FILES[0]}"
assert_eq "board env: the merge check text keeps its spaces" "reg = <0x00>" "$BOARD_MERGE_CHECK_TEXT"

assert_match "board json: the runtime roots are listed" \
  "$(python3 "$TOOL" board show --emit json)" '"runtime_root"'
assert_match "board manifest: the kernel pin is recorded" \
  "$(python3 "$TOOL" board show --emit manifest)" '^  kernel: 6\.18\.53-ophub https://'

echo "--- board fixtures"

BFIX="$SCRATCH/boards"
mkdir -p "$BFIX/common" "$BFIX/platform/fake/devicetree"
cat > "$BFIX/common/board.toml" <<'EOF'
alpine_branch = "v3.22"
alpine_release = "3.22.6"
alpine_mirror = "https://example.invalid/alpine"
alpine_minirootfs_sha256 = "821565fa8f3953eefd12497b166b4b50add2f7c57fb312e75862f5867e06fefe"
image_prefix = "alpine"
image_size_mb = 4096
disk_id = "abcd1234"
root_partuuid = "abcd1234-01"
rootfs_uuid = "9f1c7a3e-5b21-4f8d-9a1c-7b2d4e6f8a90"
timezone = "UTC"
private_files = []
EOF
fake_platform() { # rewrites the platform file with "$1" replacing its body
  cat > "$BFIX/platform/fake/board.toml" <<EOF
$1
EOF
}
fake_platform 'hostname = "fake"
kernel = "1.0"
kernel_release = "1.0-fake"
kernel_url = "https://example.invalid/kernel.tar.gz"
kernel_sha256 = "269dd8ded019f829723968a236bac40335dc9488aac8f22cf1afd5b9f3a20bb7"
uboot_url = "https://example.invalid/uboot.bin"
uboot_file = "uboot.bin"
uboot_sha256 = "4c6afa2ef90610318dbd4f9a201a432610eb0eb025afd06e8d7bf69c17309e96"
dtb = "fake.dtb"
boot_dtb = "fake-fixed.dtb"
overlays = []
merge_check_node = "node@0"
merge_check_text = "reg = <0x0>"'
BOARDS_DIR="$BFIX" python3 "$TOOL" board validate >/dev/null &&
  ok "a second platform validates" || bad "a second platform validates"

# expect_fail_board <description> <pattern> <args...>
expect_fail_board() {
  local what=$1 pattern=$2
  shift 2
  local out
  if out=$(BOARDS_DIR="$BFIX" python3 "$TOOL" "$@" 2>&1); then
    bad "$what (succeeded: $out)"
    return
  fi
  if grep -q -- "$pattern" <<<"$out"; then ok "$what"; else bad "$what (message: $out)"; fi
}

fake_platform 'hostname = "fake"
kernel = "1.0"'
expect_fail_board "a platform without the required keys is refused" "is required" \
  board show fake

fake_platform 'hostname = "fake"
kernel = "1.0"
kernel_release = "1.0-fake"
kernel_url = "https://example.invalid/kernel.tar.gz"
kernel_sha256 = "269dd8ded019f829723968a236bac40335dc9488aac8f22cf1afd5b9f3a20bb7"
uboot_url = "https://example.invalid/uboot.bin"
uboot_file = "uboot.bin"
uboot_sha256 = "4c6afa2ef90610318dbd4f9a201a432610eb0eb025afd06e8d7bf69c17309e96"
dtb = "fake.dtb"
boot_dtb = "fake-fixed.dtb"
overlays = []
merge_check_node = "node@0"
merge_check_text = "reg = <0x0>"
bogus = "1"'
expect_fail_board "an unknown board key is refused" "unknown key" board show fake

fake_platform 'hostname = "fake"
kernel = "1.0"
kernel_release = "1.0-fake"
kernel_url = "http://example.invalid/kernel.tar.gz"
kernel_sha256 = "269dd8ded019f829723968a236bac40335dc9488aac8f22cf1afd5b9f3a20bb7"
uboot_url = "https://example.invalid/uboot.bin"
uboot_file = "uboot.bin"
uboot_sha256 = "4c6afa2ef90610318dbd4f9a201a432610eb0eb025afd06e8d7bf69c17309e96"
dtb = "fake.dtb"
boot_dtb = "fake-fixed.dtb"'
expect_fail_board "a non-https board URL is refused" "must be an https:// URL" board show fake

fake_platform 'hostname = "fake"
kernel = "1.0"
kernel_release = "1.0-fake"
kernel_url = "https://example.invalid/kernel.tar.gz"
kernel_sha256 = "not-a-sha"
uboot_url = "https://example.invalid/uboot.bin"
uboot_file = "uboot.bin"
uboot_sha256 = "4c6afa2ef90610318dbd4f9a201a432610eb0eb025afd06e8d7bf69c17309e96"
dtb = "fake.dtb"
boot_dtb = "fake-fixed.dtb"'
expect_fail_board "a bad board checksum is refused" "must be a 64-character hex sha256" \
  board show fake

fake_platform 'hostname = "fake"
kernel = "1.0"
kernel_release = "1.0-fake"
kernel_url = "https://example.invalid/kernel.tar.gz"
kernel_sha256 = "269dd8ded019f829723968a236bac40335dc9488aac8f22cf1afd5b9f3a20bb7"
uboot_url = "https://example.invalid/uboot.bin"
uboot_file = "uboot.bin"
uboot_sha256 = "4c6afa2ef90610318dbd4f9a201a432610eb0eb025afd06e8d7bf69c17309e96"
dtb = "fake.dtb"
boot_dtb = "fake-fixed.dtb"
image_size_mb = "4096"'
expect_fail_board "a non-integer image size is refused" "positive integer" board show fake

fake_platform 'hostname = "fake"
kernel = "1.0"
kernel_release = "1.0-fake"
kernel_url = "https://example.invalid/kernel.tar.gz"
kernel_sha256 = "269dd8ded019f829723968a236bac40335dc9488aac8f22cf1afd5b9f3a20bb7"
uboot_url = "https://example.invalid/uboot.bin"
uboot_file = "uboot.bin"
uboot_sha256 = "4c6afa2ef90610318dbd4f9a201a432610eb0eb025afd06e8d7bf69c17309e96"
dtb = "fake.dtb"
boot_dtb = "fake-fixed.dtb"
overlays = ["devicetree/thing.dtbo"]'
expect_fail_board "a compiled overlay in the source list is refused" "must be a .dtso source" \
  board show fake

fake_platform 'hostname = "fake"
kernel = "1.0"
kernel_release = "1.0-fake"
kernel_url = "https://example.invalid/kernel.tar.gz"
kernel_sha256 = "269dd8ded019f829723968a236bac40335dc9488aac8f22cf1afd5b9f3a20bb7"
uboot_url = "https://example.invalid/uboot.bin"
uboot_file = "uboot.bin"
uboot_sha256 = "4c6afa2ef90610318dbd4f9a201a432610eb0eb025afd06e8d7bf69c17309e96"
dtb = "fake.dtb"
boot_dtb = "fake-fixed.dtb"
overlays = ["devicetree/missing.dtso"]'
expect_fail_board "an overlay that is not in the platform dir is refused" "is not in" \
  board show fake

fake_platform 'hostname = "fake"
kernel = "1.0"
kernel_release = "1.0-fake"
kernel_url = "https://example.invalid/kernel.tar.gz"
kernel_sha256 = "269dd8ded019f829723968a236bac40335dc9488aac8f22cf1afd5b9f3a20bb7"
uboot_url = "https://example.invalid/uboot.bin"
uboot_file = "uboot.bin"
uboot_sha256 = "4c6afa2ef90610318dbd4f9a201a432610eb0eb025afd06e8d7bf69c17309e96"
dtb = "fake.dtb"
boot_dtb = "fake-fixed.dtb"
private_files = ["etc/shadow"]'
expect_fail_board "a private file no runtime tree has is refused" "no runtime/root tree" \
  board show fake

expect_fail_board "a missing platform is reported" "no such platform" board show nosuch

echo "--- recipe rejections"

cat > "$RFIX/branchref.toml" <<'EOF'
name = "branchref"
version = "1.0.0"
repo = "https://example.invalid/thing.git"
ref = "main"
install = "true"
EOF
expect_fail "a branch ref is refused" "$PFIX" "$RFIX" 'must be a full 40-character commit sha' \
  recipe show branchref

cat > "$RFIX/sshrepo.toml" <<'EOF'
name = "sshrepo"
version = "1.0.0"
repo = "git@github.com:example/thing.git"
ref = "988cfe20c9c9047ef6fe2dc36dc186e3e48f86c1"
install = "true"
EOF
expect_fail "an ssh repo URL is refused" "$PFIX" "$RFIX" 'must be an https:// URL' \
  recipe show sshrepo

cat > "$RFIX/noinstall.toml" <<'EOF'
name = "noinstall"
version = "1.0.0"
repo = "https://example.invalid/thing.git"
ref = "988cfe20c9c9047ef6fe2dc36dc186e3e48f86c1"
build = "make"
EOF
expect_fail "a recipe that packages nothing is refused" "$PFIX" "$RFIX" 'must package something' \
  recipe show noinstall

cat > "$RFIX/bothpaths.toml" <<'EOF'
name = "bothpaths"
version = "1.0.0"
repo = "https://example.invalid/thing.git"
ref = "988cfe20c9c9047ef6fe2dc36dc186e3e48f86c1"
install = "install -Dm755 thing \"$DESTDIR/usr/bin/thing\""
apkbuild = "APKBUILD"
EOF
expect_fail "an install hook and an APKBUILD together are refused" "$PFIX" "$RFIX" \
  'mutually exclusive' recipe show bothpaths

cat > "$RFIX/absapkbuild.toml" <<'EOF'
name = "absapkbuild"
version = "1.0.0"
repo = "https://example.invalid/thing.git"
ref = "988cfe20c9c9047ef6fe2dc36dc186e3e48f86c1"
apkbuild = "/etc/APKBUILD"
EOF
expect_fail "an apkbuild outside the source tree is refused" "$PFIX" "$RFIX" \
  'inside the source tree' recipe show absapkbuild

cat > "$RFIX/upapkbuild.toml" <<'EOF'
name = "upapkbuild"
version = "1.0.0"
repo = "https://example.invalid/thing.git"
ref = "988cfe20c9c9047ef6fe2dc36dc186e3e48f86c1"
apkbuild = "../APKBUILD"
EOF
expect_fail "a relative apkbuild that escapes the tree is refused" "$PFIX" "$RFIX" \
  'inside the source tree' recipe show upapkbuild

cat > "$RFIX/noversion.toml" <<'EOF'
name = "noversion"
repo = "https://example.invalid/thing.git"
ref = "988cfe20c9c9047ef6fe2dc36dc186e3e48f86c1"
install = "true"
EOF
expect_fail "a recipe without a version is refused" "$PFIX" "$RFIX" 'version is required' \
  recipe show noversion

cat > "$RFIX/misnamed.toml" <<'EOF'
name = "somethingelse"
version = "1.0.0"
repo = "https://example.invalid/thing.git"
ref = "988cfe20c9c9047ef6fe2dc36dc186e3e48f86c1"
install = "true"
EOF
expect_fail "a recipe's name must match its filename" "$PFIX" "$RFIX" 'declares name' \
  recipe show misnamed

cat > "$RFIX/badmake.toml" <<'EOF'
name = "badmake"
version = "1.0.0"
repo = "https://example.invalid/thing.git"
ref = "988cfe20c9c9047ef6fe2dc36dc186e3e48f86c1"
makedepends = ["Rust"]
install = "true"
EOF
expect_fail "a bad makedepend name is refused" "$PFIX" "$RFIX" 'is not a package name' \
  recipe show badmake

cat > "$RFIX/badsource.toml" <<'EOF'
name = "badsource"
version = "1.0.0"
repo = "https://example.invalid/thing.git"
ref = "988cfe20c9c9047ef6fe2dc36dc186e3e48f86c1"
install = "true"
sources = ["https://example.invalid/other.git@main"]
EOF
expect_fail "a sibling pinned to a branch is refused" "$PFIX" "$RFIX" \
  "sources entries are '<repo>@<commit sha>'" recipe show badsource

cat > "$RFIX/badrust.toml" <<'EOF'
name = "badrust"
version = "1.0.0"
repo = "https://example.invalid/thing.git"
ref = "988cfe20c9c9047ef6fe2dc36dc186e3e48f86c1"
install = "true"
rust_toolchain = "1.88.0; rm -rf /"
EOF
expect_fail "a toolchain name that is not one is refused" "$PFIX" "$RFIX" \
  'must be a toolchain name' recipe show badrust

echo
if [ "$fails" -eq 0 ]; then
  echo "all buildcfg checks passed"
else
  echo "$fails check(s) failed"
  exit 1
fi
