# Working in this repository

Alpine SD/eMMC images for Allwinner H616/H618 TV boxes, built entirely on an
x86_64 host: no root on the host, no card reader, no cross toolchain. The worked
case is the Solovox Z8Pro (an X98H-clone H618 box). `docs/README.md` is the long
form — this file is the part an agent needs before touching anything.

## One command

```bash
python3 build.py                           # headless image, the default profile
python3 build.py --profile simple-graphics # mesa userspace + the sgc daemon
python3 build.py --board solovox-z8pro --profile simple-graphics
python3 build.py --clean --no-tests        # wipe rootfs/, skip the offline checks
```

Needs `docker` (daemon reachable), `qemu-aarch64` binfmt registered with the `F`
flag (`/proc/sys/fs/binfmt_misc/qemu-aarch64`), python3 ≥ 3.11 (`tomllib`), and
pytest for the config suite (`sudo apt install python3-pytest`, or `--no-tests`).
Output: `image/alpine-<board>-<release>-<kernel>[-<profile>].img`.

## Shape of the thing

```
build.py                     the entry point: CLI, stage order, state
scripts/00-05                the stages, bash, run inside throwaway containers
 00 fetch inputs (host)      01 recipes -> .apk   02 bootstrap   03 configure
 04 assemble + assert        05 publish a release
board/common + platform/*/   the machine: kernel/u-boot pins, devicetree, runtime files
profiles/*.toml              what an image contains: packages, services, recipes
recipes/*.toml               software outside the Alpine mirrors, pinned to a commit
tools/buildcfg.py            reads all three kinds of TOML, resolves and validates them
tools/mkapk.sh, mkbmap.py    package a DESTDIR tree; write the bmap sidecar
tests/                       see below
docs/                        all prose; the root README stays a pointer
```

The rule that explains the shape: **data is TOML, resolved by `tools/buildcfg.py`;
the stages are shell and never parse TOML.** `build.py` imports the resolver and
reads the board and profile as dicts; the stages source the emitted `build/board.env`
and `build/profile.env`. A profile may `inherit` layers (that is how
`simple-graphics` drops `linux-lts` it never wanted); `profile list` deliberately
does not offer the `essential` layer.

Boundaries that are deliberate, not accidents — the stages stay shell because
their code *is* the command lines (`mount --rbind`, `chroot apk`, `fdtoverlay`,
`losetup`, `mkfs.ext4`, `dd`), and two of the three stage containers have no
python3 at all. Do not "modernise" them into python; the payoff was in the
orchestration and the resolver, which are already python.

## Build state, and why it wipes

- `rootfs/` carries the kernel, devicetree and packages of the board+profile that
  made it. Switching either one wipes it (`build/rootfs.state` records the pair) —
  otherwise a `simple-graphics` build followed by a headless one ships mesa in the
  headless image.
- `rootfs/`, `build/` and `packages/` end up **root-owned** (containers write
  them), so the host cannot `rm -rf` them. Use `python3 build.py --clean` (which
  does it in a container), or the same thing by hand:
  `docker run --rm -v "$PWD":/work debian:trixie rm -rf /work/rootfs`. The host
  deliberately writes nothing into `build/`.
- A rebuilt image does **not** hash the same as the last one (timestamps, rsync
  order). A differing sha256 is not a regression; compare the manifest, the
  package list and the boot behaviour instead.

## Tests

```bash
python3 -m pytest tests/test_buildcfg.py -q   # the resolver, in process (62)
bash tests/buildcfg-env.sh                    # the emitted env is valid bash (12)
bash tests/qemu-flash-mode.sh                 # flash mode end to end, docker, no root
bash tests/recipe-build.sh                    # the whole recipe path, offline
```

The QEMU and recipe tests need docker, the binfmt and the inputs stage 00 fetches
(the minirootfs tarball); `qemu-flash-mode.sh` takes an image path and otherwise
picks the newest in `image/`. `python3 build.py` runs the first two as its
profiles-and-recipes stage, so a red suite stops the build before any container
starts.

The suite is **two halves on purpose**: python cannot source a shell fragment, so
"`--emit env` prints valid bash and a value containing spaces survives `eval`"
stays in `tests/buildcfg-env.sh`. Everything else is pytest, calling the resolver
directly — one test per refusal, `--emit json` parsed rather than grepped.

When you port or add a check, keep the ledger honest: the old suite's 104
assertions were accounted for group by group (41 fixture files, 36 rejection
cases), and a test that had to be weakened to be portable belongs in the bash
half instead. Never delete an assertion to make a suite pass.

## Conventions

- **Commits**: conventional-commit subject (`feat(build): …`, `fix(image): …`) and
  a prose body that says *why*, with the measured facts. Commit only when asked,
  commit locally, and **never `git push`**.
- **Branches**: feature branches, one objective at a time; docs and code for one
  change land in the same commit when the docs describe that code.
- **Docs**: all prose under `docs/` (the root README stays minimal and links in).
  Write the current design as the first design — no rejected-alternative or
  decision-change history. Mermaid blocks are fenced with ```` ```mermaid ```` and
  use `<br/>`, never `\n`, inside labels: these files are read on GitHub.
- **Style**: comments explain the non-obvious *why* and the measured numbers
  ("1536 MiB, 256 MiB headroom", "measured now: 1100 MiB in 366 ranges"), not
  what the next line does. Match the surrounding prose.

## Traps that have bitten here

- **A piped python script precedes its children.** bash flushes every line; a
  python wrapper block-buffers `print()` when stdout is not a tty, so with
  `| tee` the stage banners appear *after* the container output they announce.
  `build.py` calls `sys.stdout.reconfigure(line_buffering=True)` for this reason.
- **A stage that resolves its own config needs it in the environment.** Stage 00
  calls `buildcfg.py board show ${BOARD:+$BOARD}`; passing the board as the
  wrapper's own argument leaves `BOARD` unset there, and with two platforms
  installed the build dies with `give a platform name`.
- **Never edit a stage script while a container is running it.** bash reads the
  file incrementally; changing it mid-run can execute shifted text. Wait for the
  build to stop.
- **No `shellcheck` on this host.** `bash -n` catches syntax only — it cannot see
  a shell body whose quotes still balance but whose meaning changed (see the
  `qemu-flash-mode-body.sh` note in `docs/README.md`).
- **The board is not a test substitute.** Flash mode and grow mode are exercised
  in QEMU against the built image; the box at `10.21.50.53` is for hardware-only
  questions and needs care (no serial console, 16 s watchdog, no RTC).

## Where the detail lives

`docs/README.md` (the whole design: image layout, boot debugging, flash mode,
cold resize, packaging) · `docs/board.md` (the board layer) · `docs/recipes.md`
(the recipe format and how to add one) · `docs/reference/armbian/` (upstream
references) · `.hermes/plans/` (gitignored working notes).
