#!/usr/bin/env bash
# Compile the workbench for UOS 25.
#
# This is build.sh plus a two-phase dependency install.
#
# Upstream's prepare_vscode.sh runs a single `npm ci`, which executes every
# package's install script. One of them, foundry-local-sdk, downloads roughly
# 470 MB of NuGet packages (the CUDA ONNX Runtime and Foundry Local native
# libraries) with Node's plain `https.get`, which does not honour a proxy and
# is heavily rate limited from a UOS network - the install can stall for hours.
#
# The script short-circuits when the libraries are already present, so the
# packages are extracted without scripts, the libraries are seeded from
# UOS25_FOUNDRY_SEED, and `npm rebuild` then runs every install script as
# before. Everything else is identical to build.sh.
#
# Expects: get_repo.sh has checked out vscode/, and env.sh has been sourced.

# Note: no `-u`. version.sh and prepare_vscode.sh test unset variables, exactly
# as they do under build.sh's `set -ex`.
set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${ROOT}"

export MAX_OLD_SPACE_SIZE="${MAX_OLD_SPACE_SIZE:-8192}"
FOUNDRY_SEED="${UOS25_FOUNDRY_SEED:-/tmp/foundry-seed}"

# shellcheck disable=SC1091
. version.sh

echo "MS_COMMIT=\"${MS_COMMIT}\""

# {{{ phase 1: brand the tree and extract dependencies
echo "== installing dependencies (no scripts) =="
export npm_config_ignore_scripts=true
# shellcheck disable=SC1091
. prepare_vscode.sh
unset npm_config_ignore_scripts
# }}}

cd vscode

# {{{ phase 2: seed the Foundry Local libraries, then run install scripts
if [[ -d "${FOUNDRY_SEED}/linux-x64" ]]; then
  echo "== seeding Foundry Local native libraries =="
  mkdir -p node_modules/foundry-local-sdk/foundry-local-core/linux-x64
  cp -a "${FOUNDRY_SEED}/linux-x64/." node_modules/foundry-local-sdk/foundry-local-core/linux-x64/
else
  echo "warning: ${FOUNDRY_SEED}/linux-x64 not found - foundry-local-sdk will download its" >&2
  echo "         native libraries itself, which can be very slow" >&2
fi

echo "== running package install scripts =="
# `npm ci` treats a failing install script of an optional dependency as
# non-fatal (it drops the package and carries on); `npm rebuild` propagates the
# exit status instead. cpu-features and buildcheck - optional dependencies of
# ssh2 that cannot be built against Electron's headers - fail this way, so the
# status is tolerated here exactly as npm ci tolerates it.
npm rebuild || echo "warning: npm rebuild reported errors; optional dependencies such as cpu-features are expected to fail and are dropped by npm ci as well" >&2

# The root package's `postinstall` (node build/npm/postinstall.ts) installs the
# dependencies of build/ and of the bundled extensions. `npm ci` runs it;
# `--ignore-scripts` skipped it, so it is invoked explicitly here.
echo "== installing build and extension dependencies =="
node build/npm/postinstall.ts
# }}}

# {{{ phase 3: compile
echo "== compiling =="
export NODE_OPTIONS="--max-old-space-size=${MAX_OLD_SPACE_SIZE}"
export VSCODE_PUBLISH_COUNTER=1

npm run gulp vscode-min-prepack
# }}}

cd ..
echo "compile done"
