// The app-server child's life: the version gate, the handshake deadline, and
// how a stop reaches the child and the processes it started, run against a
// stand-in `codex` executable with real processes.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { appServerArgs } from "../src/codex-policy.ts";
import { assertSupportedCodex } from "../src/app-server.ts";
import { CodexBridge } from "../src/bridge.ts";
import { CodexProtocolClient } from "../src/json-rpc.ts";
import { descendantsOf, parseProcStat, parsePsRows } from "../src/process-tree.ts";
import { finish, model, system, user } from "./lib/fake-client.mjs";
import { goneWithin, recordedPids, writeStubCodex } from "./lib/stub-codex.mjs";

const scratch = join(fileURLToPath(new URL("..", import.meta.url)), "tmp");
mkdirSync(scratch, { recursive: true });

function scratchDir(t, name) {
	const dir = mkdtempSync(join(scratch, `${name}-`));
	writeFileSync(join(dir, "auth.json"), "{}");
	t.after(() => rmSync(dir, { recursive: true, force: true }));
	return dir;
}

function launch(executable, home) {
	return { executable, codexHome: home, cwd: home, env: { PATH: process.env.PATH }, configOverrides: [], handshakeTimeoutMs: 5000 };
}

for (const row of [
	{ name: "another release", write: (dir) => writeStubCodex(dir, { version: "0.164.0" }), error: "codex-version-unsupported found=0.164.0 expected=0.163.0" },
	{ name: "unreadable output", write: (dir) => { const path = join(dir, "codex"); writeFileSync(path, `#!${process.execPath}\nconsole.log("not a version");\n`, { mode: 0o755 }); return path; }, error: "codex-protocol-invalid method=--version field=stdout" },
	{ name: "no executable", write: (dir) => join(dir, "missing-codex"), error: "codex-version-unreadable" },
	{ name: "the supported release", write: (dir) => writeStubCodex(dir), error: undefined },
]) {
	test(`the version gate: ${row.name}`, async (t) => {
		const dir = scratchDir(t, "version");
		const outcome = assertSupportedCodex(launch(row.write(dir), dir));
		if (row.error === undefined) await outcome;
		else await assert.rejects(outcome, (error) => error.message.startsWith(row.error));
	});
}

test("a stream on another Codex release is refused before any app-server starts", async (t) => {
	const dir = scratchDir(t, "version-stream");
	const bridge = new CodexBridge({ codexHome: dir, cwd: dir, executable: writeStubCodex(dir, { version: "0.164.0" }), env: { PATH: process.env.PATH } });
	const end = await finish(bridge.streamSimple(model, { messages: [system(), user("Hello")] }));
	assert.equal(end.error.errorMessage, "codex-version-unsupported found=0.164.0 expected=0.163.0");
	assert.equal(existsSync(join(dir, "app-server.pid")), false);
	await bridge.close();
});

// The helper leads its own process group, ignores SIGTERM and outlives stdin
// EOF: only the stop's sweep of the recorded processes ends it.
for (const row of [
	{ name: "a child that exits on SIGTERM", ignoreTerm: false },
	{ name: "a child that ignores SIGTERM until the grace ends", ignoreTerm: true },
]) {
	test(`a stop ends the child and the processes it started: ${row.name}`, { timeout: 10_000 }, async (t) => {
		const dir = scratchDir(t, "stop");
		const executable = writeStubCodex(dir, { ignoreTerm: row.ignoreTerm, helper: true });
		const child = spawn(executable, appServerArgs([]), { cwd: dir, env: { PATH: process.env.PATH }, detached: true });
		const client = new CodexProtocolClient(child, true, 300);
		const [server] = await recordedPids(dir, "app-server.pid");
		const [helper] = await recordedPids(dir, "helper.pid");
		await client.kill(new Error("test-stop"));
		assert.equal(await goneWithin(server, 2000), true, "the app-server still runs");
		assert.equal(await goneWithin(helper, 2000), true, "the process it started still runs");
	});
}

