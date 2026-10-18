#!/usr/bin/env bash
# Build the .deb inside a clean UOS 25 pbuilder chroot.
#
#   sudo ./build/linux/uos25/pbuilder/create-chroot.sh    # once
#   ./build/linux/uos25/pbuilder/build.sh
#
# The source package is created with `dpkg-buildpackage -S` and handed to
# pbuilder, which runs debian/rules inside the chroot - the standard "build in a
# clean environment" flow. debian/rules drives build/linux/uos25/build-app.sh
# and installs the result, so the chroot performs the whole build.
#
# The UOS 25 archive provides everything the build needs - nodejs 20.15.1 and
# npm 9.2.0 satisfy the declared Build-Depends, with build/linux/uos25/node20/
# supplying the Node 22 features the VS Code tooling uses - so the hooks in
# hooks/ only have to refresh the package lists (D10nodejs) and repair the
# archive's truncated node-undici, which breaks fetch() (A10undici). What does
# have to be arranged around the chroot is the caches, by bind mounts:
#
#   * the toolchain caches. Fetching the VS Code sources, the npm packages, the
#     Electron binary and the build-agent sysroots from scratch inside the
#     chroot takes well over an hour and a lot of bandwidth, so the host caches
#     are bind-mounted (see BIND_MOUNTS below). Set UOS25_PB_NO_CACHES=yes to
#     build without them.
#
#   * for --offline, the vendor directory. It is bind-mounted read-mostly, and
#     the npm cache - the one part of it the build writes into - is staged as a
#     writable copy first, because it belongs to the invoking user while the
#     chroot builds as somebody else.

set -eo pipefail

# This script elevates only the pbuilder call. Running the whole script under
# sudo would strip the environment - sudo resets it by default - and the proxy,
# token and Rust paths below would silently end up empty.
if [[ "${EUID}" -eq 0 ]]; then
  echo "error: run this as your normal user, not with sudo" >&2
  echo "       (it elevates only the pbuilder call; sudo would drop the environment)" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "${ROOT}"

# --offline builds from debian/vendor and needs no network at all. The vendor
# directory is bind-mounted because it lives in the source tree, which
# debian/source/options keeps out of the source package.
OFFLINE=no
for arg in "$@"; do
  case "${arg}" in
    --offline) OFFLINE=yes ;;
    -h|--help)
      sed -n '2,24p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

