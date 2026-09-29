#!/usr/bin/env python3
"""Resolve image profiles and recipe definitions into what the build scripts use.

Two kinds of TOML file live in this repository, and both are read here so that
the same strictness applies to each:

    profiles/common.toml + profiles/<name>.toml   what an image contains
    recipes/<name>.toml                           how a piece of software is
                                                  fetched, built and packaged

The build scripts stay shell — they mount, chroot, apk, losetup and dd — but
they do not parse TOML: they run this tool first and consume its output.

    tools/buildcfg.py profile show simple-graphics --emit env > build/profile.env
    . build/profile.env          # PROFILE_APK_ADD=( ... ) and friends

Recipes are consumed as JSON by the recipe builder:

    tools/buildcfg.py recipe show simple-graphics-controller --emit json

Every check fails loudly with the file and the offending key. A key that is
misspelled, a ref that is a branch name, an added package that does not exist,
a recipe a profile names but no file defines: all of them are build errors, not
surprises on the board.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tomllib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROFILES_DIR = Path(os.environ.get("PROFILES_DIR", REPO_ROOT / "profiles"))
RECIPES_DIR = Path(os.environ.get("RECIPES_DIR", REPO_ROOT / "recipes"))
BOARDS_DIR = Path(os.environ.get("BOARDS_DIR", REPO_ROOT / "board"))

PROFILE_LIST_KEYS = (
    "apk_add",
    "apk_remove",
    "services",
    "services_remove",
    "recipes",
    "runtime_apk_add",
)
PROFILE_KEYS = {"name", *PROFILE_LIST_KEYS}

RECIPE_LIST_KEYS = ("depends", "makedepends", "sources")
RECIPE_STRING_KEYS = (
    "name",
    "version",
    "repo",
    "ref",
    "build",
    "install",
    "apkbuild",
    "rust_toolchain",
    "license",
    "maintainer",
)
RECIPE_KEYS = {*RECIPE_LIST_KEYS, *RECIPE_STRING_KEYS}

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
APK_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9+._-]*$")

# The board layer: board/common/board.toml holds what every platform shares and
# board/platform/<name>/board.toml holds one machine, which is the same
# common-plus-delta shape as profiles. These keys are the machine-specific facts
# the stages used to hardcode: the kernel and u-boot to fetch, the devicetree to
# merge, and the image's identity.
BOARD_LIST_KEYS = ("overlays", "private_files")
BOARD_STRING_KEYS = (
    "hostname",
    "kernel",
    "kernel_release",
    "kernel_url",
    "kernel_sha256",
    "uboot_url",
    "uboot_file",
    "uboot_sha256",
    "dtb",
    "boot_dtb",
    "merge_check_node",
    "merge_check_text",
    "alpine_branch",
    "alpine_release",
    "alpine_mirror",
    "alpine_minirootfs_sha256",
    "image_prefix",
    "timezone",
    "disk_id",
    "root_partuuid",
    "rootfs_uuid",
)
BOARD_INT_KEYS = ("image_size_mb",)
BOARD_KEYS = {*BOARD_LIST_KEYS, *BOARD_STRING_KEYS, *BOARD_INT_KEYS}
# What a platform (or the common layer) has to set for the build to be possible.
BOARD_REQUIRED = (
    "hostname",
    "kernel",
    "kernel_release",
    "kernel_url",
    "kernel_sha256",
    "uboot_url",
    "uboot_file",
    "uboot_sha256",
    "dtb",
    "boot_dtb",
    "alpine_release",
    "alpine_minirootfs_sha256",
)
# a sibling checkout a recipe's build needs: <repo>@<commit sha>
SOURCE_RE = re.compile(r"^(?P<repo>(?:https|file)://\S+)@(?P<ref>[0-9a-f]{40})$")
# a rustup toolchain name: the value reaches a shell command in 05, so it is
# restricted to what a toolchain name can contain
TOOLCHAIN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


class ConfigError(Exception):
    """A problem in a profile or recipe file, reported with its location."""


def read_toml(path: Path) -> dict:
    try:
        with path.open("rb") as fh:
            return tomllib.load(fh)
    except FileNotFoundError:
        raise ConfigError(f"no such file: {path}") from None
    except IsADirectoryError:
        raise ConfigError(f"not a file: {path}") from None
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(f"{path}: {exc}") from None


def check_keys(path: Path, data: dict, allowed: set[str]) -> None:
    unknown = sorted(set(data) - allowed)
    if unknown:
        known = ", ".join(sorted(allowed))
        raise ConfigError(
            f"{path}: unknown key(s) {', '.join(repr(k) for k in unknown)}"
            f" (allowed: {known})"
        )


def string_list(path: Path, data: dict, key: str) -> list[str]:
    if key not in data:
        return []
    value = data[key]
    if not isinstance(value, list):
        raise ConfigError(f"{path}: {key} must be an array of strings")
    items: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise ConfigError(f"{path}: {key} must be an array of strings, got {item!r}")
        if not item.strip():
            raise ConfigError(f"{path}: {key} has an empty entry")
        if item not in items:  # a repeat is a no-op, not an error
            items.append(item)
    return items


def string(path: Path, data: dict, key: str, *, required: bool = False) -> str:
    value = data.get(key, "")
    if not isinstance(value, str):
        raise ConfigError(f"{path}: {key} must be a string, got {value!r}")
    value = value.strip()
    if required and not value:
        raise ConfigError(f"{path}: {key} is required")
    return value


def check_apk_names(path: Path, key: str, items: list[str]) -> None:
    for item in items:
        if not APK_NAME_RE.match(item):
            raise ConfigError(f"{path}: {key} entry {item!r} is not a package name")


def resolve_profile(name: str) -> dict:
    """Merge profiles/common.toml with profiles/<name>.toml into one image spec."""
    if not name:
        raise ConfigError("no profile given (--profile <name> or PROFILES_DIR)")
    if name == "common":
        raise ConfigError("'common' is the shared layer, not a profile")

    common_path = PROFILES_DIR / "common.toml"
    path = PROFILES_DIR / f"{name}.toml"
    common = read_toml(common_path)
    profile = read_toml(path)

    check_keys(common_path, common, PROFILE_KEYS)
    check_keys(path, profile, PROFILE_KEYS)

    common_name = string(common_path, common, "name")
    if common_name and common_name != "common":
        raise ConfigError(
            f'{common_path}: declares name = "{common_name}"; the common layer is'
            ' not a profile (use name = "common" or omit it)'
        )
    profile_name = string(path, profile, "name")
    if not profile_name:
        raise ConfigError(f'{path}: has no name; it must match the file: name = "{name}"')
    if profile_name != name:
        raise ConfigError(
            f'{path}: declares name = "{profile_name}" but was loaded as {name!r}'
        )

    merged: dict[str, list[str]] = {
        key: string_list(common_path, common, key) for key in PROFILE_LIST_KEYS
    }
    for key in PROFILE_LIST_KEYS:
        for item in string_list(path, profile, key):
            if item not in merged[key]:
                merged[key].append(item)

    check_apk_names(common_path, "apk_add", merged["apk_add"])
    check_apk_names(path, "apk_add", merged["apk_add"])
    check_apk_names(path, "runtime_apk_add", merged["runtime_apk_add"])

    # A removal that removes nothing is a typo, or an attempt to drop something the
    # build itself needs (those live in scripts/01, not in the common layer).
    for item in merged["apk_remove"]:
        if item not in merged["apk_add"]:
            raise ConfigError(
                f"{path}: apk_remove lists {item!r}, which is not in the merged package"
                " set (packages the build itself needs stay in scripts/01)"
            )
    for item in merged["services_remove"]:
        if item not in merged["services"]:
            raise ConfigError(
                f"{path}: services_remove lists {item!r}, which is not in the merged"
                " service set"
            )

    remaining = [p for p in merged["apk_add"] if p not in merged["apk_remove"]]
    if not remaining:
        raise ConfigError(f"{path}: the merged package set is empty")

    for recipe in merged["recipes"]:
        if not (RECIPES_DIR / f"{recipe}.toml").is_file():
            raise ConfigError(f"{path}: recipes = [{recipe!r}] has no recipes/{recipe}.toml")

    return {
        "profile": name,
        "apk_add": remaining,
        "apk_remove": merged["apk_remove"],
        "services": [s for s in merged["services"] if s not in merged["services_remove"]],
        "services_remove": merged["services_remove"],
        "recipes": merged["recipes"],
        "runtime_apk_add": merged["runtime_apk_add"],
    }


def load_recipe(name: str) -> dict:
    """Read and validate recipes/<name>.toml."""
    if not name:
        raise ConfigError("no recipe given")
    path = RECIPES_DIR / f"{name}.toml"
    data = read_toml(path)
    check_keys(path, data, RECIPE_KEYS)

    recipe_name = string(path, data, "name", required=True)
    if recipe_name != name:
        raise ConfigError(
            f'{path}: declares name = "{recipe_name}" but was loaded as {name!r}'
        )

    repo = string(path, data, "repo", required=True)
    if not repo.startswith(("https://", "file://")):
        raise ConfigError(
            f"{path}: repo must be an https:// URL ({repo!r}). Build containers have no"
            " ssh keys, and the sgc repositories are reachable over https. file:// is"
            " accepted for tests only."
        )

    ref = string(path, data, "ref", required=True)
    if not SHA_RE.match(ref):
        raise ConfigError(
            f"{path}: ref must be a full 40-character commit sha ({ref!r}). Branches and"
            " tags are refused: they move, and then two builds of the same recipe differ."
        )

    install = string(path, data, "install")
    apkbuild = string(path, data, "apkbuild")
    if install and apkbuild:
        raise ConfigError(
            f"{path}: install and apkbuild are mutually exclusive. apkbuild names the"
            " repository's own APKBUILD, which owns the package's file layout,"
            " dependencies and metadata; install writes that layout here instead. The"
            " image should not have two answers for where a file goes."
        )
    if not install and not apkbuild:
        raise ConfigError(
            f'{path}: a recipe must package something: either apkbuild = "APKBUILD"'
            " (the upstream repository packages itself, with abuild) or an install hook"
            " that writes into $DESTDIR"
        )
    if apkbuild and (apkbuild.startswith("/") or ".." in Path(apkbuild).parts):
        raise ConfigError(
            f"{path}: apkbuild must be a path inside the source tree ({apkbuild!r})"
        )

    depends = string_list(path, data, "depends")
    makedepends = string_list(path, data, "makedepends")
    check_apk_names(path, "depends", depends)
    check_apk_names(path, "makedepends", makedepends)

    sources = string_list(path, data, "sources")
    for item in sources:
        if not SOURCE_RE.match(item):
            raise ConfigError(
                f"{path}: sources entries are '<repo>@<commit sha>' ({item!r} is not)."
                " Each is cloned into src/ beside the recipe's own checkout, which is"
                " where a crate that names a sibling by path looks for it."
            )

    rust_toolchain = string(path, data, "rust_toolchain")
    if rust_toolchain and not TOOLCHAIN_RE.match(rust_toolchain):
        raise ConfigError(
            f"{path}: rust_toolchain must be a toolchain name such as 1.88.0"
            f" ({rust_toolchain!r} is not). It is passed to rustup in the build"
            " chroot."
        )

    return {
        "recipe": name,
        "name": recipe_name,
        "version": string(path, data, "version", required=True),
        "repo": repo,
        "ref": ref,
        "license": string(path, data, "license"),
        "maintainer": string(path, data, "maintainer"),
        "depends": depends,
        "makedepends": makedepends,
        "sources": sources,
        "build": string(path, data, "build"),
        "install": install,
        "apkbuild": apkbuild,
        "rust_toolchain": rust_toolchain,
        "file": str(path),
    }


def available_platforms() -> list[str]:
    root = BOARDS_DIR / "platform"
    if not root.is_dir():
        return []
    return sorted(p.name for p in root.iterdir() if (p / "board.toml").is_file())


def runtime_trees(name: str, kind: str) -> list[str]:
    """Runtime trees a platform ships, workspace-relative: the common one, plus
    the platform's own when it has one (platform-specific runtime files)."""
    trees = [f"board/common/runtime/{kind}"]
    if (BOARDS_DIR / "platform" / name / "runtime" / kind).is_dir():
        trees.append(f"board/platform/{name}/runtime/{kind}")
    return trees


