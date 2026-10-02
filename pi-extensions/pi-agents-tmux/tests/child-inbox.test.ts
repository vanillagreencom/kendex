import assert from "node:assert/strict";
import test, { after } from "node:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { pollChildInbox } from "../extensions/subagent/child-inbox.js";
import { inboxDir, processingDir, taskRegistryPath } from "../extensions/subagent/paths.js";
import { cleanupTempRuntimes, importRuntimeCopy, tempRuntime } from "./browser-fixture.js";

after(cleanupTempRuntimes);

async function registryFailure(poll: typeof pollChildInbox): Promise<void> {
	const root = tempRuntime();
	mkdirSync(inboxDir(root, "engineer"), { recursive: true });
	const source = join(inboxDir(root, "engineer"), "work.md");
	writeFileSync(source, "inspect the code");
	// A blocked registry target makes the real atomic replacement fail after claim.
	mkdirSync(taskRegistryPath(root));
	let owner: string | undefined;
	let delivered = false;
	const pi = { sendUserMessage() { delivered = true; }, events: { emit() {} } } as unknown as Parameters<typeof poll>[2];
	const ctx = { ui: { setStatus() {} }, sessionManager: { getSessionFile() {} } } as unknown as Parameters<typeof poll>[3];
	{
		await assert.rejects(poll(root, "engineer", pi, ctx, (file) => { owner = file; }, (file) => { if (owner === file) owner = undefined; }));
		await new Promise(setImmediate);
		assert.equal(readFileSync(source, "utf8"), "inspect the code", "a registry failure after claim must restore the inbox");
		assert.equal(existsSync(join(processingDir(root, "engineer"), "work.md")), false);
		assert.equal(owner, undefined);
		assert.equal(delivered, false);
	}
}

test("whole inbox poll restores a post-claim registry failure", async () => {
	await registryFailure(pollChildInbox);
	const mutant = await importRuntimeCopy("child-inbox.ts", "await recordTaskDispatchFailure(runtimeRoot, path.basename(paths.processing, \".md\"), paths, String(error));", "void recordTaskDispatchFailure;") as typeof import("../extensions/subagent/child-inbox.js");
	await assert.rejects(registryFailure(mutant.pollChildInbox), /ENOENT/);
});

async function installedRecovery(extension: (pi: import("@earendil-works/pi-coding-agent").ExtensionAPI) => void): Promise<void> {
	const { createHarness, teardown, installExtension, fakeCtx, withoutRealIntervals } = await import("./extension-fixture.js");
	const { runtimeDirForContext } = await import("../extensions/subagent/settings.js");
	const harness = createHarness({ childAgent: "engineer", childPane: "1", tmuxPane: "%42" });
	const handlers: NonNullable<Parameters<typeof installExtension>[1]>["handlers"] = new Map();
	const ticks: Array<{ callback: () => void; ms: number }> = [];
	const root = runtimeDirForContext(fakeCtx(harness));
	const source = join(inboxDir(root, "engineer"), "work.md");
	const escaped: unknown[] = [];
	const warnings: string[] = [];
	let deliveries = 0;
	const originalFinally = Promise.prototype.finally;
	const originalWarn = console.warn;
	// Observe the timer callback's returned chain without consuming pollChildInbox's
	// rejection first. An escaped rejection turns this assertion red, not Bun's run.
	Promise.prototype.finally = function (callback) {
		const result = originalFinally.call(this, callback);
		void result.then(undefined, (error: unknown) => { escaped.push(error); });
		return result;
	};
	console.warn = (...values) => { warnings.push(values.join(" ")); };
	try {
		mkdirSync(inboxDir(root, "engineer"), { recursive: true });
		writeFileSync(source, "inspect the code");
		mkdirSync(taskRegistryPath(root));
		await withoutRealIntervals(async () => {
			const start = await installExtension(harness, { extension, handlers, sendUserMessage: async () => { deliveries++; } });
			await start({}, fakeCtx(harness));
		}, ticks);
		// File recovery and asynchronous registry writes must finish before a new tick.
		for (let i = 0; i < 100 && !warnings.some((line) => line.includes("subagent child inbox failed")); i++) await new Promise((resolve) => setTimeout(resolve, 10));
		assert.ok(warnings.some((line) => line.includes("subagent child inbox failed")), "installed poll must handle its rejection");
		assert.equal(escaped.length, 0, "installed catch must prevent escaping rejection");
		assert.equal(readFileSync(source, "utf8"), "inspect the code");
		rmSync(taskRegistryPath(root), { recursive: true });
		const inboxTick = ticks.findLast((tick) => tick.ms === 1000);
		assert.ok(inboxTick, "installed inbox interval must exist");
		inboxTick.callback();
		for (let i = 0; i < 100 && deliveries === 0; i++) await new Promise((resolve) => setTimeout(resolve, 10));
		assert.equal(deliveries, 1, "next installed poll must deliver after ownership release");
	} finally {
		for (const handler of handlers.get("session_shutdown") ?? []) await handler({}, fakeCtx(harness));
		Promise.prototype.finally = originalFinally;
		console.warn = originalWarn;
		teardown(harness);
	}
}

