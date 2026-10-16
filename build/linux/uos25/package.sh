#!/usr/bin/env bash
# Package the compiled workbench into ../VSCode-linux-<arch>.
#
# This is build/linux/package_bin.sh without the two steps that only exist for
# the split CI jobs: extracting vscode.tar.gz (the compile job already left the
# tree in place) and `chown -R root:root vscode` (which needs root and is not
# required when the deb is assembled by the same user).
#
# Expects: build.sh has already run in this tree, and build/linux/uos25/env.sh
# has been sourced.

# Note: no `-u` - several upstream variables (VSCODE_SKIP_SETUPENV,
# VSCODE_SKIP_SYSROOT, IGNORE_ELECTRON_VERSION) are legitimately unset.
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${ROOT}/vscode"

export VSCODE_PLATFORM='linux'
export VSCODE_SKIP_NODE_VERSION_CHECK=1
export VSCODE_SYSROOT_PREFIX="${VSCODE_SYSROOT_PREFIX:--glibc-2.28-gcc-10.5.0}"

if [[ "${VSCODE_ARCH}" == "arm64" ]]; then
  export VSCODE_SKIP_SYSROOT=1
elif [[ "${VSCODE_ARCH}" == "ppc64le" ]]; then
  export VSCODE_SYSROOT_REPOSITORY='VSCodium/vscode-linux-build-agent'
  export VSCODE_SYSROOT_VERSION='20260706'
  export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  export VSCODE_ELECTRON_REPOSITORY='lex-ibm/electron-ppc64le-build-scripts'
  export IGNORE_ELECTRON_VERSION="yes"
elif [[ "${VSCODE_ARCH}" == "riscv64" ]]; then
  export VSCODE_ELECTRON_REPOSITORY='riscv-forks/electron-riscv-releases'
  export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  export VSCODE_SKIP_SETUPENV=1
elif [[ "${VSCODE_ARCH}" == "loong64" ]]; then
  export VSCODE_ELECTRON_REPOSITORY='darkyzhou/electron-loong64'
  export ELECTRON_SKIP_BINARY_DOWNLOAD=1
  export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  export VSCODE_SKIP_SETUPENV=1
fi

if [[ -f "../build/linux/${VSCODE_ARCH}/electron.sh" ]]; then
  echo "" >> build/checksums/electron.txt

  if [[ -f "../build/linux/${VSCODE_ARCH}/electron.sha256sums" ]]; then
    cat "../build/linux/${VSCODE_ARCH}/electron.sha256sums" >> build/checksums/electron.txt
  fi

  # shellcheck disable=SC1090
  source "../build/linux/${VSCODE_ARCH}/electron.sh"

  TARGET=$( grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' .npmrc )

  if [[ "${ELECTRON_VERSION%%.*}" != "${TARGET%%.*}" ]] && [[ "${IGNORE_ELECTRON_VERSION}" != "yes" ]]; then
    echo "Electron ${VSCODE_ARCH} binary version doesn't match target electron version!" >&2
    exit 1
  fi

  if [[ "${ELECTRON_VERSION}" != "${TARGET}" ]]; then
    sed -i "s|target=\"${TARGET}\"|target=\"${ELECTRON_VERSION}\"|" .npmrc
    export VSCODE_ELECTRON_VERSION="${ELECTRON_VERSION}"
  fi
fi

for i in {1..5}; do
  npm ci --prefix build && break
  if [[ $i == 5 ]]; then
    echo "Npm install failed too many times" >&2
    exit 1
  fi
  echo "Npm install failed $i, trying again..."
done

if [[ -z "${VSCODE_SKIP_SETUPENV}" ]]; then
  if [[ -n "${VSCODE_SKIP_SYSROOT}" ]]; then
    # shellcheck disable=SC1091
    source ./build/azure-pipelines/linux/setup-env.sh --skip-sysroot
  else
    # shellcheck disable=SC1091
    source ./build/azure-pipelines/linux/setup-env.sh
  fi
fi

# CI starts from a clean checkout, so it runs `npm ci` here to rebuild the
# native modules against the build-agent toolchain that setup-env.sh just
# configured. Locally the compile step already installed node_modules, and
# `npm rebuild` re-runs the same install scripts against that toolchain without
# throwing the tree away - which matters because foundry-local-sdk's install
# script pulls several hundred MB of NuGet packages that would otherwise be
# downloaded a second time.
if [[ -d node_modules && "${UOS25_FORCE_NPM_CI:-no}" != "yes" ]]; then
  # Same caveat as compile.sh: optional dependencies that cannot be built
  # against Electron's headers (cpu-features, buildcheck) fail their install
  # script, which npm ci tolerates and npm rebuild reports as an error.
  npm rebuild || echo "warning: npm rebuild reported errors; optional dependencies such as cpu-features are expected to fail" >&2
else
  for i in {1..5}; do
    npm ci && break
    if [[ $i == 5 ]]; then
      echo "Npm install failed too many times" >&2
      exit 1
    fi
    echo "Npm install failed $i, trying again..."
  done
fi

node build/azure-pipelines/distro/mixin-npm.ts

# delete native files built in the `compile` step
find .build/extensions -type f -name '*.node' -print -delete

# generate Group Policy definitions
npm run copy-policy-dto --prefix build
node build/lib/policies/policyGenerator.ts build/lib/policies/policyData.jsonc linux

npm run gulp "vscode-linux-${VSCODE_ARCH}-min-packing"

if [[ -f "../build/linux/${VSCODE_ARCH}/ripgrep.sh" ]]; then
  bash "../build/linux/${VSCODE_ARCH}/ripgrep.sh" "../VSCode-linux-${VSCODE_ARCH}/resources/app/node_modules"
fi

find "../VSCode-linux-${VSCODE_ARCH}" -print0 | xargs -0 touch -c

# The tunnel CLI (build_cli.sh) is Rust and its crates use edition 2024, so it
# needs a toolchain >= 1.85 with rustup. Point UOS25_RUST_BIN at a rustup bin
# directory when the system Rust is too old or has no rustup, or set
# SHOULD_BUILD_CLI=no to ship the deb without the tunnel CLI (bin/<name> itself
# is a shell wrapper around resources/app/out/cli.js and does not need it).
if [[ -n "${UOS25_RUST_BIN:-}" ]]; then
  export PATH="${UOS25_RUST_BIN}:${PATH}"
fi

# shellcheck disable=SC1091
. ../build_cli.sh

cd ..
echo "packaged ../VSCode-linux-${VSCODE_ARCH}"
