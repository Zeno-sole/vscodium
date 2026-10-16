#!/usr/bin/env bash
# Build environment for producing the VSCodium .deb on UOS 25 (codename `snipe`)
# and its community base Deepin 25 (`crimson`).
#
# Source this from the repository root before running build-deb.sh:
#
#   . build/linux/uos25/env.sh
#
# Everything here can be overridden from the outside; the defaults describe the
# environment the packaging was validated against.

# {{{ release identity
export VSCODE_QUALITY="${VSCODE_QUALITY:-stable}"
export OS_NAME="${OS_NAME:-linux}"
export VSCODE_ARCH="${VSCODE_ARCH:-x64}"
export npm_config_arch="${npm_config_arch:-x64}"

export APP_NAME="${APP_NAME:-VSCodium}"
export BINARY_NAME="${BINARY_NAME:-codium}"
export ORG_NAME="${ORG_NAME:-Zeno-sole}"
export GH_REPO_PATH="${GH_REPO_PATH:-Zeno-sole/vscodium}"

# UOS ships a branded build: never let the app phone home for updates.
export DISABLE_UPDATE="${DISABLE_UPDATE:-yes}"
# }}}

# {{{ which parts of the pipeline run
export CI_BUILD="${CI_BUILD:-no}"
export SHOULD_BUILD="${SHOULD_BUILD:-yes}"
export SHOULD_BUILD_REH="${SHOULD_BUILD_REH:-no}"
export SHOULD_BUILD_REH_WEB="${SHOULD_BUILD_REH_WEB:-no}"
export SHOULD_BUILD_DEB="${SHOULD_BUILD_DEB:-yes}"
export SHOULD_BUILD_RPM="${SHOULD_BUILD_RPM:-no}"
export SHOULD_BUILD_TAR="${SHOULD_BUILD_TAR:-yes}"
# }}}

# {{{ package mirrors
# registry.npmjs.org is reachable but slow from this network; npmmirror is a
# full mirror and serves the Electron binaries as well.
export npm_config_registry="${npm_config_registry:-https://registry.npmmirror.com}"
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
export ELECTRON_CUSTOM_DIR="${ELECTRON_CUSTOM_DIR:-{{ version }}}"

# node-gyp reads its header dist-url out of the checked-in .npmrc and ignores
# http_proxy, so the Electron/Node headers come from a loopback mirror staged by
# setup-toolchain-mirror.sh. Set UOS25_ELECTRON_DISTURL / UOS25_NODE_DISTURL to
# whatever setup-toolchain-mirror.sh printed before sourcing this file.
export UOS25_ELECTRON_DISTURL="${UOS25_ELECTRON_DISTURL:-${UOS25_TOOLCHAIN_MIRROR:-http://127.0.0.1:8099}/electron}"
export UOS25_NODE_DISTURL="${UOS25_NODE_DISTURL:-${UOS25_TOOLCHAIN_MIRROR:-http://127.0.0.1:8099}/node}"

# Keep mirror and intranet traffic off any local HTTP proxy; only the GitHub
# fetches (electron, sysroots, ripgrep) need it.
export no_proxy="${no_proxy:-localhost,127.0.0.1,10.0.0.0/8,registry.npmmirror.com,npmmirror.com,registry.npmjs.org,pools.uniontech.com,ci.deepin.com,mirrors.hust.edu.cn}"
export NO_PROXY="${no_proxy}"
# }}}

# {{{ UOS 25 package names
# UOS 25 (Debian 12/13 lineage) still uses the pre-time64 names, so the t64
# alternatives VSCodium generates for Debian 13+ are dropped from the control
# file. See build/linux/uos25/patch-deps.mjs.
export UOS25_SKIP_T64_ALTERNATIVES="${UOS25_SKIP_T64_ALTERNATIVES:-yes}"
# }}}

export VSCODE_SKIP_NODE_VERSION_CHECK=1

# {{{ extra build environment
# pbuilder cannot pass environment variables into the chroot, but the build
# needs an HTTP proxy for the GitHub fetches. build/linux/uos25/pbuilder/build.sh
# writes such settings to this file and bind-mounts it, and the hook in
# pbuilder/hooks/ exposes it at the same path inside the chroot. Anything set
# here overrides the defaults above.
UOS25_BUILD_ENV_FILE="${UOS25_BUILD_ENV_FILE:-/tmp/uos25-buildenv/build.env}"
if [[ -f "${UOS25_BUILD_ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  . "${UOS25_BUILD_ENV_FILE}"
fi
# }}}
