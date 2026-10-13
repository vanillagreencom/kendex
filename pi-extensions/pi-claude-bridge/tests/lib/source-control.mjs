import assert from "node:assert/strict";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const packageRoot = fileURLToPath(new URL("../../", import.meta.url));

/** Run one selected contract on clean source, then require its mutation to fail. */
export function assertSourceControl({ source, before, after, suite, pattern, failure }) {
	const root = mkdtempSync(join(tmpdir(), "bridge-source-control-"));
	try {
		cpSync(join(packageRoot, "src"), join(root, "src"), { recursive: true });
		cpSync(join(packageRoot, "package.json"), join(root, "package.json"));
		// The whole library, since a suite reaches its fixtures through it.
		cpSync(join(packageRoot, "tests", "lib"), join(root, "tests", "lib"), { recursive: true });
		cpSync(join(packageRoot, "tests", suite), join(root, "tests", suite));
		symlinkSync(join(packageRoot, "node_modules"), join(root, "node_modules"), "dir");
		const path = join(root, source);
		const original = readFileSync(path, "utf8");
		assert.equal(original.split(before).length - 1, 1, "mutation must match once");
		const mutated = original.replace(before, after);
		assert.notEqual(mutated, original, "mutation must change the copied source");
		const home = join(root, "home");
		mkdirSync(home);
		const runSelected = () => {
			const result = spawnSync(process.execPath, ["--import", "tsx", "--test", `--test-name-pattern=${pattern}`, join(root, "tests", suite)], {
				cwd: root,
				env: { PATH: process.env.PATH, HOME: home, PI_CODING_AGENT_DIR: home, CLAUDE_CONFIG_DIR: home },
				encoding: "utf8",
				timeout: 60_000,
			});
			if (result.error) throw result.error;
			const output = `${result.stdout}\n${result.stderr}`;
			assert.equal(result.signal, null, output);
			return { status: result.status, output };
		};
		const clean = runSelected();
		assert.equal(clean.status, 0, clean.output);
		writeFileSync(path, mutated);
		const control = runSelected();
		assert.equal(control.status, 1, control.output);
		assert.match(control.output, /ERR_ASSERTION/, control.output);
		assert.match(control.output, failure, control.output);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}
