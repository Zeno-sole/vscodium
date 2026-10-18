// Make @vscode/gulp-electron work on Node 20.
//
// gulp-electron is CommonJS, and src/download.js does three `require()` calls of
// packages that are ESM-only - @electron/get, @octokit/rest and got all ship
// `"type": "module"` with no CommonJS entry:
//
//   const { downloadArtifact } = require("@electron/get");
//   const { Octokit } = require("@octokit/rest");
//   const got = require("got").default;
//
// require() of an ES module is only supported from Node 22.12, so on Node 20 the
// electron download step fails with ERR_REQUIRE_ESM. Each require is turned into
// a dynamic import inside the (async) function that uses it, which works on
// every Node the build supports.
//
// This patches a published package, so it is deliberately strict: exact text
// matching, no guessing, and a clear failure if the package no longer has the
// shape it expects. It runs after each `npm ci`, because that recreates
// node_modules.
//
//   node patch-modules.mjs <repository-root>

import { readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';

const rootArg = process.argv[2];
if (!rootArg) {
  console.error('usage: patch-modules.mjs <repository-root>');
  process.exit(2);
}

const ROOT = path.resolve(rootArg);
if (!existsSync(ROOT)) {
  console.error(`not a directory: ${ROOT}`);
  process.exit(1);
}

const RELATIVE_TARGET = 'vscode/node_modules/@vscode/gulp-electron/src/download.js';
const TARGET = path.resolve(ROOT, RELATIVE_TARGET);
if (!TARGET.startsWith(ROOT + path.sep)) {
  console.error(`refusing to touch ${TARGET}: outside ${ROOT}`);
  process.exit(1);
}
if (!existsSync(TARGET)) {
  console.log(`  ${RELATIVE_TARGET} not present, skipping`);
  process.exit(0);
}

// One entry per ESM-only dependency: the require line, the lazy loader that
// replaces it, and the call sites that have to await it.
const PATCHES = [
  {
    marker: '__uos25ElectronGet',
    requireFrom: 'const { downloadArtifact } = require("@electron/get");',
    requireTo: [
      '// Patched for Node 20: @electron/get is ESM-only and require() of an ES',
      '// module needs Node 22.12, so it is imported on demand instead.',
      'let __uos25ElectronGet;',
      'async function __uos25LoadElectronGet() {',
      '  return (__uos25ElectronGet ??= await import("@electron/get"));',
      '}'
    ].join('\n'),
    calls: [
      {
        // The arrow passed to withRetry has to become async for the await.
        from: [
          'return await withRetry(`download ${opts.artifactName || "electron"}`, () =>',
          '    downloadArtifact(downloadOpts)',
          '  );'
        ].join('\n'),
        to: [
          'return await withRetry(`download ${opts.artifactName || "electron"}`, async () =>',
          '    (await __uos25LoadElectronGet()).downloadArtifact(downloadOpts)',
          '  );'
        ].join('\n')
      }
    ]
  },
  {
    marker: '__uos25Octokit',
    requireFrom: 'const { Octokit } = require("@octokit/rest");',
    requireTo: [
      '// Patched for Node 20: @octokit/rest is ESM-only.',
      'let __uos25Octokit;',
      'async function __uos25LoadOctokit() {',
      '  return (__uos25Octokit ??= await import("@octokit/rest"));',
      '}'
    ].join('\n'),
    calls: [
      {
        from: 'const octokit = new Octokit({ auth: token });',
        to: 'const octokit = new (await __uos25LoadOctokit()).Octokit({ auth: token });'
      }
    ]
  },
  {
    marker: '__uos25Got',
    requireFrom: 'const got = require("got").default;',
    requireTo: [
      '// Patched for Node 20: got is ESM-only.',
      'let __uos25Got;',
      'async function __uos25LoadGot() {',
      '  return (__uos25Got ??= await import("got"));',
      '}'
    ].join('\n'),
    calls: [
      {
        from: [
          'const response = await withRetry("HEAD release asset", () =>',
          '    got(url, {'
        ].join('\n'),
        to: [
          'const response = await withRetry("HEAD release asset", async () =>',
          '    (await __uos25LoadGot()).default(url, {'
        ].join('\n')
      }
    ]
  }
];

let source = await readFile(TARGET, 'utf8');
const applied = [];
const failures = [];

for (const patch of PATCHES) {
  if (source.includes(patch.marker)) {
    continue;
  }
  if (!source.includes(patch.requireFrom)) {
    failures.push(`${patch.requireFrom}  (require line)`);
    continue;
  }
  source = source.replace(patch.requireFrom, patch.requireTo);
  for (const call of patch.calls) {
    if (!source.includes(call.from)) {
      failures.push(`${call.from.split('\n')[0]}  (call site)`);
      continue;
    }
    source = source.replace(call.from, call.to);
  }
  applied.push(patch.marker);
}

if (failures.length > 0) {
  console.error(`error: ${RELATIVE_TARGET} does not have the expected shape:`);
  for (const failure of failures) {
    console.error(`  missing ${failure}`);
  }
  console.error('       The package changed; the Node 20 patch needs revisiting.');
  process.exit(1);
}

if (applied.length === 0) {
  console.log('  already patched');
  process.exit(0);
}

if (!TARGET.startsWith(ROOT + path.sep)) {
  console.error(`refusing to write ${TARGET}: outside ${ROOT}`);
  process.exit(1);
}
await writeFile(TARGET, source);
console.log(`  patched ${RELATIVE_TARGET} (${applied.length} require${applied.length === 1 ? '' : 's'})`);
