// End-to-end regression test for the stop tool-result content bound
// (vstack#210 round 4). Spawns a real bg_task via the registered tool
// `execute` callback, then invokes the stop action through the same
// callback so the assertion runs against `makeToolResult` content (and
// the live UI `notify` call) produced by `requestStop` in its actual
// production wiring. Round 3 added the bound in production but the
// initial test only re-derived the bounded string — a future refactor
// that moved the bound or routed around it would have passed silently.

import { afterAll, describe, expect, mock, test } from "bun:test";

// Stub the peer-dep runtime exports so `background-tasks.ts` + the
// registrations / render / dashboard modules it transitively loads can
// resolve in a dev tree without `@earendil-works/pi-coding-agent` /
// `@earendil-works/pi-ai` / `@earendil-works/pi-tui` installed. All other
// imports from those packages are types (erased at runtime).
mock.module("@earendil-works/pi-coding-agent", () => ({
	getShellConfig: () => ({
		shell: process.platform === "win32" ? process.env.ComSpec ?? "cmd.exe" : "/bin/bash",
		args: process.platform === "win32" ? ["/d", "/s", "/c"] : ["-c"],
	}),
}));
mock.module("@earendil-works/pi-ai", () => ({
	StringEnum: (values: readonly string[], meta: Record<string, unknown> = {}) => ({ ...meta, enum: [...values] }),
}));
mock.module("@earendil-works/pi-tui", () => ({
	truncateToWidth: (text: string, _width: number, _suffix?: string) => text,
	visibleWidth: (text: string) => text.length,
	wrapTextWithAnsi: (text: string, _width: number) => [text],
	matchesKey: () => false,
}));
mock.module("typebox", () => {
	const passthrough = (def?: unknown) => ({ schema: def });
	return {
		Type: {
			Object: passthrough,
			Optional: passthrough,
			String: passthrough,
			Number: passthrough,
			Boolean: passthrough,
		},
	};
});

const { default: backgroundTasks } = await import("../extensions/background-tasks.js");
const { WAKE_MANIFEST_FIELD_MAX_CHARS } = await import("../extensions/wake-events.js");

interface RegisteredTool {
	name: string;
	execute: (toolCallId: string, params: any) => Promise<{ content: any[]; details: Record<string, unknown> }>;
}

interface RegisteredCommand {
	handler: (args: string, ctx: any) => Promise<void> | void;
}

interface FakePi {
	tools: Map<string, RegisteredTool>;
	commands: Map<string, RegisteredCommand>;
	handlers: Map<string, (event: any, ctx: any) => unknown>;
	messages: any[];
	entries: { type: string; payload: any }[];
	notifications: { message: string; kind: string }[];
	pi: any;
	ctx: any;
	pids: number[];
}

function makeFakePi(): FakePi {
	const tools = new Map<string, RegisteredTool>();
	const commands = new Map<string, RegisteredCommand>();
	const handlers = new Map<string, (event: any, ctx: any) => unknown>();
	const messages: any[] = [];
	const entries: { type: string; payload: any }[] = [];
	const notifications: { message: string; kind: string }[] = [];
	const pids: number[] = [];

	const pi = {
		registerTool(def: any) { tools.set(def.name, def); },
		registerCommand(name: string, def: any) { commands.set(name, def); },
		registerShortcut(_key: string, _def: any) {},
		registerMessageRenderer(_type: string, _fn: any) {},
		on(event: string, handler: (event: any, ctx: any) => unknown) { handlers.set(event, handler); },
		sendMessage(message: any, _opts: any) { messages.push(message); },
		appendEntry(type: string, payload: any) { entries.push({ type, payload }); },
	};

	const ctx = {
		cwd: process.cwd(),
		hasUI: false,
		isIdle: () => true,
		sessionManager: {
			getBranch() { return []; },
			getSessionId() { return "test-session"; },
			getSessionFile() { return "/tmp/test-session.jsonl"; },
		},
		ui: {
			notify(message: string, kind: string = "info") { notifications.push({ message, kind }); },
			setWidget(_key: string, _factory: any, _options?: any) { return () => {}; },
		},
	};

	return { tools, commands, handlers, messages, entries, notifications, pi, ctx, pids };
}

const liveFakes: FakePi[] = [];

afterAll(() => {
	// Best-effort: kill any subprocess that survived past the test's stop call.
	for (const fake of liveFakes) {
		for (const pid of fake.pids) {
			try { process.kill(-pid, "SIGKILL"); } catch { /* */ }
			try { process.kill(pid, "SIGKILL"); } catch { /* */ }
		}
	}
});

