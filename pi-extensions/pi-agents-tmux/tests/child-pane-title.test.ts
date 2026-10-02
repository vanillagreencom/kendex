import { afterEach, describe, expect, test } from "bun:test";
import { createHarness, fakeCtx, type Harness, installExtension, teardown, withoutRealIntervals } from "./extension-fixture.js";

let currentHarness: Harness | undefined;

afterEach(() => {
	if (currentHarness) {
		teardown(currentHarness);
		currentHarness = undefined;
	}
});

describe("child pane title ownership", () => {
	test("bg one-shot child identity with inherited TMUX_PANE does not set the tmux pane title", async () => {
		currentHarness = createHarness({ childAgent: "reviewer-security", tmuxPane: "%parent" });
		const onSessionStart = await installExtension(currentHarness);
		await withoutRealIntervals(async () => {
			await onSessionStart({}, fakeCtx(currentHarness!));
		});
		expect(currentHarness.titleSpawnCalls).toHaveLength(0);
		expect(currentHarness.titles).toHaveLength(0);
	});

	test("visible pane child marker sets the tmux pane title", async () => {
		currentHarness = createHarness({ childAgent: "rust", childPane: "1", tmuxPane: "%42" });
		const onSessionStart = await installExtension(currentHarness);
		await withoutRealIntervals(async () => {
			await onSessionStart({}, fakeCtx(currentHarness!));
		});
		expect(currentHarness.titles).toContain("pi agent - rust");
		expect(currentHarness.titleSpawnCalls).toContainEqual({
			command: "tmux",
			args: ["select-pane", "-t", "%42", "-T", "agent:rust"],
		});
	});
});

async function shutdownTitle(extension: (pi: import("@earendil-works/pi-coding-agent").ExtensionAPI) => void): Promise<void> {
	const { EventEmitter } = await import("node:events");
	const { setTmuxPaneTitleSpawnForTests, drainCurrentTmuxPaneTitle } = await import("../extensions/subagent/pane.js");
	const harness = createHarness({ childAgent: "engineer", childPane: "1", tmuxPane: "%42" });
	const handlers: NonNullable<Parameters<typeof installExtension>[1]>["handlers"] = new Map();
	let closed = false;
	setTmuxPaneTitleSpawnForTests((() => {
		const proc = new EventEmitter() as import("node:child_process").ChildProcess;
		proc.kill = (signal) => {
			if (signal === "SIGKILL") queueMicrotask(() => { closed = true; proc.emit("close", 1); });
			return true;
		};
		return proc;
	}) as typeof import("node:child_process").spawn);
	try {
		await withoutRealIntervals(async () => {
			const start = await installExtension(harness, { extension, handlers });
			await start({}, fakeCtx(harness));
		});
		for (const handler of handlers.get("session_shutdown") ?? []) await handler({}, fakeCtx(harness));
		expect(closed, "shutdown must drain the active title command").toBe(true);
	} finally {
		await drainCurrentTmuxPaneTitle();
		teardown(harness);
	}
}

test("installed shutdown drains the SIGTERM-resistant title command", async () => {
	const { cleanupTempRuntimes, importRuntimeCopy } = await import("./browser-fixture.js");
	try {
		const runtime = await import("../extensions/subagent/index.js");
		await shutdownTitle(runtime.default);
		const mutant = await importRuntimeCopy("index.ts", "await drainCurrentTmuxPaneTitle();\n\t\tawait drainTranscriptUsagePersistences();", "void drainCurrentTmuxPaneTitle();\n\t\tawait drainTranscriptUsagePersistences();") as typeof runtime;
		await expect(shutdownTitle(mutant.default)).rejects.toThrow("shutdown must drain the active title command");
	} finally { cleanupTempRuntimes(); }
});
