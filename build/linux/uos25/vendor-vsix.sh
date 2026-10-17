#!/usr/bin/env bash
# Point the built-in extensions at vendored .vsix files.
#
# build/lib/builtInExtensions.ts prefers `extension.vsix` over downloading from
# GitHub, and resolves it relative to the VS Code checkout. Setting that field is
# therefore all that is needed to keep the packaging step offline.
#
# Called by compile.sh after prepare_vscode.sh has written product.json.
# No-op unless UOS25_VSIX_DIR is set (see offline.sh).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
VSCODE_DIR="${ROOT}/vscode"
PRODUCT_JSON="${VSCODE_DIR}/product.json"

if [[ -z "${UOS25_VSIX_DIR:-}" ]]; then
  exit 0
fi
if [[ ! -d "${UOS25_VSIX_DIR}" ]]; then
  echo "error: UOS25_VSIX_DIR=${UOS25_VSIX_DIR} does not exist" >&2
  exit 1
fi
if [[ ! -f "${PRODUCT_JSON}" ]]; then
  echo "error: ${PRODUCT_JSON} not found" >&2
  exit 1
fi

echo "== pointing built-in extensions at ${UOS25_VSIX_DIR} =="

python3 - "${PRODUCT_JSON}" "${UOS25_VSIX_DIR}" "${VSCODE_DIR}" <<'PY'
import json
import os
import sys

product_json, vsix_dir, vscode_dir = sys.argv[1], sys.argv[2], sys.argv[3]

with open(product_json, encoding='utf-8') as handle:
    product = json.load(handle)

available = sorted(os.listdir(vsix_dir))
patched = 0
missing = []

for extension in product.get('builtInExtensions') or []:
    name, version = extension.get('name'), extension.get('version')
    # Vendored files are named <extension id>.<version>.vsix, which is how the
    # upstream releases name them.
    wanted = f'{name}.{version}.vsix'
    if wanted not in available:
        missing.append(f'{name}@{version}')
        continue
    # build/lib/builtInExtensions.ts resolves this with path.join(root, vsix),
    # so it has to be relative to the VS Code checkout.
    relative = os.path.relpath(os.path.join(vsix_dir, wanted), vscode_dir)
    extension['vsix'] = relative
    patched += 1

if missing:
    print(f'  warning: no vendored vsix for: {", ".join(missing)}', file=sys.stderr)

with open(product_json, 'w', encoding='utf-8') as handle:
    json.dump(product, handle, indent='\t')
    handle.write('\n')

print(f'  {patched} extension(s) use vendored vsix files')
PY