# pbuilder needs root. When UOS25_SUDO_PASSWORD is set it is fed to `sudo -S`,
# which is what an unattended run needs; otherwise plain sudo is used and the
# caller has to have a valid sudo timestamp. The password is only ever read
# from the environment.
run_root() {
  if [[ -n "${UOS25_SUDO_PASSWORD:-}" ]]; then
    printf '%s\n' "${UOS25_SUDO_PASSWORD}" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

BASETGZ="${UOS25_BASETGZ:-/var/cache/pbuilder/uos25-snipe-amd64.tgz}"
HOOKDIR="${ROOT}/build/linux/uos25/pbuilder/hooks"
RESULT_DIR="${ROOT}/assets"
# pbuilder unpacks the chroot and builds in /var/cache/pbuilder/build, which is
# small on a desktop install (a few GB) and cannot hold this build - the VS Code
# tree, its node_modules and the packaged application add up to several GB.
# Default to a directory on the same filesystem as /tmp instead.
BUILDPLACE="${UOS25_PB_BUILDPLACE:-/tmp/pbuilder-build}"
SYSROOT_CACHE="${UOS25_SYSROOT_CACHE:-/tmp/uos25-sysroots}"
FOUNDRY_SEED="${UOS25_FOUNDRY_SEED:-/tmp/foundry-seed}"
FOUNDRY_NUPKGS="${UOS25_FOUNDRY_NUPKG_DIR:-/tmp/foundry-nupkgs}"
TOOLCHAIN_DIR="${UOS25_TOOLCHAIN_DIR:-/tmp/vscode-toolchain}"

if [[ ! -f "${BASETGZ}" ]]; then
  echo "error: ${BASETGZ} not found - run create-chroot.sh first" >&2
  exit 1
fi

echo "== creating source package =="
# dpkg-source rather than `dpkg-buildpackage -S`: the latter runs
# `debian/rules clean` first, which would delete the host's VSCode-linux-<arch>
# tree and assets/ for no reason.
cd "${ROOT}"
dpkg-source -b .
DSC="$(ls -1t "${ROOT}"/../codium_*.dsc | head -1)"
echo "   ${DSC}"

# pbuilder cannot pass environment variables into the chroot, so the settings
# the build needs there - notably the HTTP proxy for the GitHub fetches - are
# written to a file and bind-mounted; build/linux/uos25/env.sh sources it.
#
# It is removed again on exit: env.sh sources this path unconditionally, so a
# leftover copy would leak chroot settings (HOME=/tmp in particular) into an
# ordinary host build.
BUILD_ENV_DIR="/tmp/uos25-buildenv"
mkdir -p "${BUILD_ENV_DIR}"
trap 'rm -rf "${BUILD_ENV_DIR}"' EXIT
: > "${BUILD_ENV_DIR}/build.env"
for var in http_proxy https_proxy GITHUB_TOKEN UOS25_RUST_BIN RUSTUP_HOME CARGO_HOME; do
  if [[ -n "${!var:-}" ]]; then
    printf 'export %s=%q\n' "${var}" "${!var}" >> "${BUILD_ENV_DIR}/build.env"
  fi
done
# Offline: build-app.sh sources offline.sh, which reads the vendored
# dependencies from this directory. It has to be an absolute path, because the
# chroot unpacks the source somewhere else entirely.
if [[ "${OFFLINE}" == "yes" ]]; then
  VENDOR_DIR="${UOS25_VENDOR_DIR:-${ROOT}/debian/vendor}"
  if [[ ! -d "${VENDOR_DIR}" ]]; then
    echo "error: --offline needs a vendor directory, and ${VENDOR_DIR} does not exist" >&2
    echo "       run: build/linux/uos25/vendor/fetch.sh amd64" >&2
    exit 1
  fi
  echo "== offline: vendor directory ${VENDOR_DIR} =="
  printf 'export %s=%q\n' UOS25_USE_VENDOR yes >> "${BUILD_ENV_DIR}/build.env"
  printf 'export %s=%q\n' UOS25_VENDOR_DIR "${VENDOR_DIR}" >> "${BUILD_ENV_DIR}/build.env"
fi
# The package mirrors are reachable directly and must not be routed through the
# proxy, so they are appended to whatever no_proxy the build host already
# defines rather than replacing it. github.com deliberately stays on the proxy:
# the tunnel CLI has a git dependency on github.com/microsoft/vscode-russh.
printf 'export %s=%q\n' no_proxy \
  "${no_proxy:-},localhost,127.0.0.1,registry.npmmirror.com,npmmirror.com,registry.npmjs.org,crates.io,static.crates.io,index.crates.io" \
  >> "${BUILD_ENV_DIR}/build.env"
# libcurl, which cargo uses, reads the upper-case name.
printf 'export %s=%q\n' NO_PROXY \
  "${no_proxy:-},localhost,127.0.0.1,registry.npmmirror.com,npmmirror.com,registry.npmjs.org,crates.io,static.crates.io,index.crates.io" \
  >> "${BUILD_ENV_DIR}/build.env"
# CARGO_HOME points at the build host's registry, which the chroot's build user
# cannot write to. A staged, writable one is mounted instead. It carries the
# host's cached crates and git dependencies - the tunnel CLI has git
# dependencies on github.com, and those transfers are slow and unreliable
# through this proxy - plus a cargo config pointing at a crates mirror, because
# static.crates.io transfers at a few KB/s from here.
CARGO_HOME_MOUNT="/tmp/uos25-cargo"
CARGO_MIRROR="${UOS25_CARGO_MIRROR:-https://mirrors.ustc.edu.cn/crates.io-index/}"
CARGO_HOME_HOST="${UOS25_CARGO_HOME_HOST:-${HOME}/.cargo}"
echo "== staging the cargo cache for the chroot =="
mkdir -p "${CARGO_HOME_MOUNT}/registry"
for d in git registry/index registry/cache; do
  if [[ -d "${CARGO_HOME_HOST}/${d}" ]]; then
    mkdir -p "${CARGO_HOME_MOUNT}/${d}"
    cp -a "${CARGO_HOME_HOST}/${d}/." "${CARGO_HOME_MOUNT}/${d}/"
  fi
done
cat > "${CARGO_HOME_MOUNT}/config.toml" <<EOF
# Written by build/linux/uos25/pbuilder/build.sh
# static.crates.io and the crates.io sparse index transfer at a few KB/s from
# here, so the registry is replaced with a mirror. git dependencies are not
# affected: they are resolved through the local mirrors set up with
# GIT_CONFIG_* above, and git-fetch-with-cli makes cargo go through git for them.
[source.crates-io]
replace-with = "mirror"

[source.mirror]
registry = "sparse+${CARGO_MIRROR}"

[net]
git-fetch-with-cli = true
EOF
chmod -R a+rwX "${CARGO_HOME_MOUNT}"
BIND_MOUNTS+=(--bindmounts "${CARGO_HOME_MOUNT}")
printf 'export %s=%q\n' CARGO_HOME "${CARGO_HOME_MOUNT}" >> "${BUILD_ENV_DIR}/build.env"
# offline.sh reads the vendor directory instead of CARGO_HOME when it is
# sourced; this is what tells it that a writable copy has already been staged.
printf 'export %s=%q\n' UOS25_CARGO_HOME "${CARGO_HOME_MOUNT}" >> "${BUILD_ENV_DIR}/build.env"
# Cargo's HTTP/2 multiplexing fails through this proxy ("Error in the HTTP2
# framing layer"); HTTP/1.1 does not.
printf 'export %s=%q\n' CARGO_HTTP_MULTIPLEXING "false" >> "${BUILD_ENV_DIR}/build.env"
# The tunnel CLI needs cargo to resolve two git dependencies and the crates.io
# index, and those transfers do not get through this network reliably - cargo
# gives up with "transfer too slow". The chroot build therefore skips it by
# default; set UOS25_PB_BUILD_CLI=yes to attempt it anyway. bin/codium itself is
# a shell wrapper around resources/app/out/cli.js and does not need it, and the
# host build (build/linux/uos25/build-deb.sh) does produce it.
printf 'export %s=%q\n' SHOULD_BUILD_CLI "${UOS25_PB_BUILD_CLI:-no}" >> "${BUILD_ENV_DIR}/build.env"
# pbuilder runs the build as its own unprivileged user (uid 1234 by default)
# with HOME=/nonexistent, and npm needs a writable home and cache. The host's
# npm cache is deliberately not mounted: it is owned by the invoking user, which
# is not the build user, so npm could not write to it.
printf 'export %s=%q\n' HOME "/tmp" >> "${BUILD_ENV_DIR}/build.env"
printf 'export %s=%q\n' npm_config_cache "/tmp/npm-cache" >> "${BUILD_ENV_DIR}/build.env"
# XDG_CACHE_HOME below points at the build host's cache, which the chroot's
# build user cannot write to. node-gyp would notice, fall back to a temporary
# dev dir and in doing so lose the electron target, so give it a writable one
# up front.
printf 'export %s=%q\n' npm_config_devdir "/tmp/.node-gyp" >> "${BUILD_ENV_DIR}/build.env"
echo "== build environment passed to the chroot =="
sed 's/^\(GITHUB_TOKEN=\).*/\1<set>/' "${BUILD_ENV_DIR}/build.env"

BIND_MOUNTS=(--bindmounts "${BUILD_ENV_DIR}")

# Offline builds read every build input from the vendor directory, which lives in
# the source tree; the chroot unpacks the source elsewhere, so it is mounted at
# the absolute path the environment points at. pbuilder itself still needs the
# network here, but only to provision the chroot (its build dependencies) - the
# build does not touch it.
if [[ "${OFFLINE}" == "yes" ]]; then
  echo "== offline: mounting the vendor directory into the chroot =="
  BIND_MOUNTS+=(--bindmounts "${VENDOR_DIR}")

  # npm writes into its cache directory - the debug log, the unpacked tarballs
  # it stages before renaming them into place - so the vendor's copy cannot be
  # used directly: it belongs to the invoking user, and the chroot builds as
  # somebody else. A writable copy is staged once and reused, which keeps the
  # vendor directory intact as build input.
  VENDOR_NPM_CACHE="${VENDOR_DIR}/shared/npm-cache"
  NPM_CACHE_MOUNT="${UOS25_PB_NPM_CACHE:-/tmp/uos25-npm-cache}"
  if [[ -d "${VENDOR_NPM_CACHE}" ]]; then
    if [[ ! -d "${NPM_CACHE_MOUNT}" ]] || \
       [[ -n "$(find "${VENDOR_NPM_CACHE}" -newer "${NPM_CACHE_MOUNT}/.staged" -print -quit 2>/dev/null)" ]]; then
      echo "== staging the npm cache for the chroot (this copies a few GB, once) =="
      rm -rf "${NPM_CACHE_MOUNT}"
      mkdir -p "${NPM_CACHE_MOUNT}"
      cp -a "${VENDOR_NPM_CACHE}/." "${NPM_CACHE_MOUNT}/"
      chmod -R a+rwX "${NPM_CACHE_MOUNT}"
      touch "${NPM_CACHE_MOUNT}/.staged"
    else
      echo "== reusing the staged npm cache: ${NPM_CACHE_MOUNT} =="
    fi
    BIND_MOUNTS+=(--bindmounts "${NPM_CACHE_MOUNT}")
    printf 'export %s=%q\n' UOS25_NPM_CACHE "${NPM_CACHE_MOUNT}" >> "${BUILD_ENV_DIR}/build.env"
  else
    echo "warning: ${VENDOR_NPM_CACHE} not found; the chroot cannot install npm packages offline" >&2
  fi
fi

# Local git mirrors. build-app.sh maps github.com/Microsoft/vscode through
# GIT_CONFIG_* so the several-hundred-megabyte fetch does not have to survive the
# proxy; the same mechanism covers the tunnel CLI's two git dependencies, which
# cargo would otherwise have to fetch from github.com.
GIT_MIRROR_URLS=()
GIT_MIRROR_PATHS=()
add_git_mirror() {
  GIT_MIRROR_URLS+=("$1")
  GIT_MIRROR_PATHS+=("$2")
}

# A dedicated mirror outside the build tree is preferred; the checkout inside
# the tree is a fallback, but `debian/rules clean` removes vscode/, so it
# disappears as soon as the tree is cleaned.
VSCODE_MIRROR_PATH=""
for candidate in "${UOS25_VSCODE_MIRROR_PATH:-/tmp/vscode-mirror.git}" "${ROOT}/vscode/.git"; do
  if [[ -d "${candidate}/objects" ]]; then
    VSCODE_MIRROR_PATH="${candidate}"
    break
  fi
done
if [[ -n "${VSCODE_MIRROR_PATH}" ]]; then
  echo "== VS Code mirror for the chroot: ${VSCODE_MIRROR_PATH} =="
  BIND_MOUNTS+=(--bindmounts "${VSCODE_MIRROR_PATH}")
  add_git_mirror "https://github.com/Microsoft/vscode.git" "${VSCODE_MIRROR_PATH}"
else
  echo "warning: no local VS Code mirror found; the chroot will fetch from github.com" >&2
fi

RUST_GIT_MIRRORS="${UOS25_RUST_GIT_MIRRORS:-/tmp/rust-git-mirrors}"
if [[ -d "${RUST_GIT_MIRRORS}/vscode-russh.git" && -d "${RUST_GIT_MIRRORS}/dev-tunnels.git" ]]; then
  echo "== rust git dependency mirrors: ${RUST_GIT_MIRRORS} =="
  BIND_MOUNTS+=(--bindmounts "${RUST_GIT_MIRRORS}")
  add_git_mirror "https://github.com/microsoft/vscode-russh" "${RUST_GIT_MIRRORS}/vscode-russh.git"
  add_git_mirror "https://github.com/microsoft/dev-tunnels" "${RUST_GIT_MIRRORS}/dev-tunnels.git"
fi

if [[ ${#GIT_MIRROR_URLS[@]} -gt 0 ]]; then
  printf 'export GIT_CONFIG_COUNT=%d\n' "${#GIT_MIRROR_URLS[@]}" >> "${BUILD_ENV_DIR}/build.env"
  for i in "${!GIT_MIRROR_URLS[@]}"; do
    printf 'export GIT_CONFIG_KEY_%d=%q\n' "${i}" "url.${GIT_MIRROR_PATHS[$i]}.insteadOf" >> "${BUILD_ENV_DIR}/build.env"
    printf 'export GIT_CONFIG_VALUE_%d=%q\n' "${i}" "${GIT_MIRROR_URLS[$i]}" >> "${BUILD_ENV_DIR}/build.env"
  done
fi
# @electron/get fetches the Electron binary, the libcxx headers/objects and the
# matching SHASUMS256.txt. Those are all in the build host's cache already, and
# fetching them again inside the chroot has proven unreliable, so the cache is
# mounted and pointed at. The cache root comes from env-paths, i.e. from
# XDG_CACHE_HOME (ELECTRON_CACHE is not read by this version).
#
# A writable copy is mounted rather than the cache itself: @electron/get writes
# new entries into it, and the chroot's build user is not the cache's owner.
ELECTRON_CACHE_HOST="${ELECTRON_CACHE:-${HOME}/.cache/electron}"
CACHE_ROOT_MOUNT="/tmp/uos25-cache"
ELECTRON_CACHE_MOUNT="${CACHE_ROOT_MOUNT}/electron"
if [[ -d "${ELECTRON_CACHE_HOST}" ]]; then
  echo "== staging the Electron cache for the chroot =="
  # The chroot writes its own caches (playwright, js-v8flags, ...) next to this
  # one, and those entries are owned by the chroot's build user, so chmod can
  # legitimately fail on them.
  rm -rf "${CACHE_ROOT_MOUNT}/js-v8flags" "${CACHE_ROOT_MOUNT}/ms-playwright" 2>/dev/null || true
  mkdir -p "${ELECTRON_CACHE_MOUNT}"
  cp -a "${ELECTRON_CACHE_HOST}/." "${ELECTRON_CACHE_MOUNT}/"
  chmod -R a+rwX "${CACHE_ROOT_MOUNT}" 2>/dev/null || true
  BIND_MOUNTS+=(--bindmounts "${CACHE_ROOT_MOUNT}")
  printf 'export %s=%q\n' XDG_CACHE_HOME "${CACHE_ROOT_MOUNT}" >> "${BUILD_ENV_DIR}/build.env"
  printf 'export %s=%q\n' ELECTRON_CACHE "${ELECTRON_CACHE_MOUNT}" >> "${BUILD_ENV_DIR}/build.env"
fi
# The NodeSource signing key: fetching it inside the chroot goes through the
# proxy and fails often, so the build host's copy is mounted over it.
if [[ -f /usr/share/keyrings/nodesource.gpg ]]; then
  BIND_MOUNTS+=(--bindmounts /usr/share/keyrings/nodesource.gpg)
fi
# The rustup toolchain is just files, so the host's is bind-mounted instead of
# being reinstalled into the chroot on every build (the UOS archive's rustc is
# 1.81, too old for the tunnel CLI's edition-2024 crates).
if [[ -n "${RUSTUP_HOME:-}" && -d "${RUSTUP_HOME}" ]]; then
  BIND_MOUNTS+=(--bindmounts "${RUSTUP_HOME}")
fi
if [[ -n "${UOS25_RUST_BIN:-}" && -d "${UOS25_RUST_BIN}" ]]; then
  BIND_MOUNTS+=(--bindmounts "$(dirname "${UOS25_RUST_BIN}")")
fi
if [[ "${UOS25_PB_NO_CACHES:-no}" != "yes" ]]; then
  # node-gyp header mirror: the loopback server on the host is reachable from
  # the chroot because pbuilder shares the host network namespace.
  bash build/linux/uos25/setup-toolchain-mirror.sh >/dev/null
  for d in "${SYSROOT_CACHE}" "${FOUNDRY_SEED}" "${FOUNDRY_NUPKGS}" "${TOOLCHAIN_DIR}"; do
    if [[ -d "${d}" ]]; then
      BIND_MOUNTS+=(--bindmounts "${d}")
    fi
  done
fi

mkdir -p "${RESULT_DIR}"

echo "== pbuilder build =="
mkdir -p "${BUILDPLACE}"
run_root pbuilder --build \
  --basetgz "${BASETGZ}" \
  --buildplace "${BUILDPLACE}" \
  --allow-untrusted \
  --use-network yes \
  --hookdir "${HOOKDIR}" \
  --aptcache "" \
  --buildresult "${RESULT_DIR}" \
  --debbuildopts -b \
  "${BIND_MOUNTS[@]}" \
  "${DSC}"

echo "== done =="
ls -l "${RESULT_DIR}"/*.deb
