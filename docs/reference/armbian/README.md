# Reference files from the Armbian install

The board ran Armbian before it ran this image, and two of its files answer
questions this repository would otherwise have to guess at. They are kept here
as reference, not as inputs: nothing in the build reads them.

- `armbianEnv.txt` — Armbian's u-boot environment. Its `verbosity`,
  `bootlogo`, `overlay_prefix` and `fdtfile` values are what the vendor image
  booted with, and they are what a suspicious DTB or kernel choice gets
  compared against. This image does not use `boot.scr` or an env file: it boots
  through `extlinux.conf`.
- `extlinux.conf` — Armbian's own extlinux menu, i.e. a working example of the
  vendor kernel cmdline on this board (`console=ttyS0,115200 console=tty0`,
  `no_console_suspend`, `fsck.repair=yes net.ifnames=0 max_loop=128`,
  `video=HDMI-A-1:1920x1080@60e`, `earlycon`). Its `FDT` line points at a Tanix
  TX6 DTB and its `INITRD` at `/uInitrd`, both Armbian-specific — the values
  that matter here are the `APPEND` ones.

Both files were at the repository root's `board/` directory as
`armbianEnv.txt.ref` and `extlinux.conf.armbian-ref`.
