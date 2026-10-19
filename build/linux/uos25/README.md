# Building VSCodium for UOS 25

The package is built the standard Debian way: `debian/` sits at the root of the
source tree, so `dpkg-buildpackage` and `pbuilder` both work, and `debian/rules`
drives the VSCodium build itself.

Validated against VSCodium `1.140.06880` (VS Code `1.140.0`,
commit `07f806f999227108933c2e30515b26eecc1fda74`) on UOS 25 (`snipe`, the
commercial edition of Deepin 25).

## Layout

```
debian/                     standard Debian packaging, at the source root
  control                   source + binary package, Build-Depends, Depends
  rules                     runs build/linux/uos25/build-app.sh, installs the tree
  changelog                 1.140.06880, distribution snipe
  codium.postinst           UOS variant - see below
  codium.prerm, codium.postrm
  copyright
  source/format             3.0 (native)
  source/options            keeps build outputs out of the source package
build/linux/uos25/          the UOS 25 build environment and helpers
```

## What differs from the upstream build

Upstream VSCodium builds in GitHub runners that can reach `electronjs.org`,
`nodejs.org`, `api.github.com` and `packages.microsoft.com`. A UOS 25 machine
generally cannot, and the package upstream produces is wrong for UOS in one
user-visible way:

1. **`postinst` no longer registers Microsoft's apt repository.**
   Upstream's postinst writes `/etc/apt/sources.list.d/vscode.sources` pointing
   at `https://packages.microsoft.com/repos/code` and installs Microsoft's
   signing key, gated on `if [ "@@NAME@@" != "code-oss" ]` — true for every
   VSCodium build, since the application is renamed to `codium`. On UOS that
   host is unreachable, so the stock package leaves the machine with a source
   list that makes every later `apt update` fail. `debian/codium.postinst` and
   `debian/codium.postrm` are the UOS replacements, and the package ships no
   debconf templates at all (dpkg rejects a templates file with no stanzas, and
   asking debconf for an undeclared template makes `postrm` exit 255).

2. **Toolchain downloads are redirected to mirrors.** `build/npm/preinstall.ts`
   runs node-gyp with a `--dist-url` taken from the checked-in `.npmrc`, and
   node-gyp ignores `http_proxy`/`https_proxy`. `configure-mirrors.sh` rewrites
   those dist-urls, and `setup-toolchain-mirror.sh` stages the Electron and Node
   headers plus the `SHASUMS256.txt` node-gyp insists on, on loopback — the
   public Chinese mirrors publish their checksum files with the binary-mode `*`
   prefix that node-gyp's parser cannot match.

3. **The build-agent sysroots are staged from a local cache** rather than
   fetched from `api.github.com` (`stage-sysroots.sh`). On x64 the packaging
   step always uses the glibc-2.28 build-agent toolchain, and the deb dependency
   step downloads the client sysroot a second time.

4. **The dependency install is split.** `foundry-local-sdk`'s install script
   pulls about 470 MB of NuGet packages (the CUDA ONNX Runtime and Foundry Local
   native libraries) with Node's plain `https.get`, which ignores a proxy and is
   heavily rate limited from a UOS network — the install can stall for hours.
   `compile.sh` extracts the packages without running scripts, seeds the native
   libraries from a local cache (`seed-foundry.sh`), and then runs the install
   scripts with `npm rebuild`. The script skips any package whose libraries are
   already present, so nothing else changes.

Nothing about the application itself is changed: same patches, same
`product.json`, same extensions.

## Building on the host

```sh
sudo apt-get install -y rustup          # satisfies the rustc>=1.85 build dep
export RELEASE_VERSION=1.140.06880
export GITHUB_TOKEN=$(gh auth token)    # extension downloads
export UOS25_RUST_BIN=/path/to/rustup/cargo/bin   # rust >= 1.85 for the tunnel CLI
export http_proxy=http://127.0.0.1:7890 https_proxy=http://127.0.0.1:7890
./build/linux/uos25/build-deb.sh
```

The result is `assets/codium_1.140.06880_amd64.deb`.

`build-deb.sh` wraps `dpkg-buildpackage -b -us -uc`, which runs
`debian/rules build` (→ `build/linux/uos25/build-app.sh`) and then
`debian/rules binary` (→ install into `debian/codium`, `dh_builddeb`). Pass
`--clean` for a from-scratch build; by default `-nc` is used and an already
built `VSCode-linux-x64/` is reused.

