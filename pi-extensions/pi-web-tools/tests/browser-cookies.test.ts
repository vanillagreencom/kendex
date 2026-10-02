import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { CREDENTIAL_CACHE_MS, readBrowserCookies, SQLITE_DEADLINE_MS } from "../src/utils/browser-cookies.js";
import { isolateEnvironment, piExec, processAlive, sleepingHelper, tempDir } from "./fixtures.js";

/** Where cookie discovery looks for Chromium on this platform, under the home directory, and the helper it asks for the
 * keyring secret. */
function chromiumLayout(): { profile: string[]; keyring: string } {
	switch (process.platform) {
		case "linux": return { profile: [".config", "chromium", "Default"], keyring: "secret-tool" };
		case "darwin": return { profile: ["Library", "Application Support", "Chromium", "Default"], keyring: "security" };
		default: throw new Error(`browser-cookies fixture: no Chromium layout for platform ${process.platform}`);
	}
}

/** A home holding one browser's cookie database where this platform's discovery finds it, helpers in `bin` ahead of the
 * inherited PATH, and its own temporary directory, so the read's copies are visible. */
function browserWorld(t: TestContext, browser: "firefox" | "chromium") {
	const path = process.env.PATH;
	isolateEnvironment(t, ["HOME", "PATH", "TMPDIR"]);
	const root = tempDir(t);
	const home = join(root, "home");
	const bin = join(root, "bin");
	const tmp = join(root, "tmp");
	const chromium = chromiumLayout();
	const profile = browser === "firefox" ? join(home, ".mozilla", "firefox", "default") : join(home, ...chromium.profile);
	for (const dir of [profile, bin, tmp]) mkdirSync(dir, { recursive: true });
	writeFileSync(join(profile, browser === "firefox" ? "cookies.sqlite" : "Cookies"), "");
	process.env.HOME = home;
	process.env.PATH = `${bin}:${path}`;
	process.env.TMPDIR = tmp;
	return { bin, keyring: chromium.keyring, copiesLeft: () => readdirSync(tmp).filter((name) => name.startsWith("pi-web-cookies-")).length };
}

/** A helper in `bin` that appends one line to its call log per run, waits `delaySeconds`, then prints `output`. */
function countingHelper(bin: string, name: string, output: string, delaySeconds = 0): () => number {
	const log = join(bin, `${name}.calls`);
	writeFileSync(join(bin, name), `#!/bin/sh\necho call >> '${log}'\nsleep ${delaySeconds}\nprintf '%s' '${output}'\n`);
	chmodSync(join(bin, name), 0o755);
	return () => existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean).length : 0;
}

for (const row of [
	{ name: "sqlite3 at its default deadline", browser: "firefox" as const, helper: "sqlite3" as const, options: {}, bound: SQLITE_DEADLINE_MS },
	{ name: "keyring helper at its own deadline", browser: "chromium" as const, helper: "keyring" as const, options: { keyringTimeoutMs: 300 }, bound: 300 },
]) {
	test(`cookie read: a hung ${row.name} ends the read before the helper would`, { timeout: 15_000 }, async (t) => {
		const world = browserWorld(t, row.browser);
		const hung = row.helper === "keyring" ? world.keyring : "sqlite3";
		const helper = sleepingHelper(world.bin, hung, 5);
		countingHelper(world.bin, hung === "sqlite3" ? world.keyring : "sqlite3", "");
		const started = performance.now();
		const error = await readBrowserCookies({ pi: piExec, ...row.options }).then(() => undefined, (caught: unknown) => caught);
		const elapsed = performance.now() - started;
		assert.deepEqual(
			{ timedOut: error instanceof DOMException && error.name === "TimeoutError", beforeHelperEnds: elapsed < 5_000, withinDeadline: elapsed < row.bound + 1_000, helperAlive: processAlive(helper.pid()), copiesLeft: world.copiesLeft() },
			{ timedOut: true, beforeHelperEnds: true, withinDeadline: true, helperAlive: false, copiesLeft: 0 },
		);
	});
}

test("cookie read: a keyring helper may outlast the sqlite3 deadline, as a prompt the user answers does", { timeout: 15_000 }, async (t) => {
	const world = browserWorld(t, "chromium");
	const keyringCalls = countingHelper(world.bin, world.keyring, "keyring-password", 0.5);
	countingHelper(world.bin, "sqlite3", "");
	const outcome = await readBrowserCookies({ pi: piExec, sqliteTimeoutMs: 200, keyringTimeoutMs: 5_000 }).then((result) => result?.browser, (error: Error) => error.name);
	assert.deepEqual({ outcome, keyringCalls: keyringCalls() }, { outcome: "Chromium", keyringCalls: 1 });
});

test("cookie read: a keyring secret is reused until CREDENTIAL_CACHE_MS passes", async (t) => {
	t.mock.timers.enable({ apis: ["Date"], now: 1_000_000 });
	const world = browserWorld(t, "chromium");
	const keyringCalls = countingHelper(world.bin, world.keyring, "keyring-password");
	countingHelper(world.bin, "sqlite3", "");
	const calls: number[] = [];
	for (const advance of [0, CREDENTIAL_CACHE_MS - 1, 1]) {
		t.mock.timers.tick(advance);
		await readBrowserCookies({ pi: piExec });
		calls.push(keyringCalls());
	}
	assert.deepEqual(calls, [1, 1, 2]);
});
