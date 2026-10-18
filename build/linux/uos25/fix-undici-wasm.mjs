#!/usr/bin/env node
// Repair the llhttp wasm that UOS 25's node-undici ships truncated.
//
// Why this is needed. On UOS 25 the archive's nodejs 20.15.1 does not carry its
// own undici: libnode is compiled with
//
//   NODE_SHARED_BUILTIN_UNDICI_UNDICI_PATH=/usr/share/nodejs/undici/undici-fetch.js
//
// so `node:internal/deps/undici/undici` - and with it fetch() - comes from the
// node-undici package. The llhttp wasm in that package is stored as a base64
// string, and it is broken: three separately padded chunks concatenated into one
// string, e.g.
//
//   module.exports = "<chunk1>==" + "<chunk2>==" + "<chunk3>=="
//
// undici then does
//
//   WebAssembly.compile(Buffer.from(<that string>, 'base64'))
//
// and Node's base64 decoder stops at the first '=' it meets, so it compiles the
// first 25711 bytes of a 58593-byte module. WebAssembly rejects that with
//
//   CompileError: WebAssembly.compile(): section (code 10, "Code") extends past
//   end of the module (length 47503, remaining bytes 24350) @+1357
//
// and every fetch() in the process fails. That breaks npm's own install scripts
// and the parts of the VS Code build that download anything, which is how it
// shows up here: a build that dies minutes in with a WebAssembly error from
// somewhere unrelated.
//
// The payload appears more than once - the standalone lib/llhttp/llhttp-wasm.js,
// which the undici package uses, and the inlined copy inside undici-fetch.js,
// which is the one Node's builtin actually reads - so this scans the installed
// tree rather than repairing one path. The chunks are not corrupt: decoded
// separately they are byte-identical to the intact copy the package also ships
// as lib/llhttp/llhttp-wasm. Only the concatenation of their padding is wrong,
// so re-encoding them as one unpadded string is the whole repair.
//
//   node fix-undici-wasm.mjs            repair (needs write access to the files)
//   node fix-undici-wasm.mjs --check    report only, exit 1 if anything is broken
//   node fix-undici-wasm.mjs [--check] <path>
//                                       a file, or a directory to scan
//
// The pbuilder build runs this from an A hook (pbuilder/hooks/A10undici), which
// runs as root after the build dependencies are installed and before the build
// starts. A host build has to run it itself, as root, because the files belong to
// the system nodejs.

import { readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const args = process.argv.slice(2).filter((a) => a !== '--check');
const checkOnly = process.argv.includes('--check');
const ROOT = args[0] || process.env.UOS25_UNDICI_ROOT || '/usr/share/nodejs';

// Only string literals that look like an embedded wasm module are considered:
// base64 of the wasm magic is 'AGFzbQ'. Everything else in the tree is left
// alone, whatever it looks like.
const PAYLOAD = /(["'])(AGFzbQ[A-Za-z0-9+/=]{200,})\1/g;

function say(message) {
	process.stdout.write(`fix-undici-wasm: ${message}\n`);
}

function* files(root) {
	let stat;
	try {
		stat = statSync(root);
	} catch {
		return;
	}
	if (stat.isFile()) {
		yield root;
		return;
	}
	let entries;
	try {
		entries = readdirSync(root, { withFileTypes: true });
	} catch {
		return;
	}
	for (const entry of entries) {
		const path = join(root, entry.name);
		if (entry.isDirectory()) {
			yield* files(path);
		} else if (entry.isFile() && entry.name.endsWith('.js')) {
			yield path;
		}
	}
}

// A well-formed base64 string carries padding only at the very end; anything
// before that is the signature of the concatenation bug.
function isBroken(payload) {
	return payload.replace(/=+$/, '').includes('=');
}

// The chunks, decoded separately and concatenated, are the bytes the string was
// meant to hold.
function decodeChunks(payload) {
	return Buffer.concat(payload.split(/(?<==)(?=[^=])/).map((chunk) => Buffer.from(chunk, 'base64')));
}

// Everything that has to hold before a repair is written back: the bytes are a
// wasm module, they compile, and re-encoding them survives the same decoder that
// undici uses.
function repairedPayload(bytes) {
	if (bytes.subarray(0, 4).toString('latin1') !== '\u0000asm') {
		return undefined;
	}
	if (!WebAssembly.validate(bytes)) {
		return undefined;
	}
	const encoded = bytes.toString('base64');
	if (!Buffer.from(encoded, 'base64').equals(bytes)) {
		return undefined;
	}
	return encoded;
}

let broken = 0;
let repaired = 0;

for (const path of files(ROOT)) {
	let source;
	try {
		source = readFileSync(path, 'utf8');
	} catch {
		continue;
	}
	if (!source.includes('AGFzbQ')) {
		continue;
	}

	let changed = false;
	const next = source.replace(PAYLOAD, (literal, quote, payload) => {
		if (!isBroken(payload)) {
			return literal;
		}
		const usable = Buffer.from(payload, 'base64').length;
		const bytes = decodeChunks(payload);
		const encoded = repairedPayload(bytes);
		if (!encoded) {
			say(`warning: ${path} has a padded base64 payload that is not a wasm module; left alone`);
			return literal;
		}
		broken++;
		if (checkOnly) {
			say(`${path} is broken: ${payload.length} base64 characters decode to ${usable} bytes of a ${bytes.length}-byte module`);
			return literal;
		}
		say(`${path}: ${usable} -> ${bytes.length} bytes of wasm`);
		changed = true;
		return `${quote}${encoded}${quote}`;
	});

	if (changed) {
		try {
			writeFileSync(path, next);
			repaired++;
		} catch (error) {
			say(`could not write ${path}: ${error.code || error.message}`);
			say('a host build has to run this as root; the pbuilder build repairs it in the chroot');
			process.exit(1);
		}
	}
}

if (broken === 0) {
	say(`${ROOT}: no truncated llhttp wasm found`);
} else if (checkOnly) {
	say(`${broken} truncated payload(s) under ${ROOT}; run without --check to repair`);
	process.exit(1);
} else {
	say(`repaired ${broken} payload(s) in ${repaired} file(s) under ${ROOT}`);
}
