// Work around the truncated llhttp wasm that UOS 25's node-undici installs.
//
// Why this exists. UOS 25's nodejs 20.15.1 does not carry its own undici: libnode
// is compiled with
//
//   NODE_SHARED_BUILTIN_UNDICI_UNDICI_PATH=/usr/share/nodejs/undici/undici-fetch.js
//
// so `node:internal/deps/undici/undici` - and with it fetch() - comes from the
// node-undici package. The llhttp wasm in that package is stored as a base64
// string that is three separately padded chunks concatenated, and undici feeds it
// to WebAssembly through
//
//   WebAssembly.compile(Buffer.from(require('./llhttp/llhttp-wasm.js'), 'base64'))
//
// Node's base64 decoder stops at the first '=' it meets, so it compiles the first
// 25711 bytes of a 58593-byte module and WebAssembly rejects that with
//
//   CompileError: WebAssembly.compile(): section (code 10, "Code") extends past
//   end of the module (length 47503, remaining bytes 24350) @+1357
//
// Every fetch() in the process then fails. The build needs fetch() to work even
// though it has no network: several steps call it, tolerate the network error and
// carry on, but a WebAssembly CompileError is not a network error and takes the
// build down with it, minutes later, in a step that looks unrelated.
//
// The package also installs the same module intact, as the file `llhttp-wasm`
// next to the broken string (and the chunks, decoded separately, are byte for
// byte that file). This shim hands WebAssembly that complete module instead. It
// is loaded through NODE_OPTIONS=--import together with the Node 20 loader, so
// every node process the build starts - including the ones npm spawns - gets it.
//
// This is deliberately narrow: it only touches a buffer that starts like a wasm
// module and whose section table runs past its end, and only when the complete
// copy it finds begins with exactly those bytes. Anything else is passed through
// untouched, and on a node whose undici is intact this is a no-op.
//
// The underlying bug belongs to UOS 25's node-undici packaging; this is the
// build-side workaround, chosen over repairing the installed file because the
// internal build platform gives the build no root.

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import path from 'node:path';

const RELATIVE = path.join('lib', 'llhttp', 'llhttp-wasm');

// Where the intact copy can be. The package's own directory is derived from
// node's resolution when the system undici is on the module path (Debian adds
// /usr/share/nodejs to it), and the literal path is what libnode was compiled
// against, so it works even then.
function candidates() {
	const found = [];
	try {
		const require = createRequire(import.meta.url);
		const packageJson = require.resolve('undici/package.json');
		found.push(path.join(path.dirname(packageJson), RELATIVE));
	} catch {
		// undici is not resolvable from here; fall through to the literal path
	}
	if (process.env.UOS25_LLHTTP_WASM) {
		found.push(process.env.UOS25_LLHTTP_WASM);
	}
	found.push('/usr/share/nodejs/undici/' + RELATIVE);
	return found;
}

function toBytes(input) {
	if (input instanceof ArrayBuffer) {
		return new Uint8Array(input);
	}
	if (ArrayBuffer.isView(input)) {
		return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
	}
	return undefined;
}

// A module whose section table runs past the end of the buffer. Written out
// rather than using WebAssembly.validate(), which would also reject a module that
// is complete but uses a feature this node does not know.
function isTruncated(bytes) {
	if (!bytes || bytes.length < 8 || bytes[0] !== 0 || bytes[1] !== 0x61 || bytes[2] !== 0x73 || bytes[3] !== 0x6d) {
		return false;
	}
	let offset = 8;
	while (offset < bytes.length) {
		const id = bytes[offset++];
		if (id > 12) {
			return false; // not a section id we recognise, so not a module we understand
		}
		let length = 0;
		let shift = 0;
		let byte;
		do {
			if (offset >= bytes.length) {
				return true; // the section length itself is cut short
			}
			byte = bytes[offset++];
			length += (byte & 0x7f) * 2 ** shift;
			shift += 7;
		} while (byte & 0x80);
		if (offset + length > bytes.length) {
			return true;
		}
		offset += length;
	}
	return false;
}

// The complete module, if one of the candidates is the same module with more of
// it: the truncated buffer has to be a prefix of it, byte for byte.
function completeModule(bytes) {
	for (const candidate of candidates()) {
		let full;
		try {
			full = readFileSync(candidate);
		} catch {
			continue;
		}
		if (full.length > bytes.length && full.subarray(0, bytes.length).equals(bytes)) {
			return full;
		}
	}
	return undefined;
}

let reported = false;

function repair(input) {
	const bytes = toBytes(input);
	if (!isTruncated(bytes)) {
		return undefined;
	}
	const full = completeModule(bytes);
	if (!full) {
		return undefined;
	}
	if (!reported) {
		reported = true;
		process.stderr.write(
			`llhttp-shim: replaced a ${bytes.length}-byte truncated wasm module with the ` +
			`${full.length}-byte copy node-undici also installs (see build/linux/uos25/node20/llhttp-shim.mjs)\n`
		);
	}
	return full;
}

// Both of these take a buffer and return a promise; only the buffer form needs
// looking at, and only the argument is replaced.
const compile = WebAssembly.compile;
WebAssembly.compile = function (input, ...rest) {
	return compile.call(WebAssembly, repair(input) ?? input, ...rest);
};

const instantiate = WebAssembly.instantiate;
WebAssembly.instantiate = function (input, ...rest) {
	if (ArrayBuffer.isView(input) || input instanceof ArrayBuffer) {
		return instantiate.call(WebAssembly, repair(input) ?? input, ...rest);
	}
	return instantiate.call(WebAssembly, input, ...rest);
};
