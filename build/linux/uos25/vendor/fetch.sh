#!/usr/bin/env bash
# Populate a local vendor directory with everything a UOS 25 build of VSCodium
# needs, so that the build itself can run with no network access.
#
#   ./build/linux/uos25/vendor/fetch.sh amd64
#   ./build/linux/uos25/vendor/fetch.sh amd64 arm64 loong64
#
# The data is several gigabytes per architecture, so it does not live in this
# repository: it goes to $UOS25_VENDOR_DIR (default ~/uos25-vendor) and the
# repository carries only the manifests that describe it.
#
# Layout:
#
#   <vendor>/shared/            architecture independent
#     git/vscode.git              the VS Code sources
#     git/rust/*.git              the tunnel CLI's git dependencies
#     npm-cache/                  npm's cache, so `npm ci --offline` works
#     cargo/                      CARGO_HOME, so cargo resolves offline
#   <vendor>/<arch>/
#     electron/v<ver>/            the Electron runtime, laid out like the mirror
#     node-headers/...            node-gyp headers + the SHASUMS256.txt it wants
#     foundry/                    Foundry Local NuGet packages
#     vsix/                       the built-in extensions
#     ripgrep/linux-<arch>/rg     only where upstream replaces it (loong64)
#
# manifests/<arch>.list lists the downloads as:
#
#   <sha256>  <path under <vendor>/<arch>>  <url>
#
# A sha256 of "-" means "not pinned"; fetch.sh records what it got in MANIFEST.
#
# The npm and cargo caches cannot be downloaded - they are produced by building -
# so fetch.sh seeds them from the local machine's caches when they exist. Run it
# on a machine of the target architecture to capture that architecture's
# optional native prebuilds.
#
# Then build with build/linux/uos25/build-deb.sh --offline.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../../../.." && pwd)"
# The vendor data lives under debian/ so that it travels with the source tree.
# debian/source/options keeps it out of the source package, and debian/.gitignore
# keeps it out of git - it is build input, not something to commit.
VENDOR_DIR="${UOS25_VENDOR_DIR:-${REPO_ROOT}/debian/vendor}"
MANIFEST_DIR="${HERE}/manifests"

VSCODE_COMMIT="${UOS25_VSCODE_COMMIT:-07f806f999227108933c2e30515b26eecc1fda74}"
VSCODE_REPO="${UOS25_VSCODE_REPO:-https://github.com/Microsoft/vscode.git}"
RUST_GIT_DEPS=(
  "https://github.com/microsoft/vscode-russh|fd4f608a83753f9f3e137f95600faffede71cf65|vscode-russh.git"
  "https://github.com/microsoft/dev-tunnels|64048c1409ff56cb958b879de7ea069ec71edc8b|dev-tunnels.git"
)

usage() {
  echo "usage: $0 <arch> [<arch>...]   (arch: amd64 arm64 loong64)" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage

# {{{ url validation
# Every URL here is a fixed upstream address, but it is still checked before
# being requested: only http(s), and never a loopback, private or local host.
validate_url() {
  local url="$1" host
  case "${url}" in
    https://*|http://*) ;;
    *) echo "error: refusing non-http(s) url: ${url}" >&2; return 1 ;;
  esac
  host="${url#*://}"
  host="${host%%/*}"
  host="${host%%:*}"
  case "${host}" in
    localhost|localhost.*|127.*|0.0.0.0|\[::1\]|::1|10.*|192.168.*|169.254.*|*.local|*.internal)
      echo "error: refusing local/private host: ${url}" >&2; return 1 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*)
      echo "error: refusing private host: ${url}" >&2; return 1 ;;
  esac
  return 0
}
# }}}

download() {
  local url="$1" dest="$2" want="$3"
  local attempt
  validate_url "${url}"
  mkdir -p "$(dirname "${dest}")"
  for attempt in $(seq 1 10); do
    if [[ -f "${dest}" ]]; then
      if [[ "${want}" == "-" ]] || [[ "$(sha256sum "${dest}" | cut -d' ' -f1)" == "${want}" ]]; then
        echo "    have $(basename "${dest}")"
        return 0
      fi
      rm -f "${dest}"
    fi
    echo "    fetching $(basename "${dest}") (attempt ${attempt})"
    if curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 -o "${dest}.part" "${url}"; then
      mv -f "${dest}.part" "${dest}"
      if [[ "${want}" != "-" ]] && [[ "$(sha256sum "${dest}" | cut -d' ' -f1)" != "${want}" ]]; then
        echo "    checksum mismatch for ${url}" >&2
        rm -f "${dest}"
        continue
      fi
      return 0
    fi
    rm -f "${dest}.part"
    sleep 10
  done
  echo "error: could not fetch ${url}" >&2
  return 1
}

