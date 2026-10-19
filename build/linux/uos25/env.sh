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
# ELECTRON_CUSTOM_DIR is deliberately left alone. @electron/get defaults it to
# `v${version}`, which is exactly the layout npmmirror uses, and setting it to
# the `{{ version }}` placeholder instead is fragile: the placeholder's closing
# braces make the `${VAR:-...}` assignment ambiguous and the value can end up
# with stray braces, producing URLs like .../electron/43.7.3}}/electron-...zip.

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

# {{{ optional downloads
# Neither the Electron binary nor the Playwright browsers are needed to package
# the application, and both install scripts would otherwise pull hundreds of
# megabytes. prepare_vscode.sh sets these for the compile step, but the
# packaging step runs the install scripts again through `npm rebuild`, in a
# process that never sourced it.
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
# }}}

# {{{ git-lfs
# The VS Code repository marks a few copilot test fixtures with `filter: lfs`,
# and their objects are not on the server ("remote missing object"). Nothing in
# the build needs that content, so the smudge filter is skipped and the pointers
# are left in place. This matters because git-lfs is installed on this machine -
# it is needed to push to the internal GitLab mirror, which requires LFS objects
# for the pointers in the history.
export GIT_LFS_SKIP_SMUDGE=1
# }}}

# {{{ Node 20 support
UOS25_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Exported because the functions below run in child processes (compile.sh,
# package.sh) and cannot see a variable that is not.
export UOS25_DIR

# Node 22.6 added --experimental-strip-types and 22.12 made require() of an ES
# module work; the VS Code build tooling assumes both. UOS 25 ships Node 20, and
# below that threshold the loader in node20/ supplies them. See
# build/linux/uos25/node20/README.md.
if [[ -z "${UOS25_NODE20:-}" ]]; then
  if node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=6)?0:1)' 2>/dev/null; then
    UOS25_NODE20=no
  else
    UOS25_NODE20=yes
  fi
fi
export UOS25_NODE20

if [[ "${UOS25_NODE20}" == "yes" ]]; then
  # --import is available from Node 20.6 and applies to every node process the
  # build starts, which is what avoids rewriting each npm script. Each is appended
  # only once: this file is sourced by more than one script in the pipeline, and a
  # second copy would register the same hooks twice.
  #
  # llhttp-shim.mjs comes along because the same node takes its undici from the
  # archive's node-undici, whose llhttp wasm is truncated - which makes every
  # fetch() fail with a WebAssembly error. See that file.
  for module in register.mjs llhttp-shim.mjs; do
    import="--import file://${UOS25_DIR}/node20/${module}"
    if [[ "${NODE_OPTIONS:-}" != *"${import}"* ]]; then
      export NODE_OPTIONS="${NODE_OPTIONS:-} ${import}"
    fi
  done
fi

# Run a gulp task. `npm run gulp` passes --experimental-strip-types, which Node
# older than 22.6 rejects outright, so gulp is invoked directly there; the loader
# registered above handles the TypeScript.
uos25_gulp() {
  if [[ "${UOS25_NODE20}" == "yes" ]]; then
    node --max-old-space-size="${MAX_OLD_SPACE_SIZE:-8192}" ./node_modules/gulp/bin/gulp.js "$@"
  else
    npm run gulp -- "$@"
  fi
}

# The TypeScript-requiring entry points that upstream runs before `npm ci` have
# to wait for it on Node 20, because the loader needs the TypeScript that npm ci
# installs. compile.sh calls this at the right moment instead.
uos25_run_preinstall() {
  if [[ "${UOS25_NODE20}" == "yes" ]]; then
    VSCODE_FORCE_INSTALL=1 node build/npm/preinstall.ts
  fi
}

# @vscode/gulp-electron requires three ESM-only packages from CommonJS, which
# only works from Node 22.12. patch-modules.mjs rewrites those requires; it has
# to run again after every npm ci, which is what recreates node_modules.
uos25_patch_modules() {
  if [[ "${UOS25_NODE20}" == "yes" ]]; then
    node "${UOS25_DIR}/node20/patch-modules.mjs" "${UOS25_DIR}/../../.."
  fi
}

# compile.sh, package.sh and build.sh are separate processes; bash does not pass
# functions to children unless they are exported.
export -f uos25_gulp uos25_run_preinstall uos25_patch_modules
# }}}

# {{{ writable build home
# pbuilder runs the build as its own user with HOME=/nonexistent, and everything
# that reaches for a per-user cache directory then fails or writes where it
# cannot: @electron/get resolves its cache through env-paths (XDG_CACHE_HOME,
# else $HOME/.cache), and node-gyp falls back to a temporary devdir, which loses
# the electron target. Point them at a directory the build can write whenever
# HOME is not usable. On a developer's machine this does nothing.
if [[ ! -w "${HOME:-/nonexistent}" ]]; then
  UOS25_BUILD_HOME="${UOS25_BUILD_HOME:-${TMPDIR:-/tmp}/uos25-build-home}"
  export HOME="${UOS25_BUILD_HOME}"
  export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
  export npm_config_devdir="${npm_config_devdir:-${HOME}/.node-gyp}"
  mkdir -p "${XDG_CACHE_HOME}" "${npm_config_devdir}"
fi
# }}}

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

# {{{ vendored build dependencies
# debian/vendor travels in the source package (debian/source/options keeps it
# there on purpose), so the build finds it whether it runs from a checkout, from
# a pbuilder unpack or from the source package the internal build platform
# unpacks. Use it whenever it is present: the point of the vendor directory is
# that the build needs no external network at all, and the platform it has to
# run on has none. UOS25_USE_VENDOR=no opts out.
#
# This is done here rather than in build-app.sh because env.sh is what both entry
# points source, and because the settings have to be in place for the whole
# debian/rules run, not just the compile step.
if [[ "${UOS25_USE_VENDOR:-}" != "no" && "${UOS25_OFFLINE:-no}" != "yes" ]]; then
  UOS25_VENDOR_DIR="${UOS25_VENDOR_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/debian/vendor}"
  if [[ -d "${UOS25_VENDOR_DIR}" ]]; then
    export UOS25_VENDOR_DIR UOS25_USE_VENDOR=yes
    # shellcheck disable=SC1091
    . "$(dirname "${BASH_SOURCE[0]}")/offline.sh"
  fi
fi
# }}}
