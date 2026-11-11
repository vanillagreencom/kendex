// The supported Codex list: the manifest's `@openai/codex` peer range, read
// from the package's own manifest and refused with a keyed cause when it is
// unreadable or not a list of exact releases.
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import test from "node:test";
import { parseCodexSupport, supportedCodexVersions } from "../src/codex-policy.ts";

const scratch = join(process.cwd(), "tmp");
mkdirSync(scratch, { recursive: true });

for (const row of [
	{ name: "one release", range: "0.163.0", versions: ["0.163.0"] },
	{ name: "two releases", range: "0.163.0 || 0.166.0", versions: ["0.163.0", "0.166.0"] },
	{ name: "two releases without spaces", range: "0.163.0||0.166.0", versions: ["0.163.0", "0.166.0"] },
	{ name: "an open range", range: ">=0.163.0", malformed: '">=0.163.0"' },
	{ name: "a caret range", range: "^0.163.0", malformed: '"^0.163.0"' },
	{ name: "a hyphen range", range: "0.163.0 - 0.166.0", malformed: '"0.163.0 - 0.166.0"' },
	{ name: "a prerelease", range: "0.167.0-alpha.2", malformed: '"0.167.0-alpha.2"' },
	{ name: "an empty member", range: "0.163.0 || ", malformed: '"0.163.0 || "' },
	{ name: "an empty range", range: "", malformed: '""' },
	{ name: "a range that is not a string", range: 163, malformed: "absent" },
	{ name: "no range", range: undefined, malformed: "absent" },
]) {
	test(`the supported range: ${row.name}`, () => {
		if (row.malformed === undefined) assert.deepEqual(parseCodexSupport(row.range), row.versions);
		else assert.throws(() => parseCodexSupport(row.range), { message: `codex-support-malformed range=${row.malformed}` });
	});
}

test("the package's own manifest lists the accepted 0.163.0 release", () => {
	assert.ok(supportedCodexVersions().includes("0.163.0"));
});

for (const row of [
	{ name: "a missing manifest", write: () => undefined, error: /^codex-support-unreadable path=\S+package\.json code=ENOENT$/ },
	{ name: "a manifest that is not JSON", write: (path) => writeFileSync(path, "{"), error: /^codex-support-unreadable path=\S+package\.json code=invalid-json$/ },
	{ name: "a manifest without the peer", write: (path) => writeFileSync(path, JSON.stringify({ peerDependencies: {} })), error: /^codex-support-malformed range=absent$/ },
	{ name: "a manifest that is not an object", write: (path) => writeFileSync(path, "null"), error: /^codex-support-malformed range=absent$/ },
]) {
	test(`the supported list refuses ${row.name}`, (t) => {
		const dir = mkdtempSync(join(scratch, "support-"));
		t.after(() => rmSync(dir, { recursive: true, force: true }));
		const path = join(dir, "package.json");
		row.write(path);
		assert.throws(() => supportedCodexVersions(pathToFileURL(path)), (error) => row.error.test(error.message));
	});
}
