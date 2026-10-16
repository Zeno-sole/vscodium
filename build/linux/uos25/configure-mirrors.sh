#!/usr/bin/env bash
# Point the VS Code build's toolchain downloads at mirrors reachable from a
# UOS 25 network.
#
# `build/npm/preinstall.ts` drives node-gyp with a hard-coded `--dist-url` that
# it reads out of the checked-in `.npmrc` files, and node-gyp does not honour
# http_proxy/https_proxy. On a UOS network the upstream hosts
# (electronjs.org, nodejs.org) are therefore unreachable even with a working
# proxy, so the disturl has to be rewritten to a mirror before the first
# `npm ci` runs.
#
# Must run after get_repo.sh (which checks out vscode/) and before build.sh
# (whose sourced prepare_vscode.sh runs npm ci).
#
# Usage: ./build/linux/uos25/configure-mirrors.sh [repo-root]

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
VSCODE_DIR="${ROOT}/vscode"

ELECTRON_DISTURL="${UOS25_ELECTRON_DISTURL:-https://registry.npmmirror.com/-/binary/electron}"
NODE_DISTURL="${UOS25_NODE_DISTURL:-https://registry.npmmirror.com/-/binary/node}"

if [[ ! -f "${VSCODE_DIR}/.npmrc" ]]; then
  echo "error: ${VSCODE_DIR}/.npmrc not found - run get_repo.sh first" >&2
  exit 1
fi

rewrite_disturl() {
  local file="$1" disturl="$2"
  if [[ ! -f "${file}" ]]; then
    return 0
  fi
  if grep -q '^disturl=' "${file}"; then
    sed -i "s|^disturl=.*|disturl=\"${disturl}\"|" "${file}"
    echo "disturl -> ${disturl}  (${file#"${ROOT}/"})"
  fi
}

# Electron headers for the workbench build.
rewrite_disturl "${VSCODE_DIR}/.npmrc" "${ELECTRON_DISTURL}"
# Node headers, used by the remote/server build.
rewrite_disturl "${VSCODE_DIR}/remote/.npmrc" "${NODE_DISTURL}"
