import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { join } from "node:path";
import test from "node:test";
import { loadSettings } from "../src/settings.js";
import { isolateEnvironment, settingsEnvironment, tempDir } from "./fixtures.js";

for (const { name, timeout, expected } of [
	{
		name: "timeout returns with key unset",
		timeout: true,
		expected: { key: undefined, bounded: true, warnings: 2, keyName: true, timeout: true, referenceDisclosed: false, requests: [] },
	},
	{
		name: "resolved secret",
		timeout: false,
		expected: { key: "resolved-exa", bounded: undefined, warnings: 1, keyName: false, timeout: false, referenceDisclosed: false, requests: [{ command: "op", args: ["read", "op://vault/exa/key"] }] },
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
		const requests: Array<{ command: string; args: readonly string[] }> = [];
		if (timeout) {
			// The executable is the child itself. It creates no descendants that can outlive spawnSync.
			writeFileSync(join(bin, "op"), `#!${process.execPath}\nAtomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5000); process.stdout.write("late-secret");\n`);
			chmodSync(join(bin, "op"), 0o755);
		} else {
			// Successful secret parsing does not depend on a child starting before the timeout fixture's deadline.
			const spawn = t.mock.method(childProcess, "spawnSync", (command: string, args: readonly string[]) => {
				requests.push({ command, args });
				return { pid: 1, output: [null, "resolved-exa", ""], stdout: "resolved-exa", stderr: "", status: 0, signal: null };
			});
			syncBuiltinESMExports();
			t.after(() => { spawn.mock.restore(); syncBuiltinESMExports(); });
		}
		writeFileSync(join(user, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-web-tools": { exaApiKey: "op://vault/exa/key" } } } } }));
		process.env.PI_CODING_AGENT_DIR = user;
		process.env.PATH = `${bin}:${path ?? ""}`;
		process.env.PI_WEB_TOOLS_OP_READ_TIMEOUT_MS = "100";
		const started = performance.now();
		const result = loadSettings(project);
		assert.deepEqual({
			key: result.apiKeys.exa,
			bounded: timeout ? performance.now() - started < 1500 : undefined,
			warnings: result.warnings.length,
			keyName: result.warnings.some((warning) => warning.includes("EXA_API_KEY")),
			timeout: result.warnings.some((warning) => warning.includes("100ms")),
			referenceDisclosed: result.warnings.some((warning) => warning.includes("op://")),
			requests,
		}, expected);
	});
}
