#!/usr/bin/env bash
# Produce the packaged VSCodium application tree (../VSCode-linux-<arch>) that
# debian/rules installs.
#
# This is the whole upstream pipeline - fetch, mirror setup, compile, package -
# arranged for a single UOS 25 host instead of the split CI container jobs. It
# is the entry point debian/rules calls from override_dh_auto_build.
#
# Environment (see env.sh for the defaults):
#   RELEASE_VERSION   upstream VSCodium version, e.g. 1.140.06880
#   VSCODE_ARCH       x64 (default)
#   SHOULD_BUILD_CLI  no to skip the Rust tunnel CLI
#   GITHUB_TOKEN      for the api.github.com extension downloads (403 without)
#   http_proxy/https_proxy  for the GitHub fetches only
#
# Network notes are in build/linux/uos25/README.md.

set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${ROOT}"

# shellcheck source=env.sh
. build/linux/uos25/env.sh

# Vendor/offline mode. offline.sh points every downloader at the local vendor
# directory; it is sourced here so that both the standalone script and a
# debian/rules run (which inherits only the environment) pick it up.
if [[ "${UOS25_USE_VENDOR:-no}" == "yes" && "${UOS25_OFFLINE:-no}" != "yes" ]]; then
  # shellcheck disable=SC1091
  . build/linux/uos25/offline.sh
fi

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

echo "== building VSCodium application tree =="
echo "   release  : ${RELEASE_VERSION}"
echo "   arch     : ${VSCODE_ARCH} (npm ${npm_config_arch})"
echo "   quality  : ${VSCODE_QUALITY}"
echo "   npm      : ${npm_config_registry}"
echo "   electron : ${ELECTRON_MIRROR} (custom dir: ${ELECTRON_CUSTOM_DIR:-<default>})"
echo "   proxy    : ${http_proxy:-<none>}"

# The application build is long (it compiles the whole workbench and bundles
# every extension), so an existing tree is reused. `debian/rules clean` removes
# it, which is what a from-scratch dpkg-buildpackage run does; set
# UOS25_FORCE_REBUILD=yes to force a rebuild without cleaning.
APP_TREE="VSCode-linux-${VSCODE_ARCH}"
if [[ -d "${APP_TREE}" && "${UOS25_FORCE_REBUILD:-no}" != "yes" ]]; then
  echo "== reusing existing ${APP_TREE} =="
  echo "   (debian/rules clean removes it; UOS25_FORCE_REBUILD=yes forces a rebuild)"
  exit 0
fi

# {{{ 1. sources
# A local mirror of the VS Code repository can stand in for github.com, which is
# what makes the build viable from a UOS network: the fetch is several hundred
# megabytes and a proxy that drops connections will not get through it. The
# mapping is passed through the environment rather than written to a config
# file, so nothing outside this build is modified. When the caller has already
# supplied a mapping set (pbuilder does, for the rust git dependencies as well),
# it is left alone.
if [[ -n "${UOS25_VSCODE_MIRROR:-}" && -z "${GIT_CONFIG_COUNT:-}" ]]; then
  echo "== using VS Code mirror: ${UOS25_VSCODE_MIRROR} =="
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="url.${UOS25_VSCODE_MIRROR}.insteadOf"
  export GIT_CONFIG_VALUE_0="https://github.com/Microsoft/vscode.git"
fi

if [[ ! -d vscode/.git ]]; then
  echo "== fetching VS Code sources =="
  bash get_repo.sh
fi

# Offline: drop the two bundler-config projects from the npm install list.
# Their lockfiles leave transitive peer dependencies without a resolution, so
# npm constructs a registry URL that was never fetched and cannot install them
# from a cache alone. Nothing in the product build imports either directory -
# they exist so that extension development can run with rspack or vite - so
# leaving them out does not affect the package.
if [[ "${UOS25_OFFLINE:-no}" == "yes" ]]; then
  echo "== offline: dropping build/rspack and build/vite from the npm install list =="
  sed -i -e "/^	'build\/rspack',$/d" -e "/^	'build\/vite',$/d" vscode/build/npm/dirs.ts
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
if [[ -f vscode/.build/uos25-compiled && "${UOS25_FORCE_REBUILD:-no}" != "yes" ]]; then
  echo "== workbench already compiled =="
else
  echo "== compiling workbench =="
  bash build/linux/uos25/compile.sh
fi
# }}}

# {{{ 4. package the application tree
echo "== packaging application =="
bash build/linux/uos25/package.sh
# }}}

echo "== application tree ready: VSCode-linux-${VSCODE_ARCH} =="
