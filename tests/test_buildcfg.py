"""Exercise tools/buildcfg.py without a board, a container or the network.

Covers the repository's own profiles, recipe and platform, and fixtures that
must be rejected rather than silently resolved to something wrong. This is the
resolver half of the config check; the other half - that `--emit env` prints
valid bash and that a value containing spaces survives the `eval` the stage
scripts do - is tests/buildcfg-env.sh, because python cannot source a shell
fragment. Run both together with `python3 build.py`.

    python3 -m pytest tests/test_buildcfg.py -q

The resolver reads PROFILES_DIR / RECIPES_DIR / BOARDS_DIR at call time, so the
fixture tests below point those at a scratch tree with monkeypatch instead of
setting the environment and re-importing.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))

import buildcfg  # noqa: E402


# --- fixtures ---------------------------------------------------------------

# The shared half of a scratch board tree: a common layer and one platform,
# which the board tests then rewrite.
COMMON_BOARD = """alpine_branch = "v3.22"
alpine_release = "3.22.6"
alpine_mirror = "https://example.invalid/alpine"
alpine_minirootfs_sha256 = "821565fa8f3953eefd12497b166b4b50add2f7c57fb312e75862f5867e06fefe"
image_prefix = "alpine"
image_size_mb = 4096
disk_id = "abcd1234"
root_partuuid = "abcd1234-01"
rootfs_uuid = "9f1c7a3e-5b21-4f8d-9a1c-7b2d4e6f8a90"
timezone = "UTC"
private_files = []
"""

# The shortest platform that resolves: the two input URLs and their checksums,
# the two devicetree names. Optional keys (overlays, the merge check, the image
# size) are absent on purpose - a case below adds the one it is about.
SHORT_BOARD = """hostname = "fake"
kernel = "1.0"
kernel_release = "1.0-fake"
kernel_url = "https://example.invalid/kernel.tar.gz"
kernel_sha256 = "269dd8ded019f829723968a236bac40335dc9488aac8f22cf1afd5b9f3a20bb7"
uboot_url = "https://example.invalid/uboot.bin"
uboot_file = "uboot.bin"
uboot_sha256 = "4c6afa2ef90610318dbd4f9a201a432610eb0eb025afd06e8d7bf69c17309e96"
dtb = "fake.dtb"
boot_dtb = "fake-fixed.dtb"
"""

FULL_BOARD = SHORT_BOARD + """overlays = []
merge_check_node = "node@0"
merge_check_text = "reg = <0x0>"
"""


class Scratch:
    """A scratch profiles/, recipes/ and board/ that the resolver reads.

    The three directory globals are monkeypatched, so teardown restores them
    even when a test fails and the next test never sees this tree.
    """

    def __init__(self, tmp_path, monkeypatch):
        self.profiles = tmp_path / "profiles"
        self.recipes = tmp_path / "recipes"
        self.boards = tmp_path / "board"
        for path in (self.profiles, self.recipes, self.boards / "platform"):
            path.mkdir(parents=True)
        monkeypatch.setattr(buildcfg, "PROFILES_DIR", self.profiles)
        monkeypatch.setattr(buildcfg, "RECIPES_DIR", self.recipes)
        monkeypatch.setattr(buildcfg, "BOARDS_DIR", self.boards)

    def profile(self, name, body):
        (self.profiles / f"{name}.toml").write_text(body)

    def recipe(self, name, body):
        (self.recipes / f"{name}.toml").write_text(body)

    def platform(self, name="fake", body=FULL_BOARD):
        directory = self.boards / "platform" / name
        (directory / "devicetree").mkdir(parents=True, exist_ok=True)
        (directory / "board.toml").write_text(body)
        common = self.boards / "common"
        if not (common / "board.toml").exists():
            common.mkdir(exist_ok=True)
            (common / "board.toml").write_text(COMMON_BOARD)

    def refuse(self, cli, argv, message, *, kind="profile", name="case", body=""):
        """Write the fixture, run the CLI, and require a refusal naming why.

        The whole output is checked, not just the message: a refusal has to exit
        non-zero (the old suite only checked that it failed) and has to carry
        the tool's own prefix, which is what a stage script would log.
        """
        writer = {"profile": self.profile, "recipe": self.recipe,
                  "board": self.platform}[kind]
        writer(name, body)
        code, out = cli(*argv)
        assert code == 1, f"{name}: expected exit 1, got {code}: {out}"
        assert out.startswith("buildcfg: "), f"{name}: no prefix: {out}"
        assert message in out, f"{name}: {message!r} not in {out!r}"


@pytest.fixture
def scratch(tmp_path, monkeypatch):
    return Scratch(tmp_path, monkeypatch)


@pytest.fixture
def cli(capsys):
    """Run the CLI in process; return its exit code and stdout+stderr.

    stderr is merged into the output, as `<cmd> 2>&1` did in the old suite: the
    refusals are printed there and the assertions are about their text.
    """
    def run(*argv):
        code = buildcfg.main(list(argv))
        captured = capsys.readouterr()
        return code, captured.out + captured.err
    return run


def text_of(cli, *argv):
    code, out = cli(*argv)
    assert code == 0, f"{' '.join(argv)}: exit {code}: {out}"
    return out


# --- the real profiles ------------------------------------------------------

def test_profile_list_offers_the_profiles():
    assert buildcfg.available_profiles() == ["headless", "simple-graphics"]  # profile list


def test_headless_carries_the_kernel_and_grows_the_card():
    spec = buildcfg.resolve_profile("headless")
    assert "linux-lts" in spec["apk_add"]          # headless carries linux-lts
    assert "default:growfs" in spec["services"]    # headless enables growfs


def test_headless_has_no_mesa_and_builds_nothing():
    spec = buildcfg.resolve_profile("headless")
    assert not [name for name in spec["apk_add"] if name.startswith("mesa-")]  # no mesa
    assert spec["recipes"] == []                                              # builds nothing


def test_the_text_dump_is_the_resolved_profile(cli):
    out = text_of(cli, "profile", "show", "simple-graphics")
    assert re.search(r"^profile: simple-graphics$", out, re.M)
    assert re.search(r"^  mesa-gbm$", out, re.M)          # the profile's packages are listed
    assert re.search(r"^inherits: essential$", out, re.M)  # and the layer it inherited
    headless = buildcfg.emit_text_profile(buildcfg.resolve_profile("headless"))
    assert not re.search(r"^  mesa-", headless, re.M)      # headless has no mesa


def test_the_json_is_the_resolved_profile(cli):
    spec = json.loads(text_of(cli, "profile", "show", "simple-graphics", "--emit", "json"))
    assert "mesa-gbm" in spec["apk_add"]                        # json: mesa-gbm is in the set
    assert "default:simple-graphics-controller" in spec["services"]  # the daemon is enabled
    assert spec["inherits"] == ["essential"]                    # the layer is reported


def test_the_manifest_names_the_profile_and_its_layers(cli):
    out = text_of(cli, "profile", "show", "simple-graphics", "--emit", "manifest")
    assert re.search(r"^profile: simple-graphics$", out, re.M)
    assert re.search(r"^  essential$", out, re.M)     # manifest: the layer is named
    assert re.search(r"^  linux-lts$", out, re.M)     # a removal is recorded as one


# --- the real recipes -------------------------------------------------------

def test_recipe_list_is_the_recipes_and_the_real_one_validates(cli):
    assert buildcfg.available_recipes() == ["simple-graphics-controller"]  # recipe list
    code, out = cli("recipe", "validate")
    assert code == 0, out                     # the real recipe validates


def test_the_real_recipe_says_what_it_builds(cli):
    out = text_of(cli, "recipe", "show", "simple-graphics-controller")
    assert re.search(r"^ref: [0-9a-f]{40}$", out, re.M)      # recipe pins a full sha
    assert re.search(r"^repo: https://", out, re.M)          # uses the https remote
    assert re.search(r"^apkbuild: APKBUILD$", out, re.M)     # packages with the repo's APKBUILD
    assert not re.search(r"^install:", out, re.M)            # and has no install hook of its own
    assert "cargo build --release --locked" in out           # builds with --locked
    assert re.search(                                        # installs what the APKBUILD packages
        r"^  install -Dm755 target/release/simple-graphics-controller "
        r"dist/simple-graphics-controller$", out, re.M)
    assert re.search(                                        # declares its sibling checkout
        r"^  https://github\.com/sgc-project/simple-graphics-protocol\.git@[0-9a-f]{40}$",
        out, re.M)
    assert re.search(r"^rust_toolchain: 1\.88\.0$", out, re.M)  # the rustc the mirror has not


def test_the_recipe_json_agrees_with_the_recipe_file(cli):
    spec = json.loads(text_of(cli, "recipe", "show", "simple-graphics-controller",
                              "--emit", "json"))
    assert spec["apkbuild"] == "APKBUILD"    # the apkbuild path is emitted
    pin = re.search(r'^ref = "([0-9a-f]{40})"$',
                    (REPO / "recipes" / "simple-graphics-controller.toml").read_text(), re.M)
    assert pin, "the recipe file pins no full commit sha"
    # read back from the file, not hardcoded here: a hardcoded sha goes stale the
    # next time the pin is bumped, and then the test passes while the build does not
    assert spec["ref"] == pin.group(1)


# --- profile merging --------------------------------------------------------

ESSENTIAL_LAYER = 'name = "essential"\napk_add = ["bluez", "linux-lts"]\n' \
                  'services = ["default:networking"]\napk_remove = []\n'


def test_a_profile_with_one_delta_resolves(scratch):
    scratch.profile("essential", ESSENTIAL_LAYER)
    scratch.profile("tiny", 'name = "tiny"\ninherit = "essential"\napk_add = ["nano"]\n')
    spec = buildcfg.resolve_profile("tiny")
    assert spec["apk_add"] == ["bluez", "linux-lts", "nano"]  # the layer, then the delta
    assert spec["inherits"] == ["essential"]


def test_an_entry_a_layer_already_has_is_deduplicated(scratch):
    scratch.profile("essential", ESSENTIAL_LAYER)
    scratch.profile("dupe", 'name = "dupe"\ninherit = "essential"\napk_add = ["bluez"]\n')
    spec = buildcfg.resolve_profile("dupe")
    assert spec["apk_add"].count("bluez") == 1    # deduplicated


def test_a_removed_package_and_service_leave_the_sets(scratch):
    scratch.profile("essential", ESSENTIAL_LAYER)
    scratch.profile("rm", 'name = "rm"\ninherit = "essential"\n'
                          'apk_remove = ["linux-lts"]\n'
                          'services_remove = ["default:networking"]\n')
    spec = buildcfg.resolve_profile("rm")
    assert "linux-lts" not in spec["apk_add"]                  # leaves the set
    assert spec["apk_remove"] == ["linux-lts"]                 # and is reported as removed
    assert "default:networking" not in spec["services"]        # the service leaves too
    assert spec["services_remove"] == ["default:networking"]


def test_a_profile_inherits_through_a_layer(scratch):
    scratch.profile("essential", ESSENTIAL_LAYER)
    scratch.profile("graphics", 'name = "graphics"\ninherit = "essential"\n'
                                'apk_add = ["mesa-gbm"]\n'
                                'services = ["default:graphics-thing"]\n')
    scratch.profile("gl-client", 'name = "gl-client"\ninherit = "graphics"\n'
                                 'apk_add = ["mesa-egl"]\n')
    spec = buildcfg.resolve_profile("gl-client")
    assert "mesa-gbm" in spec["apk_add"]       # inherits through a layer
    assert "mesa-egl" in spec["apk_add"]       # and keeps its own additions
    assert "bluez" in spec["apk_add"]          # and reaches the bottom layer
    assert spec["inherits"] == ["essential", "graphics"]   # the chain is reported


def test_layers_merge_in_the_order_they_are_named(scratch):
    scratch.profile("one", 'name = "one"\napk_add = ["nano", "zsh"]\n')
    scratch.profile("two", 'name = "two"\napk_add = ["vim"]\napk_remove = ["nano"]\n')
    scratch.profile("both", 'name = "both"\ninherit = ["one", "two"]\n')
    spec = buildcfg.resolve_profile("both")
    assert "vim" in spec["apk_add"]            # the later layer's packages are in
    assert "nano" not in spec["apk_add"]       # and it took back the earlier layer's
    assert "zsh" in spec["apk_add"]            # the earlier layer's others stay
    assert spec["apk_add"] == ["zsh", "vim"]   # merged in the order named


def test_naming_the_same_layer_twice_is_a_no_op(scratch):
    scratch.profile("essential", ESSENTIAL_LAYER)
    scratch.profile("repeat", 'name = "repeat"\ninherit = ["essential", "essential"]\n')
    assert buildcfg.resolve_profile("repeat")["apk_add"] == ["bluez", "linux-lts"]


def test_a_removal_a_later_layer_undoes_is_not_a_veto(scratch):
    scratch.profile("base-a", 'name = "base-a"\napk_add = ["pkg-a", "pkg-b"]\n'
                              'services = ["default:thing"]\n')
    scratch.profile("no-a", 'name = "no-a"\ninherit = "base-a"\napk_add = ["pkg-c"]\n'
                            'apk_remove = ["pkg-a"]\n'
                            'services_remove = ["default:thing"]\n')
    scratch.profile("yes-a", 'name = "yes-a"\ninherit = "no-a"\napk_add = ["pkg-a"]\n'
                             'services = ["default:thing"]\n')
    spec = buildcfg.resolve_profile("yes-a")
    assert "pkg-a" in spec["apk_add"]              # a later layer undoes the removal
    assert "pkg-a" not in spec["apk_remove"]       # and it is not emitted as a removal
    assert "default:thing" in spec["services"]     # a service put back the same way
    assert "default:thing" not in spec["services_remove"]
    # putting it back moves it behind the names added after it
    assert spec["apk_add"] == ["pkg-b", "pkg-c", "pkg-a"]


def test_without_the_put_back_the_removal_stands(scratch):
    scratch.profile("base-a", 'name = "base-a"\napk_add = ["pkg-a", "pkg-b"]\n'
                              'services = ["default:thing"]\n')
    scratch.profile("no-a", 'name = "no-a"\ninherit = "base-a"\napk_add = ["pkg-c"]\n'
                            'apk_remove = ["pkg-a"]\n'
                            'services_remove = ["default:thing"]\n')
    scratch.profile("still-no", 'name = "still-no"\ninherit = "no-a"\n')
    spec = buildcfg.resolve_profile("still-no")
    assert "pkg-a" not in spec["apk_add"]
    assert spec["apk_remove"] == ["pkg-a"]


def test_a_layer_that_adds_and_removes_the_same_name_removes_it(scratch):
    scratch.profile("contra", 'name = "contra"\napk_add = ["pkg-a", "pkg-b"]\n'
                              'apk_remove = ["pkg-a"]\n')
    assert buildcfg.resolve_profile("contra")["apk_add"] == ["pkg-b"]


def test_the_essential_layer_is_a_layer_not_an_image_choice(scratch, cli):
    scratch.profile("essential", ESSENTIAL_LAYER)
    scratch.profile("tiny", 'name = "tiny"\ninherit = "essential"\napk_add = ["nano"]\n')
    assert buildcfg.resolve_profile("essential")["apk_add"] == ["bluez", "linux-lts"]
    assert "essential" not in buildcfg.available_profiles()  # not offered by list
    assert "tiny" in buildcfg.available_profiles()           # but the profile is


# --- profile rejections -----------------------------------------------------

PROFILE_REJECTIONS = {
    # name: (body, the reason the resolver must give)
    "badkey": ('name = "badkey"\napk_addd = ["nano"]\n', "unknown key"),
    "wrongtype": ('name = "wrongtype"\napk_add = [1, 2]\n', "array of strings"),
    "tabled": ('name = "tabled"\n[section]\nkey = "value"\n', "unknown key"),
    "misnamed": ('name = "other"\napk_add = ["nano"]\n', "declares name"),
    "noname": ('apk_add = ["nano"]\n', "has no name"),
    "noremove": ('name = "noremove"\ninherit = "essential"\napk_remove = ["linux-ltsx"]\n',
                 "not in the merged package set"),
    "noservice": ('name = "noservice"\ninherit = "essential"\n'
                  'services_remove = ["default:nope"]\n', "not in the merged service set"),
    "empty": ('name = "empty"\ninherit = "essential"\n'
              'apk_remove = ["bluez", "linux-lts"]\n', "package set is empty"),
    "norecipe": ('name = "norecipe"\ninherit = "essential"\n'
                 'recipes = ["does-not-exist"]\n', "has no recipes/does-not-exist.toml"),
    "selfish": ('name = "selfish"\ninherit = "selfish"\n', "closes a loop"),
    "orphan": ('name = "orphan"\ninherit = "nosuchlayer"\n',
               "there is no profiles/nosuchlayer.toml"),
    "badinherit": ('name = "badinherit"\ninherit = 3\n', "inherit must be a layer name"),
    "tomlname": ('name = "tomlname"\ninherit = "essential.toml"\n',
                 "not a path or a filename"),
    "bare": ('name = "bare"\n', "package set is empty"),
}


@pytest.mark.parametrize("name,case", sorted(PROFILE_REJECTIONS.items()),
                         ids=sorted(PROFILE_REJECTIONS))
def test_a_profile_fixture_is_refused(scratch, cli, name, case):
    body, message = case
    scratch.profile("essential", ESSENTIAL_LAYER)
    scratch.refuse(cli, ["profile", "show", name], message, name=name, body=body)


def test_two_layers_inheriting_each_other_are_refused(scratch, cli):
    scratch.profile("essential", ESSENTIAL_LAYER)
    scratch.profile("loop-a", 'name = "loop-a"\ninherit = "loop-b"\n')
    scratch.profile("loop-b", 'name = "loop-b"\ninherit = "loop-a"\n')
    # both files exist before either is resolved, or the refusal is the missing
    # layer rather than the loop
    code, out = cli("profile", "show", "loop-a")
    assert code == 1
    assert "closes a loop" in out


def test_a_missing_profile_is_reported(scratch, cli):
    code, out = cli("profile", "show", "nosuch")
    assert code == 1
    assert "no such file" in out


def test_a_profile_refusal_raises_the_tools_own_error(scratch):
    """The exit code and the message are the CLI's; the exception is the API's."""
    scratch.profile("orphan", 'name = "orphan"\ninherit = "nosuchlayer"\n')
    with pytest.raises(buildcfg.ConfigError,
                       match=re.escape("there is no profiles/nosuchlayer.toml")):
        buildcfg.resolve_profile("orphan")


# --- the real platform ------------------------------------------------------

def test_board_list_is_the_platforms_and_the_real_one_validates(cli):
    assert buildcfg.available_platforms() == ["solovox-z8pro"]  # board list
    code, out = cli("board", "validate")
    assert code == 0, out                     # the real platform validates


def test_the_real_platform_says_what_it_needs(cli):
    out = text_of(cli, "board", "show")
    assert re.search(  # the image name is derived from the layer
        r"^board: solovox-z8pro  \(image alpine-solovox-z8pro-3\.22\.6-6\.18\.53\)$",
        out, re.M)
    assert re.search(r"^kernel: 6\.18\.53$", out, re.M)                    # the kernel is data
    assert re.search(r"^dtb: sun50i-h618-x98h\.dtb$", out, re.M)           # the vendor dtb is data
    assert re.search(r"^boot_dtb: sun50i-h618-z8pro-ethfix\.dtb$", out, re.M)  # the booted tree
    assert re.search(r"^  devicetree/sun50i-h618-z8pro-ethfix\.dtso$", out, re.M)  # overlay source
    assert re.search(r"^  board/common/runtime/root$", out, re.M)          # the runtime tree
    assert re.search(r"^  root/\.ssh/authorized_keys$", out, re.M)         # the key


def test_the_board_json_and_manifest_carry_the_pins(cli):
    spec = json.loads(text_of(cli, "board", "show", "--emit", "json"))
    assert spec["runtime_root"] == ["board/common/runtime/root"]  # the runtime roots are listed
    manifest = text_of(cli, "board", "show", "--emit", "manifest")
    assert re.search(r"^  kernel: 6\.18\.53-ophub https://", manifest, re.M)  # the kernel pin


# --- board rejections -------------------------------------------------------

BOARD_REJECTIONS = {
    # name: (body, the reason the resolver must give)
    "no-required-keys": ('hostname = "fake"\nkernel = "1.0"\n', "is required"),
    "unknown-key": (FULL_BOARD + 'bogus = "1"\n', "unknown key"),
    "not-https": (SHORT_BOARD.replace("https://example.invalid/kernel.tar.gz",
                                     "http://example.invalid/kernel.tar.gz"),
                  "must be an https:// URL"),
    "bad-sha": (SHORT_BOARD.replace(
        'kernel_sha256 = "269dd8ded019f829723968a236bac40335dc9488aac8f22cf1afd5b9f3a20bb7"',
        'kernel_sha256 = "not-a-sha"'), "must be a 64-character hex sha256"),
    "bad-image-size": (SHORT_BOARD + 'image_size_mb = "4096"\n', "positive integer"),
    "compiled-overlay": (SHORT_BOARD + 'overlays = ["devicetree/thing.dtbo"]\n',
                         "must be a .dtso source"),
    "missing-overlay": (SHORT_BOARD + 'overlays = ["devicetree/missing.dtso"]\n', "is not in"),
    "missing-private-file": (SHORT_BOARD + 'private_files = ["etc/shadow"]\n',
                             "no runtime/root tree"),
}


@pytest.mark.parametrize("name,case", sorted(BOARD_REJECTIONS.items()),
                         ids=sorted(BOARD_REJECTIONS))
def test_a_board_fixture_is_refused(scratch, cli, name, case):
    body, message = case
    scratch.refuse(cli, ["board", "show", "fake"], message, kind="board",
                   name="fake", body=body)


def test_a_second_platform_validates(scratch, cli):
    scratch.platform()                      # board validate, on the fixture tree
    code, out = cli("board", "validate")
    assert code == 0, out


def test_a_missing_platform_is_reported(scratch, cli):
    code, out = cli("board", "show", "nosuch")
    assert code == 1
    assert "no such platform" in out


def test_a_board_refusal_raises_the_tools_own_error(scratch):
    scratch.platform(body='hostname = "fake"\nkernel = "1.0"\n')
    with pytest.raises(buildcfg.ConfigError, match=re.escape("is required")):
        buildcfg.load_board("fake")


# --- recipe rejections ------------------------------------------------------

PIN = "988cfe20c9c9047ef6fe2dc36dc186e3e48f86c1"


def recipe_body(filename, **overrides):
    """A minimal valid recipe named after its file, with keys changed or dropped.

    Dropping a key is `None`, which is how the cases below remove the install
    hook or the version; list keys render as TOML arrays. An override may set
    `name` to something else, which is the misnamed case.
    """
    body = {"name": filename, "version": "1.0.0", "repo": "https://example.invalid/thing.git",
            "ref": PIN, "install": "true", **overrides}
    lines = []
    for key, value in body.items():
        if value is None:
            continue
        rendered = json.dumps(value) if isinstance(value, list) else f'"{value}"'
        lines.append(f"{key} = {rendered}")
    return "\n".join(lines) + "\n"


RECIPE_REJECTIONS = {
    # name: (the deviation from a valid recipe, the reason the resolver must give)
    "branchref": ({"ref": "main"}, "must be a full 40-character commit sha"),
    "sshrepo": ({"repo": "git@github.com:example/thing.git"}, "must be an https:// URL"),
    "noinstall": ({"install": None, "build": "make"}, "must package something"),
    "bothpaths": ({"apkbuild": "APKBUILD"}, "mutually exclusive"),
    "absapkbuild": ({"apkbuild": "/etc/APKBUILD", "install": None}, "inside the source tree"),
    "upapkbuild": ({"apkbuild": "../APKBUILD", "install": None}, "inside the source tree"),
    "noversion": ({"version": None}, "version is required"),
    "misnamed": ({"name": "somethingelse"}, "declares name"),
    "badmake": ({"makedepends": ["Rust"]}, "is not a package name"),
    "badsource": ({"sources": ["https://example.invalid/other.git@main"]},
                  "sources entries are '<repo>@<commit sha>'"),
    "badrust": ({"rust_toolchain": "1.88.0; rm -rf /"}, "must be a toolchain name"),
}


@pytest.mark.parametrize("name,case", sorted(RECIPE_REJECTIONS.items()),
                         ids=sorted(RECIPE_REJECTIONS))
def test_a_recipe_fixture_is_refused(scratch, cli, name, case):
    overrides, message = case
    scratch.refuse(cli, ["recipe", "show", name], message, kind="recipe", name=name,
                   body=recipe_body(name, **overrides))


def test_a_recipe_refusal_raises_the_tools_own_error(scratch):
    scratch.recipe("branchref", recipe_body("branchref", ref="main"))
    with pytest.raises(buildcfg.ConfigError, match=re.escape("full 40-character commit sha")):
        buildcfg.load_recipe("branchref")
