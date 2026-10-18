# Building on Node 20

UOS 25 ships Node.js 20, and the VS Code 1.140 build tooling assumes considerably
newer. This directory supplies what is missing, so the package can be built with
the Node in the archive instead of a NodeSource one.

## What Node 20 lacks

Three things, all verified against 20.15.1 (the version in the UOS 25 archive):

| Feature | Needs | What breaks without it |
| --- | --- | --- |
| `--experimental-strip-types` | 22.6 | the build is TypeScript executed directly (`npm run gulp`, a dozen npm scripts, `build/**/*.ts`, and each bundled extension's `esbuild.mts`); Node 20 rejects the flag and the `.ts` and `.mts` extensions |
| `import.meta.main` | 22 | used as the entry-point guard in 24 build scripts; it is `undefined` on Node 20, so those scripts exit silently instead of doing their job |
| `require()` of an ES module | 22.12 | several build dependencies are ESM-only and are `require()`d from CommonJS code |

`--experimental-require-module` does not exist on 20.15.1 either, so the third one
cannot be turned on with a flag.

## How this directory supplies them

**`loader.mjs` / `register.mjs`** - an ESM loader, registered through
`NODE_OPTIONS="--import file://.../register.mjs"` (`--import` is available from
Node 20.6, and applies to every node process the build starts, which is why no
npm script has to be rewritten):

* transpiles `.ts` and `.mts` on the way in, using the TypeScript the VS Code
  tree already depends on (`node_modules/typescript`, whose `transpileModule` is
  exactly the erasure `--experimental-strip-types` performs - the build's
  TypeScript is erasable-only, no enums or parameter properties). `.mts` matters
  as much as `.ts`: every bundled extension is built by its own `esbuild.mts`,
  spawned as `node <dir>/esbuild.mts`, and that is what the extension bundling
  step does 40-odd times;
* reads the extension from the path part of the URL rather than from its end.
  `extensions/markdown-language-features/esbuild.markdownEditor.mts` imports a
  helper with a cache-busting query string
  (`import(`${url.href}?version=${mtime}`)`), and a plain `url.endsWith('.mts')`
  test misses it - which shows up as `ERR_UNKNOWN_FILE_EXTENSION` from a child
  process that catches the failure and exits without printing it;
* defines `import.meta.main` per module where Node does not, comparing the
  module URL against `process.argv[1]` - the same thing Node does natively.

**`patch-modules.mjs`** - the `require()` of ESM problem is in the dependency
tree, not in the build's own code, so it cannot be solved by a loader hook: the
CommonJS `require` path is not covered by the ESM loader API. `@vscode/gulp-electron`
is CommonJS and requires three ESM-only packages (`@electron/get`,
`@octokit/rest`, `got`); each require is turned into a dynamic import inside the
async function that uses it. Run it after every `npm ci`, since that recreates
`node_modules`. It matches exact text and fails loudly if the package changes
shape.

**`gulpfile.ts`** - `build/gulpfile.ts` loads the other gulpfiles with
`require()`, and those are ES modules. That is fixed in the source tree by
`patches/00-build-load-gulpfiles-by-import.patch`, which uses dynamic import.

## The one ordering change

`prepare_vscode.sh` runs `node build/npm/preinstall.ts` *before* `npm ci`. On
Node 20 the loader needs TypeScript, which `npm ci` is what installs, so in this
mode the step is deferred: `compile.sh` runs it right after `npm ci` (with
`VSCODE_FORCE_INSTALL=1`, so the fast path cannot skip it) and before
`npm rebuild`. Nothing else in the pipeline is reordered.

## Scope

All of this is inactive when the running Node is 22.6 or newer: `env.sh` only
registers the loader and switches the gulp invocation below that threshold, and
the patches are no-ops for a newer Node (the dynamic import and the shim both
behave exactly as the native features do).

The patches are pinned to VS Code 1.140.0. `patch-modules.mjs` refuses to guess
if the shape of the package changes; `patches/00-build-load-gulpfiles-by-import.patch`
fails to apply on its own if the file moves.
