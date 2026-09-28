#!/bin/bash
# Configure the bootstrapped Alpine rootfs for the Z8Pro and drop in the
# Allwinner BSP kernel (6.18.53-ophub) that the box is known to boot with.
#
# What goes into the image is decided by a profile: profiles/common.toml plus
# profiles/<name>.toml, resolved by tools/buildcfg.py into bash arrays, which is
# what this script installs from and enables. --profile defaults to headless.
# The resolved lists are kept in build/profile.env so 03 can assert the finished
# image against exactly what this stage installed.
#
# Kernel choice: mainline has no node or driver for the X98H's wired port
# (sun50i-h616.dtsi defines only emac0; the X98H PHY hangs off emac1/RMII in
# the vendor DTB), so the BSP kernel + BSP DTB is used for hardware support.
# Alpine linux-lts is an ordinary profile package, not a kernel choice.
#
# Runs as root inside a throwaway Debian container; writes only into /work.
set -euo pipefail

WORK=/work
ROOT="$WORK/rootfs"
BUILDDIR="$WORK/build"
PACKAGES_DIR="$WORK/packages"
KREL=6.18.53-ophub
KDIR=6.18.53
BOARD_HOSTNAME=solovox
ROOT_PARTUUID=abcd1234-01
TZ_NAME=Asia/Ho_Chi_Minh
SSH_PUBKEY_FILE="$WORK/board/authorized_keys"
PROFILE="${PROFILE:-headless}"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    *) echo "unknown option: $1 (usage: $0 [--profile <name>])" >&2; exit 1 ;;
  esac
done

[ -d "$ROOT" ] || { echo "rootfs missing: run 01 first" >&2; exit 1; }

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
    echo "      run scripts/05-build-recipes.sh --profile $PROFILE first" >&2
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
      echo "      run scripts/05-build-recipes.sh --profile $PROFILE first" >&2
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
UUID=9f1c7a3e-5b21-4f8d-9a1c-7b2d4e6f8a90	/	ext4	noatime,errors=remount-ro	0	1
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
install -m 600 "$SSH_PUBKEY_FILE" "$ROOT/root/.ssh/authorized_keys"

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

echo "--- BSP kernel files into /boot"
mkdir -p "$ROOT/boot/dtbs/allwinner/overlay" "$ROOT/boot/extlinux"
install -m 755 "$WORK/kernel/boot/vmlinuz-$KREL" "$ROOT/boot/vmlinuz-$KREL"
install -m 644 "$WORK/kernel/boot/System.map-$KREL" "$ROOT/boot/System.map-$KREL"
install -m 644 "$WORK/kernel/boot/config-$KREL" "$ROOT/boot/config-$KREL"
install -m 644 "$WORK/kernel/dtbs/sun50i-h618-x98h.dtb" "$ROOT/boot/dtbs/allwinner/sun50i-h618-x98h.dtb"

echo "--- Z8Pro / X98H-clone ethernet overlay -> merged DTB"
# Overlay sets the emac1 MDIO PHY reg from 1 to 0 (clone PHY strapping).
# Merged at build time: the kernel has no initramfs here to apply overlays,
# and this u-boot is not relied on for FDTOVERLAYS support.
rm -f "$ROOT/boot/dtbs/allwinner/sun50i-h618-x98h-ethfix.dtb" # pre-rename artifact
dtc -@ -I dts -O dtb -o "$WORK/board/sun50i-h618-z8pro.dtbo" "$WORK/board/sun50i-h618-z8pro-overlay.dts" 2>/dev/null
fdtoverlay -i "$ROOT/boot/dtbs/allwinner/sun50i-h618-x98h.dtb" \
           -o "$ROOT/boot/dtbs/allwinner/sun50i-h618-z8pro-ethfix.dtb" \
           "$WORK/board/sun50i-h618-z8pro.dtbo"
install -m 644 "$WORK/board/sun50i-h618-z8pro.dtbo" "$ROOT/boot/dtbs/allwinner/overlay/"
# The merge must actually have landed: PHY reg 0x00 on the emac1 MDIO bus.
# Captured, not piped into `grep -q`: grep exits at the first match, the writer
# then dies of SIGPIPE, and with pipefail that reads as a failed check. The DTS
# dump is bigger than a pipe buffer, so this race is real, not theoretical.
phy_node=$(dtc -I dtb -O dts "$ROOT/boot/dtbs/allwinner/sun50i-h618-z8pro-ethfix.dtb" 2>/dev/null \
  | sed -n '/ethernet-phy@1/,/};/p')
case "$phy_node" in
  *"reg = <0x00>"*) ;;
  *) echo "ethfix overlay did not apply (PHY reg still 1)" >&2; exit 1 ;;
esac
echo "    merged: $(ls -l "$ROOT/boot/dtbs/allwinner/sun50i-h618-z8pro-ethfix.dtb" | awk '{print $5}') bytes"

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

echo "--- board tools"
# ota-flash (OS side) does not write the disk: it arms the next boot into flash
# mode and reboots. Flash mode is what writes, from RAM, with no rootfs mounted.
install -m 755 "$WORK/board/ota-flash" "$ROOT/usr/sbin/ota-flash"

