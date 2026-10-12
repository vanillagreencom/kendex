import { expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { tempRuntime } from "./single-agent-fixture.js";

const dirs: string[] = [];
for (const outcome of ["pass", "fail"] as const) {
	const run = outcome === "fail" ? test.failing : test;
	run(`runtime fixture without caller teardown: ${outcome}`, () => {
		dirs.push(tempRuntime(), tempRuntime());
		if (outcome === "fail") throw new Error("fixture owner must clean up after this failure");
	});
}
test("all runtime directories are gone after their tests end", () => { expect(dirs.filter(existsSync)).toEqual([]); });

// The standalone fixture imports optional Pi peers, but allocation uses none.
const STANDALONE = `import assert from "node:assert/strict";
import { mock } from "bun:test";
import { existsSync } from "node:fs";
const [fixture, outcome] = process.argv.slice(1);
const unused = () => { throw new Error("allocation called a Pi peer"); };
mock.module("@earendil-works/pi-coding-agent", () => ({
getAgentDir: unused, parseFrontmatter: unused, formatSize: unused,
truncateHead: unused, truncateTail: unused, withFileMutationQueue: unused,
getMarkdownTheme: unused
}));
mock.module("@earendil-works/pi-tui", () => ({
Container: class {}, Markdown: class {}, Spacer: class {},
truncateToWidth: unused, visibleWidth: unused, wrapTextWithAnsi: unused
}));
const { allocateTempRuntime, cleanupTempRuntimes } = await import(fixture);
const dirs = [];
const failure = new Error("standalone owner failed");
try {
dirs.push(allocateTempRuntime(), allocateTempRuntime());
assert.equal(dirs.every(existsSync), true);
if (outcome === "fail") throw failure;
} catch (error) {
if (error !== failure) throw error;
} finally { cleanupTempRuntimes(); }
assert.deepEqual(dirs.filter(existsSync), []);`;

for (const outcome of ["pass", "fail"] as const) {
	test(`standalone allocation with caller teardown: ${outcome}`, () => {
		const root = tempRuntime();
		execFileSync(process.execPath, ["--no-install", "-e", STANDALONE, "--", resolve(import.meta.dir, "single-agent-fixture.ts"), outcome], {
			env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root }, timeout: 10_000,
		});
	});
}