def load_board(name: str) -> dict:
    """Merge board/common/board.toml with board/platform/<name>/board.toml."""
    if not name:
        raise ConfigError("no platform given (--board <name>)")
    common_path = BOARDS_DIR / "common" / "board.toml"
    platform_dir = BOARDS_DIR / "platform" / name
    path = platform_dir / "board.toml"
    if not path.is_file():
        raise ConfigError(f"no such platform: board/platform/{name}/board.toml")

    common = read_toml(common_path)
    platform = read_toml(path)
    check_keys(common_path, common, BOARD_KEYS)
    check_keys(path, platform, BOARD_KEYS)

    merged = {**common, **platform}

    def source(key: str) -> Path:
        """The file a merged value came from, for error messages."""
        return path if key in platform else common_path

    for key in BOARD_REQUIRED:
        string(source(key), merged, key, required=True)
    for key in BOARD_STRING_KEYS:
        string(path, merged, key)

    for key in ("kernel_url", "uboot_url", "alpine_mirror"):
        value = string(path, merged, key)
        if value and not value.startswith("https://"):
            raise ConfigError(
                f"{path}: {key} must be an https:// URL ({value!r}); the build"
                " containers carry no ssh keys"
            )
    for key in BOARD_STRING_KEYS:
        value = string(path, merged, key)
        if value and key.endswith("_sha256") and not SHA256_RE.match(value):
            raise ConfigError(
                f"{path}: {key} must be a 64-character hex sha256 ({value!r})"
            )
    for key in ("dtb", "boot_dtb"):
        value = string(path, merged, key)
        if value and not value.endswith(".dtb"):
            raise ConfigError(f"{path}: {key} must name a .dtb ({value!r})")

    size = merged.get("image_size_mb", 0)
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        raise ConfigError(
            f"{path}: image_size_mb must be a positive integer number of MiB"
            f" (got {size!r})"
        )

    overlays = string_list(path, merged, "overlays")
    for overlay in overlays:
        if not overlay.endswith(".dtso"):
            raise ConfigError(
                f"{path}: overlays entry {overlay!r} must be a .dtso source (the"
                " compiled .dtbo is a build artifact)"
            )
        if not (platform_dir / overlay).is_file():
            raise ConfigError(
                f"{path}: overlays lists {overlay!r}, which is not in"
                f" board/platform/{name}/"
            )

    roots = runtime_trees(name, "root")
    private = string_list(path, merged, "private_files")
    for item in private:
        if not any((BOARDS_DIR.parent / tree / item).is_file() for tree in roots):
            raise ConfigError(
                f"{path}: private_files lists {item!r}, which no runtime/root tree"
                f" has ({', '.join(roots)})"
            )

    parts = [
        string(path, merged, "image_prefix"),
        name,
        string(path, merged, "alpine_release"),
        string(path, merged, "kernel"),
    ]
    image_name = "-".join(p for p in parts if p)

    spec = {
        "platform": name,
        "machine": name,
        "image_name": image_name,
        "dir": f"board/platform/{name}",
        "devicetree_dir": f"board/platform/{name}/devicetree",
        "runtime_root": roots,
        "runtime_initramfs": runtime_trees(name, "initramfs"),
        "overlays": overlays,
        "private_files": private,
        "image_size_mb": size,
    }
    spec.update({key: string(path, merged, key) for key in BOARD_STRING_KEYS})
    return spec


