#!/usr/bin/env python3
"""One command for the whole image build.

    python3 build.py                        # the headless image, everything
    python3 build.py --profile simple-graphics
    python3 build.py --board solovox-z8pro  # which machine (default: the only one)
    python3 build.py --clean                # wipe the rootfs first
    python3 build.py --no-tests --skip-fetch

It runs the stages in order and stops at the first failure, so a partially
built image is never left behind: 00 fetch/verify inputs, the board, profile and
recipe checks, 01 build the profile's recipes into packages (skipped when the
profile names none), 02 bootstrap the rootfs, 03 configure it for the board and
the profile, 04 assemble the image and assert it against both. 05 publishes a
release afterwards. The numbers are the order they run in.

The rootfs directory is reused between runs, and packages a previous profile
installed are not removed by a later one, so switching either the board or the
profile wipes it: a `simple-graphics` build followed by a `headless` build would
otherwise ship mesa userspace in the headless image, and a second board inherits
the first one's kernel and devicetree.

The board and the profile are data: board/common/board.toml plus
board/platform/<name>/board.toml, and profiles/essential.toml plus
profiles/<name>.toml, resolved by tools/buildcfg.py *in this process* - the
values are read as dicts, not parsed back out of the text the tool prints for
the stage containers. build/board.env is still written by stage 03 for the
containers to source.

The stages themselves are shell (scripts/00-05): they mount, chroot, apk,
losetup and dd, and their code is the command lines. This file orders them.

Requirements: docker (with the daemon reachable), qemu-aarch64 binfmt for the
chroot stage, and python3 >= 3.11 on the host (tomllib). Roughly two minutes end
to end on a warm cache.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

ROOT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT_DIR / "tools"))

import buildcfg  # noqa: E402  (needs the path entry above)

# installed in every stage container; 03 additionally needs python3
APT_PACKAGES = "rsync e2fsprogs fdisk dosfstools device-tree-compiler cpio"
ALPINE_IMAGE = "debian:trixie"


def die(message: str) -> NoReturn:
    print(f"build: {message}", file=sys.stderr)
    raise SystemExit(1)


def stage(name: str) -> None:
    print(f"\n=== {name}")


def run(argv: list[str], **kwargs) -> None:
    """Run a command with the terminal inherited. A failure ends the build."""
    subprocess.run(argv, check=True, **kwargs)


def capture(argv: list[str]) -> str:
    """Run a command, return its stdout, its stderr still on the terminal.

    The pipeline this replaces (`bash tests/buildcfg.sh | tail -1`) relied on
    `set -o pipefail` to fail the build when the checks failed; the return code
    is checked here instead, and only the last line is printed as build.sh did.
    """
    proc = subprocess.run(argv, stdout=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)
    return proc.stdout


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--profile", default=os.environ.get("PROFILE", "headless"),
                        help="which profile decides the image contents "
                             "(default: headless)")
    parser.add_argument("--board", default=os.environ.get("BOARD", ""),
                        help="which platform to build for "
                             "(default: the only one installed)")
    parser.add_argument("--clean", action="store_true",
                        help="wipe rootfs/ instead of reusing it")
    parser.add_argument("--no-tests", dest="run_tests", action="store_false",
                        help="skip the offline profile and recipe checks")
    parser.add_argument("--skip-fetch", dest="fetch", action="store_false",
                        help="do not fetch or verify the build inputs")
    args = parser.parse_args(argv)

    if not shutil.which("docker"):
        die("docker is not installed")
    if subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL,
                      stderr=subprocess.DEVNULL).returncode != 0:
        die("the docker daemon is not reachable")

    # --- the machine --------------------------------------------------------
    # With one platform installed there is nothing to choose; --board is how you
    # pick among several. A resolution failure is the tool's own message, which
    # already names the file and the offending key.
    board = args.board
    if not board:
        platforms = buildcfg.available_platforms()
        if not platforms:
            die(f"no platform in {buildcfg.BOARDS_DIR}/platform (see docs/README.md)")
        board = platforms[0]
    try:
        board_spec = buildcfg.load_board(board)
    except buildcfg.ConfigError as exc:
        die(f"buildcfg: {exc}")
    # One line of progress here; stage 03 writes build/board.env, which the
    # containers source (build/ is root-owned once a container has written, so
    # nothing on the host writes there).
    print(f"board   : {board} ({board_spec['image_name']})")

    def run_container(*extra: str) -> None:
        """A stage container: the workspace at /work, /dev passed through."""
        run(["docker", "run", "--rm", "--privileged",
             "-e", f"BOARD={board}", "-e", f"PROFILE={args.profile}",
             "-v", "/dev:/dev", "-v", f"{ROOT_DIR}:/work",
             ALPINE_IMAGE, *extra])

    # --- inputs -------------------------------------------------------------
    if args.fetch:
        stage("00: fetch and verify build inputs")
        # BOARD goes in the environment: stage 00 resolves the board on its own
        # when build/board.env does not exist yet, and build.sh never exported
        # it, so `--board` was silently ignored there.
        run(["bash", "scripts/00-fetch-inputs.sh"],
            env={**os.environ, "BOARD": board})

    # --- profiles and recipes ----------------------------------------------
    # Cheap and offline: catches a broken profile or recipe before any container
    if args.run_tests:
        stage("profiles and recipes")
        print(capture(["bash", "tests/buildcfg.sh"]).strip().splitlines()[-1])

    # --- recipes ------------------------------------------------------------
    # Only a profile that names recipes pays for this: headless has none.
    try:
        recipes = buildcfg.resolve_profile(args.profile)["recipes"]
    except buildcfg.ConfigError as exc:
        die(f"buildcfg: {exc}")
    if recipes:
        stage(f"01: build the profile's recipes ({' '.join(recipes)})")
        # alpine, not debian: the packer uses abuild's own tools (abuild-tar,
        # abuild-sign), which is what makes the packages apk accepts.
        #
        # --network host: the container fetches the recipes' git repositories,
        # and docker's default bridge on this workstation cannot reach github
        # (it resets the connection; the Alpine mirrors are fine). The container
        # is privileged and mounts /dev already, so it is not a new boundary -
        # and the fetch is the only thing that needs it.
        run(["docker", "run", "--rm", "--privileged", "--network", "host",
             "-v", "/dev:/dev", "-v", f"{ROOT_DIR}:/work", "alpine:3.22",
             "sh", "-c",
             "apk add --no-cache bash abuild git tar gzip openssl python3 "
             ">/dev/null && "
             f"bash /work/scripts/01-build-recipes.sh --profile {args.profile}"])
    else:
        print(f"profile '{args.profile}' names no recipes: nothing to build from source")

    # --- rootfs -------------------------------------------------------------
    rootfs = ROOT_DIR / "rootfs"
    state = ROOT_DIR / "build" / "rootfs.state"
    # Which board and profile the rootfs holds: it carries the kernel,
    # devicetree and packages of the build that made it, so a change to either
    # wipes it.
    clean = args.clean
    if state.is_file():
        previous = (state.read_text().split() + ["", ""])[:2]
        if previous[0] != board or previous[1] != args.profile:
            print(f"rootfs holds board '{previous[0] or '?'}' "
                  f"profile '{previous[1] or '?'}', "
                  f"building '{board}' '{args.profile}': wiping it")
            clean = True

    if clean and rootfs.is_dir():
        stage("clean: removing rootfs/ (it is root-owned, so a container does it)")
        run_container("rm", "-rf", "/work/rootfs")

    if not rootfs.is_dir():
        stage("02: bootstrap the Alpine rootfs (build-time packages only)")
        run_container("bash", "/work/scripts/02-bootstrap-rootfs.sh")
    else:
        print(f"rootfs/ already holds profile '{args.profile}': "
              "keeping it (--clean to rebuild)")

    # --- configure for the profile -----------------------------------------
    stage(f"03: board '{board}', profile '{args.profile}' "
          "(packages, services, kernel, flash initramfs)")
    run_container("bash", "-c",
                  "apt-get update -qq && apt-get install -y -qq "
                  f"{APT_PACKAGES} python3 >/dev/null && "
                  f"bash /work/scripts/03-configure-rootfs.sh --profile {args.profile}")

    # --- image --------------------------------------------------------------
    stage("04: assemble the image and assert it against the board and the profile")
    run_container("bash", "-c",
                  "apt-get update -qq && apt-get install -y -qq "
                  f"{APT_PACKAGES} >/dev/null && bash /work/scripts/04-build-image.sh")

    # The rootfs now holds this pair; the containers wrote build/, so the note
    # about it is written the same way (the workspace is root-owned from here).
    run_container("sh", "-c",
                  f"printf '%s %s\\n' '{board}' '{args.profile}' "
                  "> /work/build/rootfs.state")

    # --- result -------------------------------------------------------------
    images = sorted((ROOT_DIR / "image").glob("*.img"),
                    key=lambda path: path.stat().st_mtime, reverse=True)
    if not images:
        die("no image in image/ after stage 04")
    img = images[0]

    stage("done")
    print(f"board   : {board}")
    print(f"profile : {args.profile}")
    print(f"image   : {img} ({img.stat().st_size} bytes)")
    print(f"sha256  : {capture(['sha256sum', str(img)]).split()[0]}")
    print(f"""
What is in it (on the board):

  cat /etc/solovox/image-manifest

Flash it whole to a card, e.g.:

  sudo dd if={img} of=/dev/sdX bs=4M conv=fsync status=progress

Publish a release for OTA (regenerates the .gz/.bmap/.size sidecars):

  scripts/05-ota-publish.sh""")
    return 0


if __name__ == "__main__":
    # build.sh's echoes appeared in order because bash flushes every line; a
    # piped python buffers its own print() output instead, so the board line and
    # the stage banners came out after the container output they precede when
    # the build was piped (to tee, or to a log). Line-buffer to keep the log
    # readable in the order the stages actually ran.
    sys.stdout.reconfigure(line_buffering=True)
    os.chdir(ROOT_DIR)
    try:
        sys.exit(main())
    except subprocess.CalledProcessError as exc:
        sys.exit(exc.returncode)