git_mirror() {
  local url="$1" ref="$2" dest="$3"
  local attempt
  validate_url "${url}"
  if [[ -d "${dest}/objects" ]] && git -C "${dest}" cat-file -e "${ref}^{commit}" 2>/dev/null; then
    echo "    have $(basename "${dest}")"
    return 0
  fi
  echo "    cloning $(basename "${dest}")"
  rm -rf "${dest}"
  mkdir -p "${dest}"
  git init -q --bare "${dest}"
  for attempt in $(seq 1 10); do
    if git -C "${dest}" fetch --depth 1 "${url}" "${ref}" 2>&1; then
      return 0
    fi
    echo "    fetch attempt ${attempt} failed"
    sleep 10
  done
  echo "error: could not fetch ${url} ${ref}" >&2
  return 1
}

# node-gyp downloads SHASUMS256.txt next to the headers it wants, so it has to
# exist; the format it parses is plain `sha256sum` output.
write_shasums() {
  local dir="$1"
  ( cd "${dir}" && sha256sum ./*.tar.gz > SHASUMS256.txt )
  echo "    wrote $(basename "${dir}")/SHASUMS256.txt"
}

seed_cache() {
  local src="$1" dest="$2" what="$3"
  if [[ ! -d "${src}" ]]; then
    echo "  warning: no local ${what} at ${src}; run this on a machine that has built once" >&2
    return 0
  fi
  echo "  seeding ${what} from ${src}"
  mkdir -p "${dest}"
  cp -a "${src}/." "${dest}/"
}

fetch_shared() {
  local shared="${VENDOR_DIR}/shared"
  echo "== shared -> ${shared} =="
  mkdir -p "${shared}"
  git_mirror "${VSCODE_REPO}" "${VSCODE_COMMIT}" "${shared}/git/vscode.git"
  local entry url ref name
  for entry in "${RUST_GIT_DEPS[@]}"; do
    IFS='|' read -r url ref name <<< "${entry}"
    git_mirror "${url}" "${ref}" "${shared}/git/rust/${name}"
  done
  # Cargo's registry/src is 1.8 GB of extracted sources that cargo re-creates
  # from the cache, so only index, cache and git are worth carrying.
  mkdir -p "${shared}/cargo"
  for sub in registry/index registry/cache git; do
    if [[ -d "${HOME}/.cargo/${sub}" ]]; then
      mkdir -p "${shared}/cargo/${sub}"
      cp -a "${HOME}/.cargo/${sub}/." "${shared}/cargo/${sub}/"
      echo "  seeded cargo ${sub}"
    fi
  done
  seed_cache "${HOME}/.npm" "${shared}/npm-cache" "npm cache"
}

fetch_arch() {
  local arch="$1"
  local list="${MANIFEST_DIR}/${arch}.list"
  local root="${VENDOR_DIR}/${arch}"

  if [[ ! -f "${list}" ]]; then
    echo "error: no manifest for arch ${arch}" >&2
    return 1
  fi

  echo "== ${arch} -> ${root} =="
  mkdir -p "${root}"

  local sha path url
  while read -r sha path url; do
    [[ -z "${sha}" || "${sha}" == \#* ]] && continue
    download "${url}" "${root}/${path}" "${sha}"
  done < "${list}"

  # node-gyp wants a SHASUMS256.txt beside the headers it downloads.
  local d
  for d in "${root}"/node-headers/electron/*/ "${root}"/node-headers/node/*/; do
    [[ -d "${d}" ]] || continue
    if compgen -G "${d}*.tar.gz" > /dev/null; then
      write_shasums "${d%/}"
    fi
  done

  {
    echo "# ${arch} vendor contents, generated by vendor/fetch.sh"
    echo "# date: $(date -Iseconds)"
    ( cd "${root}" && find . -type f -print0 | sort -z | xargs -0 sha256sum )
  } > "${root}/MANIFEST"
  echo "  wrote ${root}/MANIFEST"
}

for arch in "$@"; do
  case "${arch}" in
    amd64|arm64|loong64) ;;
    *) echo "error: unsupported arch ${arch}" >&2; usage ;;
  esac
done

fetch_shared
for arch in "$@"; do
  fetch_arch "${arch}"
done

echo
echo "vendor ready: ${VENDOR_DIR}"
echo "build offline with:  ./build/linux/uos25/build-deb.sh --offline"