function extractText(toolResult: { content: any[] }): string {
	for (const part of toolResult.content ?? []) {
		if (part?.type === "text" && typeof part.text === "string") return part.text;
	}
	return "";
}

async function spawnHugeCommandAndStop(): Promise<{ stopResult: { content: any[]; details: Record<string, unknown> }; notifications: { message: string; kind: string }[]; safeCommandCap: number }> {
	const fake = makeFakePi();
	liveFakes.push(fake);
	backgroundTasks(fake.pi);

	// Initialize state — `session_start` wires activeCtx + activeSessionId and
	// runs restoreSnapshots(); without it the bg_task tool throws on the
	// first persistSnapshots() call because there is no active context.
	const sessionStart = fake.handlers.get("session_start");
	if (!sessionStart) throw new Error("session_start handler not registered");
	await sessionStart({}, fake.ctx);

	const bgTask = fake.tools.get("bg_task");
	if (!bgTask) throw new Error("bg_task tool not registered");

	// Spawn a task whose command is 100KB. The shell parses `sleep 10` then a
	// comment, so the process itself runs sleep while the command string
	// (kept in memory by the extension) is what we are testing the bound for.
	const hugeCommand = `sleep 10 # ${"X".repeat(100_000)}`;
	const spawnResult = await bgTask.execute("call-spawn", { action: "spawn", command: hugeCommand });
	const taskSnap = (spawnResult.details as { task?: { id?: string; pid?: number } }).task;
	const taskId = taskSnap?.id;
	const pid = typeof taskSnap?.pid === "number" ? taskSnap.pid : 0;
	if (typeof taskId !== "string") throw new Error("spawned task missing id");
	if (pid > 0) fake.pids.push(pid);

	const stopResult = await bgTask.execute("call-stop", { action: "stop", id: taskId });
	return { stopResult, notifications: fake.notifications, safeCommandCap: WAKE_MANIFEST_FIELD_MAX_CHARS };
}

describe("requestStop tool-result content (vstack#210 round 4)", () => {
	test("100KB command spawn → stop produces a bounded tool-result content + notify", async () => {
		const { stopResult, safeCommandCap } = await spawnHugeCommandAndStop();
		const text = extractText(stopResult);

		// The stop reply is `Stopped/Stopping ${task.id} (${command}).` with
		// command bounded by WAKE_MANIFEST_FIELD_MAX_CHARS plus a small
		// envelope ("Stopping bg-N (", ").", short id).
		expect(text.length).toBeLessThan(safeCommandCap + 128);
		expect(text).not.toContain("X".repeat(safeCommandCap + 1));

		// `details.task` is the compact manifest; double-check the command
		// in it is also bounded.
		const detailsTask = (stopResult.details as { task?: Record<string, unknown> }).task as Record<string, unknown>;
		const detailsCommand = String(detailsTask?.command ?? "");
		expect(detailsCommand.length).toBeLessThanOrEqual(safeCommandCap);
		expect(detailsCommand).not.toContain("X".repeat(safeCommandCap + 1));
	});

	test("/bg:stop slash-command notify payload is bounded for a 100KB command", async () => {
		const fake = makeFakePi();
		liveFakes.push(fake);
		backgroundTasks(fake.pi);

		const sessionStart = fake.handlers.get("session_start");
		if (!sessionStart) throw new Error("session_start handler not registered");
		await sessionStart({}, fake.ctx);

		const bgTask = fake.tools.get("bg_task");
		if (!bgTask) throw new Error("bg_task tool not registered");
		const stopCommand = fake.commands.get("bg:stop");
		if (!stopCommand) throw new Error("bg:stop command not registered");

		const hugeCommand = `sleep 10 # ${"Y".repeat(100_000)}`;
		const spawnResult = await bgTask.execute("call-spawn", { action: "spawn", command: hugeCommand });
		const taskSnap = (spawnResult.details as { task?: { id?: string; pid?: number } }).task;
		const taskId = String(taskSnap?.id ?? "");
		const pid = typeof taskSnap?.pid === "number" ? taskSnap.pid : 0;
		if (!taskId) throw new Error("spawned task missing id");
		if (pid > 0) fake.pids.push(pid);

		fake.notifications.length = 0;
		await stopCommand.handler(taskId, fake.ctx);

		const stopNotifications = fake.notifications.filter((n) => /^(Stopping|Stopped)\s/.test(n.message));
		expect(stopNotifications.length).toBeGreaterThanOrEqual(1);
		for (const note of stopNotifications) {
			expect(note.message.length).toBeLessThan(WAKE_MANIFEST_FIELD_MAX_CHARS + 128);
			expect(note.message).not.toContain("Y".repeat(WAKE_MANIFEST_FIELD_MAX_CHARS + 1));
		}
	});
});
