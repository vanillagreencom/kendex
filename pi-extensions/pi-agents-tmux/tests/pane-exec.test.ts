import assert from "node:assert/strict";
import test, { after } from "node:test";
import { execCapture } from "../extensions/subagent/pane.js";
import { cleanupTempRuntimes, importRuntimeCopy, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);

test("command capture requires a fixed probe or a resolver-approved bridge", async () => {
   const { symlinkSync } = await import("node:fs");
   const { join } = await import("node:path");
   const runtime = await import("../extensions/subagent/pane.js");
   const root = tempRuntime();
   const bridge = join(root, "bridge path ' with spaces");
   symlinkSync(process.execPath, bridge);
   const options = { env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root } };
   const refused = async (capture: typeof execCapture) => {
      const result = await capture(bridge, ["-e", 'console.log("unexpected execution")'], options);
      assert.equal(result.code, 1, "an unresolved executable must not start");
      assert.equal(result.stdout, "");
      assert.ok(result.error instanceof Error);
   };
   await refused(execCapture);
   const mutant = await importRuntimeCopy("pane.ts", 'if (!new Set(["tmux", "ps", "bash", process.execPath, resolvedPiBridgeCommand]).has(command)) {', 'if (!new Set(["tmux", "ps", "bash", process.execPath, resolvedPiBridgeCommand]).has(command) && false) {') as typeof runtime;
   await assert.rejects(refused(mutant.execCapture), /an unresolved executable must not start/);
   for (const [command, args] of [
      ["tmux", ["-V"]], ["ps", ["-p", String(process.pid)]], ["bash", ["-c", "printf probe"]],
      [process.execPath, ["-e", 'console.log("fixture")']],
   ] as const) {
      const result = await execCapture(command, [...args], options);
      assert.equal(result.code, 0);
      assert.equal(result.error, undefined);
   }
   const previous = process.env.PI_BRIDGE_BIN;
   process.env.PI_BRIDGE_BIN = bridge;
   try {
      assert.equal(await runtime.resolvePiBridgeBin(), bridge);
      const result = await execCapture(bridge, ["-e", 'console.log("resolved bridge")'], options);
      assert.equal(result.code, 0);
      assert.equal(result.stdout.trim(), "resolved bridge");
   } finally {
      if (previous === undefined) delete process.env.PI_BRIDGE_BIN;
      else process.env.PI_BRIDGE_BIN = previous;
   }
});

async function stalled(capture: typeof execCapture): Promise<void> {
	const root = tempRuntime();
	// Real time here lets the OS start and reap a SIGTERM-resistant faux bridge.
	const result = await capture(process.execPath, ["-e", 'process.on("SIGTERM", () => {}); console.log(process.pid); setTimeout(() => console.log("natural-exit"), 2000)'], {
		cwd: root, timeoutMs: 200, signal: AbortSignal.timeout(1600), env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root },
	});
	assert.match(String(result.error), /timed out/);
	assert.equal(result.code, 1);
	assert.ok(!result.stdout.includes("natural-exit"), "kill escalation must end the stalled bridge");
	const pid = Number(result.stdout.trim());
	assert.ok(pid > 0, "faux bridge must have started");
	assert.throws(() => process.kill(pid, 0), { code: "ESRCH" }, "no bridge child may survive the timeout");
}

test("execCapture deadlines reap a stalled bridge, including kill escalation", { timeout: 10_000 }, async () => {
	await stalled(execCapture);
	const mutant = await importRuntimeCopy("pane.ts", 'setTimeout(() => stop(new Error(`${command} timed out after ${timeoutMs}ms`)), timeoutMs)', 'setTimeout(() => {}, timeoutMs)') as typeof import("../extensions/subagent/pane.js");
	await assert.rejects(stalled(mutant.execCapture), /timed out/);
	const noEscalation = await importRuntimeCopy("pane.ts", 'if (failure) kill("SIGKILL");', 'if (failure) void failure;', [
		{ before: 'kill("SIGKILL");\n\t\t\t\tcloseBound', after: 'void failure;\n\t\t\t\tcloseBound' },
	]) as typeof import("../extensions/subagent/pane.js");
	await assert.rejects(stalled(noEscalation.execCapture), /kill escalation must end/);
});

async function cancelledCapture(capture: typeof execCapture): Promise<void> {
	const controller = new AbortController();
	controller.abort(new Error("cancelled-before-spawn"));
	const result = await capture("missing-command-must-not-spawn", [], { signal: controller.signal, env: {} });
	assert.equal(result.error, controller.signal.reason, "pre-spawn cancellation must retain the abort reason");
}

