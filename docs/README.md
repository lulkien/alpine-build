# Alpine Linux for the Solovox Z8Pro (Allwinner H618 TV box)

Built on an x86_64 host; nothing runs on the board during the build. Target
board: a **Solovox Z8Pro** — an X98H clone (H618, 2–4 GB LPDDR, SD card
`mmcblk0` + 14.6 GB eMMC `mmcblk2`, 100M Ethernet behind RMII, Mali-G31 via
panfrost, NEC IR receiver). Vendor artifacts keep the `x98h` name in their
filenames (`sun50i-h618-x98h.dtb`, `ophub/u-boot allwinner/x98h`) because that
is what upstream calls this hardware family.

## Result

```
image/alpine-solovox-z8pro-3.22.6-6.18.53.img        1536 MiB raw SD/eMMC image
image/alpine-solovox-z8pro-3.22.6-6.18.53.img.sha256 its digest, written beside the image by stage 04
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
LABEL flash        # flash mode: RAM initramfs, writes an image, no OS
  LINUX /boot/vmlinuz-6.18.53-ophub
  INITRD /boot/ram-initramfs.gz
LABEL grow         # grow mode: the same initramfs, resizes the rootfs cold
  LINUX /boot/vmlinuz-6.18.53-ophub
  INITRD /boot/ram-initramfs.gz
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

- `/usr/sbin/ota-flash` (source `board/common/runtime/root/usr/sbin/ota-flash`)
  arms the next boot.
- `/boot/ram-initramfs.gz` is the RAM initramfs both boot modes run from; the
  `flash` and `grow` extlinux labels are what select the mode, with
  `ram_mode=flash` and `ram_mode=grow`.

`ota-flash <url>` writes nothing. It checks the URL and its sidecars, bakes the
image URL, its sha256, size, bmap and the target disk into the `flash` label,
saves `/boot/extlinux/extlinux.conf.bak`, sets `DEFAULT flash` and reboots. The
next boot runs the initramfs instead of the OS: kernel and userspace come from
RAM, no rootfs is mounted, and the only thing touching the card is `dd`. That is
the point of the design. Writing the boot medium from the running OS put ext4
writeback inside the image being written, and the flasher's own executables were
read back from the blocks `dd` was overwriting.

Flash mode sequence (`board/common/runtime/initramfs/init`, which dispatches between
the two modes): read the `ota_*` parameters from the kernel command line, wait for the
target device, bring `eth0` up and take a DHCP lease, check the published sidecars
against what was armed, fetch the bmap, put the boot configuration back when the target
is not the disk holding it, prove the target is zero where the image is, stream the
`.gz` through gzip writing only the mapped ranges, verify every range by reading it
back, check the u-boot magic at KiB 8, extend the root partition to fill the card, make
the kernel re-read the table it just wrote, flush the cache the write left behind, save
the attempt's log where the installed OS will find it, reboot. The freshly written
image has `DEFAULT bsp`, so the box comes up in the OS.

Eight details of that sequence carry the design:

- **The device wait.** devtmpfs is mounted early, but the mmc controllers probe
  asynchronously and the eMMC runs 8-bit tuning before registering, so its node
  appears well after the SD's. Reading `[ -b $OTA_TARGET ]` too early says "the
  target does not exist" and refuses for no reason — which is how the first two
  attempts at an eMMC flash failed, three seconds in, before any network was tried.
  The init waits up to 20 s (logging how long it took) and logs the block-device
  inventory at entry either way.
- **DHCP only.** The flasher waits (bounded) for carrier and then retries DHCP four
  times. It takes no static address on the command line: this LAN assigns by DHCP
  only — a static address is not routed here and snooping/port security refuses it —
  so a handed-over address would fail at the metadata fetch and look like a bad
  image.
- **The two flags the RAM labels must carry.** `clk_ignore_unused` and
  `pm_genpd_ignore_unused` are not decoration: without them the kernel disables the
  clocks and power domains it believes nothing is using, and the eMMC controller's are
  among them (console evidence: `clk: Disabling unused clocks`, `PM: genpd: Disabling
  unused power domains`, and a `sync_state() pending` complaint from the power
  controller). The `bsp` and `debug` labels always had them; the `flash` and `grow`
  labels did not, and the build now fails if either loses them again.
- **Sustained eMMC writes from the RAM init stall the CPU — and still finish.** These
  writes block a CPU for seconds at a time, so the RCU stall detector prints its stack
  dumps repeatedly and the console looks dead. It is not dead: `resize2fs` on the eMMC
  completed (392960 → 3816704 blocks) after several minutes of exactly that, with small
  writes (every log milestone) landing normally throughout and raw sequential writes from
  the OS running at 17 MB/s with no stalls at all. **Do not power-cycle it while it is
  grinding**: the run is not lost, the resize is simply slow, and a reset in the middle
  costs the whole attempt.
- **The partition node the write created.** On a blank target the kernel never had a
  partition table to read, so it made no partition node at all: `$OTA_ROOTPART` does not
  exist on this boot, and the attempt's record cannot be written where the installed OS
  looks for it. The write creates that table, so the init makes the kernel re-read it
  (`blockdev --rereadpt`, with nothing mounted on the target — asserted just before the
  write) and waits up to 10 s for devtmpfs to publish the node.
- **The write line reports the write, not the plan.** Progress comes from the target's
  own write counter, and the last line used to print the planned total as "written"
  whatever had happened — so a failed write announced `100%` and then, two lines later,
  that it had failed. The line now claims completion only when the writer exited zero;
  otherwise it reports what the counter gained before the stream ended,
  `[write] FAILED: 12/1100 MiB written before the stream ended`.
- **A target on another disk.** `ota-flash` derives its target from the disk holding
  `/` and will not take another; a hand-armed label may (`ota_target=/dev/mmcblk1`,
  flashing the eMMC from the SD). When the target is not the disk the boot
  configuration lives on, the init puts that configuration back to the installed
  system *before* the slow part — otherwise it survives the flash still armed and
  the machine re-enters flash mode forever. A target that *is* the boot disk needs
  none of that, and the refusal path already restores it.
- **The record.** Every log line goes to a RAM log carrying the attempt's own uptime
  (there is no RTC in RAM), and every exit — success, refusal, give-up — appends it
  to `/var/log/flash-attempt.log` on the partition named by `ota_rootpart`. A failure
  that only ever appeared on the HDMI console is readable afterwards from the
  installed system; on success the file lands in the freshly written image's own
  filesystem. That partition is usually the one this boot just wrote, and its blocks are
  then the buffer cache's pre-write copy of the medium, so the mount is retried once
  after `blockdev --flushbufs`; a mount that still fails says so, error string and all,
  instead of silently dropping the record — a successful flash that left no log is
  exactly what that silence bought. A partition node that does not exist on this boot is
  reported the same way, and the record stays on the console only.

Recovery, and the two outcomes are different:

- A failure **before the first byte is written** — no DHCP lease, a target device
  that never appears, sidecar missing, bmap inconsistent with the image, or a target
  that is not zero outside the mapped ranges — restores `extlinux.conf.bak`, syncs
  and reboots: the installed system starts as if nothing had happened. The flasher
  also refuses to start writing while anything on the target is mounted.
  `ota-flash --cancel` undoes the arming before that reboot as well.
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

The map holds one range per run of non-zero blocks, so flash mode writes what the
image holds and skips the rest: about 1.1 GiB of the headless image's 1.5 GiB, in
366 ranges. Unmapped blocks are never written and the image is zero there, so the
target must already hold zeros outside the mapped ranges. A card that
already held a different image does not: its old bytes survive in those gaps and
the result is a disk that is not the image it claims to be, verified ranges and
all. Flash mode therefore checks the gaps *before* it writes anything, and
refuses a target that fails — a failure before the first byte, so the installed
system is still intact and the fix is to re-arm with `--full`, which writes
every byte.

### Filling the card

The image is built to hold the rootfs with headroom (`image_size_mb` in
`board/common/board.toml`, 1536 MiB today, with stage 04 refusing a rootfs that
does not fit with 256 MiB to spare). Its size is a cost rather than a round
number, and it is the flasher that pays: blocks the image does not map have to be
read and hashed to prove they are zero before a sparse write may start, and a
full write writes them. On a bigger card, everything the disk has is handed over,
by whichever mode can see the disk with nothing mounted from it:

- **the partition.** Flash mode extends it right after the write has been verified
  (one 4-byte write to the partition table), and grow mode does the same for a
  medium that was installed as a plain image copy — where the filesystem already
  fills its partition, so nothing running from that medium could extend it. Grow
  mode can finish the job in one boot where flash mode hands it to the OS: it
  writes the table *and* re-reads it (`blockdev --rereadpt`; nothing is mounted),
  so the extension and the resize happen together.
- **the filesystem**, grown by grow mode with `e2fsck -f` and then `resize2fs` on
  the unmounted partition.

The `growfs` service in the default runlevel decides and arms that boot, for either
reason: the filesystem smaller than its partition, or the partition smaller than
the disk. It compares `tune2fs -l` with its partition's size
(`/sys/class/block/*/size`) and the disk's own, stopping at the next partition's
start so a later partition is never grown over, and when there is room it saves
`/boot/extlinux/extlinux.conf.bak`, points `DEFAULT` at the `grow` label, counts
the attempt and reboots. Grow mode restores that backup before it reboots, so the
box comes back to the installed system either way, and `/var/log/grow.log` on the
card records what happened. It gives up after two attempts
(`/var/lib/growfs/attempts` — remove that file to retry), so a resize that cannot
finish does not loop.

The service used to do the resize itself, with `resize2fs` on the mounted root.
That is the online path, and it commits through the kernel's
`EXT4_IOC_RESIZE_FS`: on this board the box stopped answering within ~15 s of
starting it, came back in a watchdog reset loop, and left the filesystem
unchanged and needing journal replay. The same resize with nothing mounted took
seconds on the same card. That is why the two halves are separate boots instead
of one boot and one call — and why the equivalent online path is worth refusing
by default until it has been proven on the machine in question.

`ota_fill=0` on the `flash` label skips the partition extension, and then there is
nothing for grow mode to do.

`tests/qemu-flash-mode.sh` exercises both paths for real without the board. It
boots the image's own kernel and initramfs on QEMU's `virt` machine with a disk
file as `ota_target` and an HTTP server standing in for the NAS, and runs three
cases. 1: a successful flash leaves the boot area byte-identical to the image and
the whole target differing from it only by the record the guest left (well under a
MiB), and that record is there. 2: an abort before the first byte restores the boot
configuration from the backup, leaves the rest of the target untouched, and leaves
a record of its own. 3: a stream that dies mid-write reports the write as failed
and never claims 100%. The guest fetches the compressed artifact and the sidecars,
as the board does — a bare `.img` dies in the guest's gzip — and the harness makes
that set from the current image when it is missing or older. `BOOTDIR=` points it
at a candidate initramfs, so one can be tried without rebuilding the image that
carries it. The container body lives in `tests/qemu-flash-mode-body.sh`: as one
single-quoted shell argument it silently lost every line containing an apostrophe,
and `bash -n` cannot see that, because the quote count still balances.

`tests/qemu-flash-other-target.sh` covers the two-disk shape of the same mode: the
boot configuration on one virtio disk (armed, its backup beside it) and an all-zero
target on the other — flashing the eMMC from the SD, the case `ota-flash` refuses by
design and a hand-armed label allows. It checks that the boot disk is back on the
installed system before the slow part and that the target still matches the image.

`tests/qemu-disk-probe.sh` is a debug helper rather than a test: it boots a minimal
initramfs with one virtio disk and answers whether sparse writes from a pipe and
from a file land on the device, printing the device from inside the guest and
dumping the host-side file afterwards.

`tests/qemu-grow-mode.sh` covers grow mode without the board, in the two shapes it
has to handle: `fs`, where only the filesystem is small, and `dd`, where the
partition is what has to grow first. Both boot the RAM initramfs with
`ram_mode=grow` and check that the guest ended with the filesystem filling
everything the disk allows, restored the boot configuration from
`extlinux.conf.bak`, cleared the arming counter, and wrote `/var/log/grow.log`; the
`dd` case also asserts the partition table the guest wrote and re-read.

`tests/qemu-flash-small.sh` runs the same chain against a 16 MiB fixture in
seconds, which is the one to run on every change. It and the other-target test
read a prepared `/tmp/otasrv` fixture — `test.img` with its `.gz`, `.sha256` and
`.size`, a small hand-made image — and build the bmap for their own copy of it.
Its target is larger than the fixture on purpose, so the partition extension runs
for real; the reference is patched with the same 4 bytes before the comparison,
and the harness reads the target's partition entry back to confirm what the guest
wrote. `POISON=1` fills the target with random bytes first, so the gap check has
to refuse: the write never starts, the boot configuration is restored, and the
installed system stays intact.

## Growing the root filesystem (cold, from RAM)

A medium installed as a plain image copy carries the image's own partition table: p1
is image-sized and the filesystem already fills it, so nothing on a running system can
grow it — the table cannot be re-read while the rootfs on it is mounted, and resizing
that rootfs online wedges this board (unreachable within ~15 s, then a watchdog reset
loop, the filesystem unchanged and needing journal replay). Both are avoided by doing
the work with nothing mounted from the card, in the second mode of the RAM initramfs:

    growfs service (default runlevel, on the installed OS)
        compares the filesystem with its partition, and the partition with the disk;
        when there is room it saves extlinux.conf, points DEFAULT at `grow`, counts
        the attempt, and reboots
    boot with the `grow` label (ram_mode=grow, no OS running)
        finds the root filesystem by its ext4 label, gives the partition the rest of
        the disk it can use, e2fsck -f, resize2fs, records what happened, restores
        the boot configuration, clears the counter, reboots
    the OS comes up with the grown filesystem

Three properties are deliberate, each of them because of a failure seen on hardware:

- **It logs as it goes, into the filesystem it is growing.** A panic skips every
  handler the script has, and this mode runs on a console nobody can query from
  anywhere: the first run of the grow mode on an eMMC died before its first log line
  and left no record at all, which is why it could not be explained afterwards. Each
  milestone is now appended to the target's `/var/log/grow.log` — mount, write, sync,
  unmount, because e2fsck and resize2fs both need the filesystem unmounted and a
  mount held across them would make this the second writer.
- **It disarms the boot configuration before the slow part.** Same reason: a
  configuration still pointing at `grow` reboots into the same panic forever, and the
  machine can then never reach its OS. The service re-arms whenever there is still
  room, so disarming early costs nothing and every failure lands back in the installed
  system.
- **It carries `clk_ignore_unused pm_genpd_ignore_unused`** like the flash label, so the
  early boot cannot disable the eMMC controller's clock and power domain (see the flash
  section). The resize still makes the console look dead for minutes even with them in
  place: budget minutes, and do not interrupt it. It completes — the partition extension, the
  `e2fsck` and the `resize2fs` all finished on this eMMC, 1.4 GiB → 14.3 GiB — so the
  right move at that point is patience, not a power cycle.
- **It waits for the disk to be there.** devtmpfs is mounted in the first seconds of
  this mode's life, but the mmc controllers are still probing: at t+3s
  `/sys/class/block` can hold no partition node at all, so looking once reports "no
  ext4 filesystem labelled rootfs" on a disk that is sitting right there. It waits
  (bounded, 20 s) for a partition node and prints the inventory when it gives up. The
  same premature look refused a flash three seconds in, before any network, and was
  fixed with a wait there first.
- **A failing resize is bounded.** The counter keeps the service from arming more than
  `MAX_ATTEMPTS` times, so a resize that cannot finish does not become a boot loop.

To read the record after a medium that loops: boot the *other* medium, mount the quiet
one, read `/var/log/grow.log`. `debugfs -R "cat /var/log/grow.log" /dev/<part>` works
even when the filesystem is unclean, and replays no journal.

Flash mode follows the same rule for the same reason: it disarms the boot
configuration immediately before the write. Every refusal has already happened by
then, so writing the boot partition cannot turn a refusal into a write — and it
rewrites a block the image already fills, so the write still puts down exactly the
image. The record deliberately stays out of that step: a fresh log block would land
in a gap no sparse write touches. It goes out at each exit instead — on a successful
flash, into the filesystem that was just written, which is the one difference the
test allows between the target and the image.

### Provisioning a spare medium from the OS

Writing a *boot* medium has to happen in RAM, for the reasons above. A medium the
running system is not using has no such problem, and the OS does it faster and more
predictably: a full 1536 MiB image to the eMMC took about 90 s there (17 MB/s) against
roughly 3 MB/s with RCU stalls from the RAM init's kernel on the same device,
byte-for-byte verified afterwards:

```
wget -O - <release>.img.gz | gzip -dc | dd of=/dev/mmcblk1 bs=8M oflag=direct
dd if=/dev/mmcblk1 bs=1M | head -c 1610612736 | sha256sum   # against <release>.img.sha256
```

Then give p1 the rest of the medium (the four-byte count at MBR offset 458) and grow
the filesystem offline with `e2fsck -f` + `resize2fs`, rather than booting the spare
and letting the grow mode try — which is the path that had no record when it failed.

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
`build/board.env` for the stage scripts, and `build.py --board <name>` picks the
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
python3 build.py                           # headless, the default profile
python3 build.py --profile simple-graphics # mesa userspace + the sgc daemon
python3 build.py --clean --no-tests        # wipe the rootfs first, skip the checks
```

`build.py` is the entry point: it resolves the board and the profile by importing
`tools/buildcfg.py` (so the host needs python3 ≥ 3.11), then runs the stages.

It runs `00` fetch/verify, the board, profile and recipe checks, `01` for the
profile's recipes (packages from `recipes/`, skipped when the profile names none),
then `02`, `03` and `04` through throwaway containers, and prints the image path,
size and sha256. Roughly two minutes on a warm cache; a recipe that compiles adds
its own build time.

The stages below are the same thing spelled out, for running or debugging one of
them on its own. Inputs are fetched and hash-verified first, then each stage runs
through a throwaway container so the host needs no extra tooling — `docker` and
`qemu-aarch64` binfmt, plus python3 ≥ 3.11 for `build.py` and the profile/recipe
checks.

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

What an image contains is a profile, not a flag. A profile names the layers it
inherits and then states its difference from them:

```
profiles/essential.toml       every image: ssh, DHCP client, tzdata, dosfstools,
                              linux-lts, the boot/default service lists
profiles/headless.toml        inherit = "essential", nothing of its own
                              (the default profile)
profiles/simple-graphics.toml inherit = "essential", plus the mesa userspace and
                              the sgc daemon
```

`inherit` takes one layer or an array, and the layers are merged left to right:

```toml
inherit = "essential"
inherit = ["essential", "graphics"]
```

Each layer's own `inherit` is resolved first, then the layers are applied in that
one order — the deepest parent first, each parent's inheritance before the layer
itself, the profile last:

```
kept = []                                    what the image gets
for layer in that order:
    kept += layer.apk_add        # already there: no change
    kept -= layer.apk_remove     # a later add puts it back, at the end
```

So the layer that touched a name last decides. A profile can remove what the layer
it inherits added (that is how `simple-graphics` drops `linux-lts`), and a layer
further down can put it back — an earlier removal is not a veto. The emitted
`apk_remove` carries only what ends up removed, because that list is what stage 03
`apk del`s and stage 04 asserts absent. Services resolve the same way.
`tools/buildcfg.py` refuses a loop (`a` inheriting `b` inheriting `a`), a layer
that does not exist, a layer name with `.toml` or a path in it, a removal that
names nothing any layer asks for, and a merged package set that ends up empty.

The resolved lists are emitted twice: as bash arrays into `build/profile.env` for
stage 03 to install from, and as `/etc/solovox/image-manifest` inside the image
(which records the profile, the layers it inherited, and the commit each recipe
came from), so a running box can say what it is. Stage 04 reads the same
`build/profile.env` back and asserts the finished image against it: every package
installed, every removal absent, every service shipped and enabled, and the
`mainline` extlinux entry present only when `linux-lts` actually is. A profile is
validated before any of that — unknown keys, a name that does not match the file,
a removal that removes nothing, a service whose init script does not exist are all
build errors (`tests/buildcfg.sh`).

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
  the vendor tool) — `root=PARTUUID=abcd1234-01` resolves identically there. Note
  what a plain image copy does *not* do: it carries the image's own partition
  table, so a 14.6 GiB chip starts with an image-sized partition (1535 MiB, `df`
  showing 1.5 G). That resolves itself on the first boot: `growfs` sees the
  partition smaller than the disk, arms one grow boot, and grow mode extends the
  partition and the filesystem together — no hand-editing, no second boot. Two
  media flashed from one image share `root=PARTUUID=abcd1234-01`, though, so blank
  the one you are not booting: zero its first 16 MiB, MBR and u-boot and ext4
  superblock alike.
- The 100M link is the piece to watch on first boot: if it stays down, compare
  `ip link`/`ethtool` against the Armbian install and tune the RMII delays in
  the DTB (the vendor DTB may need `allwinner,rx/tx-delay-ps` or an
  `ethfix`-style overlay port).