test("installed inbox callback catches failure and releases ownership for the next poll", async () => {
	const runtime = await import("../extensions/subagent/index.js");
	await installedRecovery(runtime.default);
	const escape = await importRuntimeCopy("index.ts", 'console.warn(`subagent child inbox failed for ${childAgentName}: ${String(error)}`);', 'console.warn(`subagent child inbox failed for ${childAgentName}: ${String(error)}`); throw error;') as typeof runtime;
	await assert.rejects(installedRecovery(escape.default), /installed catch must prevent/);
	const retained = await importRuntimeCopy("index.ts", "if (childCurrentTaskFile === file) childCurrentTaskFile = undefined;", "if (childCurrentTaskFile === file) void childCurrentTaskFile;") as typeof runtime;
	await assert.rejects(installedRecovery(retained.default), /next installed poll must deliver/);
});

async function shutdownInbox(extension: (pi: import("@earendil-works/pi-coding-agent").ExtensionAPI) => void): Promise<void> {
	const { EventEmitter } = await import("node:events");
	const { createHarness, teardown, installExtension, fakeCtx, withoutRealIntervals } = await import("./extension-fixture.js");
	const { setTmuxPaneTitleSpawnForTests } = await import("../extensions/subagent/pane.js");
	const { runtimeDirForContext } = await import("../extensions/subagent/settings.js");
	const harness = createHarness({ childAgent: "engineer", childPane: "1", tmuxPane: "%42" });
	const handlers: NonNullable<Parameters<typeof installExtension>[1]>["handlers"] = new Map();
	const ticks: Array<{ callback: () => void; ms: number; cleared?: boolean }> = [];
	let idle = false;
	const ctx = { ...fakeCtx(harness), isIdle: () => idle };
	const source = join(inboxDir(runtimeDirForContext(ctx), "engineer"), "work.md");
	let deliveries = 0;
	let stalled!: () => void;
	const stall = new Promise<void>((resolve) => { stalled = resolve; });
	// The title command ignores SIGTERM, so shutdown's title drain waits for the kill escalation.
	setTmuxPaneTitleSpawnForTests((() => {
		const proc = new EventEmitter() as import("node:child_process").ChildProcess;
		proc.kill = (signal) => {
			if (signal === "SIGTERM") stalled();
			else queueMicrotask(() => proc.emit("close", 1));
			return true;
		};
		return proc;
	}) as typeof import("node:child_process").spawn);
	try {
		await withoutRealIntervals(async () => {
			const start = await installExtension(harness, { extension, handlers, sendUserMessage: async () => { deliveries++; } });
			// The startup poll skips a busy session, so only a timer tick can claim the task.
			await start({}, ctx);
			mkdirSync(inboxDir(runtimeDirForContext(ctx), "engineer"), { recursive: true });
			writeFileSync(source, "inspect the code");
			idle = true;
			const shutdown = (async () => { for (const handler of handlers.get("session_shutdown") ?? []) await handler({}, ctx); })();
			await stall;
			// Every interval still live fires while the title drain waits.
			for (const tick of ticks) if (!tick.cleared) tick.callback();
			// The drain's one-second kill escalation outlasts a claim's local file operations.
			await shutdown;
			// A claimed task finishes its delivery before teardown removes its runtime.
			for (let i = 0; i < 100 && !existsSync(source) && deliveries === 0; i++) await new Promise((resolve) => setTimeout(resolve, 10));
		}, ticks);
		assert.ok(existsSync(source), "shutdown must stop the inbox poller before its awaited drains");
		assert.equal(deliveries, 0);
	} finally { teardown(harness); }
}

test("shutdown stops the inbox poller before a stalled title drain", { timeout: 10_000 }, async () => {
	const runtime = await import("../extensions/subagent/index.js");
	await shutdownInbox(runtime.default);
	const late = await importRuntimeCopy("index.ts", "\t\tif (childInboxPoller) clearInterval(childInboxPoller);\n\t\tif (runtimeLaneRefresh) clearInterval(runtimeLaneRefresh);\n\t\tcompletionPoller = undefined;", "\t\tif (runtimeLaneRefresh) clearInterval(runtimeLaneRefresh);\n\t\tcompletionPoller = undefined;", [
		{ before: "await drainCurrentTmuxPaneTitle();\n\t\tawait drainTranscriptUsagePersistences();", after: "await drainCurrentTmuxPaneTitle();\n\t\tif (childInboxPoller) clearInterval(childInboxPoller);\n\t\tawait drainTranscriptUsagePersistences();" },
	]) as typeof runtime;
	await assert.rejects(shutdownInbox(late.default), /shutdown must stop the inbox poller/);
});
