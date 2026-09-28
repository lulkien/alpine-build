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
```

`build.sh` fetches and verifies the inputs, checks the profile and recipe
definitions, runs the three build stages through throwaway containers, and leaves
`image/alpine-solovox-z8pro-*.img` behind. `bash build.sh --help` lists the
options (`--clean`, `--no-tests`, `--skip-fetch`).

Then flash `image/*.img` to an SD card and boot it.

What goes into an image is a profile under `profiles/`; software that is not in
the Alpine mirrors is a recipe under `recipes/`. The stages themselves are
`scripts/00`–`04`.

Documentation: [docs/README.md](docs/README.md) — kernel choice (why the
Allwinner BSP kernel rather than mainline), image layout, profiles and the
package set, the Z8Pro Ethernet PHY overlay, [docs/recipes.md](docs/recipes.md)
for building software into the image, and open items.
