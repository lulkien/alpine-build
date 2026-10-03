# The board layer

A **profile** decides what software an image contains. A **board** decides what
machine it is: which kernel and u-boot to assemble it from, which devicetree it
boots, what it calls itself, and which files ship in it that are not packages.

Both are data, resolved by the same tool, and both are common-plus-delta:

```
board/common/board.toml                    what every platform shares
board/platform/<name>/board.toml           one machine (name = the directory)
profiles/essential.toml + a profile that inherits it  the software half
```

`tools/buildcfg.py board show <name> --emit env > build/board.env` resolves the
pair into bash values, which the stage scripts source, and
`--emit manifest` writes the board lines of `/etc/solovox/image-manifest` (the
kernel and u-boot pins, which nothing else records). `build.py` takes
`--board <name>`, defaulting to the only platform installed:

```
python3 build.py --board solovox-z8pro --profile simple-graphics
```

## What is in a platform directory

```
board/platform/solovox-z8pro/
  board.toml                 the machine (below)
  devicetree/
    sun50i-h618-z8pro-ethfix.dtso   ours: compiled and merged in the build
    vendor/                          carried from the vendor, never built here
  runtime/                          optional, same shape as board/common/runtime
```

Every file the build *compiles* is ours and lives as a `.dtso` source; the
compiled `.dtbo` and the merged `.dtb` are build outputs under `build/devicetree/`
(ignored, wiped by a clean), so no generated devicetree is ever committed. A
vendor tree is kept under `vendor/` for provenance: the vendor DTB the kernel
ships with, and the vendor's own overlay text in the bare `/fragment@0` form
`dtc` refuses — the file our canonical overlay was rewritten from.

## What is in board/common

```
board/common/board.toml
board/common/runtime/root/         files copied into the image rootfs
board/common/runtime/initramfs/    files copied into the RAM initramfs, whose two
                                    boot modes (flash, grow) run from it
```

The runtime trees are conventions rather than keys, and they **mirror the
destination**:

```
runtime/root/usr/sbin/ota-flash                -> /usr/sbin/ota-flash
runtime/root/etc/init.d/growfs                 -> /etc/init.d/growfs
runtime/root/etc/runlevels/default/growfs      -> a real symlink, enabled at boot
runtime/root/root/.ssh/authorized_keys         -> /root/.ssh/authorized_keys
runtime/root/usr/lib/solovox/mbr.sh            -> /usr/lib/solovox/mbr.sh, and
                                                  copied into the RAM initramfs as
                                                  /bin/mbr.sh (the modes write the
                                                  table, this side only reads it)
runtime/initramfs/init                         -> /init in the RAM initramfs
runtime/initramfs/bin/bmap-write               -> /bin/bmap-write there
runtime/initramfs/bin/grow-rootfs              -> /bin/grow-rootfs there, and the
                                                  script /init execs for grow mode
```

So nothing writes a destination down: stage 03 copies the trees with modes and
symlinks intact, and stage 04 asserts every file in them exists at the same path
in the finished image. This is also why config and executables are as separate as
they are on the running system: a script sits where the init system looks, the
SSH key under `/root/.ssh`.

Two things a tree cannot express, both explicit:

- **Modes that git does not track.** Git records only the executable bit, so
  `private_files = ["root/.ssh/authorized_keys"]` names the files that must end up
  `0600` and root-owned (a key sshd or dropbear refuses otherwise looks like a
  wrong key, not a wrong mode).
- **Ownership.** The build copies files as the receiving user; 03 chowns the trees
  to root, because that is what the board has.

## Keys

| Key | Required | Meaning |
|---|---|---|
| `hostname` | yes | the image's hostname |
| `kernel` | yes | kernel asset name (the ophub `<version>` directory) |
| `kernel_release` | yes | the version inside the image (`vmlinuz-<kernel_release>`, `/lib/modules/<kernel_release>`) |
| `kernel_url`, `kernel_sha256` | yes | what stage 00 downloads and verifies |
| `uboot_url`, `uboot_file`, `uboot_sha256` | yes | u-boot for this SoC, and the name it is saved as |
| `dtb` | yes | the vendor devicetree from the kernel tree, installed to `/boot/dtbs/allwinner/` |
| `boot_dtb` | yes | the merged tree the image boots |
| `overlays` | no | our `.dtso` sources, merged into `boot_dtb` in order |
| `merge_check_node`, `merge_check_text` | no | the assertion that the merge landed: that node must contain that text in the decompiled result |
| `alpine_branch`, `alpine_release`, `alpine_mirror`, `alpine_minirootfs_sha256` | yes (common) | the rootfs to bootstrap |
| `image_prefix`, `image_size_mb` | yes (common) | the image is `<image_prefix>-<platform>-<alpine_release>-<kernel>`; the size is MiB the image holds, i.e. the rootfs plus headroom, asserted in stage 04 |
| `disk_id`, `root_partuuid`, `rootfs_uuid` | yes (common) | MBR id, kernel `root=`, filesystem UUID |
| `timezone` | no | the image's clock |
| `private_files` | no | runtime files that must be `0600` |

Validation refuses unknown keys, a missing required key, an `overlays` entry that
is not a `.dtso` or not in the platform directory, a `private_files` entry no
runtime tree has, a non-`https://` URL, a checksum that is not 64 hex characters,
a `dtb` that is not a `.dtb`, and an `image_size_mb` that is not a positive
integer. Run `tools/buildcfg.py board validate` — the build does, before any
container starts.

## Adding a platform

1. `mkdir board/platform/<name>` with a `board.toml` setting the required keys.
2. Add `devicetree/` (your `.dtso` sources, and any vendor files under `vendor/`).
3. Add a profile for the software, or reuse one.

Nothing in `scripts/` changes: the stages read the board layer, and the two names
that identify the build (the machine and the profile) are arguments.