test("an already cancelled capture starts nothing", async () => {
	await cancelledCapture(execCapture);
	const mutant = await importRuntimeCopy("pane.ts", 'if (signal?.aborted) return { code: 1, stdout: "", stderr: "Command aborted", error: signal.reason };', 'if (signal?.aborted) void signal.reason;') as typeof import("../extensions/subagent/pane.js");
	await assert.rejects(cancelledCapture(mutant.execCapture), /pre-spawn cancellation/);
});

test("in-flight capture cancellation terminates the child", async () => {
	const cancelled = async (capture: typeof execCapture) => {
		const root = tempRuntime();
		// The OS must launch the faux bridge before the caller cancels it.
		const result = await capture(process.execPath, ["-e", 'console.log(process.pid); setTimeout(() => {}, 2000)'], {
			timeoutMs: 10_000, signal: AbortSignal.timeout(200), env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root },
		});
		assert.match(String(result.error), /aborted/);
		const pid = Number(result.stdout.trim());
		assert.ok(pid > 0);
		assert.throws(() => process.kill(pid, 0), { code: "ESRCH" });
	};
	await cancelled(execCapture);
	const mutant = await importRuntimeCopy("pane.ts", 'signal?.addEventListener("abort", abort, { once: true });', 'void signal;') as typeof import("../extensions/subagent/pane.js");
	await assert.rejects(cancelled(mutant.execCapture), /aborted/);
});

test("command capture bounds each retained output stream", async () => {
	for (const stream of ["stdout", "stderr"] as const) {
		const bounded = async (capture: typeof execCapture) => {
			const root = tempRuntime();
			const result = await capture(process.execPath, ["-e", `process.${stream}.write("x".repeat(2 * 1024 * 1024))`], {
				env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root }, timeoutMs: 10_000,
			});
			assert.equal(result.code, 0);
			assert.equal(result[stream].length, 1024 * 1024, "retained command output must be bounded");
		};
		await bounded(execCapture);
		const mutant = await importRuntimeCopy("pane.ts", `${stream} = (${stream} + data.toString()).slice(-1024 * 1024);`, `${stream} = (${stream} + data.toString());`) as typeof import("../extensions/subagent/pane.js");
		await assert.rejects(bounded(mutant.execCapture), /retained command output must be bounded/);
	}
});

async function interruptedLifecycle(runtime: typeof import("../extensions/subagent/pane.js")): Promise<void> {
	const { writePaneRegistry, readPaneRegistry } = await import("../extensions/subagent/tasks.js");
	const { paneSessionPath } = await import("../extensions/subagent/paths.js");
	const { mkdirSync, writeFileSync, readFileSync } = await import("node:fs");
	const { dirname } = await import("node:path");
	const { testAgent, mockPiEvents } = await import("./single-agent-fixture.js");
	const { withChildBudget } = await import("../extensions/subagent/child-budget.js");
	for (const [operation, interruption] of [
		["force", "timeout"], ["resume", "timeout"], ["stop", "timeout"], ["kill", "timeout"],
		["force", "cancel"], ["resume", "cancel"], ["stop", "cancel"],
	] as const) {
		const root = tempRuntime();
		const controller = new AbortController();
		const pi = mockPiEvents([]);
		const agent = { ...testAgent(), pane: true };
		const session = paneSessionPath(root, agent.name);
		mkdirSync(dirname(session), { recursive: true });
		writeFileSync(session, "live session");
		const entry = { agent: agent.name, paneId: "%42", windowName: "agent:test", cwd: root, sessionFile: session, promptFile: "prompt", launcherFile: "launcher", startedAt: "2026-10-01T00:00:00Z" };
		await writePaneRegistry(root, { [agent.name]: entry });
		runtime.setPaneExecCaptureForTests(async (_command, args) => {
			if (interruption === "cancel") controller.abort(new Error("cancel pane preparation"));
			if (operation === "kill" && args[0] === "display-message") return { code: 0, stdout: "%42", stderr: "" };
			return { code: 1, stdout: "", stderr: "tmux interrupted", ...(operation === "kill" ? {} : { error: new Error("tmux interrupted") }) };
		});
		try {
			const call = withChildBudget(pi, root, controller.signal, () => operation === "stop" || operation === "kill" ? runtime.stopPersistentPane(root, agent.name)
				: runtime.runPersistentPaneAgent(root, root, "parent", [agent], agent.name, "inspect", undefined, undefined, undefined, undefined, pi, operation === "force", operation === "resume" ? "latest" : undefined));
			await assert.rejects(call);
			assert.equal(readFileSync(session, "utf8"), "live session", "interrupted probe must preserve live session");
			assert.deepEqual(await readPaneRegistry(root), { [agent.name]: entry }, "failed stop must preserve pane ownership");
		} finally { runtime.setPaneExecCaptureForTests(); }
	}
}