def emit_text_board(spec: dict) -> str:
    lines = [f"board: {spec['machine']}  (image {spec['image_name']})"]
    for key in BOARD_STRING_KEYS:
        lines.append(f"{key}: {spec[key] or '(none)'}")
    lines.append(f"image_size_mb: {spec['image_size_mb']}")
    for key in ("overlays", "private_files", "runtime_root", "runtime_initramfs"):
        lines.append(f"{key} ({len(spec[key])}):")
        lines.extend(f"  {item}" for item in spec[key]) if spec[key] else lines.append("  (none)")
    return "\n".join(lines) + "\n"


def sh_quote(value: str) -> str:
    """Quote a value for sourcing (and for eval): the emitted file is bash."""
    return "'" + str(value).replace("'", "'\\''") + "'"


def emit_env_board(spec: dict) -> str:
    """The board half of the shell contract: values the stage scripts source.

    Paths are workspace-relative (the containers mount the workspace at /work).
    Values are quoted, so `eval "$(tools/buildcfg.py board show --emit env)"`
    works as well as writing the file: stage 00 runs on the host, where build/
    may be owned by root from an earlier container run.
    """
    lines = [
        "# generated by tools/buildcfg.py - do not edit",
        f"BOARD_MACHINE={sh_quote(spec['machine'])}",
        f"BOARD_IMAGE_NAME={sh_quote(spec['image_name'])}",
        f"BOARD_IMAGE_SIZE_MB={spec['image_size_mb']}",
        f"BOARD_DIR={sh_quote(spec['dir'])}",
        f"BOARD_DEVICETREE_DIR={sh_quote(spec['devicetree_dir'])}",
    ]
    for key in BOARD_STRING_KEYS:
        lines.append(f"BOARD_{key.upper()}={sh_quote(spec[key])}")
    for key, var in (
        ("overlays", "BOARD_OVERLAYS"),
        ("private_files", "BOARD_PRIVATE_FILES"),
        ("runtime_root", "BOARD_RUNTIME_ROOTS"),
        ("runtime_initramfs", "BOARD_RUNTIME_INITRAMFS_DIRS"),
    ):
        quoted = " ".join(sh_quote(item) for item in spec[key])
        lines.append(f"{var}=({quoted})")
    return "\n".join(lines) + "\n"


