# Alpine Linux for the Solovox Z8Pro (Allwinner H618 TV box)

Built on an x86_64 host; nothing runs on the board during the build. Target
board: a **Solovox Z8Pro** — an X98H clone (H618, 2–4 GB LPDDR, SD card
`mmcblk0` + 14.6 GB eMMC `mmcblk2`, 100M Ethernet behind RMII, Mali-G31 via
panfrost, NEC IR receiver). Vendor artifacts keep the `x98h` name in their
filenames (`sun50i-h618-x98h.dtb`, `ophub/u-boot allwinner/x98h`) because that
is what upstream calls this hardware family.

## Result

```
image/alpine-solovox-z8pro-3.22.6-6.18.53.img        4.0 GiB raw SD/eMMC image
image/alpine-solovox-z8pro-3.22.6-6.18.53.img.sha256 719f9ecfcf6a7b71083d8cb650ba91ead3d349d99e1760aba5550001adc2e47a
```

Flash it whole to an SD card (or later to eMMC); it contains the bootloader,
the kernel and the rootfs.

## Kernel choice: Allwinner BSP, not Alpine mainline

The wired port of this box is not usable with a mainline kernel:

- `sun50i-h616.dtsi` (checked at v6.12 and v6.18) defines **only `emac0`**
  (GMAC at 0x5020000). There is no `emac1` node.
- The X98H vendor DTB enables **`ethernet@5030000` (emac1)** with
  `phy-mode = "rmii"`, `phy-handle` to `ethernet-phy@1`, and `emac0` disabled —
  this is the port the RJ45 is wired to, and why Armbian carries an `ethfix`
  overlay for RMII clock delays.
- `dwmac-sun8i.c` has no H616 EMAC200 (emac1) support to drive it.

