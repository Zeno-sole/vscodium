#!/usr/bin/env bash
# Assemble the UOS 25 .deb from an already packaged application tree.
#
# This is the deb part of build/linux/prepare_assets.sh, with the UOS maintainer
# scripts substituted for the upstream ones before the gulp tasks run.
#
# Expects: build/linux/uos25/package.sh has produced ../VSCode-linux-<arch>,
# and build/linux/uos25/env.sh has been sourced.

set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
UOS25_DIR="${ROOT}/build/linux/uos25"
cd "${ROOT}/vscode"

if [[ ! -d "../VSCode-linux-${VSCODE_ARCH}" ]]; then
  echo "error: ../VSCode-linux-${VSCODE_ARCH} not found - run package.sh first" >&2
  exit 1
fi

# Swap in the UOS maintainer scripts. The gulp task reads these from
# resources/linux/debian/ and expands the @@NAME@@/@@VERSION@@ placeholders.
cp "${UOS25_DIR}/debian/postinst.template" resources/linux/debian/postinst.template
cp "${UOS25_DIR}/debian/postrm.template" resources/linux/debian/postrm.template

npm run gulp "vscode-linux-${VSCODE_ARCH}-prepare-deb"

# The UOS build has no debconf questions left, and dpkg rejects a templates file
# that contains no template stanzas, so it is dropped from the staging tree
# before it is packed.
DEB_ARCH=amd64
if [[ "${VSCODE_ARCH}" == "arm64" ]]; then DEB_ARCH=arm64; fi
if [[ "${VSCODE_ARCH}" == "armhf" ]]; then DEB_ARCH=armhf; fi
rm -f ".build/linux/deb/${DEB_ARCH}/codium-${DEB_ARCH}/DEBIAN/templates"

npm run gulp "vscode-linux-${VSCODE_ARCH}-build-deb"

cd "${ROOT}"
mkdir -p assets
mv vscode/.build/linux/deb/*/deb/*.deb assets/
echo "deb written to assets/"