echo "--- growfs (fill the card on the first boot after a flash)"
# flash mode extends the root partition to the end of the card before it
# reboots; this service grows the filesystem into it once, then reports that
# there is nothing to do on later boots.
RESIZE=""; for c in "$ROOT/usr/sbin/resize2fs" "$ROOT/sbin/resize2fs"; do [ -x "$c" ] && RESIZE="$c"; done
[ -n "$RESIZE" ] || { echo "FAIL: resize2fs missing from the rootfs (needs e2fsprogs-extra)"; exit 1; }
install -m 755 "$WORK/board/growfs" "$ROOT/etc/init.d/growfs"
ln -sf /etc/init.d/growfs "$ROOT/etc/runlevels/boot/growfs"

echo "--- mdev hotplug daemon (this kernel has no uevent helper, so nothing"
echo "    creates /dev nodes or loads modules for hotplugged devices)"
install -m 755 "$WORK/board/mdev-hotplug" "$ROOT/etc/init.d/mdev-hotplug"
ln -sf /etc/init.d/mdev-hotplug "$ROOT/etc/runlevels/boot/mdev-hotplug"

echo "--- flash-mode initramfs"
# Static busybox + the flash init + the bmap writer in a cpio archive. This is
# what runs when the flash label boots: the target disk is not mounted, so the
# write cannot collide with a live rootfs.
IR="$WORK/flash-initramfs"
rm -rf "$IR"
mkdir -p "$IR/bin" "$IR/dev" "$IR/tmp" "$IR/proc" "$IR/sys" "$IR/mnt/root"
[ -x "$ROOT/bin/busybox.static" ] || { echo "FAIL: busybox-static missing from the rootfs"; exit 1; }
install -m 755 "$ROOT/bin/busybox.static" "$IR/bin/busybox"
ln -sf busybox "$IR/bin/sh"
install -m 755 "$WORK/board/flash-init" "$IR/init"
install -m 755 "$WORK/board/bmap-write.sh" "$IR/bin/bmap-write"
[ -f "$ROOT/usr/share/udhcpc/default.script" ] || { echo "FAIL: no udhcpc script in the rootfs"; exit 1; }
install -m 755 "$ROOT/usr/share/udhcpc/default.script" "$IR/udhcpc.script"
# init's stdio is /dev/console: it has to exist before the kernel execs /init
mknod -m 600 "$IR/dev/console" c 5 1
mknod -m 666 "$IR/dev/null" c 1 3
( cd "$IR" && find . | cpio -o -H newc --quiet | gzip -9 ) > "$ROOT/boot/flash-initramfs.gz" \
  || { echo "FAIL: cannot build flash-initramfs.gz"; exit 1; }
ls -lh "$ROOT/boot/flash-initramfs.gz"
# cpio -t prints names without the leading ".".
# Listed once into a variable: `gzip | cpio | grep -q` would end the pipeline at
# the first match and kill the writers with SIGPIPE, which pipefail then reports
# as the check itself failing. The listing is wrapped in newlines so an entry can
# be matched in any position, not just first or last.
ir_listing=$'\n'$(gzip -dc "$ROOT/boot/flash-initramfs.gz" | cpio -t 2>/dev/null)$'\n'
for entry in init bin/busybox bin/bmap-write udhcpc.script; do
  case "$ir_listing" in
    *$'\n'"$entry"$'\n'*) ;;
    *) echo "FAIL: $entry missing from flash-initramfs.gz" >&2; exit 1 ;;
  esac
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
  FDT /boot/dtbs/allwinner/sun50i-h618-z8pro-ethfix.dtb
  APPEND root=PARTUUID=$ROOT_PARTUUID rw rootfstype=ext4 rootwait console=ttyS0,115200 console=tty0 panic=30 no_console_suspend consoleblank=0 max_loop=128 net.ifnames=0 clk_ignore_unused pm_genpd_ignore_unused video=HDMI-A-1:1920x1080@60e

LABEL bsp-nofix
  MENU LABEL Alpine (BSP kernel $KREL, unpatched vendor DTB)
  LINUX /boot/vmlinuz-$KREL
  FDT /boot/dtbs/allwinner/sun50i-h618-x98h.dtb
  APPEND root=PARTUUID=$ROOT_PARTUUID rw rootfstype=ext4 rootwait console=ttyS0,115200 console=tty0 panic=30 no_console_suspend consoleblank=0 max_loop=128 net.ifnames=0 clk_ignore_unused pm_genpd_ignore_unused video=HDMI-A-1:1920x1080@60e

LABEL debug
  MENU LABEL Alpine debug (BSP kernel, explicit /dev/mmcblk0p1, loglevel=8)
  LINUX /boot/vmlinuz-$KREL
  FDT /boot/dtbs/allwinner/sun50i-h618-z8pro-ethfix.dtb
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

# Flash mode: RAM-only initramfs that downloads an image and writes it to the
# disk. ota-flash rewrites this APPEND with ota_* parameters before setting
# DEFAULT to flash, and restores extlinux.conf.bak if the flash aborts before
# the first byte is written.
cat >> "$ROOT/boot/extlinux/extlinux.conf" <<EOF

LABEL flash
  MENU LABEL Flash mode (downloads and writes an image, no OS running)
  LINUX /boot/vmlinuz-$KREL
  FDT /boot/dtbs/allwinner/sun50i-h618-z8pro-ethfix.dtb
  INITRD /boot/flash-initramfs.gz
  APPEND rdinit=/init console=ttyS0,115200 console=tty0 net.ifnames=0 loglevel=7 video=HDMI-A-1:1920x1080@60e panic=30
EOF

echo "--- resulting /boot"
ls -lh "$ROOT/boot"

cleanup
echo "--- rootfs size"
du -sh "$ROOT"