def emit_manifest_board(spec: dict) -> str:
    """The board lines of /etc/solovox/image-manifest: which machine, and which
    kernel and u-boot it was assembled from (inputs nothing else records)."""
    return "\n".join(
        [
            f"board: {spec['machine']}  hostname {spec['hostname']}",
            f"  kernel: {spec['kernel_release']} {spec['kernel_url']}",
            f"  kernel_sha256: {spec['kernel_sha256']}",
            f"  u-boot: {spec['uboot_file']} {spec['uboot_url']}",
            "  devicetree: "
            + spec["dtb"]
            + (" + " + " ".join(spec["overlays"]) if spec["overlays"] else "")
            + f" -> {spec['boot_dtb']}",
        ]
    ) + "\n"


def available_profiles() -> list[str]:
    return sorted(
        p.stem for p in PROFILES_DIR.glob("*.toml") if p.stem != "common"
    )


def available_recipes() -> list[str]:
    return sorted(p.stem for p in RECIPES_DIR.glob("*.toml"))


def emit_text_profile(spec: dict) -> str:
    lines = [f"profile: {spec['profile']}"]
    for key in ("apk_add", "apk_remove", "services", "recipes", "runtime_apk_add"):
        items = spec[key]
        lines.append(f"{key} ({len(items)}):")
        if items:
            lines.extend(f"  {item}" for item in items)
        else:
            lines.append("  (none)")
    return "\n".join(lines) + "\n"


