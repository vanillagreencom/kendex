import assert from "node:assert/strict";
import { cpSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import type { TestContext } from "node:test";
import { world } from "./world.js";

/** Run the same assertion against a source defect in an owned disposable copy. */
export function rejectsMutation(t: Pick<TestContext, "after">, file: string, needle: string, replacement: string, suite: string, name: string): void {
	const { root } = world(t);
	const packageRoot = fileURLToPath(new URL("../..", import.meta.url));
	for (const path of ["src", "tests", "package.json"]) cpSync(join(packageRoot, path), join(root, path), { recursive: true });
	symlinkSync(join(packageRoot, "node_modules"), join(root, "node_modules"), "dir");
	const path = join(root, file);
	const source = readFileSync(path, "utf8");
	assert.equal(source.split(needle).length - 1, 1);
	const changed = source.replace(needle, replacement);
	assert.notEqual(changed, source);
	writeFileSync(path, changed);
	// Node uses this marker to refuse a test runner nested in its current worker.
	const { NODE_TEST_CONTEXT: _parentTestContext, ...env } = process.env;
	const child = spawnSync(process.execPath, ["--import", "tsx", "--test", `--test-name-pattern=${name}`, suite], { cwd: root, env, encoding: "utf8", timeout: 30_000 });
	assert.equal(child.error, undefined);
	assert.equal(child.status, 1, child.stdout + child.stderr);
	assert.match(child.stdout, /code: 'ERR_ASSERTION'/);
}