So the image ships the BSP kernel the board already ran in production
(`6.18.53-ophub` from the [ophub/kernel](https://github.com/ophub/kernel)
`kernel_stable` release), paired with the Alpine 3.22 userspace. That kernel has
the hardware baked in:

| Requirement | Config |
|---|---|
| boot without initramfs | `CONFIG_MMC_SUNXI=y`, `CONFIG_EXT4_FS=y` |
| wired Ethernet (emac1) | `CONFIG_DWMAC_SUN8I=y`, `CONFIG_STMMAC_ETH=y` |
| HDMI console | `CONFIG_DRM_SUN8I_DW_HDMI=y`, `CONFIG_DRM_SUN4I=y` |
| Mali-G31 GPU | `CONFIG_DRM_PANFROST=m` |
| IR receiver | `CONFIG_IR_SUNXI=m` |
| PMIC (AXP313) | `CONFIG_SUNXI_RSB=y`, `CONFIG_MFD_AXP20X_RSB=y` |

Alpine's own `linux-lts` (6.12.110) is also installed and selectable as a
second extlinux entry for comparison/debugging. It boots the board but has no
wired Ethernet.

## Image layout

```
offset 8 KiB   u-boot-sunxi-with-spl.bin (Allwinner SPL + u-boot, eGON.BT0)
offset 1 MiB   MBR partition 1, bootable flag, type 83 (Linux), rest of the disk
               ext4, LABEL=rootfs, UUID=9f1c7a3e-5b21-4f8d-9a1c-7b2d4e6f8a90
               PARTUUID=abcd1234-01  (MBR disk id abcd1234)
```

The bootable flag is not cosmetic: u-boot's `distro_bootcmd` walks only
partitions from `part list -bootable` and scans them for
`boot.scr`/`extlinux/extlinux.conf`.

`/boot/extlinux/extlinux.conf`:

```
TIMEOUT 30
DEFAULT bsp
LABEL bsp          # vendor DTB + Z8Pro ethernet overlay (see below)
  LINUX /boot/vmlinuz-6.18.53-ophub
  FDT   /boot/dtbs/allwinner/sun50i-h618-z8pro-ethfix.dtb
  APPEND root=PARTUUID=abcd1234-01 rw rootfstype=ext4 rootwait
         console=ttyS0,115200 console=tty0 panic=30 ...
         clk_ignore_unused pm_genpd_ignore_unused video=HDMI-A-1:1920x1080@60e
LABEL bsp-nofix    # same kernel, unpatched vendor DTB
  FDT   /boot/dtbs/allwinner/sun50i-h618-x98h.dtb
LABEL debug        # explicit /dev/mmcblk0p1, no rootwait, loglevel=8
  LINUX /boot/vmlinuz-6.18.53-ophub
  APPEND root=/dev/mmcblk0p1 rw rootfstype=ext4 ignore_loglevel loglevel=8
         panic=15 console=ttyS0,115200 console=tty0 ...
LABEL mainline     # Alpine 6.12.110, no wired Ethernet
  LINUX /boot/vmlinuz-lts
LABEL flash        # flash mode: RAM-only initramfs, writes an image, no OS
  LINUX /boot/vmlinuz-6.18.53-ophub
  INITRD /boot/flash-initramfs.gz
```

`root=PARTUUID=` (not `UUID=`) is used so the same image boots from SD and from
eMMC without editing the cmdline.

Three cmdline details are deliberate:

- **`console=tty0` last.** The kernel gives `/dev/console` to the last
  `console=` entry. With `console=ttyS0` last, all userspace output (OpenRC,
  service logs, login) went to the unattached UART and the HDMI screen looked
  frozen even on a healthy boot.
- **`rootfstype=ext4`, `panic=`.** Without `rootfstype` the kernel probes
  filesystem types; `panic=` reboots on a panic instead of freezing, so a
  failure re-prints on screen where there is no serial console.
- **`clk_ignore_unused`, `pm_genpd_ignore_unused`.** The vendor DTB does not
  describe every clock/power domain the SoC has, and late init can otherwise
  gate something the boot still needs.

## Boot debugging (HDMI-only board)

Symptom seen once: kernel messages stop after the eMMC boot partition line
(`mmcblk1boot1: mmc1:0001 AJNB4R 4.00MiB`), then an idle blinking cursor and no
OpenRC output. That is the signature of the kernel **not reaching userspace** —
with `rootwait` on the cmdline a missing/undetected root device waits forever
and silently, so nothing is logged.

- `check access for rdinit=/init failed: -2, ignoring` is a **kernel** warning
  from `init/main.c` (6.16+). It fires whenever there is no initramfs, i.e. by
  design here, and is harmless; an upstream patch exists to stop printing it
  unless `rdinit=` was passed explicitly.
- To find the real stop: set `DEFAULT debug` on the card and boot. The kernel
  then uses `/dev/mmcblk0p1` instead of a PARTUUID, drops `rootwait`, raises the
  loglevel, and panics+reboots on failure — so either the boot log shows the
  actual error, or `VFS: Cannot open root device` repeats, which means the SD
  card is not being detected at all.
- Check the card before trusting the image: read the whole card back and compare
  with `image/*.img` (`sudo dd if=/dev/sdX bs=4M count=1024 | sha256sum`), and
  watch `dmesg` for I/O errors on the reader.
- `/usr/libexec/rc/sh/openrc-run.sh: line 15: can't create
  /proc/sys/kernel/hotplug: nonexistent directory` (the line number belongs to
  `/etc/init.d/mdev`, which openrc sources) is the same kind of noise:
  `/proc/sys/kernel/hotplug` only exists with `CONFIG_UEVENT_HELPER`, and the
  BSP kernel is built without it (`# CONFIG_UEVENT_HELPER is not set`). Device
  nodes come from devtmpfs (`CONFIG_DEVTMPFS_MOUNT=y`), so both writers in
  `/etc/init.d/mdev` are guarded in the build. Side effect of a missing uevent
  helper: `mdev.conf` rules only run at coldplug, so hotplugged devices get
  their devtmpfs node but no per-owner/mode fixup or `$MODALIAS` autoload.

## OTA reflash over HTTP (flash mode)

Two pieces ship in the image:

- `/usr/sbin/ota-flash` (source `board/runtime/ota-flash`) arms the next boot.
- a `flash` extlinux label and `/boot/flash-initramfs.gz` are flash mode itself.

`ota-flash <url>` writes nothing. It checks the URL and its sidecars, bakes the
image URL, its sha256, size, bmap and the target disk into the `flash` label,
saves `/boot/extlinux/extlinux.conf.bak`, sets `DEFAULT flash` and reboots. The
next boot runs the initramfs instead of the OS: kernel and userspace come from
RAM, no rootfs is mounted, and the only thing touching the card is `dd`. That is
the point of the design. Writing the boot medium from the running OS put ext4
writeback inside the image being written, and the flasher's own executables were
read back from the blocks `dd` was overwriting.

Flash mode sequence (`board/runtime/flash-init`): read the `ota_*` parameters from the
kernel command line, bring `eth0` up over DHCP, fetch the bmap, stream the `.gz`
through gzip writing only the mapped ranges, verify every range by reading it
back, check the u-boot magic at KiB 8, reboot. The freshly written image has
`DEFAULT bsp`, so the box comes up in the OS.

Recovery, and the two outcomes are different:

- A failure **before the first byte is written** — no DHCP lease, sidecar
  missing, bmap inconsistent with the image, or a target that is not zero
  outside the mapped ranges — restores `extlinux.conf.bak`, syncs and reboots:
  the installed system starts as if nothing had happened. `ota-flash --cancel`
  undoes the arming before that reboot as well.
- A failure **after the write starts** leaves a partly written disk. Nothing on
  the machine can recover it: pull the card and flash it in a reader.

```
# on this host: compress, build the bmap, write the sidecars, publish a release
# folder to the NAS and verify it over HTTP
scripts/05-ota-publish.sh

# on the board: check the source and the metadata, change nothing
ota-flash http://10.21.50.12:8080/latest/alpine-solovox-z8pro-3.22.6-6.18.53.img.gz --test

# on the board: arm flash mode and reboot into it
ota-flash http://10.21.50.12:8080/latest/alpine-solovox-z8pro-3.22.6-6.18.53.img.gz

# inspect or undo the arming before rebooting
ota-flash --status
ota-flash --cancel
```

### Release folders

One build, one folder. `scripts/05-ota-publish.sh` writes it under
`/srv/remotemount/OTA` on the NAS — an NFS mount from `10.21.50.10`, so releases
live on the storage host rather than in a home directory:

```
alpine-solovox-z8pro-3.22.6-6.18.53-20260924-205512/
  alpine-solovox-z8pro-3.22.6-6.18.53.img.gz       transfer artifact
  alpine-solovox-z8pro-3.22.6-6.18.53.img.sha256   sha256 of the raw image
  alpine-solovox-z8pro-3.22.6-6.18.53.img.size     size of the raw image
  alpine-solovox-z8pro-3.22.6-6.18.53.img.bmap     block map for the sparse write
  SHA256SUMS                                        the files above with hashes
latest -> <newest release>                          relative symlink
```

The folder name is the image name plus the time of the publish, so rebuilding
never overwrites an older release and an old image stays fetchable. Check a
release by hand with `sha256sum -c SHA256SUMS` inside its folder.

`deploy/ota-images.container` serves that base read-only as its HTTP root on
port 8080, so the release-pinned URL is
`http://10.21.50.12:8080/<release>/<name>.img.gz` and the dated `latest`
symlink gives the same file a stable name. `--flat` publishes straight into the
base with no release folder, `--local` skips the NAS and serves `image/` from
the build host.

Options: `-y` skip the prompt, `--full` write every byte instead of the mapped
blocks, `--no-reboot` arm without rebooting, `--test` check only. Exit codes: 1
usage/root, 2 boot configuration problem, 3 source unreachable, 4 target
problem, 6 preparation failed.

Sidecars sit next to the `.gz` and are derived from its URL: `<name>.img.sha256`
(sha256 of the raw image), `<name>.img.size` (bytes) and `<name>.img.bmap`
(`SHA256SUMS` covers the artifacts in the folder themselves).
The bmap is generated by `tools/mkbmap.py` and carries a sha256 per range. It is
not bmaptool's format: ours is `<Ranges>` with start-plus-length spans, where
`bmaptool` writes `<BlockMap>` with `start` / `start-end` spans and a
`<BmapFileChecksum>` element, so neither tool can read the other's file (feeding
ours to `bmaptool` fails outright). Measured against this writer on the same
target, bmaptool was not faster, and Alpine has no bmaptool package for the
initramfs anyway, so the bmap stays ours.

