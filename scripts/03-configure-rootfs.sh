#!/bin/bash
# Configure the bootstrapped Alpine rootfs for one machine, from board data.
#
# The machine is board/common/board.toml plus board/platform/<name>/board.toml,
# resolved by tools/buildcfg.py into build/board.env: the kernel and u-boot to
# expect, the devicetree and its overlays, the hostname, the image's IDs and the
# runtime files that ship. Nothing in this script names a board, a kernel version
# or a devicetree file - that is the point of the layer.
#
# What goes into the image is decided by a profile: profiles/common.toml plus
# profiles/<name>.toml, resolved into bash arrays, which is what this script
# installs from and enables. --profile defaults to headless. The resolved lists
# are kept in build/profile.env so 03 can assert the finished image against
# exactly what this stage installed.
#
# Why this board needs the vendor kernel at all: mainline has no node or driver
# for the X98H's wired port (sun50i-h616.dtsi defines only emac0; the box's PHY
# hangs off emac1/RMII in the vendor DTB), so the BSP kernel + BSP DTB is used for
# hardware support. Alpine linux-lts is an ordinary profile package, not a kernel
# choice. The port is fixed for real by the board's devicetree overlay.
#
# Runs as root inside a throwaway Debian container; writes only into /work.
set -euo pipefail

WORK=/work
ROOT="$WORK/rootfs"
BUILDDIR="$WORK/build"
PACKAGES_DIR="$WORK/packages"
PROFILE="${PROFILE:-headless}"

# The machine's values are data: board/common/board.toml plus
# board/platform/<name>/board.toml. build.sh resolves them before the containers
# start; doing it again here (python3 is in this container) keeps this stage
# runnable on its own, and this is the only place build/board.env is written.
mkdir -p "$BUILDDIR"
BOARD="${BOARD:-${BOARD_MACHINE:-}}"
if [ -f "$BUILDDIR/board.env" ]; then
  # shellcheck disable=SC1090
  . "$BUILDDIR/board.env"
fi
BOARD="${BOARD:-$BOARD_MACHINE}"
[ -n "$BOARD" ] || BOARD=$(python3 "$WORK/tools/buildcfg.py" board list | head -1)
python3 "$WORK/tools/buildcfg.py" board show "$BOARD" --emit env > "$BUILDDIR/board.env"
# shellcheck disable=SC1090
. "$BUILDDIR/board.env"

# The names the rest of this script uses. The board layer is their only source:
# no board name, kernel version or devicetree file is written into this script.
KREL="$BOARD_KERNEL_RELEASE"
KDIR="$BOARD_KERNEL"
ROOT_PARTUUID="$BOARD_ROOT_PARTUUID"
TZ_NAME="$BOARD_TIMEZONE"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    *) echo "unknown option: $1 (usage: $0 [--profile <name>])" >&2; exit 1 ;;
  esac
done

[ -d "$ROOT" ] || { echo "rootfs missing: run 02 first" >&2; exit 1; }

cleanup() {
  for m in proc dev sys; do
    mountpoint -q "$ROOT/$m" && umount -R "$ROOT/$m" || true
  done
}
trap cleanup EXIT

mount -t proc proc "$ROOT/proc"
mount --rbind /dev "$ROOT/dev"
mount --rbind /sys "$ROOT/sys"

echo "--- profile: $PROFILE"
# tools/buildcfg.py merges profiles/common.toml with the profile and emits bash
# arrays: the profile decides the packages, the services and the recipes, and
# nothing below re-states them.
mkdir -p "$BUILDDIR"
python3 "$WORK/tools/buildcfg.py" profile show "$PROFILE" --emit env > "$BUILDDIR/profile.env"
# shellcheck disable=SC1090
. "$BUILDDIR/profile.env"
printf '    %s packages, %s recipes, %s services\n' \
  "${#PROFILE_APK_ADD[@]}" "${#PROFILE_RECIPES[@]}" "${#PROFILE_SERVICES[@]}"

echo "--- profile packages"
chroot "$ROOT" /sbin/apk add --no-cache "${PROFILE_APK_ADD[@]}"

if [ "${#PROFILE_RUNTIME_APK_ADD[@]}" -gt 0 ]; then
  echo "--- runtime packages for the recipe-built ones"
  chroot "$ROOT" /sbin/apk add --no-cache "${PROFILE_RUNTIME_APK_ADD[@]}"
