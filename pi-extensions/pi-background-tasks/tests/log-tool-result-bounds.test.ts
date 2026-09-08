import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { DEFAULT_LOG_TAIL_MAX_CHARS as cap } from "../extensions/constants.js";
import type { BackgroundTaskSnapshot, BackgroundLogTruncation } from "../extensions/types.js";
import { WAKE_MANIFEST_FIELD_MAX_CHARS as fieldCap } from "../extensions/wake-events.js";
import { privateLogRoot } from "./fixtures/log-settings.js";

const logFile = "/tmp/kendex-pi-bg/bg-log-1-1700000000000.log";
const marker = "retained log tail\n";
const tail = marker + "z".repeat(cap - marker.length - 1) + "!";
const rows = [
	{ name: "bg_task huge log and metadata", tool: "bg_task", output: "z".repeat(cap * 3) + tail, huge: true, path: logFile },
	{ name: "bg_status huge log and metadata", tool: "bg_status", output: "z".repeat(cap * 3) + tail, huge: true, path: logFile },
	{ name: "bg_task long log path", tool: "bg_task", output: "z".repeat(cap * 3) + tail, huge: true, path: "/tmp/" + "L".repeat(5_000) },
	{ name: "bg_status long log path", tool: "bg_status", output: "z".repeat(cap * 3) + tail, huge: true, path: "/tmp/" + "L".repeat(5_000) },
	{ name: "bg_task small output", tool: "bg_task", output: "all good\n", huge: false, path: logFile },
	{ name: "bg_status small output", tool: "bg_status", output: "all good\n", huge: false, path: logFile },
	{ name: "bg_task empty output", tool: "bg_task", output: "", huge: false, path: logFile },
	{ name: "bg_status empty output", tool: "bg_status", output: "", huge: false, path: logFile },
];

interface ChildResult {
	result: { content: { type: string; text: string }[]; details: { action: string; task: BackgroundTaskSnapshot; fullOutputPath?: string; truncation?: BackgroundLogTruncation } };
	calls: unknown[];
}

test("registered log tool result rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "registered log table must contain cases").toBeGreaterThan(0);
	const root = privateLogRoot();
	try {
		const inputs = rows.map((row) => ({
			tool: row.tool, output: row.output,
			task: {
				id: "bg-log-1", pid: 4242, logFile: row.path,
				command: row.huge ? "Q".repeat(200_000) : "echo log",
				title: row.huge ? "T".repeat(5_000) : "log",
				cwd: row.huge ? "/" + "C".repeat(5_000) : "/path/work",
				procIdent: { pid: 4242, startToken: "private-start", comm: "private-command" },
			},
		}));
		const child = spawnSync(process.execPath, [join(import.meta.dir, "fixtures", "registered-log.ts")], {
			cwd: root, env: { ...process.env, PI_CODING_AGENT_DIR: join(root, "agent"), PI_BG_TASK_DIR: join(root, "logs") },
			input: JSON.stringify(inputs), encoding: "utf8", timeout: 10_000, killSignal: "SIGKILL", maxBuffer: 2_000_000,
		});
		if (child.error) throw new Error(`registered log child spawn failed: ${child.error.message}`);
		if (child.status !== 0) throw new Error(`registered log child exited ${child.status ?? child.signal}: ${child.stderr}`);
		const results: ChildResult[] = JSON.parse(child.stdout);
		if (results.length !== rows.length) throw new Error(`registered log child returned ${results.length} rows; expected ${rows.length}`);
		for (const [index, row] of rows.entries()) {
			const { result, calls } = results[index]!;
			const task = result.details.task;
			const safePath = row.path.length <= fieldCap ? row.path : "/tmp/" + "L".repeat(fieldCap - 6) + "…";
			const text = row.huge
				? `[...truncated]\n${tail}\n\n[Background log truncated. Showing last ${cap} of ${row.output.length} character(s). Full log: ${safePath}]`
				: row.output || "(empty)";
			expect({
				content: result.content, action: result.details.action,
				task: { id: task.id, pid: task.pid, command: task.command, title: task.title, cwd: task.cwd, logFile: task.logFile },
				fullOutputPath: result.details.fullOutputPath, truncation: result.details.truncation,
				bounded: Buffer.byteLength(JSON.stringify(result), "utf8") < 16_384,
				internalIdentity: task.procIdent, calls,
			}, row.name).toStrictEqual({
				content: [{ type: "text", text }], action: "log",
				task: { id: "bg-log-1", pid: 4242, command: row.huge ? "Q".repeat(fieldCap - 1) + "…" : "echo log", title: row.huge ? "T".repeat(fieldCap - 1) + "…" : "log", cwd: row.huge ? "/" + "C".repeat(fieldCap - 2) + "…" : "/path/work", logFile: safePath },
				fullOutputPath: row.huge ? safePath : undefined,
				truncation: row.huge ? { direction: "tail", truncated: true, fullOutputPath: safePath, shownChars: cap, totalChars: row.output.length } : undefined,
				bounded: true, internalIdentity: undefined,
				calls: [{ id: row.tool === "bg_task" ? "bg-log-1" : null, pid: row.tool === "bg_status" ? 4242 : null }, { outputSameTask: true }, { rememberSameTask: true }],
			});
		}
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
});
