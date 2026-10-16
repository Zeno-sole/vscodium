#!/usr/bin/env bash
# End-to-end UOS 25 (codename `snipe`) .deb build for VSCodium.
#
# Runs the same pipeline as the upstream CI, but arranged for a single UOS 25
# host instead of the split container jobs, and with the network assumptions
# documented in build/linux/uos25/README.md.
#
#   ./build/linux/uos25/build-deb.sh
#
# Environment:
#   RELEASE_VERSION   e.g. 1.140.06880 (defaults to upstream/stable.json's tag
#                     plus the current time patch, as get_repo.sh computes it)
#   VSCODE_ARCH       x64 (default), arm64, ...
#   UOS25_SYSROOT_CACHE  directory holding the build-agent sysroot tarballs
#   UOS25_TOOLCHAIN_DIR  where the header mirror is staged (default /tmp/vscode-toolchain)
#   http_proxy/https_proxy  needed only for GitHub fetches (electron binary,
#                     sysroot tarballs, clang); mirrors are excluded via no_proxy.
#
# Artifacts land in ./assets.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${ROOT}"

# shellcheck source=env.sh
. build/linux/uos25/env.sh

export RELEASE_VERSION="${RELEASE_VERSION:-1.140.06880}"

# Bundling the marketplace extensions downloads prebuilt .vsix files from
# api.github.com, which rate limits anonymous requests with a 403. Any token
# with public read access works; `gh auth token` is used when GITHUB_TOKEN is
# not already exported.
if [[ -z "${GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
  if [[ -n "${GITHUB_TOKEN}" ]]; then
    export GITHUB_TOKEN
    echo "   github token : from gh credential store"
  fi
fi

echo "== UOS 25 deb build =="
echo "   release  : ${RELEASE_VERSION}"
echo "   arch     : ${VSCODE_ARCH} (npm ${npm_config_arch})"
echo "   quality  : ${VSCODE_QUALITY}"

# {{{ 1. sources
if [[ ! -d vscode/.git ]]; then
  echo "== fetching VS Code sources =="
  bash get_repo.sh
fi
# }}}

# {{{ 2. build-time downloads
echo "== preparing mirrors =="
# shellcheck disable=SC1090
eval "$(bash build/linux/uos25/setup-toolchain-mirror.sh)"
bash build/linux/uos25/configure-mirrors.sh
# Staging the sysroots is best effort: if the tarballs are absent the build
# falls back to downloading them itself.
# shellcheck disable=SC1090
eval "$(bash build/linux/uos25/stage-sysroots.sh || true)"
# Pre-fetch the Foundry Local native libraries so npm does not stall on them.
bash build/linux/uos25/seed-foundry.sh || true
# }}}

# {{{ 3. compile the workbench
echo "== compiling workbench =="
bash build/linux/uos25/compile.sh
# }}}

# {{{ 4. package the application tree
echo "== packaging application =="
bash build/linux/uos25/package.sh
# }}}

# {{{ 5. assemble the deb
echo "== building deb =="
bash build/linux/uos25/prepare-deb.sh
# }}}

echo "== done =="
ls -l assets/*.deb
