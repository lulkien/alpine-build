# Recipes: building software into the image

A recipe describes one piece of software that is not in the Alpine mirrors: where
its source comes from, which commit of it, how to build it, and what to install
into the image. `scripts/05-build-recipes.sh` builds the recipes a profile names
and turns each one into a signed Alpine package.

```
recipes/simple-graphics-controller.toml    one recipe, one file
profiles/simple-graphics.toml              names it: recipes = [ "..." ]
tools/buildcfg.py                          validates and resolves both
tools/mkapk.sh                             DESTDIR tree -> signed .apk
scripts/05-build-recipes.sh                fetch, build in a chroot, package
tests/buildcfg.sh                          format checks, no board required
tests/recipe-build.sh                      the whole recipe path, offline
```

## File format

TOML, read with `tomllib`. Ten keys plus three lists:

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | must equal the filename without `.toml` |
| `version` | yes | upstream version; becomes the package version |
| `repo` | yes | git URL, `https://` only |
| `ref` | yes | full 40-character commit sha |
| `build` | no | shell run in the source tree to build it |
| `install` | one of `install`/`apkbuild` | shell run in the source tree to install it, into `$DESTDIR` |
| `apkbuild` | one of `install`/`apkbuild` | path to the repository's own APKBUILD: abuild packages and signs that |
| `rust_toolchain` | no | rustup toolchain the build chroot installs, when the mirror's rustc is too old |
| `license` | no | recorded in the package metadata |
| `maintainer` | no | recorded in the package metadata |
| `depends` | no | Alpine packages the built binaries need on the board |
| `makedepends` | no | Alpine packages installed in the build chroot first |
| `sources` | no | sibling checkouts the build resolves by path, as `<repo>@<commit sha>` |

Hooks are multi-line TOML strings. They are shell, run with `set -e`, in the
checked-out source tree. `install` also has `DESTDIR` set to the empty file tree
that becomes the package, so paths are written as
`"$DESTDIR/usr/bin/program"` and never touch the build host. Avoid double quotes
in a hook: 05 passes it to `sh -c "…"`, so single quotes are the safe ones.

Three rules are enforced because breaking them costs an image, not a test:

- **`ref` is a commit sha, never a branch or a tag.** Branches move, and then two
  builds of the same recipe produce different software under the same version.
  `tools/buildcfg.py` refuses anything that is not 40 hex characters.
- **`repo` is `https://`.** Build containers carry no ssh keys, and the `sgc`
  repositories are public over https.
- **Exactly one of `install` and `apkbuild`.** A recipe that writes the file tree
  itself and also names an APKBUILD has two answers for where a file goes, and a
  recipe with neither packages nothing. Both belong at validation time, not in a
  half-built image.

## Packaging: the repository's APKBUILD, or an install hook

`install` is for software whose upstream repository says nothing about packaging
into an image: the recipe writes `$DESTDIR`, and `tools/mkapk.sh` turns that tree
into a signed `.apk`.

`apkbuild` is for software that already packages itself. The repository's own
APKBUILD owns the file layout, the runtime dependencies and the metadata, so the
image stops keeping a second copy of them that drifts. 05 installs `abuild` in the
build chroot, hands it the build key (signing key in `$HOME/.abuild`, public half
in `/etc/apk/keys`, the same pair stage 02 trusts in the image) and runs

```
abuild -F -d -P <build/abuild-out/<name>>
```

`-F` because root is the only user in the chroot; `-d` because the dependency
check insists on an implicit `build-base` and these packages compile nothing
on their own. The `.apk` is copied out to `packages/<name>_<version>-r0.apk`, so
stage 02 sees the same flat directory either way, and abuild's index and working
directory stay in `build/abuild-out/`.

What that means for a recipe: with `apkbuild`, `build` still has to produce
whatever the APKBUILD packages. `recipes/simple-graphics-controller.toml` is the
worked example - its APKBUILD packages a prebuilt `dist/simple-graphics-controller`,
so the recipe's `build` compiles, strips and places exactly that file.

`tools/buildcfg.py` also refuses unknown keys, non-string array entries, a
`version`-less recipe, a `name` that does not match the file, and package names
that are not package names.

## Example

`recipes/simple-graphics-controller.toml` is the first recipe:

```toml
name = "simple-graphics-controller"
version = "0.1.0"
repo = "https://github.com/sgc-project/simple-graphics-controller.git"
ref = "8a4562a02b7fd3b5a9595e1cbf68b3a8f6a27a02"
makedepends = ["rust", "cargo", "binutils", "file"]
depends = []
build = """
CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=cc cargo build --release --locked --features drm,input
install -Dm755 target/release/simple-graphics-controller dist/simple-graphics-controller
strip -s dist/simple-graphics-controller
"""
sources = [
    "https://github.com/sgc-project/simple-graphics-protocol.git@2ed4c588a7e8a9113fa6e0830b3c54af4e747f5c",
]
apkbuild = "APKBUILD"
```

It is deliberately the easy case: pure Rust, no C dependencies, `Cargo.lock`
committed so `--locked` resolves nothing new, and nothing to install in the
chroot beyond a Rust toolchain plus the binutils `strip` and `file` the APKBUILD
wants. That APKBUILD packages a prebuilt binary, which is why the recipe's `build`
ends with the artifact where the APKBUILD looks for it: `dist/`.

