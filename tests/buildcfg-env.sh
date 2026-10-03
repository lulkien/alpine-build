#!/bin/bash
# buildcfg-env.sh: the shell half of tools/buildcfg.py's contract.
#
# `--emit env` prints bash, and something other than python consumes it: stage
# 03 sources it inside a container, stage 04 sources it to assert the finished
# image, and stage 00 evals it on the host when build/board.env does not exist
# yet. So "the emitted text is valid bash, and a value containing spaces
# survives the round trip" is a property of that text, and only bash can check
# it - python cannot source a shell fragment.
#
# The resolver's own behaviour is tested in tests/test_buildcfg.py. Run both
# whenever the profile, recipe or board format, or the resolver, changes.
#
#   tests/buildcfg-env.sh
#   python3 -m pytest tests/test_buildcfg.py -q
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
TOOL="$REPO/tools/buildcfg.py"
fails=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fails=$((fails + 1)); }

# assert_eq <description> <expected> <actual>
assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

echo "--- profile env"

# the emitted env is what the build scripts source: prove it is sourceable bash
env_out=$(python3 "$TOOL" profile show simple-graphics --emit env)
# shellcheck disable=SC1090
eval "$env_out"
assert_eq "env: profile name" "simple-graphics" "$PROFILE_NAME"
assert_eq "env: 14 packages (9 essential + 6 mesa - linux-lts)" "14" "${#PROFILE_APK_ADD[@]}"
assert_eq "env: one removal" "linux-lts" "${PROFILE_APK_REMOVE[0]}"
assert_eq "env: 20 services" "20" "${#PROFILE_SERVICES[@]}"
assert_eq "env: one recipe" "simple-graphics-controller" "${PROFILE_RECIPES[0]}"
if printf '%s\n' "${PROFILE_APK_ADD[@]}" | grep -qx 'linux-lts'; then
  bad "env: linux-lts is not installed in this profile"
else
  ok "env: linux-lts is not installed in this profile"
fi

echo "--- board env"

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

echo
if [ "$fails" -eq 0 ]; then
  echo "all buildcfg checks passed"
else
  echo "$fails check(s) failed"
  exit 1
fi
