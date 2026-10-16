#!/usr/bin/env bash
# Serve the Electron and Node headers that `npm ci` needs, from a local mirror.
#
# Why this exists: `build/npm/preinstall.ts` runs node-gyp with a `--dist-url`
# read from the checked-in `.npmrc`, and node-gyp
#   - does not honour http_proxy/https_proxy, and
#   - verifies the downloaded tarball against the `SHASUMS256.txt` published
#     next to it on the same dist-url.
#
# On a UOS network electronjs.org/nodejs.org are unreachable, and the public
# Chinese mirrors (registry.npmmirror.com) publish their SHASUMS files with the
# binary-mode `*` filename prefix, which node-gyp's parser cannot match. So the
# headers and a correctly formatted SHASUMS256.txt are staged locally and served
# over loopback; configure-mirrors.sh then points `.npmrc` at this server.
#
# Usage:
#   ./build/linux/uos25/setup-toolchain-mirror.sh [--dir DIR] [--port PORT]
#
# Prints the two dist-url values to export (see build/linux/uos25/env.sh).

set -euo pipefail

DIR="${UOS25_TOOLCHAIN_DIR:-/tmp/vscode-toolchain}"
PORT="${UOS25_TOOLCHAIN_PORT:-8099}"
ELECTRON_VERSION="${UOS25_ELECTRON_VERSION:-43.7.3}"
NODE_VERSION="${UOS25_NODE_VERSION:-24.21.0}"
MIRROR_BASE="${UOS25_BINARY_MIRROR:-https://registry.npmmirror.com/-/binary}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

fetch() {
  local url="$1" out="$2"
  if [[ -s "${out}" ]]; then
    echo "cached  ${out}" >&2
    return 0
  fi
  echo "fetch   ${url}" >&2
  curl -fsSL --noproxy '*' --retry 5 --retry-delay 3 -o "${out}" "${url}"
}

stage() {
  local name="$1" version="$2" tarball="$3"
  local target="${DIR}/${name}/v${version}"
  mkdir -p "${target}"
  fetch "${MIRROR_BASE}/${name}/v${version}/${tarball}" "${target}/${tarball}"
  # node-gyp splits SHASUMS lines on whitespace and expects exactly two fields,
  # so the plain `sha256sum` output is what it wants.
  ( cd "${target}" && sha256sum "${tarball}" > SHASUMS256.txt )
  echo "staged  ${target}/${tarball}" >&2
}

stage electron "${ELECTRON_VERSION}" "node-v${ELECTRON_VERSION}-headers.tar.gz"
stage node "${NODE_VERSION}" "node-v${NODE_VERSION}-headers.tar.gz"

if ! curl -fsS --noproxy '*' -o /dev/null "http://127.0.0.1:${PORT}/electron/v${ELECTRON_VERSION}/SHASUMS256.txt" 2>/dev/null; then
  echo "serving ${DIR} on 127.0.0.1:${PORT}" >&2
  setsid nohup python3 -m http.server "${PORT}" --bind 127.0.0.1 --directory "${DIR}" \
    > "${DIR}/http.log" 2>&1 < /dev/null &
  disown
  sleep 2
fi

cat <<EOF

export UOS25_ELECTRON_DISTURL="http://127.0.0.1:${PORT}/electron"
export UOS25_NODE_DISTURL="http://127.0.0.1:${PORT}/node"
EOF
