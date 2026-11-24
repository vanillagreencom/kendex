import { cpSync, symlinkSync } from "node:fs";
import { spawnSync, type SpawnSyncReturns } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import type { TestContext } from "node:test";
import { world } from "./world.js";

export const packageRoot = fileURLToPath(new URL("../..", import.meta.url));

/** Copy the package's sources and tests into an owned disposable root; `linkModules: false` leaves node_modules to the caller. */
export function copyPackage(t: Pick<TestContext, "after">, { linkModules = true } = {}): string {
	const { root } = world(t);
	for (const path of ["src", "tests", "package.json"]) cpSync(join(packageRoot, path), join(root, path), { recursive: true });
	if (linkModules) symlinkSync(join(packageRoot, "node_modules"), join(root, "node_modules"), "dir");
	return root;
}

/** Run node:test suites of a package copy in a child process. */
export function runCopySuites(root: string, args: readonly string[]): SpawnSyncReturns<string> {
	// Node uses this marker to refuse a test runner nested in its current worker.
	const { NODE_TEST_CONTEXT: _parentTestContext, ...env } = process.env;
	const child = spawnSync(process.execPath, ["--import", "tsx", "--test", ...args], { cwd: root, env, encoding: "utf8", timeout: 30_000 });
	if (child.error) throw child.error;
	return child;
}
