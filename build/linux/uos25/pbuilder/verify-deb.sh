#!/usr/bin/env bash
# Verify a VSCodium deb inside a clean UOS 25 pbuilder chroot.
#
# The deb is bind-mounted into the chroot, installed there, and checked by
# pbuilder/verify-in-chroot.sh. Run create-chroot.sh once beforehand.
#
# Usage: ./build/linux/uos25/pbuilder/verify-deb.sh [path/to/codium_*.deb]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
BASETGZ="${UOS25_BASETGZ:-/var/cache/pbuilder/uos25-snipe-amd64.tgz}"

DEB="${1:-}"
if [[ -z "${DEB}" ]]; then
  DEB="$(ls -1 "${ROOT}"/assets/*.deb 2>/dev/null | head -1 || true)"
fi
if [[ -z "${DEB}" || ! -f "${DEB}" ]]; then
  echo "usage: $0 [path/to/codium_*.deb]" >&2
  exit 2
fi
DEB="$(readlink -f "${DEB}")"

if [[ ! -f "${BASETGZ}" ]]; then
  echo "error: ${BASETGZ} not found - run pbuilder/create-chroot.sh first" >&2
  exit 1
fi

WORK="$(mktemp -d /tmp/uos25-verify.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
cp "${DEB}" "${WORK}/"
cp "${ROOT}/build/linux/uos25/pbuilder/verify-in-chroot.sh" "${WORK}/"
chmod +x "${WORK}/verify-in-chroot.sh"

echo "verifying $(basename "${DEB}") in ${BASETGZ}"
sudo pbuilder --execute \
  --basetgz "${BASETGZ}" \
  --allow-untrusted \
  --bindmounts "${WORK}" \
  -- "${WORK}/verify-in-chroot.sh" "${WORK}/$(basename "${DEB}")"
