# alpine-solovox-z8pro

Alpine Linux SD/eMMC image for the Solovox Z8Pro, an X98H-clone Allwinner H618
TV box.

Builds a 4 GiB raw image (u-boot + BSP kernel + Alpine 3.22 rootfs) entirely on
an x86_64 host: no root, no card reader, no cross toolchain — a qemu binfmt
chroot bootstraps the rootfs and a privileged container assembles the image.

Quick start:

```bash
bash build.sh                              # the headless image
bash build.sh --profile simple-graphics    # mesa + the sgc daemon
bash build.sh --board solovox-z8pro --profile simple-graphics
```

`build.sh` fetches and verifies the inputs, checks the board, profile and recipe
definitions, runs the build stages through throwaway containers, and leaves
`image/alpine-solovox-z8pro-*.img` behind. `bash build.sh --help` lists the
options (`--board`, `--clean`, `--no-tests`, `--skip-fetch`).

Then flash `image/*.img` to an SD card and boot it.

An image is two independent choices: a **board** (`board/platform/<name>/`, the
machine: kernel, u-boot, devicetree, hostname, and the files that ship in it) and
a **profile** (`profiles/<name>.toml`, the software: packages, services and
recipes, plus an `inherit` naming the layers it starts from). `--board` defaults
to the only platform installed. The stages themselves are `scripts/00`–`05`.

Documentation: [docs/README.md](docs/README.md) — kernel choice (why the
Allwinner BSP kernel rather than mainline), image layout, profiles and the
package set, the Z8Pro Ethernet PHY overlay, [docs/board.md](docs/board.md) for
the board layer, [docs/recipes.md](docs/recipes.md) for building software into
the image, and open items.