## Toolchain

Two rustcs matter, and they are not the same one.

**In the build chroot.** Alpine v3.22's `rust` is 1.87.0. That is enough for a
crate on edition 2021, and **not** enough for either of the crates here: the daemon
uses let-chains (stable in 1.88) and the Slint fork declares
`rust-version = "1.92"`. A recipe that needs more says so:

```toml
rust_toolchain = "1.88.0"
```

05 then installs it with rustup inside the chroot — the Alpine `rustup` package
ships only `rustup-init`, so the first toolchain is installed by running that,
with `HOME=/root` deciding where it lives — and runs the recipe's `build` hook
with `~/.cargo/bin` on `PATH` and that toolchain as the default. The chroot is a
cache, so the download is paid once, not per build. The mirror's `rust`/`cargo`
are not installed at all for such a recipe; what it needs instead is the C linker
and headers plus `file` and `binutils`:

```toml
makedepends = ["gcc", "musl-dev", "binutils", "file"]
```

Two traps cost a build each. `--target aarch64-unknown-linux-musl` asks for a std
the chroot's toolchain does not carry, so build natively and let the triple be the
host's. And `RUSTFLAGS='-C target-feature=+crt-static'` breaks every proc-macro in
the graph ("cannot produce proc-macro ... does not support these crate types"):
musl targets already link statically by default, and the APKBUILD's `file` check
is what proves it, not a flag.

**On the workstation.** The .deb and .apk flavors `cargo` builds by hand (and the
`just dist-*` recipes) use the host cross toolchain; on Alpine that is the daemon
repository's own APKBUILD, which packages a prebuilt binary. Nothing about either
toolchain reaches the image: the build chroot is a throwaway tree, and only the
installed files do.

## Using a recipe

```bash
# what the file resolves to, as text or as JSON for the builder
tools/buildcfg.py recipe show simple-graphics-controller
tools/buildcfg.py recipe show simple-graphics-controller --emit json
tools/buildcfg.py recipe validate          # every recipe in the directory
tools/buildcfg.py recipe list

# the profile side: which recipes an image builds, fully resolved
tools/buildcfg.py profile show simple-graphics
tools/buildcfg.py profile show simple-graphics --emit env > build/profile.env
```

The `--emit env` form is the contract with the shell build scripts: it writes
`PROFILE_APK_ADD=( ... )` and the rest as bash arrays, so stage 2 sources one
generated file instead of parsing TOML.

## How a build gets there

```bash
# what a profile resolves to, and what a recipe contains
tools/buildcfg.py profile show simple-graphics
tools/buildcfg.py recipe show simple-graphics-controller

# build every recipe the profile names into packages/ (Alpine container: the
# packer uses abuild's tools)
scripts/05-build-recipes.sh --profile simple-graphics

# then the image, which installs them and records the commits
bash build.sh --profile simple-graphics
```

`build.sh` runs 05 for profiles that name recipes, so the two commands above are
one in practice. 05 keeps its caches under the workspace, all reusable:

```
src/<name>/            the checkout at the recipe's ref
build/chroot/          aarch64 Alpine rootfs with the recipes' makedepends
build/destdir/<name>/  what a recipe installed (the package's file tree)
build/keys/            the signing key pair
packages/              the built .apk files
```

## Adding a recipe

1. Create `recipes/<name>.toml` with the keys above; `name` must equal the file.
2. Pin `ref` to the commit you mean: `git ls-remote <repo> <branch>` for a fresh
   value, or copy it from the checkout you have tested.
3. Add the name to `recipes = [ ... ]` in the profile that should carry it, and
   add any OpenRC service it ships to `services = [ ... ]` in the same profile.
4. Run `tests/buildcfg.sh`.
5. Bumping means editing `ref` (and `version` when upstream released) — a recipe
   in the image manifest is what makes an installed box auditable later.

## Package naming

A recipe becomes `<name>_<version>-r0.apk`, arch `aarch64`, installed by stage 02
from the build's own `packages/` directory. Alpine packages rather than files
copied into the rootfs: ownership and modes come from the package, `apk info`/
`apk del` work on the board, and dependency metadata travels with it.

`tools/mkapk.sh` builds the package with abuild's own stream tools
(`abuild-tar`, `abuild-sign`) rather than a hand-written writer. Three gzip
streams, in this order:

```
.SIGN.RSA.<keyname>   RSA-SHA1 over the compressed control stream
.PKGINFO              the control stream, end-of-archive record cut
payload               the data stream, one sha1 per file
```

The key pair lives in `build/keys/` (gitignored, generated once by 05) and stage
02 copies the public half into the image's `/etc/apk/keys`, so the packages
install as **trusted** — no `--allow-untrusted` anywhere.

Two load-bearing details, both found by testing against apk instead of reading
documentation, and both recorded here because getting them wrong produces only
"BAD archive" or "package file format error":

- the tar flags are `apk_tar` from abuild's `functions.sh`:
  `--format=posix --pax-option=exthdr.name=%d/PaxHeaders/%f,atime:=0,ctime:=0`.
  Without them tar writes its own extended-header naming, apk mis-parses the
  stream, and the package is refused with `-1026 package file format error`.
- the signature stream has to exist at all, and `datahash` is the sha256 of the
  *compressed* data stream. A package without a signature is refused with
  `-74 BAD archive`, which is all apk says about it.