## Building offline (vendored dependencies)

UOS builds run without network access. Everything the build downloads is fetched
once into `debian/vendor/`, where it travels with the source tree and is reused
by every later build:

```sh
./build/linux/uos25/vendor/fetch.sh amd64            # once, where there is network
./build/linux/uos25/build-deb.sh --offline           # host
./build/linux/uos25/pbuilder/build.sh --offline      # UOS 25 chroot
```

`offline.sh` points every downloader at the vendor directory (serving it over
loopback for the ones that need an HTTP URL), turns on `npm`/`cargo` offline
modes, maps the git dependencies onto vendored mirrors, and selects the host
toolchain. `env.sh` sources it automatically whenever `debian/vendor` exists, so
the internal build platform - which has no external network and no way to pass
options to the build - gets the same behaviour from a plain `dpkg-buildpackage`;
`UOS25_USE_VENDOR=no` opts out. The data is several gigabytes per architecture
and is deliberately not committed (`debian/.gitignore`), but it *is* shipped in
the source package: see [vendor/README.md](vendor/README.md) for the layout, the
per-architecture manifests, and why the source package has to carry it.

amd64 is verified end to end: the package builds inside a network namespace with
no route off the machine, and installs in a UOS 25 chroot. arm64 and loong64 are
parameterised - each manifest carries that architecture's Electron, its node-gyp
headers, its Foundry Local variant and, for loong64, its ripgrep replacement -
but populating and building them has to happen on those architectures.

## Building inside a UOS 25 pbuilder chroot

```sh
sudo ./build/linux/uos25/pbuilder/create-chroot.sh    # once
./build/linux/uos25/pbuilder/build.sh
```

This creates the source package with `dpkg-source -b` and hands the `.dsc` to
pbuilder, which runs `debian/rules` inside the chroot, so the whole build happens
in a clean UOS 25 environment. The result lands in `assets/`.

Several things have to be arranged around the chroot, because pbuilder runs the
build as its own unprivileged user with a minimal environment:

* **nodejs.** The archive's nodejs 20.15.1 and npm 9.2.0 satisfy
  `Build-Depends: nodejs (>= 20)` on their own, so the chroot needs nothing
  added: the Node 22 features the VS Code build tooling uses
  (`--experimental-strip-types`, `import.meta.main`) come from the loader in
  [node20/](node20/README.md). `pbuilder/hooks/D10nodejs` refreshes the package
  lists so the archive's current nodejs is visible to that resolution, and adds
  the NodeSource `node_22.x` repository instead when `UOS25_PB_NODE22=yes` — the
  reference build host uses nodejs 22, but that needs deb.nodesource.com, which
  a UOS network cannot reach. The signing key is taken from the build host when
  it already has one, because fetching it through the proxy is unreliable.
* **`fetch()` in the archive's nodejs.** UOS 25's `node-undici` ships llhttp's
  wasm as three separately padded base64 chunks concatenated into one string, and
  Node's base64 decoder stops at the first `=` — so it compiles 25711 bytes of a
  58593-byte module and every `fetch()` in the archive's nodejs fails with a
  WebAssembly `CompileError`. The payload appears twice, in
  `lib/llhttp/llhttp-wasm.js` and inlined in `undici-fetch.js`, which is the copy
  libnode is compiled to load
  (`NODE_SHARED_BUILTIN_UNDICI_UNDICI_PATH`). The build needs `fetch()` to work
  even though it has no network — several steps call it and tolerate the network
  error, but not a WebAssembly error — so
  [node20/llhttp-shim.mjs](node20/llhttp-shim.mjs) hands WebAssembly the intact
  copy the package also installs, in process, through `NODE_OPTIONS`. It needs no
  root, which is what makes it work on the internal platform; repairing the
  installed file would need root there.
* **`npm ls` output.** `build/lib/dependencies.ts` runs `npm ls --all --omit=dev`
  and, when it fails, filters its stderr against a small allowlist. That allowlist
  is matched against npm's old `npm ERR!` prefix; npm 10 prints `npm error`, so the
  loop matches nothing and every failure is tolerated — which is what upstream's
  build relies on. The archive's npm 9 does print `npm ERR!`, and then the
  lockfile's own `@microsoft/dev-tunnels-ssh` peer mismatch (3.12.22 pinned against
  a `^3.12.42` peer requirement) becomes fatal.
  `patches/00-build-tolerate-npm9-ls-output.patch` drops the version-dependent
  check and uses the output either way, so both npm versions behave the same.
