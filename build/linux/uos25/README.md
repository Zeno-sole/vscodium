# Building VSCodium for UOS 25

This directory adapts the VSCodium build so that `codium_<version>_amd64.deb`
can be produced and validated on UOS 25 (codename `snipe`), the commercial
edition of Deepin 25 (`crimson`).

Validated against VSCodium `1.140.06880` (VS Code `1.140.0`,
commit `07f806f999227108933c2e30515b26eecc1fda74`).

## What differs from the upstream build

Upstream VSCodium builds in GitHub runners that can reach `electronjs.org`,
`nodejs.org`, `api.github.com` and `packages.microsoft.com`. A UOS 25 machine
generally cannot, and the package it produces is wrong for UOS in one
user-visible way. The adaptations are:

1. **`postinst` no longer registers Microsoft's apt repository.**
   Upstream's `resources/linux/debian/postinst.template` writes
   `/etc/apt/sources.list.d/vscode.sources` pointing at
   `https://packages.microsoft.com/repos/code` and installs Microsoft's signing
   key, gated on `if [ "@@NAME@@" != "code-oss" ]` — true for every VSCodium
   build, since the application is renamed to `codium`. On UOS that host is
   unreachable, so installing the stock deb leaves the machine with a source
   list that makes every later `apt update` fail.
   `debian/postinst.template` and `debian/templates.template` in this directory
   are the UOS replacements; `prepare-deb.sh` substitutes them before the deb is
   assembled.

2. **Toolchain downloads are redirected to mirrors.** `build/npm/preinstall.ts`
   runs node-gyp with a `--dist-url` taken from the checked-in `.npmrc`, and
   node-gyp ignores `http_proxy`/`https_proxy`. `configure-mirrors.sh` rewrites
   those dist-urls, and `setup-toolchain-mirror.sh` stages the Electron and Node
   headers (plus the `SHASUMS256.txt` node-gyp insists on) on loopback, because
   the public Chinese mirrors publish their checksum files with the binary-mode
   `*` prefix that node-gyp's parser cannot match.

3. **The build-agent sysroots are staged from a local cache** rather than
   downloaded from `api.github.com` (`stage-sysroots.sh`). On x64 the packaging
   step always uses the glibc-2.28 build-agent toolchain, and the deb dependency
   step downloads the client sysroot a second time.

4. **The pipeline runs in one pass.** Upstream splits compile and package across
   two CI jobs and hands `vscode.tar.gz` between them; `package.sh` is
   `build/linux/package_bin.sh` without the tar hand-off and without the
   `chown -R root:root` that only makes sense inside the CI container.

5. **The dependency install is split in two.** `foundry-local-sdk`'s install
   script fetches about 470 MB of NuGet packages (Foundry Local Core, the CUDA
   ONNX Runtime and ONNX Runtime GenAI) with Node's plain `https.get`, which
   ignores a proxy and is heavily rate limited from a UOS network — the install
   can stall for hours. `compile.sh` therefore extracts the packages without
   running scripts, seeds the native libraries from a local cache
   (`seed-foundry.sh`), and then runs the install scripts with `npm rebuild`.
   The script skips any package whose libraries are already present, so nothing
   else changes.

Nothing about the application itself is changed: same patches, same
`product.json`, same extensions.

## Building

```sh
cd <repo>
. build/linux/uos25/env.sh          # defaults are fine for UOS 25 x64
export RELEASE_VERSION=1.140.06880
export http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890   # GitHub only
export GITHUB_TOKEN=$(gh auth token)                                        # extension downloads
./build/linux/uos25/build-deb.sh
```

The result is `assets/codium_<version>_amd64.deb`.

`http_proxy` is only needed for hosts that are actually blocked — the Electron
binary release, the sysroot tarballs, the chromium clang bundle. Mirrors and
intranet hosts are excluded through `no_proxy` in `env.sh`.

`GITHUB_TOKEN` is required: bundling the marketplace extensions downloads
prebuilt `.vsix` files from `api.github.com`, which answers anonymous requests
with `403`. `build-deb.sh` falls back to `gh auth token` when the variable is
not set.

### Prerequisites

* Node.js 22.x (the `.nvmrc` in the VS Code tree asks for 24; the build sets
  `VSCODE_SKIP_NODE_VERSION_CHECK=1`, and 22 is what UOS 25 ships)
* `jq`, `fakeroot`, `dpkg-dev`, `build-essential`, `python3`
* a Rust toolchain >= 1.85 **with rustup**, for the tunnel CLI. UOS 25 ships
  rustc 1.81 without rustup, which is too old: the CLI crates use edition 2024.
  Install a toolchain with rustup (a mirror such as `rsproxy.cn` works when
  `static.rust-lang.org` is unreachable) and point `UOS25_RUST_BIN` at its
  `cargo/bin`, or set `SHOULD_BUILD_CLI=no` to ship the deb without the tunnel
  CLI — `bin/codium` is a shell wrapper around `resources/app/out/cli.js` and
  works either way.
* the sysroot tarballs in `UOS25_SYSROOT_CACHE` (default
  `/tmp/vscode-amd64-sysroot`), from the `Microsoft/vscode-linux-build-agent`
  release `v20260212-405735`:
  * `x86_64-linux-gnu-glibc-2.28-gcc-10.5.0.tar.gz`
  * `x86_64-linux-gnu-glibc-2.28-gcc-8.5.0.tar.gz`
  * `debian_bullseye_amd64_sysroot.tar.xz` (chromium sysroot, from the Electron
    build CDN; used by the deb dependency step)

### Scripts

| script | purpose |
| --- | --- |
| `env.sh` | build environment (release identity, mirrors, `no_proxy`) |
| `build-deb.sh` | end-to-end: fetch → mirror → compile → package → deb |
| `configure-mirrors.sh` | rewrite the `.npmrc` dist-urls in the VS Code tree |
| `setup-toolchain-mirror.sh` | stage and serve Electron/Node headers on loopback |
| `stage-sysroots.sh` | extract the build-agent and chromium sysroots from the local cache |
| `seed-foundry.sh` | pre-fetch the Foundry Local native libraries for the seed |
| `compile.sh` | brand + compile the workbench (upstream `build.sh`, split install) |
| `package.sh` | build `VSCode-linux-x64` (upstream `package_bin.sh` minus CI glue) |
| `prepare-deb.sh` | assemble the deb with the UOS maintainer scripts |
| `debian/` | UOS `postinst`/`templates` replacements |


## Validating in a UOS 25 pbuilder chroot

The deb is verified inside a clean UOS 25 environment, so that dependency
resolution and the maintainer scripts are exercised against the real UOS
repositories rather than the build host:

```sh
sudo ./build/linux/uos25/pbuilder/create-chroot.sh     # once
./build/linux/uos25/pbuilder/verify-deb.sh assets/codium_*.deb
```

`verify-deb.sh` bind-mounts the deb into the chroot and runs
`verify-in-chroot.sh`, which installs it, checks that every dependency resolves
from the UOS repositories, that the launcher and desktop entry exist, that no
Microsoft apt source was written, and that `apt update` still succeeds
afterwards.

The chroot is created from
`http://pools.uniontech.com/desktop-professional-V25` (`snipe`,
`main community commercial`). Two details are worth remembering:

* `pbuilder --components` is not forwarded to `debootstrap`, so the components
  must be passed as `--debootstrapopts --components=main,community,commercial`.
* The UOS mirror is signed with a key that is not in the public keyrings, so
  `--debootstrapopts --no-check-gpg --allow-untrusted` is required.
