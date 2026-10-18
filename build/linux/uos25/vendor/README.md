# Vendoring the build dependencies

UOS builds run without network access, so everything the build would otherwise
download is fetched once, into a local vendor directory, and read from there.
This directory holds the manifests and the tooling; the data itself goes to
`debian/vendor/`, so that it travels with the source tree.

## Layout

```
debian/vendor/                  $UOS25_VENDOR_DIR, overridable
  shared/                       architecture independent
    git/vscode.git                the VS Code sources
    git/rust/vscode-russh.git     the tunnel CLI's git dependencies
    git/rust/dev-tunnels.git
    npm-cache/                    npm's cache, so `npm ci --offline` works
    cargo/                        CARGO_HOME, so cargo resolves offline
  amd64/                        one directory per architecture
    electron/v43.7.3/             the Electron runtime + its SHASUMS256.txt
                                  + electron.d.ts
    node-headers/electron/...     node-gyp headers (Electron ABI)
    node-headers/node/...         node-gyp headers (Node: v24.21.0 for the server
                                  build, v20.15.1 for dependencies such as
                                  @vscode/fs-copyfile that build against the
                                  running Node)
    foundry/                      Foundry Local NuGet packages
    vsix/                         the built-in extensions
    ripgrep/linux-loong64/rg       only where upstream replaces it
    MANIFEST                      what was fetched, with checksums
  arm64/  loong64/              same shape
```

It is build input, not something to commit: `debian/.gitignore` keeps it out of
git, and `debian/source/options` keeps it out of the source package, so a
`dpkg-source -b` run stays at a few megabytes instead of several gigabytes. A
pbuilder run mounts it into the chroot, since the chroot unpacks the source
somewhere else entirely.

`electron/` and `node-headers/` mirror the URL layout the downloaders use, so
they can be served over loopback unchanged: @electron/get asks for
`<mirror>/<customDir>/<file>`, and node-gyp asks for
`<disturl>/v<version>/node-v<version>-headers.tar.gz` plus the `SHASUMS256.txt`
beside it (which fetch.sh generates).

## Fetching

```sh
./build/linux/uos25/vendor/fetch.sh amd64              # one architecture
./build/linux/uos25/vendor/fetch.sh amd64 arm64 loong64 # all of them
```

Run it where there is network access. It is restartable: anything already
present with the right checksum is left alone. `manifests/<arch>.list` records
`<sha256>  <path>  <url>` per artifact; a sha256 of `-` means "not pinned, record
what we get".

The npm and cargo caches cannot be downloaded - they are produced by building -
so fetch.sh seeds them from the local machine's caches. **Populate each
architecture's vendor set on a machine of that architecture**: the JS packages
and Rust crates are architecture independent, but the optional native prebuilds
in the npm cache are not, and neither is the Electron runtime.

## Building offline

```sh
./build/linux/uos25/build-deb.sh --offline              # on the host
./build/linux/uos25/pbuilder/build.sh --offline         # in a UOS 25 chroot
```

`--offline` sources `build/linux/uos25/offline.sh`, which

* unsets the proxy variables, so an accidental download fails immediately;
* serves the vendor directory over loopback (port 8098) for the downloaders
  that cannot be pointed at a file;
* points @electron/get and node-gyp at it;
* sets `npm_config_offline` and `CARGO_NET_OFFLINE` with the vendored caches;
* maps the git dependencies onto the vendored mirrors through `GIT_CONFIG_*`;
* sets `VSCODE_SKIP_SETUPENV=1`, selecting the host toolchain.

That last point is the one deliberate difference from an online build. The
build-agent toolchain (the glibc-2.28 clang, its sysroots and the libcxx
headers/objects) is not vendored: it is another ~700 MB per architecture and its
download is driven by a script that reads from a hard-coded URL, so skipping it
avoids patching `setup-env.sh`. Compiling against the host toolchain is what you
want for a UOS-only package anyway, and it is what upstream VSCodium already
does for loong64.

## What is verified

amd64 is verified end to end: the package builds inside a network namespace with
no route off the machine and installs in a UOS 25 chroot.

arm64 and loong64 are prepared but not built here - neither architecture is
available on this machine. Their manifests carry the right artifacts for each
(the arm64 Electron, the cross-platform Foundry Local package that arm64 needs
because the GPU one is x86_64-only, loong64's separate Electron build and its
ripgrep replacement), and the vendor layout is parameterised by architecture, but
populating and building them has to happen on those architectures.

## Notes

* `build/rspack` and `build/vite` are dropped from the npm install list for
  offline builds (`build-app.sh` edits `build/npm/dirs.ts`). Their lockfiles
  leave transitive peer dependencies without a resolution, so npm constructs a
  registry URL that was never fetched; nothing in the product build imports
  either directory.
* `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD` and `ELECTRON_SKIP_BINARY_DOWNLOAD` are set
  in `env.sh`. `prepare_vscode.sh` sets them for the compile step, but the
  packaging step runs the same install scripts again through `npm rebuild`, in a
  process that never sourced it - without them the build pulls the Playwright
  browsers.
* A vendor directory is a build input like any other: `fetch.sh` writes a
  `MANIFEST` with the checksum of everything in it, so it can be audited or
  compared between machines.
