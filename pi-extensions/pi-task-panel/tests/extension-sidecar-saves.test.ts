import { expect, spyOn, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, unlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import * as atomicWrite from "../extensions/atomic-write.ts";
import { clearPackageConfigCache } from "../extensions/package-config.js";
import { fakeCtx, fakePi, mockPiModules } from "./lib/fake-pi.ts";

mockPiModules();

const SESSION_ID = "sidecar-saves-test";

interface Panel {
	ctx: ReturnType<typeof fakeCtx>;
	notifications: Array<{ message: string; level: string }>;
	pi: ReturnType<typeof fakePi>;
	sidecar: string;
	tasksWrite: (params: Record<string, unknown>) => Promise<any>;
}

async function withPanel(run: (panel: Panel) => Promise<void>, expectedWarnings: string[] = []): Promise<void> {
	const previousPiDir = process.env.PI_CODING_AGENT_DIR;
	const previousDiagnosticLog = process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
	const base = realpathSync(mkdtempSync(join(tmpdir(), "pi-task-panel-saves-")));
	try {
		process.env.PI_CODING_AGENT_DIR = join(base, "agent");
		process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = join(base, "diagnostics.log");
		clearPackageConfigCache();
		const { default: taskPanel } = await import("../extensions/task-panel.js");
		const pi = fakePi();
		taskPanel(pi as never);
		const notifications: Array<{ message: string; level: string }> = [];
		const ctx = fakeCtx(base, SESSION_ID, notifications);
		const tool = pi.tools.get("tasks_write");
		let call = 0;
		await run({
			ctx,
			notifications,
			pi,
			sidecar: join(base, "agent", "kendex", "sessions", SESSION_ID, "pi-task-panel", "state.json"),
			tasksWrite: (params) => tool.execute(`call-${++call}`, params, undefined, undefined, ctx),
		});
		expect(notifications.filter((note) => note.level === "warning").map((note) => note.message.split("\n")[0])).toEqual(expectedWarnings);
	} finally {
		if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousPiDir;
		if (previousDiagnosticLog === undefined) delete process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
		else process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = previousDiagnosticLog;
		clearPackageConfigCache();
		rmSync(base, { recursive: true, force: true });
	}
}

function handler(pi: ReturnType<typeof fakePi>, event: string) {
	const registered = pi.handlers.get(event);
	if (!registered) throw new Error(`handler-missing=${event}`);
	return registered;
}

function sidecarTasks(sidecar: string): string[] {
	return JSON.parse(readFileSync(sidecar, "utf8")).tasks.map((task: { content: string }) => task.content);
}

test("a tasks_write call writes the sidecar off the calling turn and holds its result until the write lands", async () => {
	await withPanel(async ({ pi, sidecar, tasksWrite }) => {
		const pending = tasksWrite({ action: "add_task", task: "first" });
		expect(existsSync(sidecar)).toBe(false);
		await pending;
		expect(sidecarTasks(sidecar)).toEqual(["first"]);
		expect(JSON.parse(readFileSync(sidecar, "utf8"))).toEqual(pi.appended.at(-1)?.data);
	});
});

test("an unchanged state writes neither the sidecar nor a session entry", async () => {
	await withPanel(async ({ pi, sidecar, tasksWrite }) => {
		await tasksWrite({ action: "add_task", task: "first" });
		await tasksWrite({ action: "start_task", task: "first" });
		const entries = pi.appended.length;
		unlinkSync(sidecar);
		await tasksWrite({ action: "start_task", task: "first" });
		expect(existsSync(sidecar)).toBe(false);
		expect(pi.appended).toHaveLength(entries);
		await tasksWrite({ action: "add_task", task: "second" });
		expect(sidecarTasks(sidecar)).toEqual(["first", "second"]);
		expect(pi.appended).toHaveLength(entries + 1);
	});
});

test("session shutdown waits for a queued sidecar write", async () => {
	await withPanel(async ({ ctx, pi, sidecar, tasksWrite }) => {
		const pending = tasksWrite({ action: "add_task", task: "last" });
		await handler(pi, "session_shutdown")({ type: "session_shutdown" }, ctx);
		expect(existsSync(sidecar)).toBe(true);
		expect(sidecarTasks(sidecar)).toEqual(["last"]);
		await pending;
	});
});

test("tree navigation reads the sidecar only after a queued write lands", async () => {
	await withPanel(async ({ ctx, pi, tasksWrite }) => {
		const pending = tasksWrite({ action: "add_task", task: "queued" });
		await handler(pi, "session_tree")({ type: "session_tree" }, ctx);
		await pending;
		const result = await tasksWrite({ action: "start_task", task: "queued" });
		expect(result.details.message).toBe("queued");
	});
});

test("a save queued behind a pending sidecar write starts only after it and lands last", async () => {
	await withPanel(async ({ pi, sidecar, tasksWrite }) => {
		const realWrite = atomicWrite.writeFileAtomic;
		let release = () => {};
		const held = new Promise<void>((resolve) => {
			release = resolve;
		});
		const write = spyOn(atomicWrite, "writeFileAtomic").mockImplementationOnce(async (file, text) => {
			await held;
			await realWrite(file, text);
		});
		try {
			const first = tasksWrite({ action: "add_task", task: "first" });
			const second = tasksWrite({ action: "add_task", task: "second" });
			// setImmediate runs after every queued microtask, so a second save that
			// skipped the queue would have called the write by now.
			await new Promise((resolve) => setImmediate(resolve));
			expect(write).toHaveBeenCalledTimes(1);
			expect(pi.appended).toHaveLength(0);
			release();
			await Promise.all([first, second]);
			expect(write).toHaveBeenCalledTimes(2);
		} finally {
			write.mockRestore();
		}
		expect(pi.appended.map((entry) => entry.data.tasks.map((task: { content: string }) => task.content))).toEqual([["first"], ["first", "second"]]);
		expect(sidecarTasks(sidecar)).toEqual(["first", "second"]);
	});
});

/** Makes the sidecar directory a plain file, so the next sidecar write fails; the returned function undoes it. */
function blockSidecar(sidecar: string): () => void {
	const directory = dirname(sidecar);
	rmSync(directory, { recursive: true, force: true });
	mkdirSync(dirname(directory), { recursive: true });
	writeFileSync(directory, "not a directory", "utf8");
	return () => unlinkSync(directory);
}

/** Makes the next session-entry append throw; the returned function undoes it. */
function refuseAppend(pi: ReturnType<typeof fakePi>): () => void {
	const append = pi.appendEntry;
	pi.appendEntry = () => {
		throw new Error("append refused");
	};
	return () => {
		pi.appendEntry = append;
	};
}

const failedSaves: Array<{ failure: string; warnings: string[]; arm: (panel: Panel) => Array<() => void> }> = [
	{ failure: "session-entry append", warnings: ["persistence_failure=session-entry"], arm: ({ pi }) => [refuseAppend(pi)] },
	{ failure: "sidecar write", warnings: ["persistence_failure=sidecar-write"], arm: ({ sidecar }) => [blockSidecar(sidecar)] },
	{
		failure: "sidecar write and session-entry append",
		warnings: ["persistence_failure=sidecar-write", "persistence_failure=session-entry-no-sidecar"],
		arm: ({ pi, sidecar }) => [blockSidecar(sidecar), refuseAppend(pi)],
	},
];

for (const { failure, warnings, arm } of failedSaves) {
	test(`after a failed ${failure}, repeating the same change saves it again`, async () => {
		await withPanel(async (panel) => {
			const { pi, sidecar, tasksWrite } = panel;
			await tasksWrite({ action: "add_task", task: "first" });
			const undo = arm(panel);
			await tasksWrite({ action: "mark_done", task: "first" });
			for (const restore of undo) restore();
			const entries = pi.appended.length;
			await tasksWrite({ action: "mark_done", task: "first" });
			expect(pi.appended).toHaveLength(entries + 1);
			const saved = JSON.parse(readFileSync(sidecar, "utf8"));
			expect(saved.tasks.map((task: { status: string }) => task.status)).toEqual(["completed"]);
			expect(saved).toEqual(pi.appended.at(-1)?.data);
		}, warnings);
	});
}
