#!/usr/bin/env bash
# Seed the Foundry Local native libraries so `npm ci` does not have to fetch them.
#
# foundry-local-sdk's install script downloads the Foundry Local Core, ONNX
# Runtime (CUDA) and ONNX Runtime GenAI NuGet packages - about 470 MB - using
# Node's `https.get`, which ignores a proxy and is heavily rate limited from a
# UOS network. It skips any package whose main library is already present, so
# fetching the same packages with curl (which does honour a proxy) and dropping
# the libraries in place makes the install finish in seconds.
#
# The seed directory is consumed by compile.sh through UOS25_FOUNDRY_SEED.
#
# Usage: ./build/linux/uos25/seed-foundry.sh [--nupkg-dir DIR] [--out DIR]

set -euo pipefail

NUPKG_DIR="${UOS25_FOUNDRY_NUPKG_DIR:-/tmp/foundry-nupkgs}"
OUT="${UOS25_FOUNDRY_SEED:-/tmp/foundry-seed}"
RID="${UOS25_FOUNDRY_RID:-linux-x64}"
VERSIONS_FILE="${UOS25_FOUNDRY_VERSIONS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nupkg-dir) NUPKG_DIR="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# NuGet flat-container coordinates of the three packages the install script
# uses on linux-x64 (see foundry-local-sdk/script/install-standard.cjs).
PACKAGES=(
  "microsoft.ai.foundry.local.core/1.2.3"
  "microsoft.ml.onnxruntime.gpu.linux/1.26.0"
  "microsoft.ml.onnxruntimegenai.foundry/0.14.1"
)

mkdir -p "${NUPKG_DIR}" "${OUT}/${RID}"

for spec in "${PACKAGES[@]}"; do
  name="${spec%%/*}"
  version="${spec##*/}"
  nupkg="${NUPKG_DIR}/${name}.${version}.nupkg"
  if [[ ! -s "${nupkg}" ]]; then
    url="https://api.nuget.org/v3-flatcontainer/${name}/${version}/${name}.${version}.nupkg"
    echo "fetch   ${url}" >&2
    curl -fsSL --retry 5 --retry-delay 5 -o "${nupkg}" "${url}"
  fi
  echo "extract ${name}.${version} (${RID})" >&2
  python3 - "${nupkg}" "${OUT}/${RID}" "${RID}" <<'PY'
import sys, zipfile, os, shutil

nupkg, out_dir, rid = sys.argv[1], sys.argv[2], sys.argv[3]
prefix = f"runtimes/{rid}/native/"
os.makedirs(out_dir, exist_ok=True)
with zipfile.ZipFile(nupkg) as z:
    for entry in z.namelist():
        if not entry.startswith(prefix):
            continue
        base = os.path.basename(entry)
        if not base.endswith(".so") or not base:
            continue
        with z.open(entry) as src, open(os.path.join(out_dir, base), "wb") as dst:
            shutil.copyfileobj(src, dst)
        print(f"  {base}", file=sys.stderr)
PY
done

cat > "${OUT}/${RID}/package.json" <<EOF
{
  "name": "@foundry-local-core/${RID}",
  "version": 1.2.3,
  "description": "Native binaries for Foundry Local SDK (${RID})",
  "private": true
}
EOF

echo "seed ready: ${OUT}/${RID}" >&2
ls -l "${OUT}/${RID}" >&2