* **Environment variables.** pbuilder does not pass them in, so `build.sh`
  writes what the build needs — the HTTP proxy, `GITHUB_TOKEN`, `UOS25_RUST_BIN`,
  `HOME`, `XDG_CACHE_HOME`, `CARGO_HOME` and the git mirror mappings — to
  `/tmp/uos25-buildenv/build.env` and bind-mounts that directory; `env.sh`
  sources it. Note that `sudo` resets the environment, so `build.sh` elevates
  only the pbuilder call and refuses to run as root itself.
* **Writable caches.** The chroot's build user (uid 1234) does not own anything
  under the invoking user's home, so the Electron and cargo caches are staged
  into writable copies under `/tmp` rather than mounted where they live. `HOME`
  is set to `/tmp` for the same reason, and `npm_config_devdir` keeps node-gyp
  from falling back to a temporary directory (which loses the electron target).
* **Git mirrors.** The VS Code fetch is several hundred megabytes and the tunnel
  CLI has two git dependencies; none of those transfers survive this proxy.
  `build.sh` bind-mounts local mirrors (`/tmp/vscode-mirror.git`,
  `/tmp/rust-git-mirrors`) and maps the upstream URLs onto them through
  `GIT_CONFIG_*`, so nothing is written to a git config file.
* **Build place.** pbuilder builds in `/var/cache/pbuilder/build`, which is only
  a few GB on a desktop install; this build needs more, so
  `--buildplace /tmp/pbuilder-build` is used.
* **The tunnel CLI is skipped by default.** It is Rust with edition-2024 crates,
  so it needs a toolchain ≥ 1.85 *with cargo and rustup*; the UOS archive has
  rustc-1.95 (not on `PATH`), cargo 1.81 — too old to read an edition-2024
  manifest — and no rustup, and a build with no external network cannot fetch a
  toolchain. `debian/rules` therefore defaults `SHOULD_BUILD_CLI` to `no`, which
  is how every verified package has been built. `bin/codium` is a shell wrapper
  around `resources/app/out/cli.js` and does not need it. Set
  `UOS25_PB_BUILD_CLI=yes` (with `UOS25_RUST_BIN` pointing at a rustup toolchain)
  to attempt it in the chroot anyway.

`UOS25_PB_NO_CACHES=yes` builds without any of the staged caches and mirrors,
which is what a genuinely cold build would do.

## Building on the internal platform

The internal build platform fetches `codium_1.140.06880.dsc` and its tarball, runs
`pbuilder --build` with its own configuration, and never sees this repository or
the machine it was built on - so the source package is the entire input, and it has
no external network. Everything the build would otherwise download therefore has to
be inside it:

* `debian/vendor/` travels in the tarball (`debian/source/options` deliberately
  does not ignore it), which is why the source package is about 2.8 GB;
* `env.sh` switches the build to those dependencies by itself whenever
  `debian/vendor` is there, so a plain `dpkg-buildpackage` behaves like `--offline`;
* pbuilder unpacks the source as its build user, so the npm and cargo caches in
  the vendor come out writable and need no staging;
* that platform runs the build with `HOME=/nonexistent`; `env.sh` points `HOME`,
  `XDG_CACHE_HOME` and node-gyp's devdir at a writable directory in that case.

The hooks under `pbuilder/hooks/` are **not** used there - the platform brings its
own pbuilder configuration - so nothing the build needs may live in a hook. That is
why the archive's broken `fetch()` is worked around in process
(`node20/llhttp-shim.mjs`) rather than by repairing the installed file, which would
need root.

To build the package the way the platform does:

```sh
dpkg-source -b .
sudo pbuilder --build --basetgz /var/cache/pbuilder/uos25-snipe-amd64.tgz \
  --buildplace /tmp/pbuilder-build --allow-untrusted --use-network yes \
  --aptcache '' --buildresult /tmp/result --debbuildopts -b \
  ../codium_1.140.06880.dsc
```

