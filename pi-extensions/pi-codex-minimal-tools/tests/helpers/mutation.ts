import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { TestContext } from "node:test";
import { copyPackage, runCopySuites } from "./package-copy.js";

/** Run the same assertion against a source defect in an owned disposable copy. */
export function rejectsMutation(t: Pick<TestContext, "after">, file: string, needle: string, replacement: string, suite: string, name: string): void {
	const root = copyPackage(t);
	const path = join(root, file);
	const source = readFileSync(path, "utf8");
	assert.equal(source.split(needle).length - 1, 1);
	const changed = source.replace(needle, replacement);
	assert.notEqual(changed, source);
	writeFileSync(path, changed);
	const child = runCopySuites(root, [`--test-name-pattern=${name}`, suite]);
	assert.equal(child.status, 1, child.stdout + child.stderr);
	assert.match(child.stdout, /code: 'ERR_ASSERTION'/);
}
