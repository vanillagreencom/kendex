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