The map skips roughly 70% of the image, so flash mode writes about 1.2 GiB
instead of 4 GiB. Unmapped blocks are never written and the image is zero there,
so the target must already hold zeros outside the mapped ranges. A card that
already held a different image does not: its old bytes survive in those gaps and
the result is a disk that is not the image it claims to be, verified ranges and
all. Flash mode therefore checks the gaps *before* it writes anything, and
refuses a target that fails — a failure before the first byte, so the installed
system is still intact and the fix is to re-arm with `--full`, which writes
every byte.

### Filling the card

The image is built at a fixed 4096 MiB. On a bigger card, flash mode hands the
rest of the card to the root partition after the write has been verified — one
4-byte write to the partition table — and reboots. That order is what makes it
possible: the table can only be re-read while nothing is mounted from it, so it
has to happen in flash mode rather than from the running system. The flasher
grows the partition only; the filesystem is grown by the image itself on the
next boot, by the `growfs` service in the boot runlevel. It compares the
filesystem size (`tune2fs -l`) with its partition's size
(`/sys/class/block/*/size`) and runs `resize2fs` only when there is something to
grow — growing a mounted ext4 is supported, and the comparison makes it a no-op
on every later boot. `ota_fill=0` on the `flash` label skips the extension.

`tests/qemu-flash-mode.sh` exercises both paths for real without the board. It
boots the image's own kernel and initramfs on QEMU's `virt` machine with a disk
file as `ota_target` and an HTTP server standing in for the NAS, then checks that
a successful flash leaves the target byte-identical to the image, and that an
abort before the first byte restores the boot configuration from the backup and
leaves the rest of the target untouched.

