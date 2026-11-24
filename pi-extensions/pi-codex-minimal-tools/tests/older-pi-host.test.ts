import assert from "node:assert/strict";
import { mkdirSync, readdirSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import * as piAi from "@earendil-works/pi-ai";
import { copyPackage, packageRoot, runCopySuites } from "./helpers/package-copy.js";

/* The shim keeps a fallback for each pi-ai export or subpath it reads that an older
 * supported host lacks. The suite installs Pi 1.6.0, so these rows run again in a
 * package copy whose pi-ai is 1.6.0 without them. The published 0.85.1 package exports
 * none of the transcript helpers (Pi 0.86.0 adds them), 0.85.1 and 1.0.1 export no
 * ToolCallArgumentsStream (1.5.0) and no getIdentityHeaders (1.4.0), and 0.75.0 exports
 * no api/simple-options subpath. */

const ABSENT_EXPORTS = ["getCurrentTools", "getDeclaredTools", "getSystemMessageText", "renderSystemMessageUpdate", "resolveTranscript", "ToolCallArgumentsStream", "getIdentityHeaders"];
// Printed by the stub, so the run shows its rows read the older surface and not the installed one.
const STUB_MARKER = "older-pi-host: pi-ai without the older hosts' exports";

const ROWS = [
	{ suite: "tests/transcript-context.test.ts", name: "the request carries the prompt and the tools of a context with the prompt and tool fields, Pi below 0.86" },
	{ suite: "tests/responses-stream-deltas.test.ts", name: "streamed function-call arguments are read once and parse once at completion" },
	{ suite: "tests/responses-stream-deltas.test.ts", name: "completed function-call arguments: an invalid escape" },
	{ suite: "tests/responses-stream-deltas.test.ts", name: "completed function-call arguments: malformed arguments" },
	{ suite: "tests/provider-sse-request.test.ts", name: "SSE transport sends the pi originator and the host's User-Agent" },
	{ suite: "tests/provider-sse-request.test.ts", name: "SSE transport sends max_output_tokens within the context window where the host clamps it" },
];

const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/** Link every installed module into the copy, with pi-ai replaced by a root-only re-export that leaves out ABSENT_EXPORTS. */
function installOlderPiAi(root: string): void {
	const modules = join(packageRoot, "node_modules");
	const scope = join(root, "node_modules", "@earendil-works");
	mkdirSync(scope, { recursive: true });
	for (const entry of readdirSync(modules)) if (entry !== "@earendil-works") symlinkSync(join(modules, entry), join(root, "node_modules", entry));
	for (const entry of readdirSync(join(modules, "@earendil-works"))) if (entry !== "pi-ai") symlinkSync(join(modules, "@earendil-works", entry), join(scope, entry));
	for (const name of ABSENT_EXPORTS) assert.ok(name in piAi, `the installed pi-ai exports ${name}`);
	const names = Object.keys(piAi).filter((name) => name !== "default" && !ABSENT_EXPORTS.includes(name));
	const stub = join(scope, "pi-ai");
	mkdirSync(stub);
	writeFileSync(join(stub, "package.json"), JSON.stringify({ name: "@earendil-works/pi-ai", type: "module", exports: { ".": "./index.mjs" } }));
	writeFileSync(join(stub, "index.mjs"), [
		`import * as real from ${JSON.stringify(import.meta.resolve("@earendil-works/pi-ai"))};`,
		`process.stderr.write(${JSON.stringify(`${STUB_MARKER}\n`)});`,
		`export const { ${names.join(", ")} } = real;`,
	].join("\n"));
}

test("the fallback rows pass on a pi-ai without the exports older Pi hosts lack", (t) => {
	const root = copyPackage(t, { linkModules: false });
	installOlderPiAi(root);
	const suites = [...new Set(ROWS.map((row) => row.suite))];
	const child = runCopySuites(root, ["--test-reporter=tap", ...ROWS.map((row) => `--test-name-pattern=^${escapeRegExp(row.name)}$`), ...suites]);
	const output = child.stdout + child.stderr;
	assert.equal(child.status, 0, output);
	assert.ok(output.includes(STUB_MARKER), output);
	for (const row of ROWS) assert.match(child.stdout, new RegExp(`^ok \\d+ - ${escapeRegExp(row.name)}$`, "m"), `${row.name} did not pass\n${output}`);
});