test("close stops a connected child and the processes it started", { timeout: 10_000 }, async (t) => {
	const dir = scratchDir(t, "close");
	const bridge = new CodexBridge({ codexHome: dir, cwd: dir, executable: writeStubCodex(dir, { helper: true }), env: { PATH: process.env.PATH } });
	assert.deepEqual(await bridge.discoverModels(5000), { models: [] });
	const [server] = await recordedPids(dir, "app-server.pid");
	const [helper] = await recordedPids(dir, "helper.pid");
	await bridge.close();
	assert.equal(await goneWithin(server, 2000), true);
	assert.equal(await goneWithin(helper, 2000), true);
});

test("a handshake that never answers loses its child at the discovery deadline", { timeout: 10_000 }, async (t) => {
	const dir = scratchDir(t, "stall");
	const bridge = new CodexBridge({ codexHome: dir, cwd: dir, executable: writeStubCodex(dir, { answer: false }), env: { PATH: process.env.PATH } });
	assert.deepEqual(await bridge.discoverModels(500), { models: [], notice: "codex-discovery-timeout after_ms=500" });
	const [first] = await recordedPids(dir, "app-server.pid");
	assert.equal(await goneWithin(first, 3000), true, "the stalled child outlived the discovery deadline");
	await bridge.close();
});

test("after an abort during a stalled handshake, that child stops and the next stream ends", { timeout: 15_000 }, async (t) => {
	const dir = scratchDir(t, "stall-abort");
	const bridge = new CodexBridge({ codexHome: dir, cwd: dir, executable: writeStubCodex(dir, { answer: false }), env: { PATH: process.env.PATH }, handshakeDeadlineMs: 1000 });
	t.after(() => bridge.close());
	const abort = new AbortController();
	const aborted = bridge.streamSimple(model, { messages: [system(), user("Hello")] }, { signal: abort.signal });
	const [first] = await recordedPids(dir, "app-server.pid");
	abort.abort();
	assert.equal((await finish(aborted)).reason, "aborted");
	assert.equal(await goneWithin(first, 3000), true, "the aborted handshake's child still runs");
	const next = await finish(bridge.streamSimple(model, { messages: [system(), user("Again")] }));
	assert.equal(next.error.errorMessage, "codex-handshake-timeout after_ms=1000");
	const pids = await recordedPids(dir, "app-server.pid");
	assert.equal(pids.length, 2, "the next stream opened its own child");
	assert.equal(await goneWithin(pids[1], 3000), true, "the timed-out child still runs");
});

test("the process table readers keep pid, parent, group and start time", () => {
	// A command holding spaces and parentheses, as /proc/<pid>/stat shows it.
	const stat = "4242 (node (x) y) S 4200 4242 4200 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 7 0 987654 1000 100 18446744073709551615";
	assert.deepEqual(parseProcStat(4242, stat), { pid: 4242, ppid: 4200, pgid: 4242, start: "987654" });
	assert.deepEqual(parsePsRows("  101     1   101 Mon Oct 19 21:00:01 2026\n  202   101   202 Mon Oct 19 21:00:02 2026\n"), [
		{ pid: 101, ppid: 1, pgid: 101, start: "Mon Oct 19 21:00:01 2026" },
		{ pid: 202, ppid: 101, pgid: 202, start: "Mon Oct 19 21:00:02 2026" },
	]);
	const table = [
		{ pid: 10, ppid: 1, pgid: 10, start: "a" },
		{ pid: 11, ppid: 10, pgid: 10, start: "b" },
		{ pid: 12, ppid: 11, pgid: 12, start: "c" },
		{ pid: 13, ppid: 1, pgid: 13, start: "d" },
	];
	assert.deepEqual(descendantsOf(10, table).map(({ pid }) => pid), [11, 12]);
});
