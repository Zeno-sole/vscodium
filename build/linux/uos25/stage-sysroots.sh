#!/usr/bin/env bash
# Stage the VSCodium build-agent sysroots from a local cache.
#
# On x64 the packaging step always uses the build-agent toolchain: it sources
# `build/azure-pipelines/linux/setup-env.sh`, which downloads
#   .build/sysroots/glibc-2.28-gcc-10.5.0   (client, clang target)
#   .build/sysroots/glibc-2.28-gcc-8.5.0    (remote server, gcc target)
# from the Microsoft/vscode-linux-build-agent GitHub release, and the deb
# dependency step (build/linux/debian/install-sysroot.ts) downloads the client
# one again into $VSCODE_SYSROOT_DIR. Both honour a pre-existing directory, so
# pre-extracting the tarballs keeps the build off api.github.com.
#
# Put the tarballs in UOS25_SYSROOT_CACHE (default /tmp/vscode-amd64-sysroot):
#   x86_64-linux-gnu-glibc-2.28-gcc-10.5.0.tar.gz
#   x86_64-linux-gnu-glibc-2.28-gcc-8.5.0.tar.gz
# (any host reachable from the build machine can fetch them; the release is
#  microsoft/vscode-linux-build-agent tag v20260212-405735).
#
# Usage: ./build/linux/uos25/stage-sysroots.sh [repo-root]

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
CACHE="${UOS25_SYSROOT_CACHE:-/tmp/vscode-amd64-sysroot}"
SYSROOT_ROOT="${ROOT}/vscode/.build/sysroots"

stage() {
  local tarball="$1" name="$2"
  local dest="${SYSROOT_ROOT}/${name}"
  if [[ -f "${dest}/.stamp" && "$(cat "${dest}/.stamp")" == "${tarball}" ]]; then
    echo "cached  ${dest}" >&2
    return 0
  fi
  if [[ ! -f "${CACHE}/${tarball}" ]]; then
    echo "missing ${CACHE}/${tarball} - leaving the sysroot to be downloaded" >&2
    return 1
  fi
  echo "extract ${tarball} -> ${dest}" >&2
  rm -rf "${dest}"
  mkdir -p "${dest}"
  tar -xzf "${CACHE}/${tarball}" -C "${dest}"
  # install-sysroot.ts compares the whole file against the expected asset name,
  # so the stamp must not end with a newline.
  printf '%s' "${tarball}" > "${dest}/.stamp"
}

stage "x86_64-linux-gnu-glibc-2.28-gcc-10.5.0.tar.gz" "glibc-2.28-gcc-10.5.0"
stage "x86_64-linux-gnu-glibc-2.28-gcc-8.5.0.tar.gz" "glibc-2.28-gcc-8.5.0"

# The deb dependency step also needs the chromium sysroot
# (build/linux/debian/install-sysroot.ts, getChromiumSysroot), which it fetches
# from the Electron build CDN and extracts into $TMPDIR. Stage it the same way
# when the tarball is available in the cache.
CHROMIUM_DIR="${TMPDIR:-/tmp}/debian_bullseye_amd64-sysroot"
CHROMIUM_URL="https://msftelectronbuild.z5.web.core.windows.net/sysroots/toolchain/f2e052b0cdab9b6f9bfe311c5269264d5f4e38a018bbc27ba2314b73ac8f7053"
if [[ -f "${CHROMIUM_DIR}/.stamp" && "$(cat "${CHROMIUM_DIR}/.stamp")" == "${CHROMIUM_URL}" ]]; then
  echo "cached  ${CHROMIUM_DIR}" >&2
elif [[ -f "${CACHE}/debian_bullseye_amd64_sysroot.tar.xz" ]]; then
  echo "extract debian_bullseye_amd64_sysroot.tar.xz -> ${CHROMIUM_DIR}" >&2
  rm -rf "${CHROMIUM_DIR}"
  mkdir -p "${CHROMIUM_DIR}"
  cp "${CACHE}/debian_bullseye_amd64_sysroot.tar.xz" "${CHROMIUM_DIR}/"
  tar -xf "${CHROMIUM_DIR}/debian_bullseye_amd64_sysroot.tar.xz" -C "${CHROMIUM_DIR}"
  printf '%s' "${CHROMIUM_URL}" > "${CHROMIUM_DIR}/.stamp"
else
  echo "missing ${CACHE}/debian_bullseye_amd64_sysroot.tar.xz - leaving it to be downloaded" >&2
fi

cat <<EOF

export VSCODE_SYSROOT_DIR="${SYSROOT_ROOT}/glibc-2.28-gcc-10.5.0"
EOF