`tests/qemu-flash-small.sh` runs the same chain against a 16 MiB fixture in
seconds, which is the one to run on every change. Its target is larger than the
fixture on purpose, so the partition extension runs for real; the reference is
patched with the same 4 bytes before the comparison, and the harness reads the
target's partition entry back to confirm what the guest wrote. `POISON=1` fills
the target with random bytes first, so the gap check has to refuse: the write
never starts, the boot configuration is restored, and the installed system stays
intact.

## USB hotplug (and why a plugged-in keyboard did nothing)

Two things have to work for a device plugged in after boot, and the image was
doing neither.

Alpine's `mdev` service populates `/dev` once at boot and then hands hotplug
duties to the kernel by writing `/sbin/mdev` into `/proc/sys/kernel/hotplug`.
That is the uevent helper, and this BSP kernel is built without
`CONFIG_UEVENT_HELPER` — the sysctl exists but stays empty — so nothing runs on
a hotplug event. A device plugged in later gets no `/dev` node, and its modalias
never reaches `modprobe`. The `mdev-hotplug` service in the boot runlevel runs
`mdev -d`, which listens on the kernel's netlink uevents and does that work
itself.

What made this look like broken hardware: the kernel *did* enumerate the device
and `usbhid` *did* bind its interfaces, so the device showed up in sysfs while
`/sys/class/input/` never gained anything and the kernel logged nothing about
HID at all. A wireless dongle cloning Apple's keyboard id (`05ac:024f`) needs
the `hid-apple` module, and module loading is exactly what was missing.

## Clock (this board has no RTC)

Out of the box the clock sat at Jan 2 1970, and every HTTPS fetch failed —
`apk` printed `certificate verify failed` followed by a misleading
`Permission denied`. The image now enables both halves of the fix:

- `swclock` in the boot runlevel: restores the timestamp saved at the last
  shutdown, so the date is plausible from early boot. It provides `clock`, so it
  occupies hwclock's slot (the two cannot both be enabled).
- `ntpd` in the default runlevel (`need net`): busybox NTP client running as
  user `ntp`, peers from `/etc/conf.d/ntpd` (`pool.ntp.org`,
  `time.cloudflare.com`).