test("interrupted pane probes and failed kill preserve session and ownership", async () => {
	const runtime = await import("../extensions/subagent/pane.js");
	await interruptedLifecycle(runtime);
	const absent = await importRuntimeCopy("pane.ts", 'const result = await execCapture("tmux", args);\n\tif (result.error) throw result.error;', 'const result = await execCapture("tmux", args);\n\tvoid result.error;') as typeof runtime;
	await assert.rejects(interruptedLifecycle(absent), /ENOENT|interrupted probe must preserve live session/);
	const falseStop = await importRuntimeCopy("pane.ts", "if (result.code !== 0) throw new Error(`Failed to kill tmux pane ${paneId}: ${result.stderr || result.stdout}`);", "void result.code;") as typeof runtime;
	await assert.rejects(interruptedLifecycle(falseStop), /Missing expected rejection/);
});

async function cancelledReset(runtime: typeof import("../extensions/subagent/pane.js")): Promise<void> {
	const { withChildBudget } = await import("../extensions/subagent/child-budget.js");
	const { paneSessionPath } = await import("../extensions/subagent/paths.js");
	const { mkdirSync, writeFileSync, readFileSync } = await import("node:fs");
	const { dirname } = await import("node:path");
	const { mockPiEvents } = await import("./single-agent-fixture.js");
	const root = tempRuntime();
	const session = paneSessionPath(root, "engineer");
	mkdirSync(dirname(session), { recursive: true });
	writeFileSync(session, "live session");
	const controller = new AbortController();
	await withChildBudget(mockPiEvents([]), root, controller.signal, async () => {
		controller.abort(new Error("cancel reset"));
		await runtime.resetPersistentPaneSession(root, "engineer").catch(() => {});
	});
	assert.equal(readFileSync(session, "utf8"), "live session", "cancelled session reset must preserve the session");
}

test("session file effects stop on cancellation", async () => {
	const runtime = await import("../extensions/subagent/pane.js");
	await cancelledReset(runtime);
	const mutant = await importRuntimeCopy("pane.ts", "export async function resetPersistentPaneSession(runtimeRoot: string, agentName: string): Promise<string | undefined> {\n\tchildSignal()?.throwIfAborted();", "export async function resetPersistentPaneSession(runtimeRoot: string, agentName: string): Promise<string | undefined> {", [{ before: "childSignal()?.throwIfAborted();\n\tawait fs.promises.rename(sessionFile, archived);", after: "await fs.promises.rename(sessionFile, archived);" }]) as typeof runtime;
	await assert.rejects(cancelledReset(mutant), /ENOENT/);
});

async function nestedShutdown(capture: typeof execCapture): Promise<void> {
	const { withChildBudget } = await import("../extensions/subagent/child-budget.js");
	const { mockPiEvents } = await import("./single-agent-fixture.js");
	const { existsSync, readFileSync } = await import("node:fs");
	const { join } = await import("node:path");
	const root = tempRuntime();
	const pidFile = join(root, "pid");
	const naturalFile = join(root, "natural");
	let shutdown!: () => Promise<void>;
	const pi = mockPiEvents([]);
	pi.on = (_event: string, handler: () => Promise<void>) => { shutdown = handler; return () => {}; };
	const call = withChildBudget(pi, root, undefined, () => capture(process.execPath, ["-e", 'process.on("SIGTERM", () => {}); require("node:fs").writeFileSync(process.argv[1], String(process.pid)); setTimeout(() => require("node:fs").writeFileSync(process.argv[2], "natural-exit"), 2000)', pidFile, naturalFile], { timeoutMs: 10_000, env: { PATH: "/usr/bin:/bin", HOME: root, TMPDIR: root } }));
	const settled = Promise.allSettled([call]);
	try {
		// Wait for the real child to install its signal handler before shutdown.
		for (let i = 0; i < 100 && !existsSync(pidFile); i++) await new Promise((resolve) => setTimeout(resolve, 10));
		assert.ok(existsSync(pidFile));
		await shutdown();
		await settled;
		assert.equal(existsSync(naturalFile), false, "shutdown must cancel nested capture without an explicit signal");
		assert.throws(() => process.kill(Number(readFileSync(pidFile, "utf8")), 0), { code: "ESRCH" });
	} finally { await Promise.allSettled([call]); }
}

