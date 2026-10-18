// Register the Node 20 compatibility loader.
//
// See loader.mjs for what it does and README.md for why it exists. Put into
// NODE_OPTIONS by env.sh when the running Node is older than 22.6:
//
//   NODE_OPTIONS="--import file:///path/to/register.mjs"
//
// `--import` is available from Node 20.6, and applies to every node process the
// build starts - which is what makes this work without patching the npm scripts
// that hand .ts files to node.

import { register } from 'node:module';

register('./loader.mjs', import.meta.url);