Check on the board with `date`, `rc-service ntpd status`, `rc-status default`.

## Packages

The base rootfs is built by `02` and carries only what the *build* needs;
everything image-visible comes from the profile (see "Profiles" below). The
`headless` image is about 160 packages, roughly 90 of them `linux-firmware-*`
subpackages. The functional set:

| Area | Packages |
|---|---|
| init / base | `alpine-base`, `openrc`, `busybox` (+`-openrc`, `-mdev-openrc`, `-suid`, `-binsh`), `mdev-conf`, `alpine-conf`, `alpine-baselayout(-data)`, `alpine-keys`, `alpine-release`, `apk-tools` |
| ssh server | `dropbear`, `dropbear-openrc` (`DROPBEAR_OPTS="-s"`, host keys generated on first start) |
| ssh client | `openssh-client-default`, `openssh-client-common`, `openssh-keygen` (ssh/scp/sftp, ssh-keygen) |
| networking | `ifupdown-ng`, `bridge`, busybox `udhcpc` + `/usr/share/udhcpc/default.script` |
| filesystems | `e2fsprogs`, `dosfstools`, `cryptsetup-libs`, `device-mapper-libs` |
| kernel | `linux-lts` (Alpine 6.12.110), `mkinitfs`, `kmod`, BSP `6.18.53-ophub` on disk |
| misc | `tzdata`, `ca-certificates-bundle`, `musl`, `libcrypto3`, `linux-firmware` |
| GPU userspace (`simple-graphics` profile) | `mesa-gbm`, `mesa-egl`, `mesa-gles`, `mesa-dri-gallium`, `libgcc`, `font-dejavu` — see "Profiles" below |

`dropbear` is the ssh server; the openssh client packages are kept for the
`ssh`/`scp`/`sftp`/`ssh-keygen` CLIs (the `dropbear-dbclient`/`-ssh`/`-scp`
variants are not installed). No `dhcpcd`: busybox `udhcpc` is the DHCP client.
Installed outside the package set: `/usr/sbin/ota-flash` (network reflash, see
"OTA reflash over HTTP" below) and `/etc/solovox/image-manifest` (what this image
is: profile, packages, recipe commits — see "Profiles" below).

Login: hostname `solovox`, user `root`, password locked (`/etc/shadow` `root:*`),
key-only over ssh
via the `master` ed25519 key in `/root/.ssh/authorized_keys`; dropbear runs with
`-s` so password auth is refused outright. A tty password set with `passwd`
therefore only affects local console (tty1..tty6, `getty` on HDMI) and serial
login (uncomment the `ttyS0` line in `/etc/inittab` for UART).

## Z8Pro / X98H-clone Ethernet overlay

### What is in `board/`

The board layer lives here: `board/common/` is what every machine shares (the
Alpine release, the image naming and IDs, and the runtime files that ship in the
image), and `board/platform/<name>/` is one machine (its kernel and u-boot pins,
its devicetree, its hostname). `tools/buildcfg.py` resolves the pair into
`build/board.env` for the stage scripts, and `build.sh --board <name>` picks the
machine. The runtime trees mirror their destinations, so a file's path in
`board/common/runtime/root/` is its path on the board; compiled devicetrees go to
`build/devicetree/`, never into the tree. See [docs/board.md](board.md).

The board's PHY answers at MDIO address 0, while the vendor DTB places it at
address 1 on emac1's MDIO bus — the link stays down until that is corrected.
Source overlay:

```
amlogic-s9xxx-armbian/build-armbian/armbian-files/platform-files/allwinner/
  bootfs/dtb/allwinner/overlay/sun50i-h618-z8pro.dtbo
```

which contains a single fragment:

```
target-path = "/soc/ethernet@5030000/mdio/ethernet-phy@1";
__overlay__ { reg = <0x0>; };
```

Two things about it matter for the build:

- That file is **decompiled DTS text**, not a compiled blob (`file` calls it
  "Device Tree File (v1), ASCII text"), and dtc will not recompile it as-is:
  its bare `/fragment@0 {}` root form fails with `syntax error`. The canonical
  `/plugin/;` form is kept at `board/devicetree/sun50i-h618-z8pro-ethfix.dtso` with
  identical semantics.
