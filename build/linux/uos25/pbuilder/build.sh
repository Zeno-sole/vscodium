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
# Two things the UOS 25 archive cannot provide, handled by the hook in
# hooks/ and by bind mounts:
#
#   * nodejs >= 22. The archive ships nodejs 20, but the VS Code build runs
#     `node --experimental-strip-types` (node >= 22.6). hooks/D10nodesource
#     adds the NodeSource repository before build dependencies are resolved.
#
#   * the toolchain caches. Fetching the VS Code sources, the npm packages, the
#     Electron binary and the build-agent sysroots from scratch inside the
#     chroot takes well over an hour and a lot of bandwidth, so the host caches
#     are bind-mounted (see BIND_MOUNTS below). Set UOS25_PB_NO_CACHES=yes to
#     build without them.

set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "${ROOT}"

BASETGZ="${UOS25_BASETGZ:-/var/cache/pbuilder/uos25-snipe-amd64.tgz}"
HOOKDIR="${ROOT}/build/linux/uos25/pbuilder/hooks"
RESULT_DIR="${ROOT}/assets"
NPM_CACHE="${UOS25_NPM_CACHE:-${HOME}/.npm}"
SYSROOT_CACHE="${UOS25_SYSROOT_CACHE:-/tmp/vscode-amd64-sysroot}"
FOUNDRY_SEED="${UOS25_FOUNDRY_SEED:-/tmp/foundry-seed}"
TOOLCHAIN_DIR="${UOS25_TOOLCHAIN_DIR:-/tmp/vscode-toolchain}"

if [[ ! -f "${BASETGZ}" ]]; then
  echo "error: ${BASETGZ} not found - run create-chroot.sh first" >&2
  exit 1
fi

echo "== creating source package =="
bash build/linux/uos25/build-deb.sh --source
DSC="$(ls -1t "${ROOT}"/../codium_*.dsc | head -1)"
echo "   ${DSC}"

# pbuilder cannot pass environment variables into the chroot, so the settings
# the build needs there - notably the HTTP proxy for the GitHub fetches - are
# written to a file and bind-mounted; build/linux/uos25/env.sh sources it.
BUILD_ENV_DIR="/tmp/uos25-buildenv"
mkdir -p "${BUILD_ENV_DIR}"
: > "${BUILD_ENV_DIR}/build.env"
for var in http_proxy https_proxy no_proxy GITHUB_TOKEN UOS25_RUST_BIN; do
  if [[ -n "${!var:-}" ]]; then
    printf '%s=%q\n' "${var}" "${!var}" >> "${BUILD_ENV_DIR}/build.env"
  fi
done
echo "== build environment passed to the chroot =="
sed 's/^\(GITHUB_TOKEN=\).*/\1<set>/' "${BUILD_ENV_DIR}/build.env"

BIND_MOUNTS=(--bindmounts "${BUILD_ENV_DIR}")
if [[ "${UOS25_PB_NO_CACHES:-no}" != "yes" ]]; then
  # node-gyp header mirror: the loopback server on the host is reachable from
  # the chroot because pbuilder shares the host network namespace.
  bash build/linux/uos25/setup-toolchain-mirror.sh >/dev/null
  for d in "${NPM_CACHE}" "${SYSROOT_CACHE}" "${FOUNDRY_SEED}" "${TOOLCHAIN_DIR}"; do
    if [[ -d "${d}" ]]; then
      BIND_MOUNTS+=(--bindmounts "${d}")
    fi
  done
fi

mkdir -p "${RESULT_DIR}"

echo "== pbuilder build =="
sudo pbuilder --build \
  --basetgz "${BASETGZ}" \
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