def emit_env_profile(spec: dict) -> str:
    lines = [
        "# generated by tools/buildcfg.py - do not edit",
        f"PROFILE_NAME={spec['profile']}",
    ]
    for key in ("apk_add", "apk_remove", "services", "recipes", "runtime_apk_add"):
        var = "PROFILE_" + key.upper()
        quoted = " ".join(f'"{item}"' for item in spec[key])
        lines.append(f"{var}=({quoted})")
    return "\n".join(lines) + "\n"


def source_label(item: str) -> str:
    """'<repo>@<sha>' -> '<repo name>@<short sha>', for the manifest."""
    repo, ref = item.rsplit("@", 1)
    name = repo.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
    return f"{name}@{ref[:12]}"


def emit_manifest_profile(spec: dict) -> str:
    """The profile half of /etc/solovox/image-manifest.

    Recipe metadata is resolved here because it lives in the recipe files; the
    installed package list is appended by the build script, which is the only
    side that knows what actually landed in the image.
    """
    lines = [f"profile: {spec['profile']}"]
    for key in ("apk_add", "apk_remove", "services", "runtime_apk_add"):
        lines.append(f"{key}:")
        lines.extend(f"  {item}" for item in spec[key])
        if not spec[key]:
            lines.append("  (none)")
    lines.append("recipes:")
    if not spec["recipes"]:
        lines.append("  (none)")
    for name in spec["recipes"]:
        recipe = load_recipe(name)
        siblings = " ".join(source_label(s) for s in recipe["sources"])
        lines.append(
            f"  {name} {recipe['version']} {recipe['ref']} {recipe['repo']}"
            + (f" {siblings}" if siblings else "")
        )
    return "\n".join(lines) + "\n"