- The overlay is **merged at build time** (`dtc -@` then `fdtoverlay`) into
  `/boot/dtbs/allwinner/sun50i-h618-z8pro-ethfix.dtb`, because this image boots
  with no initramfs and u-boot's `FDTOVERLAYS` support is not assumed. The
  compiled `.dtbo` still ships in `/boot/dtbs/allwinner/overlay/` for other
  boot paths.
- `03-configure-rootfs.sh` asserts the merge landed (PHY `reg = <0x00>` in the
  merged blob) and fails the build otherwise. The unpatched DTB remains
  selectable as the `bsp-nofix` label for A/B comparison.

## Build

One command does the whole thing:

```bash
bash build.sh                              # headless, the default profile
bash build.sh --profile simple-graphics    # mesa userspace + the sgc daemon
bash build.sh --clean --no-tests           # wipe the rootfs first, skip the checks
```

It runs `00` fetch/verify, the board, profile and recipe checks, `01` for the
profile's recipes (packages from `recipes/`, skipped when the profile names none),
then `02`, `03` and `04` through throwaway containers, and prints the image path,
size and sha256. Roughly two minutes on a warm cache; a recipe that compiles adds
its own build time.

The stages below are the same thing spelled out, for running or debugging one of
them on its own. Inputs are fetched and hash-verified first, then each stage runs
through a throwaway container so the host needs no extra tooling — only `docker`
and `qemu-aarch64` binfmt are required (plus `python3` for the profile/recipe
checks and anything you run by hand).

```bash
# 0. download + verify inputs (u-boot, minirootfs, ophub kernel release)
bash scripts/00-fetch-inputs.sh

# sanity check the profiles and recipes (host python3, no docker)
tests/buildcfg.sh

# 1. Alpine aarch64 rootfs: only what the build needs, native apk in a qemu chroot
docker run --rm --privileged -v "$PWD":/work debian:trixie \
  bash /work/scripts/02-bootstrap-rootfs.sh

# 2. profile packages + services, board config, BSP kernel + modules,
#    extlinux.conf, flash-mode initramfs, /etc/solovox/image-manifest
#    (python3 is needed here: tools/buildcfg.py resolves the profile)
PROFILE=headless
docker run --rm --privileged -v /dev:/dev -v "$PWD":/work debian:trixie \
  bash -c "apt-get update -qq && apt-get install -y -qq rsync e2fsprogs fdisk dosfstools device-tree-compiler cpio python3 && bash /work/scripts/03-configure-rootfs.sh --profile $PROFILE"

# 3. image: partition table, ext4, rootfs, u-boot at KiB 8, and the profile
#    assertions (needs host /dev for losetup)
docker run --rm --privileged -v /dev:/dev -v "$PWD":/work debian:trixie \
  bash -c 'apt-get update -qq && apt-get install -y -qq rsync e2fsprogs fdisk dosfstools device-tree-compiler cpio && bash /work/scripts/04-build-image.sh'

# 4. publish a release folder to the NAS: .gz, .sha256, .size, .bmap, SHA256SUMS
scripts/05-ota-publish.sh

# 5. optional: exercise flash mode end to end without the board
tests/qemu-flash-mode.sh
```

Inputs pulled once into the project tree: the minirootfs tarball, the ophub
kernel release (`kernel/6.18.53.tar.gz` unpacked to `kernel/boot`,
`kernel/dtbs`, `kernel/6.18.53/`), and `u-boot-sunxi-with-spl.bin`.

### Profiles

What an image contains is a profile, not a flag:

```
profiles/common.toml          every image: ssh, DHCP client, tzdata, dosfstools,
                              linux-lts, the boot/default service lists
profiles/headless.toml        nothing on top of common (the default profile)
profiles/simple-graphics.toml common + the mesa userspace + the sgc daemon
```

