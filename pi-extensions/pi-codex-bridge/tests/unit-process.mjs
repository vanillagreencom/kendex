// The app-server child's life: the version gate, the handshake deadline, and
// how a stop reaches the child and the processes it started, run against a
// stand-in `codex` executable with real processes.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { once } from "node:events";
import { cpSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { appServerArgs } from "../src/codex-policy.ts";
import { assertSupportedCodex, startAppServer } from "../src/app-server.ts";
import { CodexBridge } from "../src/bridge.ts";
import { CodexProtocolClient } from "../src/json-rpc.ts";
import { descendantsOf, parseProcStat, parsePsRows } from "../src/process-tree.ts";
import { finish, model, system, user } from "./lib/fake-client.mjs";
import { ARG_SENTINEL, fixtureWorld, markerPidsFromPs } from "./lib/codex-fixture.mjs";
import { alive, goneWithin, recordedPids, writeStubCodex } from "./lib/stub-codex.mjs";

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

test("fixture marker ps rows identify only this world's live marker command", () => {
	const markerScript = fileURLToPath(new URL("./fixtures/marker-mcp.mjs", import.meta.url));
	const markers = { user: "/fixture world/STARTED-user" };
	const command = `${process.execPath} ${markerScript} ${markers.user} --token ${ARG_SENTINEL}`;
	for (const row of [
		{ name: "running", line: ` 101 S+ ${command}`, expected: [101] },
		{ name: "zombie", line: ` 101 Z+ ${command}`, expected: [] },
		{ name: "another world", line: ` 102 S ${command.replace(markers.user, "/another world/STARTED-user")}`, expected: [] },
		{ name: "another script", line: ` 103 S ${command.replace(markerScript, `${markerScript}.other`)}`, expected: [] },
		{ name: "another executable", line: ` 104 S ${command.replace(process.execPath, "/another/node")}`, expected: [] },
		{ name: "arguments that only mention the marker", line: ` 105 S ${process.execPath} -e ${command}`, expected: [] },
		{ name: "empty", line: "", expected: [] },
	]) {
		assert.deepEqual(markerPidsFromPs(row.line, markers), row.expected, row.name);
	}
});

test("fixture marker discovery and cleanup keep another world's marker alive", { timeout: 10_000 }, async (t) => {
	const world = await fixtureWorld("marker-identity");
	const foreignRoot = mkdtempSync(join(scratch, "foreign-marker-"));
	const markerScript = fileURLToPath(new URL("./fixtures/marker-mcp.mjs", import.meta.url));
	const children = [];
	let closed = false;
	t.after(async () => {
		for (const { child, exited } of children) {
			child.kill("SIGKILL");
			await exited;
		}
		if (!closed) await world.close();
		rmSync(foreignRoot, { recursive: true, force: true });
	});
	for (const marker of [world.markers.user, join(foreignRoot, "STARTED")]) {
		const child = spawn(process.execPath, [markerScript, marker, "--token", ARG_SENTINEL], { stdio: ["pipe", "ignore", "inherit"] });
		children.push({ child, exited: once(child, "exit") });
		await recordedPids(marker === world.markers.user ? world.root : foreignRoot, marker === world.markers.user ? "STARTED-user" : "STARTED");
	}
	const [owned, foreign] = children;
	assert.deepEqual(world.runningMarkers(), [owned.child.pid]);
	// A pid record alone must not let this world's cleanup kill another marker.
	writeFileSync(world.markers.late, `${foreign.child.pid}\n`);
	// Signal delivery can precede observable exit. Record real sends as well as liveness.
	const kill = process.kill;
	const signalled = [];
	process.kill = function (pid, ...args) {
		signalled.push(pid);
		return kill.call(process, pid, ...args);
	};
	try {
		await world.close();
	} finally {
		process.kill = kill;
	}
	closed = true;
	await owned.exited;
	assert.equal(signalled.includes(foreign.child.pid), false);
	assert.equal(alive(foreign.child.pid), true);
});

test("marker assertions reject zombie and foreign-world cleanup regressions", async (t) => {
	const packageDir = fileURLToPath(new URL("..", import.meta.url));
	// A sibling tmp of the common checkout keeps the copy outside every worktree.
	const commonDir = execFileSync("git", ["rev-parse", "--git-common-dir"], { cwd: packageDir, encoding: "utf8", timeout: 5000 }).trim();
	const controlScratch = resolve(packageDir, commonDir, "..", "..", "tmp");
	mkdirSync(controlScratch, { recursive: true });
	const copy = mkdtempSync(join(controlScratch, "codex-marker-control-"));
	t.after(() => rmSync(copy, { recursive: true, force: true }));
	for (const path of ["src", "tests", "package.json"]) cpSync(join(packageDir, path), join(copy, path), { recursive: true });
	symlinkSync(join(packageDir, "node_modules"), join(copy, "node_modules"), "dir");
	const fixture = join(copy, "tests/lib/codex-fixture.mjs");
	let source = readFileSync(fixture, "utf8");
	for (const [before, after] of [
		['!row[2].startsWith("Z") && ', ""],
		["return runningMarkers(markers).includes(pid);", 'try { return process.platform === "darwin" ? execFileSync("ps", ["-p", String(pid), "-ww", "-o", "command="], { encoding: "utf8" }).includes(markerScript) : readFileSync(`/proc/${pid}/cmdline`, "utf8").includes(markerScript); } catch { return false; }'],
	]) {
		assert.equal(source.split(before).length - 1, 1);
		const changed = source.replace(before, after);
		assert.notEqual(changed, source);
		source = changed;
	}
	writeFileSync(fixture, source);
	// Node otherwise refuses the nested runner inside its current test worker.
	const { NODE_TEST_CONTEXT: _parentTestContext, ...env } = process.env;
	const child = spawn(process.execPath, ["--import", "tsx", "--test", "--test-force-exit", "--test-reporter=tap", "--test-name-pattern=^fixture marker ", "tests/unit-process.mjs"], { cwd: copy, env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
	const closed = once(child, "close");
	let output = "";
	child.stdout.on("data", (chunk) => { output += chunk; });
	child.stderr.on("data", (chunk) => { output += chunk; });
	let timedOut = false;
	const deadline = setTimeout(() => {
		timedOut = true;
		process.kill(-child.pid, "SIGKILL");
	}, 30_000);
	try {
		const [code, signal] = await closed;
		assert.equal(timedOut, false, output);
		assert.equal(signal, null, output);
		assert.equal(code, 1, output);
		for (const name of ["fixture marker ps rows identify only this world's live marker command", "fixture marker discovery and cleanup keep another world's marker alive"]) {
			const row = output.split("# Subtest: ").find((block) => block.startsWith(`${name}\n`));
			assert.ok(row, output);
			assert.match(row, /^.*\nnot ok \d+ - /);
			assert.match(row, /code: 'ERR_ASSERTION'/);
		}
		assert.match(output, /^# fail 2$/m);
	} finally {
		clearTimeout(deadline);
		if (child.pid !== undefined && child.exitCode === null && child.signalCode === null) {
			process.kill(-child.pid, "SIGKILL");
			await closed;
		}
	}
});

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

test("the handshake deadline also covers a version check that never ends", { timeout: 10_000 }, async (t) => {
	const dir = scratchDir(t, "version-stall");
	const outcome = startAppServer({ ...launch(writeStubCodex(dir, { versionStall: true }), dir), handshakeTimeoutMs: 500 }, new AbortController().signal);
	await assert.rejects(outcome, (error) => error.message === "codex-handshake-timeout after_ms=500");
	assert.equal(existsSync(join(dir, "app-server.pid")), false);
});

// close waits for a child still in its handshake, one that ignores SIGTERM
// for the whole grace here: an open close aborts itself, and one the
// discovery deadline aborted before.
for (const row of [
	{ name: "while discovery waits on it", deadlineMs: 10_000, awaitDiscovery: false },
	{ name: "after the discovery deadline gave up on it", deadlineMs: 1000, awaitDiscovery: true },
]) {
	test(`close waits for a child still in its handshake: ${row.name}`, { timeout: 15_000 }, async (t) => {
		const dir = scratchDir(t, "stall");
		const bridge = new CodexBridge({ codexHome: dir, cwd: dir, executable: writeStubCodex(dir, { answer: false, ignoreTerm: true }), env: { PATH: process.env.PATH }, handshakeDeadlineMs: 10_000 });
		const discovered = bridge.discoverModels(row.deadlineMs);
		const [pid] = await recordedPids(dir, "app-server.pid");
		if (row.awaitDiscovery) assert.deepEqual(await discovered, { models: [], notice: `codex-discovery-timeout after_ms=${row.deadlineMs}` });
		await bridge.close();
		assert.equal(alive(pid), false, "close returned while the child still ran");
		if (!row.awaitDiscovery) assert.deepEqual(await discovered, { models: [], notice: "codex-bridge-closed" });
	});
}

test("an abort during a stalled handshake ends only that stream: the next one joins the open and the handshake deadline stops the child", { timeout: 15_000 }, async (t) => {
	const dir = scratchDir(t, "stall-abort");
	const bridge = new CodexBridge({ codexHome: dir, cwd: dir, executable: writeStubCodex(dir, { answer: false }), env: { PATH: process.env.PATH }, handshakeDeadlineMs: 2000 });
	t.after(() => bridge.close());
	const abort = new AbortController();
	const aborted = bridge.streamSimple(model, { messages: [system(), user("Hello")] }, { signal: abort.signal });
	const [first] = await recordedPids(dir, "app-server.pid");
	abort.abort();
	assert.equal((await finish(aborted)).reason, "aborted");
	const next = await finish(bridge.streamSimple(model, { messages: [system(), user("Again")] }));
	assert.equal(next.error.errorMessage, "codex-handshake-timeout after_ms=2000");
	assert.deepEqual(await recordedPids(dir, "app-server.pid"), [first], "the next stream opened its own child");
	assert.equal(await goneWithin(first, 3000), true, "the timed-out child still runs");
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
