import assert from "node:assert/strict";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const packageRoot = fileURLToPath(new URL("../../", import.meta.url));

/** Remove one behavior in a disposable source copy and require its contract test to fail. */
export function assertSourceControl({ source, before, after, suite, pattern, failure }) {
	const root = mkdtempSync(join(tmpdir(), "bridge-source-control-"));
	try {
		cpSync(join(packageRoot, "src"), join(root, "src"), { recursive: true });
		cpSync(join(packageRoot, "package.json"), join(root, "package.json"));
		mkdirSync(join(root, "tests", "lib"), { recursive: true });
		cpSync(join(packageRoot, "tests", suite), join(root, "tests", suite));
		cpSync(fileURLToPath(import.meta.url), join(root, "tests", "lib", "source-control.mjs"));
		symlinkSync(join(packageRoot, "node_modules"), join(root, "node_modules"), "dir");
		const path = join(root, source);
		const original = readFileSync(path, "utf8");
		assert.equal(original.split(before).length - 1, 1, "mutation must match once");
		const mutated = original.replace(before, after);
		assert.notEqual(mutated, original, "mutation must change the copied source");
		writeFileSync(path, mutated);
		const home = join(root, "home");
		mkdirSync(home);
		const result = spawnSync(process.execPath, ["--import", "tsx", "--test", `--test-name-pattern=${pattern}`, join(root, "tests", suite)], {
			cwd: root,
			env: { PATH: process.env.PATH, HOME: home, PI_CODING_AGENT_DIR: home, CLAUDE_CONFIG_DIR: home },
			encoding: "utf8",
		});
		if (result.error) throw result.error;
		const output = `${result.stdout}\n${result.stderr}`;
		assert.equal(result.signal, null, output);
		assert.equal(result.status, 1, output);
		assert.match(output, /ERR_ASSERTION/, output);
		assert.match(output, failure, output);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}