`tools/buildcfg.py` merges common with the chosen profile, subtracts what the
profile removes (`apk_remove` of `linux-lts` in `simple-graphics`), and emits the
resolved lists twice: as bash arrays into `build/profile.env` for stage 2 to
install from, and as `/etc/solovox/image-manifest` inside the image, so a
running box can say which profile it is and which commit each recipe came from.
Stage 3 reads the same `build/profile.env` back and asserts the finished image
against it: every package installed, every removal absent, every service shipped
and enabled, and the `mainline` extlinux entry present only when `linux-lts`
actually is. A profile is validated before any of that — unknown keys, a name
that does not match the file, a removal that removes nothing, a service whose
init script does not exist are all build errors (`tests/buildcfg.sh`).

Software that is not in the Alpine mirrors is a recipe; see
[docs/recipes.md](recipes.md).

| Profile package | Why |
|---|---|
| `mesa-gbm` | `libgbm.so.1` — the buffer allocator a GBM client links; the only GL library that ends up in its `NEEDED` list |
| `mesa-egl`, `mesa-gles` | `libEGL.so.1` / `libGLESv2.so.2`, dlopened at runtime, so they never appear in `NEEDED` and adding them later needs no rebuild |
| `mesa-dri-gallium` | the panfrost DRI driver — without it EGL enumerates no device and the client silently renders on the CPU |
| `libgcc` | `libgcc_s.so.1`: dynamically linked musl clients (built with the host cross toolchain) resolve their unwind symbols here. Alpine does not install it by default, and it fails late: `Error loading shared library libgcc_s.so.1` |
| `font-dejavu` | a font FILE on disk; the image has no fontconfig and no fonts, so a UI toolkit has to be handed a `.ttf` path itself |

Why the mesa userspace is a profile rather than always on: the kernel half is
already there (the BSP kernel ships panfrost and the Mali-G31 works without any
of this), so an image that never runs a GL client does not need it. And a missing
mesa does not look broken — a client that cannot get a GL context logs
`Using Software renderer` and drops to the CPU, which reads as a slow UI rather
than as a missing package.

### Bootloader

`u-boot-sunxi-with-spl.bin` (790521 bytes,
sha256 `4c6afa2ef90610318dbd4f9a201a432610eb0eb025afd06e8d7bf69c17309e96`) comes
from [ophub/u-boot `allwinner/x98h`](https://github.com/ophub/u-boot/tree/main/u-boot/allwinner/x98h)
— the same known-good binary the Armbian install uses. Its `bootcmd` is
`run distro_bootcmd` with `boot_targets=fel mmc_auto usb0 pxe dhcp`, so no
`boot.scr` or `armbianEnv.txt` is involved; extlinux.conf drives the boot.
Mainline u-boot was not built: `transpeed-8k618-t_defconfig` exists, but the
SDRAM/PMIC bring-up of this specific box is what the vendor-ish prebuilt gets
right.

## Notes and follow-ups

- Root login is key-only; `~/.ssh/id_ed25519.pub` ("master") is installed for
  root, and no password is set — set one with `passwd` over ssh if console
  login is ever wanted. Serial console (`console=ttyS0,115200`) is enabled but
  the box was built for HDMI (`console=tty0`).
- `mkinitfs` unused: the BSP kernel has MMC and ext4 built in, so no initramfs
  is generated for it. Alpine's `linux-lts` keeps its own `initramfs-lts`.
- Missing versus the Armbian install: IR keymap/wiring (`/etc/rc_keymaps`, a
  keymap loader service), the `ethfix`-equivalent RMII delay tuning if the link
  misbehaves, and eMMC installation. Each is a config change, not a kernel
  change, because the BSP kernel + DTB already enable those blocks.
- Alpine `apk upgrade` will update `linux-lts` but knows nothing about the BSP
  kernel; pin or remove `linux-lts` if a future upgrade should not touch
  `/boot`.
- eMMC install: flash the same image to eMMC (`dd` from the running system or
  the vendor tool) — `root=PARTUUID=abcd1234-01` resolves identically there.
- The 100M link is the piece to watch on first boot: if it stays down, compare
  `ip link`/`ethtool` against the Armbian install and tune the RMII delays in
  the DTB (the vendor DTB may need `allwinner,rx/tx-delay-ps` or an
  `ethfix`-style overlay port).