No `--hookdir`, no `--bindmounts`, no `--offline`: if that produces a `.deb`, the
source package is self-contained.

## Verifying the deb

```sh
./build/linux/uos25/pbuilder/verify-deb.sh assets/codium_*.deb
```

Bind-mounts the deb into the chroot and runs `pbuilder/verify-in-chroot.sh`,
which installs it, checks that every dependency resolves from the UOS
repositories, that the launcher and desktop entry exist, that no Microsoft apt
source was written, and that `apt update` still succeeds afterwards.

## Prerequisites for a host build

* Node.js 20 or newer. The archive's 20.15.1 is enough — `node20/` supplies what
  the tooling needs from 22 — and so is the 22 a developer machine tends to have.
* `jq`, `fakeroot`, `dpkg-dev`, `debhelper`, `build-essential`, `python3`
* a Rust toolchain >= 1.85 with rustup, only if you want the tunnel CLI. The UOS
  archive cannot provide one (rustc-1.95 is there but cargo is 1.81 and cannot
  read an edition-2024 manifest), so `SHOULD_BUILD_CLI` defaults to `no` and the
  package ships without `codium-tunnel`. To include it, install a toolchain with
  rustup (a mirror such as `rsproxy.cn` works when `static.rust-lang.org` is
  unreachable), point `UOS25_RUST_BIN` at its `cargo/bin` and pass
  `SHOULD_BUILD_CLI=yes`. `bin/codium` is a shell wrapper around
  `resources/app/out/cli.js` and works either way.
* the sysroot tarballs in `UOS25_SYSROOT_CACHE` (default
  `/tmp/uos25-sysroots`), from the `Microsoft/vscode-linux-build-agent`
  release `v20260212-405735`:
  * `x86_64-linux-gnu-glibc-2.28-gcc-10.5.0.tar.gz`
  * `x86_64-linux-gnu-glibc-2.28-gcc-8.5.0.tar.gz`
  * `debian_bullseye_amd64_sysroot.tar.xz` (chromium sysroot, from the Electron
    build CDN)

## Scripts

| script | purpose |
| --- | --- |
| `env.sh` | build environment (release identity, mirrors, `no_proxy`) |
| `build-app.sh` | fetch → mirror → compile → package; called by `debian/rules` |
| `build-deb.sh` | `dpkg-buildpackage` wrapper (`--clean`, `--source`) |
| `configure-mirrors.sh` | rewrite the `.npmrc` dist-urls in the VS Code tree |
| `setup-toolchain-mirror.sh` | stage and serve Electron/Node headers on loopback |
| `stage-sysroots.sh` | extract the build-agent and chromium sysroots from the local cache |
| `seed-foundry.sh` | pre-fetch the Foundry Local native libraries for the seed |
| `compile.sh` | brand + compile the workbench (upstream `build.sh`, split install) |
| `package.sh` | build `VSCode-linux-x64` (upstream `package_bin.sh` minus CI glue) |
| `offline.sh` | point a build at a local vendor directory (no network) |
| `vendor/fetch.sh` | populate the vendor directory for one or more architectures |
| `vendor-vsix.sh` | point `product.json`'s built-in extensions at vendored `.vsix` |
| `pbuilder/create-chroot.sh` | create the UOS 25 base tarball |
| `pbuilder/build.sh` | source package + `pbuilder --build` |
| `pbuilder/verify-deb.sh` | install and check the deb in the chroot |
| `pbuilder/hooks/D10nodejs` | refresh the chroot's package lists; add nodejs 22 only on request |

### UOS 25 repository details

The chroot is created from
`http://pools.uniontech.com/desktop-professional-V25` (`snipe`,
`main community commercial`). Two details are worth remembering:

* `pbuilder --components` is not forwarded to `debootstrap`, so the components
  must be passed as `--debootstrapopts --components=main,community,commercial`.
  `linux-libc-dev` only lives in `commercial`, and without it
  `build-essential` fails to configure.
* The UOS mirror is signed with a key that is not in the public keyrings, so
  `--debootstrapopts --no-check-gpg --allow-untrusted` is required.

Note also that `libasound2t64` and `libgtk-3-0t64` do not exist on UOS 25 (it
has `libasound2` and `libgtk-3-0`); `debian/control` lists the plain names first
so the dependency resolves there.
