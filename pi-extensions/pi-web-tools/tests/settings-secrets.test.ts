import assert from "node:assert/strict";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { loadSettings } from "../src/settings.js";
import { isolateEnvironment, settingsEnvironment, tempDir } from "./fixtures.js";

for (const { name, program, expected } of [
	{
		name: "timeout returns with key unset",
		program: 'Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5000); process.stdout.write("late-secret");',
		expected: { key: undefined, bounded: true, warnings: 2, keyName: true, timeout: true, referenceDisclosed: false },
	},
	{
		name: "resolved secret",
		program: 'if (process.argv[2] !== "read" || process.argv[3] !== "op://vault/exa/key") process.exit(1); process.stdout.write("resolved-exa");',
		expected: { key: "resolved-exa", bounded: true, warnings: 1, keyName: false, timeout: false, referenceDisclosed: false },
	},
]) {
	test(`settings secret process: ${name}`, (t) => {
		const path = process.env.PATH;
		isolateEnvironment(t, [...settingsEnvironment, "PATH"]);
		const root = tempDir(t);
		const user = join(root, "agent");
		const project = join(root, "project");
		const bin = join(root, "bin");
		mkdirSync(user);
		mkdirSync(project);
		mkdirSync(bin);
		// The executable is the child itself. It creates no descendants that can outlive spawnSync.
		writeFileSync(join(bin, "op"), `#!${process.execPath}\n${program}\n`);
		chmodSync(join(bin, "op"), 0o755);
		writeFileSync(join(user, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-web-tools": { exaApiKey: "op://vault/exa/key" } } } } }));
		process.env.PI_CODING_AGENT_DIR = user;
		process.env.PATH = `${bin}:${path ?? ""}`;
		process.env.PI_WEB_TOOLS_OP_READ_TIMEOUT_MS = "100";
		const started = performance.now();
		const result = loadSettings(project);
		assert.deepEqual({
			key: result.apiKeys.exa,
			bounded: performance.now() - started < 1500,
			warnings: result.warnings.length,
			keyName: result.warnings.some((warning) => warning.includes("EXA_API_KEY")),
			timeout: result.warnings.some((warning) => warning.includes("100ms")),
			referenceDisclosed: result.warnings.some((warning) => warning.includes("op://")),
		}, expected);
	});
}
