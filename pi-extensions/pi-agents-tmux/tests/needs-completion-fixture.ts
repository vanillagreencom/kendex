// The neutral world for the needs_completion suites: a runtime root with
// one pane agent, a seeded git repo the agent works in, the fake extension
// API that records emitted events, and an observer that reads a task
// record back as one line. Nothing here plants a defect; a case that needs
// one (a held lock, a trap script, a hook) builds it inline.
import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { taskRegistryPath } from "../extensions/subagent/paths.js";
import { readTaskRegistry, writePaneRegistry, writeTaskRegistry } from "../extensions/subagent/tasks.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";
import { removeSettled } from "./remove-settled.js";

export const ABSENT = "ABSENT";

const runtimeRoots = new Set<string>();
const repos = new Set<string>();

export function tempRuntimeRoot(): string {
	const dir = mkdtempSync(join(tmpdir(), "needs-completion-runtime-"));
	runtimeRoots.add(dir);
	return dir;
}

// A repo with one commit and one untracked file, the dirty state a subagent leaves behind.
export function tempGitRepo(): string {
	const cwd = mkdtempSync(join(tmpdir(), "needs-completion-cwd-"));
	repos.add(cwd);
	git(cwd, "init");
	writeFileSync(join(cwd, "tracked.txt"), "initial\n", "utf8");
	git(cwd, "add", "tracked.txt");
	git(cwd, "commit", "--no-gpg-sign", "-m", "initial commit");
	writeFileSync(join(cwd, "dirty.txt"), "dirty\n", "utf8");
	return cwd;
}

export function git(cwd: string, ...args: string[]): string {
	return execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", ...args], { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
}

// Runtime roots drain their fire-and-forget writers before removal; repos are plain.
export async function cleanupNeedsCompletionWorlds(): Promise<void> {
	for (const dir of runtimeRoots) {
		rmSync(`${taskRegistryPath(dir)}.lock`, { force: true, recursive: true });
		await removeSettled(dir);
	}
	runtimeRoots.clear();
	for (const dir of repos) rmSync(dir, { force: true, recursive: true });
	repos.clear();
}

export async function seedPaneTask(runtimeRoot: string, cwd: unknown, taskId: string, patch: Partial<PaneTaskRecord> = {}): Promise<PaneTaskRecord> {
	await writePaneRegistry(runtimeRoot, {
		rust: {
			agent: "rust",
			cwd: cwd as string,
			launcherFile: join(runtimeRoot, "launcher.sh"),
			paneId: "%1",
			promptFile: join(runtimeRoot, "prompt.md"),
			sessionFile: join(runtimeRoot, "session.jsonl"),
			startedAt: "2026-05-20T00:00:00.000Z",
			windowName: "rust-agent",
		},
	});
	const record: PaneTaskRecord = {
		agent: "rust",
		createdAt: "2026-05-20T00:00:00.000Z",
		kind: "pane",
		outboxFile: outboxPath(runtimeRoot, taskId),
		status: "running",
		task: "Do work",
		taskId,
		updatedAt: "2026-05-20T00:00:01.000Z",
		...patch,
	};
	await writeTaskRegistry(runtimeRoot, { [taskId]: record });
	return record;
}

export function outboxPath(runtimeRoot: string, taskId: string): string {
	return join(runtimeRoot, "outbox", "rust", `${taskId}.json`);
}

export function writeOutbox(runtimeRoot: string, taskId: string, body: string | Record<string, unknown>): string {
	const file = outboxPath(runtimeRoot, taskId);
	mkdirSync(dirname(file), { recursive: true });
	writeFileSync(file, typeof body === "string" ? body : JSON.stringify(body), "utf8");
	return file;
}

export type Emitted = Array<{ name: string; payload: any }>;

export function fakePi(emitted: Emitted): any {
	return { events: { emit: (name: string, payload: any) => emitted.push({ name, payload }) }, sendMessage: () => undefined };
}

export function holdTaskRegistryLock(runtimeRoot: string): string {
	const lockDir = `${taskRegistryPath(runtimeRoot)}.lock`;
	mkdirSync(lockDir, { recursive: true });
	return lockDir;
}

export async function waitForTaskRecord(runtimeRoot: string, taskId: string, predicate: (record: PaneTaskRecord | undefined) => boolean): Promise<PaneTaskRecord> {
	let record: PaneTaskRecord | undefined;
	for (let attempt = 0; attempt < 100; attempt += 1) {
		record = (await readTaskRegistry(runtimeRoot))[taskId];
		if (predicate(record)) return record!;
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
	throw new Error(`Timed out waiting for task record ${taskId}; last=${JSON.stringify(record)}`);
}

// A record's completion state as one line: paths relative to the runtime
// root, the archive's timestamped basename read as `<archive>`, and whether
// the file each path names is still there.
export function completionState(runtimeRoot: string, record: PaneTaskRecord | undefined, outboxFile: string): string {
	if (!record) return `record=${ABSENT}`;
	const rel = (file: string | undefined) => (file ? relative(runtimeRoot, file).replace(/\/\d+-([^/]+)$/, "/<archive>-$1") : ABSENT);
	const archive = record.completionArchivePath;
	return [
		`status=${record.status}`,
		`summary=${JSON.stringify(record.summary ?? ABSENT)}`,
		`source=${rel(record.completionSourcePath)}`,
		`archive=${rel(archive)}${archive ? (existsSync(archive) ? " present" : " missing") : ""}`,
		`outbox=${existsSync(outboxFile) ? "present" : "gone"}`,
	].join(" ");
}

export function eventNames(emitted: Emitted): string {
	return emitted.map((event) => event.name.replace(/^subagents:/, "")).join(",") || "none";
}
