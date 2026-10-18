// ESM loader that lets Node 20 run the VS Code build tooling.
//
// The build is written in TypeScript and executed directly: `npm run gulp` and
// a dozen npm scripts hand .ts files to node, relying on `--experimental-strip-types`,
// which exists from Node 22.6. Node 20 - what UOS 25 ships - rejects the flag
// outright, and without it refuses the .ts extension.
//
// Two things are needed, and both are done here so that no upstream file has to
// be rewritten:
//
//   * transpile TypeScript on the way in. The compiler is the TypeScript that
//     the VS Code tree already depends on (node_modules/typescript), used
//     through its transpileModule API - the build's TypeScript is
//     erasable-only, so this is the same erasure `--experimental-strip-types`
//     performs. The set of extensions is the one that flag accepts: .ts and
//     .mts. The extension is what decides the module system here rather than
//     the nearest package.json, because every .ts in the VS Code tree is ESM
//     (`vscode/package.json` is `"type": "module"`) and .mts always is.
//
//   * provide `import.meta.main`, which is undefined before Node 22. The build
//     guards ~24 entry points with it, and without it those scripts exit
//     silently instead of doing their job. It is defined per module here rather
//     than by patching each site.
//
// Registered by register.mjs, which env.sh puts into NODE_OPTIONS when the
// running Node is too old. See README.md in this directory.

import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

// build/linux/uos25/node20/loader.mjs -> repository root
const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../..');
const VSCODE_DIR = path.join(REPO_ROOT, 'vscode');

// The extensions `--experimental-strip-types` accepts. .mts matters as much as
// .ts: every bundled extension is built by its own esbuild.mts, spawned as
// `node <dir>/esbuild.mts`.
const TS_EXTENSIONS = ['.ts', '.mts'];

// The extension is read from the path part of the URL rather than from its end,
// because a few modules are imported with a cache-busting query string -
// extensions/markdown-language-features/esbuild.markdownEditor.mts does
// `import(`${url.href}?version=${mtime}`)`. `fileURLToPath` drops the query
// again, so this test is the only place that has to see through it.
function isTypeScript(url) {
  const pathname = url.split('?')[0].split('#')[0];
  return TS_EXTENSIONS.some((ext) => pathname.endsWith(ext));
}

const requireFromVscode = createRequire(pathToFileURL(path.join(VSCODE_DIR, 'package.json')));

let typescript;
function getTypeScript() {
  if (!typescript) {
    typescript = requireFromVscode('typescript');
  }
  return typescript;
}

// Prepended to every transpiled module. `import.meta` is an ordinary extensible
// object, so the property can simply be added where Node does not define it.
const MAIN_SHIM = [
  "import { fileURLToPath as __uos25FileURLToPath } from 'node:url';",
  "import { resolve as __uos25Resolve } from 'node:path';",
  "if (!('main' in import.meta)) {",
  '  Object.defineProperty(import.meta, \'main\', {',
  '    configurable: true,',
  '    value: process.argv[1] !== undefined &&',
  '      __uos25FileURLToPath(import.meta.url) === __uos25Resolve(process.argv[1])',
  '  });',
  '}',
  ''
].join('\n');

function transpile(source, url) {
  const ts = getTypeScript();
  const result = ts.transpileModule(source, {
    fileName: url,
    compilerOptions: {
      module: ts.ModuleKind.ESNext,
      target: ts.ScriptTarget.ES2022,
      // Each file is transpiled on its own, exactly like the built-in stripping.
      isolatedModules: true,
      verbatimModuleSyntax: true,
      allowImportingTsExtensions: true,
      sourceMap: false,
      inlineSourceMap: false
    },
    reportDiagnostics: false
  });
  return result.outputText;
}

export async function resolve(specifier, context, nextResolve) {
  try {
    return await nextResolve(specifier, context);
  } catch (error) {
    // Node's default resolver does not know the TypeScript extensions. The
    // build writes those specifiers as real relative paths, so resolving them
    // against the importing module is all that is missing.
    if (!isTypeScript(specifier)) {
      throw error;
    }
    if (specifier.startsWith('.') || specifier.startsWith('/')) {
      const base = context.parentURL ? new URL(specifier, context.parentURL) : pathToFileURL(specifier);
      return { url: base.href, format: 'module', shortCircuit: true };
    }
    throw error;
  }
}

export async function load(url, context, nextLoad) {
  if (!isTypeScript(url)) {
    return nextLoad(url, context);
  }
  const source = await readFile(fileURLToPath(url), 'utf8');
  const js = transpile(source, url);
  return { format: 'module', source: MAIN_SHIM + js, shortCircuit: true };
}