fi

if [ "${#PROFILE_RECIPES[@]}" -gt 0 ]; then
  echo "--- recipe packages (built by 05, not from the mirrors)"
  # The packages are ours and are signed with the build key, so apk only needs
  # that key's public half: copying it in is what lets the install below run
  # without --allow-untrusted. Copied into the rootfs first: the chroot cannot
  # see /work.
  if [ ! -d "$WORK/build/keys" ]; then
    echo "FAIL: no signing key in $WORK/build/keys" >&2
    echo "      run scripts/01-build-recipes.sh --profile $PROFILE first" >&2
    exit 1
  fi
  install -d -m 755 "$ROOT/etc/apk/keys"
  for pub in "$WORK/build/keys"/*.rsa.pub; do
    [ -f "$pub" ] || continue
    install -m 644 "$pub" "$ROOT/etc/apk/keys/$(basename "$pub")"
    echo "    trusted key: $(basename "$pub")"
  done
  for recipe in "${PROFILE_RECIPES[@]}"; do
    apk_file=""
    for candidate in "$PACKAGES_DIR/${recipe}"_[0-9]*.apk; do
      [ -f "$candidate" ] && apk_file="$candidate"
    done
    if [ -z "$apk_file" ]; then
      echo "FAIL: no built package for recipe '$recipe' in $PACKAGES_DIR" >&2
      echo "      run scripts/01-build-recipes.sh --profile $PROFILE first" >&2
      exit 1
    fi
    install -m 644 "$apk_file" "$ROOT/tmp/$(basename "$apk_file")"
    chroot "$ROOT" /sbin/apk add --no-cache "/tmp/$(basename "$apk_file")"
    rm -f "$ROOT/tmp/$(basename "$apk_file")"
    echo "    $recipe <- $(basename "$apk_file")"
  done
fi

echo "--- base config files"
printf '%s\n' "$BOARD_HOSTNAME" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1	localhost.localdomain localhost $BOARD_HOSTNAME
::1		localhost.localdomain localhost $BOARD_HOSTNAME
EOF

cat > "$ROOT/etc/fstab" <<EOF
# <file system>	<mount point>	<type>	<options>		<dump>	<pass>
UUID=$BOARD_ROOTFS_UUID	/	ext4	noatime,errors=remount-ro	0	1
EOF

cat > "$ROOT/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

printf '%s\n' "$TZ_NAME" > "$ROOT/etc/timezone"
ln -sf "/usr/share/zoneinfo/$TZ_NAME" "$ROOT/etc/localtime"

# Key-only remote login: dropbear host keys are generated on first start by
# dropbear-openrc; -s disables password auth (root's password is locked anyway).
cat > "$ROOT/etc/conf.d/dropbear" <<'EOF'
DROPBEAR_OPTS="-s"
DROPBEAR_BANNER=""
EOF
mkdir -p "$ROOT/root/.ssh"
# The key itself is a runtime file (board/common/runtime/root/root/.ssh/), copied
# with its tree further down and kept 0600 by BOARD_PRIVATE_FILES: this script
# never names the file.

# Services are enabled further down, from the profile's list, once the board's
# own init scripts are in place: every entry is checked against the image, so an
# entry whose script is missing fails the build instead of the boot.

echo "--- clock (no RTC on this board)"
# Without this the clock sits at 1970 until someone sets it by hand, and every
# HTTPS fetch fails with "certificate verify failed" (apk included).
# swclock: restore the timestamp saved at the last shutdown, so the date is
# roughly right from early boot; it provides "clock", so it takes hwclock's
# slot in the boot runlevel.
# ntpd: busybox NTP client, started from the default runlevel (needs net).
[ -x "$ROOT/etc/init.d/swclock" ] && ln -sf /etc/init.d/swclock "$ROOT/etc/runlevels/boot/swclock"
cat > "$ROOT/etc/conf.d/ntpd" <<'EOF'
# busybox NTP client; started by the ntpd service, which needs networking.
NTPD_OPTS="-N -p pool.ntp.org -p time.cloudflare.com"
EOF
grep -E "^ntp:" "$ROOT/etc/passwd" >/dev/null || echo "WARNING: no ntp user for the ntpd service" >&2

echo "--- board kernel files into /boot"
mkdir -p "$ROOT/boot/dtbs/allwinner/overlay" "$ROOT/boot/extlinux"
install -m 755 "$WORK/kernel/boot/vmlinuz-$KREL" "$ROOT/boot/vmlinuz-$KREL"
install -m 644 "$WORK/kernel/boot/System.map-$KREL" "$ROOT/boot/System.map-$KREL"
install -m 644 "$WORK/kernel/boot/config-$KREL" "$ROOT/boot/config-$KREL"
install -m 644 "$WORK/kernel/dtbs/$BOARD_DTB" "$ROOT/boot/dtbs/allwinner/$BOARD_DTB"

echo "--- board devicetree overlays -> $BOARD_BOOT_DTB"
# The overlays are the board's own sources (BOARD_OVERLAYS, .dtso), compiled and
# merged here: the kernel has no initramfs to apply overlays, and this u-boot is
# not relied on for FDTOVERLAYS support. One overlay or several - fdtoverlay takes
# them in order. The compiled artifacts belong to the build, not the tree: they go
# under build/, which is ignored and wiped by a clean.
rm -f "$ROOT/boot/dtbs/allwinner/sun50i-h618-x98h-ethfix.dtb" # pre-rename artifact
# the overlay was installed as sun50i-h618-z8pro.dtbo before this file was
# renamed; a reused rootfs keeps it otherwise, and two overlays for one board in
# /boot/dtbs/allwinner/overlay/ invite reading the wrong one
rm -f "$ROOT/boot/dtbs/allwinner/overlay/sun50i-h618-z8pro.dtbo"
DTBO_DIR="$WORK/build/devicetree/overlay"
mkdir -p "$DTBO_DIR"
DTBOS=()
for overlay in "${BOARD_OVERLAYS[@]}"; do
  overlay_name=$(basename "${overlay%.dtso}")
  dtc -@ -I dts -O dtb -o "$DTBO_DIR/$overlay_name.dtbo" \
    "$WORK/$BOARD_DIR/$overlay" 2>/dev/null
  DTBOS+=("$DTBO_DIR/$overlay_name.dtbo")
done
fdtoverlay -i "$ROOT/boot/dtbs/allwinner/$BOARD_DTB" \
           -o "$ROOT/boot/dtbs/allwinner/$BOARD_BOOT_DTB" \
           "${DTBOS[@]}"
install -m 644 "${DTBOS[@]}" "$ROOT/boot/dtbs/allwinner/overlay/"
# The merge must actually have landed: the node the board layer names must contain
# the text it names, or the board boots with a dead port and it reads as a hardware
# fault. Captured, not piped into `grep -q`: grep exits at the first match, the
# writer then dies of SIGPIPE, and with pipefail that reads as a failed check. The
# DTS dump is bigger than a pipe buffer, so this race is real, not theoretical.
merged_node=$(dtc -I dtb -O dts "$ROOT/boot/dtbs/allwinner/$BOARD_BOOT_DTB" 2>/dev/null \
  | sed -n "/$BOARD_MERGE_CHECK_NODE/,/};/p")
case "$merged_node" in
  *"$BOARD_MERGE_CHECK_TEXT"*) ;;
  *) echo "FAIL: $BOARD_MERGE_CHECK_NODE in $BOARD_BOOT_DTB does not contain" \
          "'$BOARD_MERGE_CHECK_TEXT': the overlay did not apply" >&2
     exit 1 ;;
esac
echo "    merged: $(stat -c %s "$ROOT/boot/dtbs/allwinner/$BOARD_BOOT_DTB") bytes," \
     "$BOARD_MERGE_CHECK_NODE has $BOARD_MERGE_CHECK_TEXT"

echo "--- BSP modules into /lib/modules"
# The tarball's top-level directory is already named <KREL>, so it must be
# unpacked into /lib/modules or the modules land at /<KREL>.
rm -rf "$ROOT/$KREL" "$ROOT/lib/modules/$KREL"
mkdir -p "$ROOT/lib/modules"
tar -xzf "$WORK/kernel/$KDIR/modules-$KREL.tar.gz" -C "$ROOT/lib/modules"
ls "$ROOT/lib/modules"
[ -d "$ROOT/lib/modules/$KREL" ] || { echo "BSP modules did not extract to /lib/modules/$KREL" >&2; exit 1; }

echo "--- mdev hotplug-helper writes (kernel has no CONFIG_UEVENT_HELPER)"
# /etc/init.d/mdev writes /proc/sys/kernel/hotplug, which only exists when the
# kernel is built with CONFIG_UEVENT_HELPER. The BSP kernel is not, so openrc
# logs "can't create /proc/sys/kernel/hotplug: nonexistent directory" on boot
# and shutdown. Device nodes come from devtmpfs (CONFIG_DEVTMPFS_MOUNT=y), so
# guard the writes instead of leaving the noise in the log.
sed -i -e 's|^\techo "/sbin/mdev" > /proc/sys/kernel/hotplug|\t[ -e /proc/sys/kernel/hotplug ] \&\& echo "/sbin/mdev" > /proc/sys/kernel/hotplug|' \
       -e 's|^\techo > /proc/sys/kernel/hotplug|\t[ -e /proc/sys/kernel/hotplug ] \&\& echo > /proc/sys/kernel/hotplug|' \
  "$ROOT/etc/init.d/mdev"
grep -n "hotplug" "$ROOT/etc/init.d/mdev"

echo "--- board runtime files"
# board/common/runtime/root/ mirrors the image's layout: a file's path in the tree
# is its path on the board, so modes, the two OpenRC runlevel symlinks and the
# ownership all carry themselves. This is why no destination is written down here,
# and why config and executables are as separate as they are on the running
# system: a script sits where the init system looks for it, the SSH key under
# /root/.ssh. A platform may add its own tree of the same shape (board.toml's
# runtime_root lists them in order).
#
# ota-flash (OS side) does not write the disk: it arms the next boot into flash
# mode and reboots. Flash mode is what writes, from RAM, with no rootfs mounted.
# Filling the card is two boots, one per mode of the same RAM initramfs: flash
# mode extends the root partition to the end of the card before it reboots, and
# the growfs service then arms one grow boot, which grows the filesystem with
# nothing mounted from it. Neither half can be done from the running OS - the
# partition table cannot be re-read while the rootfs on it is mounted, and the
# online resize2fs wedges this board - which is why both are boots.
for tree in "${BOARD_RUNTIME_ROOTS[@]}"; do
  echo "    $tree"
  # -rlptDHX, not -a: the file's mode in the tree is the mode on the board (git
  # tracks the executable bit, which is why the tree is the source of truth), but
  # ownership must not be copied - the files are root's on the board, and a
  # host-user-owned authorized_keys is a key dropbear refuses.
  rsync -rlptDHX --numeric-ids --no-owner --no-group "$WORK/$tree/" "$ROOT/"
done
for item in "${BOARD_PRIVATE_FILES[@]}"; do
  chmod 600 "$ROOT/$item"
done
# The files are root's on the board. rsync runs as root inside the container but
# writes as the receiving user, and a reused rootfs keeps an older uid, so say it
# explicitly: sshd and dropbear refuse an authorized_keys that is not owned by the
# user it authenticates.
for tree in "${BOARD_RUNTIME_ROOTS[@]}"; do
  ( cd "$WORK/$tree" && find . \( -type f -o -type l \) -printf '%P\n' ) |
    while IFS= read -r rel; do
      chown -h 0:0 "$ROOT/$rel"
    done
done
# What the tree promises has to be true of the image: an init script that is not
# executable, or a service that is in the tree but not enabled, boots as a
# missing daemon and reads like a bug in the software.
for tree in "${BOARD_RUNTIME_ROOTS[@]}"; do
  for script in "$WORK/$tree"/etc/init.d/*; do
    [ -e "$script" ] || continue
    name=$(basename "$script")
    [ -x "$ROOT/etc/init.d/$name" ] ||
      { echo "FAIL: /etc/init.d/$name is missing or not executable in the rootfs" >&2; exit 1; }
  done
  for level in "$WORK/$tree"/etc/runlevels/*; do
    [ -d "$level" ] || continue
    level_name=$(basename "$level")
    for entry in "$level"/*; do
      [ -e "$entry" ] || continue
      name=$(basename "$entry")
      [ -L "$ROOT/etc/runlevels/$level_name/$name" ] ||
        { echo "FAIL: $name is not enabled in the $level_name runlevel" >&2; exit 1; }
    done
  done
done
# resize2fs is not for the OS to run: it is the payload grow mode runs inside the
# RAM initramfs, which is packed out of this rootfs, so it has to be here.
RESIZE=""; for c in "$ROOT/usr/sbin/resize2fs" "$ROOT/sbin/resize2fs"; do [ -x "$c" ] && RESIZE="$c"; done
[ -n "$RESIZE" ] || { echo "FAIL: resize2fs missing from the rootfs (needs e2fsprogs-extra)"; exit 1; }

echo "--- RAM initramfs (flash mode and grow mode)"
# Static busybox + both modes' userspace in one cpio archive. It is what runs when
# either the flash label or the grow label boots, and both act on the card with
# nothing mounted from it: flash mode writes an image, grow mode resizes the root
# filesystem (the online path wedges this board, see the growfs service).
IR="$BUILDDIR/ram-initramfs"
rm -rf "$IR"
mkdir -p "$IR/bin" "$IR/dev" "$IR/tmp" "$IR/proc" "$IR/sys" "$IR/mnt/root" \
         "$IR/lib" "$IR/sbin" "$IR/usr/sbin" "$IR/usr/lib"
[ -x "$ROOT/bin/busybox.static" ] || { echo "FAIL: busybox-static missing from the rootfs"; exit 1; }
install -m 755 "$ROOT/bin/busybox.static" "$IR/bin/busybox"
ln -sf busybox "$IR/bin/sh"
# /init, the bmap writer and the grow mode come from the runtime trees
# (board/common/runtime/initramfs/: init -> /init, bin/* -> /bin/*), the same
# mirror-the-destination convention as the rootfs tree.
for tree in "${BOARD_RUNTIME_INITRAMFS_DIRS[@]}"; do
  rsync -rlptDHX --numeric-ids --no-owner --no-group "$WORK/$tree/" "$IR/"
done
# Grow mode's e2fsprogs are the image's own binaries, dynamically linked, so the
# loader and their libraries come with them. Two traps that each cost a boot:
#   - the soname files are symlinks (libe2p.so.2 -> libe2p.so.2.x), so copy with
#     `cat` rather than `cp -a`: a copied symlink is dangling in the archive and
#     the loader reports "Error loading shared library libe2p.so.2";
#   - the dependency pass also copies /lib/ld-musl-aarch64.so.1 (every dynamic
#     binary lists the loader) and it must not end up non-executable: execve()
#     runs the loader, and mode 644 there fails every binary in the archive with
#     EACCES, which at boot reads as "Failed to execute /init (error -13)".
# Hence the explicit modes, re-applied after the copy.
E2_BINS="/sbin/e2fsck /usr/sbin/resize2fs /usr/sbin/tune2fs"
e2_copy() { # $1 = path inside the rootfs, $2 = mode for the copy
  [ -e "$ROOT$1" ] || return 1
  mkdir -p "$IR$(dirname "$1")"
  cat "$ROOT$1" > "$IR$1" || return 1
  chmod "$2" "$IR$1"
}
for bin in $E2_BINS; do
  e2_copy "$bin" 755 ||
    { echo "FAIL: $bin missing from the rootfs (grow mode runs it from the initramfs)" >&2; exit 1; }
done
e2_ldd="$BUILDDIR/e2fs-libs"
# The loader's own --list instead of the ldd script: ldd is a shell script that an
# image may not have installed, and the loader covers one binary per call.
# shellcheck disable=SC2086
for bin in $E2_BINS; do
  chroot "$ROOT" /lib/ld-musl-aarch64.so.1 --list "$bin" 2>/dev/null || true
done | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^\//) print $i }' | sort -u > "$e2_ldd"
[ -s "$e2_ldd" ] || { echo "FAIL: no dependencies listed for the grow mode binaries"; exit 1; }
while IFS= read -r lib; do
  e2_copy "$lib" 644 ||
    { echo "FAIL: $lib is needed by grow mode's e2fsprogs but is not in the rootfs" >&2; exit 1; }
done < "$e2_ldd"
for bin in /lib/ld-musl-aarch64.so.1 $E2_BINS; do
  [ -f "$IR$bin" ] && chmod 755 "$IR$bin"
done
[ -f "$ROOT/usr/share/udhcpc/default.script" ] || { echo "FAIL: no udhcpc script in the rootfs"; exit 1; }
install -m 755 "$ROOT/usr/share/udhcpc/default.script" "$IR/udhcpc.script"
# init's stdio is /dev/console: it has to exist before the kernel execs /init
mknod -m 600 "$IR/dev/console" c 5 1
mknod -m 666 "$IR/dev/null" c 1 3
( cd "$IR" && find . | cpio -o -H newc --quiet | gzip -9 ) > "$ROOT/boot/ram-initramfs.gz" \
  || { echo "FAIL: cannot build ram-initramfs.gz"; exit 1; }
ls -lh "$ROOT/boot/ram-initramfs.gz"
# cpio -t prints names without the leading ".". Listed once into a variable:
# `gzip | cpio | grep -q` would end the pipeline at the first match and kill the
# writers with SIGPIPE, which pipefail then reports as the check itself failing.
# The listing is wrapped in newlines so an entry can be matched in any position,
# not just first or last.
ir_listing=$'\n'$(gzip -dc "$ROOT/boot/ram-initramfs.gz" | cpio -t 2>/dev/null)$'\n'
for entry in init bin/busybox bin/bmap-write bin/grow-rootfs udhcpc.script \
             sbin/e2fsck usr/sbin/resize2fs usr/sbin/tune2fs lib/ld-musl-aarch64.so.1; do
  case "$ir_listing" in
    *$'\n'"$entry"$'\n'*) ;;
    *) echo "FAIL: $entry missing from ram-initramfs.gz" >&2; exit 1 ;;
  esac
done
# What has to exec inside the archive needs the executable bit in the archive, and
# the loader most of all: execve() runs it for every binary above.
ir_modes=$(gzip -dc "$ROOT/boot/ram-initramfs.gz" | cpio -tv 2>/dev/null)
mode_ok() { printf '%s\n' "$ir_modes" | awk -v n="$1" '$1 == "-rwxr-xr-x" && $NF == n { found = 1 } END { exit !found }'; }
for entry in init bin/busybox bin/grow-rootfs sbin/e2fsck usr/sbin/resize2fs lib/ld-musl-aarch64.so.1; do
  mode_ok "$entry" ||
    { echo "FAIL: $entry is not executable in ram-initramfs.gz (a non-executable loader breaks every binary)" >&2; exit 1; }
done

echo "--- services from the profile"
# An entry is <runlevel>:<service>; a bare name means the default runlevel. Its
# init script has to exist by now: an image that enables a service it does not
# ship is broken at boot, and the build is where that is still cheap to catch.
for entry in "${PROFILE_SERVICES[@]}"; do
  level=${entry%%:*}
  svc=${entry#*:}
  if [ "$level" = "$entry" ]; then
    level=default
  fi
  if [ ! -x "$ROOT/etc/init.d/$svc" ]; then
    echo "FAIL: profile '$PROFILE' enables service '$svc' but /etc/init.d/$svc is not in the image" >&2
    exit 1
  fi
  mkdir -p "$ROOT/etc/runlevels/$level"
  ln -sf "/etc/init.d/$svc" "$ROOT/etc/runlevels/$level/$svc"
done
ls "$ROOT/etc/runlevels/boot" "$ROOT/etc/runlevels/default"

echo "--- image manifest"
# What this image is: the profile, the packages it asked for, what it removed,
# the commit each recipe was built from, and the versions that actually landed.
# Read on the board at /etc/solovox/image-manifest.
install -d -m 755 "$ROOT/etc/solovox"
{
  python3 "$WORK/tools/buildcfg.py" board show "$BOARD" --emit manifest
  python3 "$WORK/tools/buildcfg.py" profile show "$PROFILE" --emit manifest
  printf 'built: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'packages:\n'
  chroot "$ROOT" /sbin/apk info -v | sed 's/^/  /'
} > "$ROOT/etc/solovox/image-manifest"

echo "--- extlinux.conf"
cat > "$ROOT/boot/extlinux/extlinux.conf" <<EOF
TIMEOUT 30
DEFAULT bsp
MENU TITLE Solovox Z8Pro Alpine

# Pick a label by editing DEFAULT (no serial console on this board).
# 'debug' replaces the PARTUUID with an explicit /dev/mmcblk0p1, drops
# rootwait and raises the loglevel, so a missing root panics and reboots
# instead of waiting silently forever.
# 'console=tty0' is last on purpose: /dev/console goes to the last console=
# entry, and userspace output (OpenRC, service logs, login) has to appear on
# HDMI, not on the unattached UART.

LABEL bsp
  MENU LABEL Alpine (BSP kernel $KREL, Z8Pro ethfix)
  LINUX /boot/vmlinuz-$KREL
  FDT /boot/dtbs/allwinner/$BOARD_BOOT_DTB
  APPEND root=PARTUUID=$ROOT_PARTUUID rw rootfstype=ext4 rootwait console=ttyS0,115200 console=tty0 panic=30 no_console_suspend consoleblank=0 max_loop=128 net.ifnames=0 clk_ignore_unused pm_genpd_ignore_unused video=HDMI-A-1:1920x1080@60e

LABEL bsp-nofix
  MENU LABEL Alpine (BSP kernel $KREL, unpatched vendor DTB)
  LINUX /boot/vmlinuz-$KREL
  FDT /boot/dtbs/allwinner/$BOARD_DTB
  APPEND root=PARTUUID=$ROOT_PARTUUID rw rootfstype=ext4 rootwait console=ttyS0,115200 console=tty0 panic=30 no_console_suspend consoleblank=0 max_loop=128 net.ifnames=0 clk_ignore_unused pm_genpd_ignore_unused video=HDMI-A-1:1920x1080@60e

LABEL debug
  MENU LABEL Alpine debug (BSP kernel, explicit /dev/mmcblk0p1, loglevel=8)
  LINUX /boot/vmlinuz-$KREL
  FDT /boot/dtbs/allwinner/$BOARD_BOOT_DTB
  APPEND root=/dev/mmcblk0p1 rw rootfstype=ext4 ignore_loglevel loglevel=8 panic=15 console=ttyS0,115200 console=tty0 no_console_suspend consoleblank=0 max_loop=128 net.ifnames=0 clk_ignore_unused pm_genpd_ignore_unused video=HDMI-A-1:1920x1080@60e

EOF

# The mainline entry exists only when linux-lts is in the image: a profile is
# allowed to remove it (the graphics one does), and a label pointing at a kernel
# that is not on the disk is a boot failure waiting for the next TIMEOUT.
mainline=0
for pkg in "${PROFILE_APK_ADD[@]}"; do
  if [ "$pkg" = linux-lts ]; then mainline=1; fi
done
if [ "$mainline" = 1 ]; then
cat >> "$ROOT/boot/extlinux/extlinux.conf" <<EOF

LABEL mainline
  MENU LABEL Alpine (mainline linux-lts, no wired ethernet)
  LINUX /boot/vmlinuz-lts
  INITRD /boot/initramfs-lts
  FDT /boot/dtbs-lts/allwinner/sun50i-h618-transpeed-8k618-t.dtb
  APPEND root=PARTUUID=$ROOT_PARTUUID rw rootfstype=ext4 rootwait console=ttyS0,115200 console=tty0 panic=30 max_loop=128 net.ifnames=0
EOF
fi

# The RAM initramfs has two modes and one archive. Flash mode downloads an image
# and writes it to the disk: ota-flash rewrites this APPEND with ota_* parameters
# before setting DEFAULT to flash, and restores extlinux.conf.bak if the flash
# aborts before the first byte is written.
cat >> "$ROOT/boot/extlinux/extlinux.conf" <<EOF

LABEL flash
  MENU LABEL Flash mode (downloads and writes an image, no OS running)
  LINUX /boot/vmlinuz-$KREL
  FDT /boot/dtbs/allwinner/$BOARD_BOOT_DTB
  INITRD /boot/ram-initramfs.gz
  APPEND rdinit=/init ram_mode=flash console=ttyS0,115200 console=tty0 net.ifnames=0 loglevel=7 video=HDMI-A-1:1920x1080@60e panic=30
EOF

# Grow mode: the same RAM initramfs, cold-resizing the root filesystem. The growfs
# service points DEFAULT here (after saving extlinux.conf.bak) when the filesystem
# is smaller than its partition; grow mode restores that file before it reboots,
# so this is a one-boot detour. Picking the label by hand at the menu is safe:
# resize2fs on a filesystem that already fills its partition does nothing.
cat >> "$ROOT/boot/extlinux/extlinux.conf" <<EOF

LABEL grow
  MENU LABEL Cold resize the root filesystem (no OS running)
  LINUX /boot/vmlinuz-$KREL
  FDT /boot/dtbs/allwinner/$BOARD_BOOT_DTB
  INITRD /boot/ram-initramfs.gz
  APPEND rdinit=/init ram_mode=grow console=ttyS0,115200 console=tty0 loglevel=7 panic=30
EOF

echo "--- resulting /boot"
ls -lh "$ROOT/boot"

cleanup
echo "--- rootfs size"
du -sh "$ROOT"