test("shutdown drains nested capture and its escalation", async () => {
	await nestedShutdown(execCapture);
	const mutant = await importRuntimeCopy("pane.ts", "const signal = options.signal ?? childSignal();", "const signal = options.signal;") as typeof import("../extensions/subagent/pane.js");
	await assert.rejects(nestedShutdown(mutant.execCapture), /shutdown must cancel nested capture/);
});

test("shared signal policy falls back to the child and reports failed delivery", async () => {
	const runtime = await import("../extensions/subagent/process-signal.js");
	const exercise = (signal: typeof runtime.signalProcessGroupOrChild) => {
		const original = process.kill;
		const calls: string[] = [];
		process.kill = (() => { calls.push("group"); throw new Error("group refused"); }) as typeof process.kill;
		try {
			const outcomes = signal({ pid: 42, kill() { calls.push("child"); return false; } }, "SIGTERM");
			assert.deepEqual(calls, process.platform === "win32" ? ["child"] : ["group", "child"], "signal policy must fall back to the child");
			assert.equal(outcomes.at(-1)?.ok, false);
			assert.equal(outcomes.at(-1)?.target, "child");
			assert.equal(outcomes.at(-1)?.error, "proc.kill returned false");
		} finally { process.kill = original; }
	};
	exercise(runtime.signalProcessGroupOrChild);
	const mutant = await importRuntimeCopy("process-signal.ts", "const ok = proc.kill(signal);", "const ok = false;") as typeof runtime;
	assert.throws(() => exercise(mutant.signalProcessGroupOrChild), /signal policy must fall back/);
});

async function cancelledEnqueue(runtime: typeof import("../extensions/subagent/pane.js")): Promise<void> {
	const { spyOn } = await import("bun:test");
	const fs = await import("node:fs");
	const { withChildBudget } = await import("../extensions/subagent/child-budget.js");
	const { writePaneRegistry } = await import("../extensions/subagent/tasks.js");
	const { paneSessionPath, inboxDir } = await import("../extensions/subagent/paths.js");
	const { PANE_LAUNCHER_VERSION } = await import("../extensions/subagent/types.js");
	const { testAgent, mockPiEvents } = await import("./single-agent-fixture.js");
	const root = tempRuntime();
	const cwd = process.cwd();
	const agent = { ...testAgent(), pane: true };
	const controller = new AbortController();
	await writePaneRegistry(root, { [agent.name]: { agent: agent.name, paneId: "%42", windowName: "agent:test", cwd, sessionFile: paneSessionPath(root, agent.name), promptFile: "prompt", launcherFile: "launcher", startedAt: "2026-10-01T00:00:00Z", launcherVersion: PANE_LAUNCHER_VERSION } });
	runtime.setPaneExecCaptureForTests(async (_command, args) => ({ code: 0, stdout: args.includes("#{pane_pid}") ? String(process.pid) : "%42", stderr: "" }));
	const mkdir = fs.promises.mkdir.bind(fs.promises);
	const spy = spyOn(fs.promises, "mkdir").mockImplementation((async (dir, options) => {
		const result = await mkdir(dir, options);
		if (String(dir) === inboxDir(root, agent.name)) controller.abort(new Error("cancel before enqueue"));
		return result;
	}) as typeof fs.promises.mkdir);
	const pi = mockPiEvents([]);
	try {
		const call = withChildBudget(pi, root, controller.signal, () => runtime.queuePersistentPaneTask(root, "parent", cwd, agent, "inspect", undefined, undefined, undefined, pi));
		await Promise.allSettled([call]);
		assert.deepEqual(fs.readdirSync(inboxDir(root, agent.name)), [], "cancelled enqueue must create no inbox task");
	} finally { spy.mockRestore(); runtime.setPaneExecCaptureForTests(); }
}

test("cancellation before inbox enqueue creates no task", async () => {
	const runtime = await import("../extensions/subagent/pane.js");
	await cancelledEnqueue(runtime);
	const mutant = await importRuntimeCopy("pane.ts", "childSignal()?.throwIfAborted();\n\tawait fs.promises.writeFile(taskFile, delegation,", "await fs.promises.writeFile(taskFile, delegation,") as typeof runtime;
	await assert.rejects(cancelledEnqueue(mutant), /cancelled enqueue must create no inbox task/);
});
