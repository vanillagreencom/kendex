import assert from "node:assert/strict";
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { COOKIE_READ_DEADLINE_MS, CREDENTIAL_CACHE_MS, readBrowserCookies } from "../src/utils/browser-cookies.js";
import { isolateEnvironment, piExec, processAlive, sleepingHelper, tempDir } from "./fixtures.js";

/** A home holding one browser's cookie database, helpers in `bin` ahead of the inherited PATH, and its own temporary
 * directory, so the read's copies are visible. */
function browserWorld(t: TestContext, browser: "firefox" | "chromium") {
	const path = process.env.PATH;
	isolateEnvironment(t, ["HOME", "PATH", "TMPDIR"]);
	const root = tempDir(t);
	const home = join(root, "home");
	const bin = join(root, "bin");
	const tmp = join(root, "tmp");
	const profile = browser === "firefox" ? join(home, ".mozilla", "firefox", "default") : join(home, ".config", "chromium", "Default");
	for (const dir of [profile, bin, tmp]) mkdirSync(dir, { recursive: true });
	writeFileSync(join(profile, browser === "firefox" ? "cookies.sqlite" : "Cookies"), "");
	process.env.HOME = home;
	process.env.PATH = `${bin}:${path}`;
	process.env.TMPDIR = tmp;
	return { bin, copiesLeft: () => readdirSync(tmp).filter((name) => name.startsWith("pi-web-cookies-")).length };
}

/** A helper in `bin` that prints `output` and appends one line to its call log per run. */
function countingHelper(bin: string, name: string, output: string): () => number {
	const log = join(bin, `${name}.calls`);
	writeFileSync(join(bin, name), `#!/bin/sh\necho call >> '${log}'\nprintf '%s' '${output}'\n`);
	chmodSync(join(bin, name), 0o755);
	return () => existsSync(log) ? readFileSync(log, "utf8").split("\n").filter(Boolean).length : 0;
}

for (const row of [
	{ name: "sqlite3 at the default deadline", browser: "firefox" as const, helper: "sqlite3", timeoutMs: undefined },
	{ name: "secret-tool", browser: "chromium" as const, helper: "secret-tool", timeoutMs: 300 },
]) {
	test(`cookie read: a hung ${row.name} ends the read before the helper would`, { timeout: 15_000 }, async (t) => {
		const world = browserWorld(t, row.browser);
		const helper = sleepingHelper(world.bin, row.helper, 5);
		countingHelper(world.bin, row.helper === "sqlite3" ? "secret-tool" : "sqlite3", "");
		const started = performance.now();
		const error = await readBrowserCookies({ pi: piExec, timeoutMs: row.timeoutMs }).then(() => undefined, (caught: unknown) => caught);
		const elapsed = performance.now() - started;
		assert.deepEqual(
			{ timedOut: error instanceof DOMException && error.name === "TimeoutError", beforeHelperEnds: elapsed < 5_000, withinDeadline: elapsed < (row.timeoutMs ?? COOKIE_READ_DEADLINE_MS) + 1_000, helperAlive: processAlive(helper.pid()), copiesLeft: world.copiesLeft() },
			{ timedOut: true, beforeHelperEnds: true, withinDeadline: true, helperAlive: false, copiesLeft: 0 },
		);
	});
}

test("cookie read: a keyring secret is reused until CREDENTIAL_CACHE_MS passes", async (t) => {
	t.mock.timers.enable({ apis: ["Date"], now: 1_000_000 });
	const world = browserWorld(t, "chromium");
	const keyringCalls = countingHelper(world.bin, "secret-tool", "keyring-password");
	countingHelper(world.bin, "sqlite3", "");
	const calls: number[] = [];
	for (const advance of [0, CREDENTIAL_CACHE_MS - 1, 1]) {
		t.mock.timers.tick(advance);
		await readBrowserCookies({ pi: piExec });
		calls.push(keyringCalls());
	}
	assert.deepEqual(calls, [1, 1, 2]);
});
