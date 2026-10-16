#!/usr/bin/env bash
# Create the UOS 25 (codename `snipe`) pbuilder base tarball.
#
# The UOS mirror is signed with a key that is not shipped in the public
# keyrings, and pbuilder does not forward --components to debootstrap, so the
# components are passed through --debootstrapopts (comma separated).
#
# Usage: sudo ./build/linux/uos25/pbuilder/create-chroot.sh
#
# Environment:
#   UOS25_DIST        snipe
#   UOS25_MIRROR      http://pools.uniontech.com/desktop-professional-V25
#   UOS25_COMPONENTS  main,community,commercial
#   UOS25_BASETGZ     /var/cache/pbuilder/uos25-snipe-amd64.tgz

set -euo pipefail

DIST="${UOS25_DIST:-snipe}"
MIRROR="${UOS25_MIRROR:-http://pools.uniontech.com/desktop-professional-V25}"
COMPONENTS="${UOS25_COMPONENTS:-main,community,commercial}"
BASETGZ="${UOS25_BASETGZ:-/var/cache/pbuilder/uos25-snipe-amd64.tgz}"
ARCH="${UOS25_ARCH:-amd64}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "error: pbuilder --create needs root (run with sudo)" >&2
  exit 1
fi

# pbuilder aborts if the apt cache directory does not exist yet.
mkdir -p /var/cache/pbuilder/aptcache /var/cache/pbuilder/result /var/cache/pbuilder/hooks

# The intranet mirror must not be routed through a proxy.
env http_proxy= https_proxy= all_proxy= NO_PROXY='*' \
  pbuilder --create \
    --distribution "${DIST}" \
    --architecture "${ARCH}" \
    --mirror "${MIRROR}" \
    --basetgz "${BASETGZ}" \
    --debootstrapopts --variant=buildd \
    --debootstrapopts --components="${COMPONENTS}" \
    --debootstrapopts --no-check-gpg \
    --allow-untrusted

echo "base tarball: ${BASETGZ}"
