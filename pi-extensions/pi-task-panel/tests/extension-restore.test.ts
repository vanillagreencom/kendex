import { expect, test } from "bun:test";
import { mkdtempSync, readFileSync, realpathSync, rmSync, unlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { clearPackageConfigCache } from "../extensions/package-config.js";
import { fakeCtx, fakePi, mockPiModules } from "./lib/fake-pi.ts";

mockPiModules();

const SESSION_ID = "restore-test";
const BRANCH_STATE_MISSING = "persistence_failure=branch-state-missing";

/** Saved in this order, so the sidecar ends holding `newer`; `mid` passes only the tool-result task cap, the other large lists the session entry cap too. */
const SAVES = {
	small: ["small task"],
	mid: Array.from({ length: 150 }, (_value, index) => `mid ${index}`),
	older: Array.from({ length: 200 }, (_value, index) => `${"o".repeat(400)} older ${index}`),
	newer: Array.from({ length: 200 }, (_value, index) => `${"n".repeat(400)} newer ${index}`),
};
type Save = keyof typeof SAVES;
/** A save's session custom entry, or its tasks_write tool result. */
type BranchRecord = `${Save}.${"entry" | "result"}`;

const ROWS: Array<{ name: string; branch: BranchRecord[]; sidecar: boolean; expected: Save | "empty"; warnings: string[] }> = [
	{ name: "a tree point before any task save ignores the newer sidecar", branch: [], sidecar: true, expected: "empty", warnings: [] },
	{ name: "a manifest naming an older state keeps the last full list and warns", branch: ["small.entry", "older.entry"], sidecar: true, expected: "small", warnings: [BRANCH_STATE_MISSING] },
	{ name: "a manifest naming the sidecar state restores the sidecar", branch: ["small.entry", "older.entry", "newer.entry"], sidecar: true, expected: "newer", warnings: [] },
	{ name: "bounded details naming an older state keep the last full list and warn", branch: ["small.result", "older.result"], sidecar: true, expected: "small", warnings: [BRANCH_STATE_MISSING] },
	{ name: "bounded details naming the sidecar state replace older full details", branch: ["small.result", "newer.result"], sidecar: true, expected: "newer", warnings: [] },
	{ name: "bounded details naming the full entry before them keep that list without the sidecar", branch: ["small.entry", "small.result", "mid.entry", "mid.result"], sidecar: true, expected: "mid", warnings: [] },
	{ name: "a fork without the sidecar keeps the last full list and warns", branch: ["small.entry", "newer.entry"], sidecar: false, expected: "small", warnings: [BRANCH_STATE_MISSING] },
];

for (const row of ROWS) {
	test(`session_tree restore: ${row.name}`, async () => {
		const previousPiDir = process.env.PI_CODING_AGENT_DIR;
		const previousDiagnosticLog = process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
		const base = realpathSync(mkdtempSync(join(tmpdir(), "pi-task-panel-restore-")));
		try {
			process.env.PI_CODING_AGENT_DIR = join(base, "agent");
			process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = join(base, "diagnostics.log");
			clearPackageConfigCache();
			const { default: taskPanel } = await import("../extensions/task-panel.js");
			const pi = fakePi();
			taskPanel(pi as never);
			const notifications: Array<{ message: string; level: string }> = [];
			const ctx = fakeCtx(base, SESSION_ID, notifications);
			const records = new Map<BranchRecord, unknown>();
			for (const save of Object.keys(SAVES) as Save[]) {
				const tasks = SAVES[save].map((content) => ({ content }));
				const result = await pi.tools.get("tasks_write").execute(`call-${save}`, { action: "replace", tasks }, undefined, undefined, ctx);
				const entry = pi.appended.at(-1);
				records.set(`${save}.entry`, { type: "custom", customType: entry?.customType, data: entry?.data });
				records.set(`${save}.result`, { type: "message", message: { role: "toolResult", toolName: "tasks_write", details: result.details } });
			}
			expect(pi.appended.map((entry) => entry.data.fullSnapshot)).toEqual([undefined, undefined, false, false]);
			if (!row.sidecar) unlinkSync(join(base, "agent", "kendex", "sessions", SESSION_ID, "pi-task-panel", "state.json"));
			ctx.sessionManager.getBranch = () => row.branch.map((name) => records.get(name)) as never;

			const navigate = pi.handlers.get("session_tree");
			if (!navigate) throw new Error("handler-missing=session_tree");
			await navigate({}, ctx);
			const exported = join(base, "exported.md");
			await pi.commands.get("tasks:export").handler(exported, ctx);
			const restored = readFileSync(exported, "utf8").split("\n").filter((line) => line.startsWith("- ")).map((line) => line.slice(2).replace(/ \((active|done|dropped)\)$/, ""));
			expect(restored.sort()).toEqual(row.expected === "empty" ? [] : [...SAVES[row.expected]].sort());
			expect(notifications.filter((note) => note.level === "warning").map((note) => note.message.split("\n")[0])).toEqual(row.warnings);
		} finally {
			if (previousPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previousPiDir;
			if (previousDiagnosticLog === undefined) delete process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG;
			else process.env.PI_TASK_PANEL_DIAGNOSTIC_LOG = previousDiagnosticLog;
			clearPackageConfigCache();
			rmSync(base, { recursive: true, force: true });
		}
	});
}