def emit_text_recipe(recipe: dict) -> str:
    lines = [f"recipe: {recipe['recipe']}"]
    for key in ("version", "repo", "ref", "license", "maintainer"):
        lines.append(f"{key}: {recipe[key] or '(none)'}")
    lines.append(f"apkbuild: {recipe['apkbuild'] or '(none: install hook)'}")
    if recipe["rust_toolchain"]:
        lines.append(f"rust_toolchain: {recipe['rust_toolchain']}")
    for key in ("depends", "makedepends"):
        lines.append(f"{key} ({len(recipe[key])}): " + " ".join(recipe[key]))
    if recipe["sources"]:
        lines.append(f"sources ({len(recipe['sources'])}):")
        lines.extend(f"  {item}" for item in recipe["sources"])
    build: str = recipe["build"] or ""
    install: str = recipe["install"] or ""
    if build:
        lines.append("build:")
        lines.extend(f"  {line}" for line in build.splitlines())
    if install:
        lines.append("install:")
        lines.extend(f"  {line}" for line in install.splitlines())
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p_profile = sub.add_parser("profile", help="profiles/*.toml")
    p_profile.add_argument("action", choices=("show", "list"))
    p_profile.add_argument("name", nargs="?")
    p_profile.add_argument("--emit", choices=("text", "json", "env", "manifest"), default="text")

    p_recipe = sub.add_parser("recipe", help="recipes/*.toml")
    p_recipe.add_argument("action", choices=("show", "list", "validate"))
    p_recipe.add_argument("names", nargs="*")
    p_recipe.add_argument("--emit", choices=("text", "json"), default="text")

    p_board = sub.add_parser("board", help="board/platform/<name>/board.toml")
    p_board.add_argument("action", choices=("show", "list", "validate"))
    p_board.add_argument("name", nargs="?")
    p_board.add_argument(
        "--emit", choices=("text", "json", "env", "manifest"), default="text"
    )

    args = parser.parse_args(argv)

    try:
        if args.command == "profile":
            if args.action == "list":
                for name in available_profiles():
                    print(name)
                return 0
            spec = resolve_profile(args.name or "")
            if args.emit == "json":
                print(json.dumps(spec, indent=2, sort_keys=True))
            elif args.emit == "env":
                sys.stdout.write(emit_env_profile(spec))
            elif args.emit == "manifest":
                sys.stdout.write(emit_manifest_profile(spec))
            else:
                sys.stdout.write(emit_text_profile(spec))
            return 0

        if args.command == "board":
            if args.action == "list":
                for name in available_platforms():
                    print(name)
                return 0
            name = args.name
            if not name:
                platforms = available_platforms()
                if args.action == "validate":
                    if not platforms:
                        raise ConfigError(f"no platforms in {BOARDS_DIR}/platform")
                    for platform in platforms:
                        load_board(platform)
                    print(f"all {len(platforms)} platform(s) validate")
                    return 0
                if len(platforms) != 1:
                    raise ConfigError(
                        "give a platform name; available: "
                        + ", ".join(platforms or ["none"])
                    )
                name = platforms[0]
            spec = load_board(name)
            if args.emit == "json":
                print(json.dumps(spec, indent=2, sort_keys=True))
            elif args.emit == "env":
                sys.stdout.write(emit_env_board(spec))
            elif args.emit == "manifest":
                sys.stdout.write(emit_manifest_board(spec))
            else:
                sys.stdout.write(emit_text_board(spec))
            if args.action == "validate":
                print(f"board {name}: ok")
            return 0

        if args.action == "list":
            for name in available_recipes():
                print(name)
            return 0

        names = args.names or available_recipes()
        if not names:
            raise ConfigError(f"no recipes in {RECIPES_DIR}")
        out = []
        for name in names:
            recipe = load_recipe(name)
            if args.emit == "json":
                out.append(json.dumps(recipe, indent=2, sort_keys=True))
            else:
                out.append(emit_text_recipe(recipe))
        sys.stdout.write("\n".join(out))
        return 0
    except ConfigError as exc:
        print(f"buildcfg: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
