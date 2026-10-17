#!/usr/bin/env bash
# Point a VSCodium build at a local vendor directory so that it needs no network.
#
#   . build/linux/uos25/offline.sh
#
# or let build-deb.sh do it:  ./build/linux/uos25/build-deb.sh --offline
#
# The vendor directory is populated by vendor/fetch.sh; see vendor/README.md for
# what it contains. Everything the build would otherwise download is either read
# from that directory or served from it over loopback by a local file server, so
# the build works with no route off the machine at all.
#
# The one deliberate difference from an online build: the build-agent toolchain
# (glibc-2.28 clang + sysroots + libcxx) is not used, because vendoring it means
# another ~700 MB per architecture and a patched setup-env.sh. Offline builds
# compile against the host toolchain instead, which for a UOS-only package is
# what you want anyway. VSCODE_SKIP_SETUPENV is what selects that.

set -euo pipefail

# Resolved once and exported: offline.sh is sourced more than once per build
# (by build-deb.sh and again by build-app.sh, which debian/rules calls), and by
# then env.sh may have sourced a build environment file that changes HOME.
if [[ -n "${UOS25_VENDOR_DIR:-}" ]]; then
  VENDOR_DIR="${UOS25_VENDOR_DIR}"
else
  # The vendor data lives under debian/ so that it travels with the source tree.
  VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/debian/vendor"
  export UOS25_VENDOR_DIR="${VENDOR_DIR}"
fi
VENDOR_PORT="${UOS25_VENDOR_PORT:-8098}"
ARCH="${UOS25_VENDOR_ARCH:-amd64}"
case "${VSCODE_ARCH:-x64}" in
  x64) ARCH="${UOS25_VENDOR_ARCH:-amd64}" ;;
  arm64) ARCH="${UOS25_VENDOR_ARCH:-arm64}" ;;
  loong64) ARCH="${UOS25_VENDOR_ARCH:-loong64}" ;;
esac

ARCH_DIR="${VENDOR_DIR}/${ARCH}"
SHARED_DIR="${VENDOR_DIR}/shared"

if [[ ! -d "${ARCH_DIR}" ]]; then
  echo "error: no vendor directory for ${ARCH} at ${ARCH_DIR}" >&2
  echo "       run: build/linux/uos25/vendor/fetch.sh ${ARCH}" >&2
  return 1 2>/dev/null || exit 1
fi

# {{{ no egress
# The build must not be able to reach anything. Unsetting the proxy is not
# enough on its own - that only removes the one path that was working - but it
# does make an accidental download fail loudly instead of succeeding slowly.
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
export no_proxy='*'
export NO_PROXY='*'
# }}}

# {{{ local file server
# Several downloaders insist on an HTTP URL and cannot be pointed at a file
# (node-gyp, @electron/get). They are served the vendor directory over loopback.
if ! curl -fsS --noproxy '*' -o /dev/null "http://127.0.0.1:${VENDOR_PORT}/" 2>/dev/null; then
  echo "== starting the vendor file server on 127.0.0.1:${VENDOR_PORT} =="
  # The architecture directory is the document root, so the URLs the build uses
  # (/electron/..., /node-headers/...) match the vendor layout directly. The log
  # goes to the temp directory, not into the vendor tree, which is build input.
  setsid nohup python3 -m http.server "${VENDOR_PORT}" --bind 127.0.0.1 \
    --directory "${ARCH_DIR}" > "${TMPDIR:-/tmp}/uos25-vendor-http.log" 2>&1 < /dev/null &
  disown
  sleep 2
fi
export UOS25_VENDOR_URL="http://127.0.0.1:${VENDOR_PORT}"
# }}}

# {{{ electron
# @electron/get honours ELECTRON_MIRROR, so the Electron runtime comes from the
# vendor instead of github.com. ELECTRON_CUSTOM_DIR is left at its default
# (v<version>), which is how the vendor directory is laid out.
export ELECTRON_MIRROR="${UOS25_VENDOR_URL}/electron/"
# loong64 uses a different Electron build; package_bin.sh sets VSCODE_ELECTRON_VERSION
# from build/linux/loong64/electron.sh. VSCODE_ELECTRON_REPOSITORY is deliberately
# not used here: that path resolves the asset through api.github.com.
# }}}

# {{{ node-gyp headers
# node-gyp builds <disturl>/v<version>/node-v<version>-headers.tar.gz and the
# matching SHASUMS256.txt next to it; the vendor directory mirrors that layout.
export UOS25_ELECTRON_DISTURL="${UOS25_VENDOR_URL}/node-headers/electron"
export UOS25_NODE_DISTURL="${UOS25_VENDOR_URL}/node-headers/node"
export UOS25_OFFLINE=yes
# }}}

# {{{ package managers
# npm and cargo both work from their caches without network. The caches are
# shared between architectures: the JS packages and the Rust crates are
# architecture independent, only the optional native prebuilds differ.
export npm_config_cache="${SHARED_DIR}/npm-cache"
export npm_config_offline=true
export CARGO_HOME="${SHARED_DIR}/cargo"
export CARGO_NET_OFFLINE=true
# }}}

# {{{ everything else
# Host toolchain instead of the build-agent one.
export VSCODE_SKIP_SETUPENV=1

# Where this architecture's vendor files are, for the build steps that copy
# rather than fetch (the Electron type definitions).
export UOS25_ARCH_VENDOR_DIR="${ARCH_DIR}"

# Foundry Local native runtime: the nupkg cache is used directly.
export UOS25_FOUNDRY_NUPKG_DIR="${ARCH_DIR}/foundry"

# Built-in extensions: vendored .vsix files, injected into product.json by
# compile.sh so nothing is fetched from api.github.com.
export UOS25_VSIX_DIR="${ARCH_DIR}/vsix"

# loong64's ripgrep replacement, used by build/linux/loong64/ripgrep.sh.
export UOS25_RIPGREP_DIR="${ARCH_DIR}/ripgrep"
# }}}

# {{{ git mirrors
# The VS Code sources and the tunnel CLI's git dependencies, through
# GIT_CONFIG_* so that no config file is written.
GIT_MIRROR_URLS=("https://github.com/Microsoft/vscode.git" "https://github.com/microsoft/vscode-russh" "https://github.com/microsoft/dev-tunnels")
GIT_MIRROR_PATHS=("${SHARED_DIR}/git/vscode.git" "${SHARED_DIR}/git/rust/vscode-russh.git" "${SHARED_DIR}/git/rust/dev-tunnels.git")
export GIT_CONFIG_COUNT=0
for i in "${!GIT_MIRROR_URLS[@]}"; do
  if [[ -d "${GIT_MIRROR_PATHS[$i]}/objects" ]]; then
    export "GIT_CONFIG_KEY_${GIT_CONFIG_COUNT}=url.${GIT_MIRROR_PATHS[$i]}.insteadOf"
    export "GIT_CONFIG_VALUE_${GIT_CONFIG_COUNT}=${GIT_MIRROR_URLS[$i]}"
    GIT_CONFIG_COUNT=$((GIT_CONFIG_COUNT + 1))
  fi
done
export GIT_CONFIG_COUNT
# }}}

echo "== offline build: arch ${ARCH}, vendor ${VENDOR_DIR} =="
echo "   npm  : ${npm_config_cache} (offline)"
echo "   cargo: ${CARGO_HOME} (offline)"
echo "   electron, node-gyp headers: ${UOS25_VENDOR_URL}"
echo "   git mirrors: ${GIT_CONFIG_COUNT} mapped"
