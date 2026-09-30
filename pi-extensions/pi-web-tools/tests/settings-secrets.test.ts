import assert from "node:assert/strict";
import childProcess from "node:child_process";
import { chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { join } from "node:path";
import test from "node:test";
import { clearPackageConfigCache, SETTINGS_RECHECK_MS } from "../src/package-config.js";
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
		clearPackageConfigCache();
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

// Every provider request asks for the settings, so the resolved object,
// `op read` included, is memoized: resolved again only when a raw input's
// text changes or a settings change clears the memo.
test("settings secret process: op read runs once per change, not once per load", (t) => {
	isolateEnvironment(t, settingsEnvironment);
	const root = tempDir(t);
	const user = join(root, "agent");
	const project = join(root, "project");
	mkdirSync(user);
	mkdirSync(project);
	const requests: string[] = [];
	const spawn = t.mock.method(childProcess, "spawnSync", (_command: string, args: readonly string[]) => {
		requests.push(args[1]!);
		return { pid: 1, output: [null, "resolved", ""], stdout: "resolved", stderr: "", status: 0, signal: null };
	});
	syncBuiltinESMExports();
	t.after(() => { spawn.mock.restore(); syncBuiltinESMExports(); });
	let now = 0;
	t.mock.method(performance, "now", () => now);
	const writeKey = (reference: string) => writeFileSync(join(user, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-web-tools": { exaApiKey: reference } } } } }));
	process.env.PI_CODING_AGENT_DIR = user;
	clearPackageConfigCache();
	writeKey("op://vault/exa/key");
	const steps: Array<[string, () => void, string[]]> = [
		["first load", () => {}, ["op://vault/exa/key"]],
		["inside the window", () => { now = SETTINGS_RECHECK_MS - 1; }, ["op://vault/exa/key"]],
		["past the window, text unchanged", () => { now = SETTINGS_RECHECK_MS * 3; }, ["op://vault/exa/key"]],
		["past the window, text changed", () => { writeKey("op://vault/exa/rotated"); now = SETTINGS_RECHECK_MS * 5; }, ["op://vault/exa/key", "op://vault/exa/rotated"]],
		["a settings change", () => clearPackageConfigCache(), ["op://vault/exa/key", "op://vault/exa/rotated", "op://vault/exa/rotated"]],
	];
	for (const [name, act, expected] of steps) {
		act();
		assert.equal(loadSettings(project).apiKeys.exa, "resolved", name);
		assert.deepEqual(requests, expected, name);
	}
});

// A failed `op read` is not kept: 1Password may be locked now and unlocked a
// moment later, with no settings text changing in between. The failure is
// served for its window, then `op read` runs again.
test("settings secret process: a failed op read is retried after one window", (t) => {
	isolateEnvironment(t, settingsEnvironment);
	const root = tempDir(t);
	const user = join(root, "agent");
	const project = join(root, "project");
	mkdirSync(user);
	mkdirSync(project);
	let unlocked = false;
	let reads = 0;
	const spawn = t.mock.method(childProcess, "spawnSync", () => {
		reads += 1;
		return unlocked
			? { pid: 1, output: [null, "resolved", ""], stdout: "resolved", stderr: "", status: 0, signal: null }
			: { pid: 1, output: [null, "", ""], stdout: "", stderr: "", status: 1, signal: null };
	});
	syncBuiltinESMExports();
	t.after(() => { spawn.mock.restore(); syncBuiltinESMExports(); });
	let now = 0;
	t.mock.method(performance, "now", () => now);
	writeFileSync(join(user, "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-web-tools": { exaApiKey: "op://vault/exa/key" } } } } }));
	process.env.PI_CODING_AGENT_DIR = user;
	clearPackageConfigCache();
	const steps: Array<[string, () => void, string | undefined, number]> = [
		["locked", () => {}, undefined, 1],
		["inside the window", () => { unlocked = true; now = SETTINGS_RECHECK_MS - 1; }, undefined, 1],
		["past the window, text unchanged", () => { now = SETTINGS_RECHECK_MS * 3; }, "resolved", 2],
		["a resolved key is kept", () => { now = SETTINGS_RECHECK_MS * 5; }, "resolved", 2],
	];
	for (const [name, act, key, expectedReads] of steps) {
		act();
		assert.equal(loadSettings(project).apiKeys.exa, key, name);
		assert.equal(reads, expectedReads, name);
	}
});
