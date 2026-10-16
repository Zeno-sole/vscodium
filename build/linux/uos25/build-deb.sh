#!/usr/bin/env bash
# Build the UOS 25 .deb through the standard Debian tooling.
#
# debian/ lives at the root of the source tree, so the package is produced by
# dpkg-buildpackage, which calls debian/rules; debian/rules drives
# build/linux/uos25/build-app.sh and installs the resulting application tree.
#
#   ./build/linux/uos25/build-deb.sh              # binary package
#   ./build/linux/uos25/build-deb.sh --clean      # from scratch (debian/rules clean first)
#   ./build/linux/uos25/build-deb.sh --source     # source package (.dsc) for pbuilder
#
# The binary package is written next to the source tree by dpkg-buildpackage and
# copied into ./assets, which is git-ignored.
#
# Environment:
#   RELEASE_VERSION   upstream VSCodium version (default 1.140.06880)
#   GITHUB_TOKEN      for the api.github.com extension downloads
#   http_proxy/https_proxy  for the GitHub fetches only

set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${ROOT}"

# shellcheck source=env.sh
. build/linux/uos25/env.sh

export RELEASE_VERSION="${RELEASE_VERSION:-1.140.06880}"

# Extension bundling hits api.github.com, which answers anonymous requests with
# a 403. `gh auth token` is used when GITHUB_TOKEN is not exported.
if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
  if [[ -n "${GITHUB_TOKEN}" ]]; then
    export GITHUB_TOKEN
  fi
fi

MODE=binary
CLEAN_OPT=(-nc)
for arg in "$@"; do
  case "${arg}" in
    --source) MODE=source ;;
    --clean) CLEAN_OPT=() ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) echo "unknown argument: ${arg}" >&2; exit 2 ;;
  esac
done

echo "== UOS 25 deb build =="
echo "   release  : ${RELEASE_VERSION}"
echo "   arch     : ${VSCODE_ARCH}"
echo "   mode     : ${MODE}"

if [[ "${MODE}" == "source" ]]; then
  # Source package only, for `pbuilder --build`.
  dpkg-buildpackage -S -us -uc -d
  echo "== source package written to $(cd .. && pwd) =="
  ls -1 ../codium_*.dsc
  exit 0
fi

# `-nc` reuses an already built application tree (build-app.sh skips the build
# when VSCode-linux-<arch> exists). Use --clean for the full from-scratch flow,
# which is what debian/rules clean exists for.
dpkg-buildpackage -b -us -uc "${CLEAN_OPT[@]}"

mkdir -p assets
mv -f ../codium_"${RELEASE_VERSION}"_amd64.deb assets/ 2>/dev/null || true
mv -f ../codium_"${RELEASE_VERSION}"-*_amd64.deb assets/ 2>/dev/null || true
mv -f ../codium_"${RELEASE_VERSION}"_amd64.changes assets/ 2>/dev/null || true

echo "== done =="
ls -l assets/*.deb
