import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import * as fs from "node:fs";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, expect, test } from "bun:test";
import { formatTaskRecordResult } from "../extensions/subagent/renderers.js";
import { setGitExecFileForTests } from "../extensions/subagent/cwd-snapshot.js";
import { setFileLockOptionsForTests } from "../extensions/subagent/file-lock.js";
import { taskRegistryPath } from "../extensions/subagent/paths.js";
import {
	markTaskNeedsCompletion,
	pollPaneCompletions,
	readTaskRegistry,
	recordTaskDispatchFailure,
	refreshTaskDiagnostics,
	setAfterCompletionArchiveForTests,
	setBeforeCompletionRegistryUpdateForTests,
	writePaneRegistry,
	writeTaskRegistry,
} from "../extensions/subagent/tasks.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";

function tempDir(prefix: string): string {
	return mkdtempSync(join(tmpdir(), prefix));
}

function holdTaskRegistryLock(runtimeRoot: string): string {
	const lockDir = `${taskRegistryPath(runtimeRoot)}.lock`;
	mkdirSync(lockDir, { recursive: true });
	return lockDir;
}

function forceFastRegistryLockTimeout(): void {
	setFileLockOptionsForTests({ retryMs: 1, staleMs: Number.POSITIVE_INFINITY, timeoutMs: 5 });
}

function tempGitRepo(): string {
	const cwd = tempDir("needs-completion-cwd-");
	execFileSync("git", ["init"], { cwd, stdio: "ignore" });
	writeFileSync(join(cwd, "tracked.txt"), "initial\n", "utf8");
	execFileSync("git", ["add", "tracked.txt"], { cwd, stdio: "ignore" });
	execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", "commit", "--no-gpg-sign", "-m", "initial commit"], { cwd, stdio: "ignore" });
	writeFileSync(join(cwd, "dirty.txt"), "dirty\n", "utf8");
	return cwd;
}

function installFsmonitorTrap(cwd: string): string {
	const sentinel = join(cwd, "fsmonitor-invoked.log");
	const script = join(cwd, "fsmonitor.sh");
	writeFileSync(script, `#!/bin/sh\necho invoked >> ${JSON.stringify(sentinel)}\nexit 0\n`, "utf8");
	chmodSync(script, 0o755);
	execFileSync("git", ["config", "core.fsmonitor", script], { cwd, stdio: "ignore" });
	return sentinel;
}

function installGpgTrap(cwd: string): string {
	const sentinel = join(cwd, "gpg-invoked.log");
	const script = join(cwd, "gpg.sh");
	writeFileSync(script, `#!/bin/sh\necho invoked >> ${JSON.stringify(sentinel)}\nexit 1\n`, "utf8");
	chmodSync(script, 0o755);
	execFileSync("git", ["config", "log.showSignature", "true"], { cwd, stdio: "ignore" });
	execFileSync("git", ["config", "gpg.program", script], { cwd, stdio: "ignore" });
	return sentinel;
}

function installCleanFilterTrap(cwd: string): string {
	const sentinel = join(cwd, "filter-invoked.log");
	const script = join(cwd, "clean-filter.sh");
	writeFileSync(join(cwd, ".gitattributes"), "tracked.txt filter=trap\n", "utf8");
	execFileSync("git", ["add", ".gitattributes"], { cwd, stdio: "ignore" });
	execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", "commit", "--no-gpg-sign", "-m", "add attrs"], { cwd, stdio: "ignore" });
	writeFileSync(script, `#!/bin/sh\necho invoked >> ${JSON.stringify(sentinel)}\ncat\n`, "utf8");
	chmodSync(script, 0o755);
	execFileSync("git", ["config", "filter.trap.clean", script], { cwd, stdio: "ignore" });
	writeFileSync(join(cwd, "tracked.txt"), "modified\n", "utf8");
	return sentinel;
}

function replaceHeadWithFakeSignedCommit(cwd: string): void {
	const tree = execFileSync("git", ["write-tree"], { cwd, encoding: "utf8" }).trim();
	const branch = execFileSync("git", ["symbolic-ref", "--short", "HEAD"], { cwd, encoding: "utf8" }).trim();
	const commitBody = [
		`tree ${tree}`,
		"author Pi Test <pi-test@example.invalid> 1700000000 +0000",
		"committer Pi Test <pi-test@example.invalid> 1700000000 +0000",
		"gpgsig -----BEGIN PGP SIGNATURE-----",
		" ",
		" fake",
		" -----END PGP SIGNATURE-----",
		"",
		"fake signed commit",
		"",
	].join("\n");
	const commitPath = join(cwd, "fake-signed-commit.txt");
	writeFileSync(commitPath, commitBody, "utf8");
	const commit = execFileSync("git", ["hash-object", "-t", "commit", "-w", commitPath], { cwd, encoding: "utf8" }).trim();
	execFileSync("git", ["update-ref", `refs/heads/${branch}`, commit], { cwd, stdio: "ignore" });
}

async function seedPaneTask(runtimeRoot: string, cwd: string, taskId: string, patch: Partial<PaneTaskRecord> = {}): Promise<PaneTaskRecord> {
	await writePaneRegistry(runtimeRoot, {
		rust: {
			agent: "rust",
			cwd,
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
		outboxFile: join(runtimeRoot, "outbox", "rust", `${taskId}.json`),
		status: "running",
		task: "Do work",
		taskId,
		updatedAt: "2026-05-20T00:00:01.000Z",
		...patch,
	};
	await writeTaskRegistry(runtimeRoot, { [taskId]: record });
	return record;
}

async function waitForTaskRecord(
	runtimeRoot: string,
	taskId: string,
	predicate: (record: PaneTaskRecord | undefined) => boolean,
): Promise<PaneTaskRecord> {
	let record: PaneTaskRecord | undefined;
	for (let attempt = 0; attempt < 100; attempt += 1) {
		record = (await readTaskRegistry(runtimeRoot))[taskId];
		if (predicate(record)) return record!;
		await new Promise((resolve) => setTimeout(resolve, 10));
	}
	throw new Error(`Timed out waiting for task record ${taskId}; last=${JSON.stringify(record)}`);
}

describe("needs_completion cwd snapshots", () => {
	test("markTaskNeedsCompletion snapshots the pane registry cwd", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		const fsmonitorSentinel = installFsmonitorTrap(cwd);
		try {
			await seedPaneTask(runtimeRoot, cwd, "task-1");

			const updated = await markTaskNeedsCompletion(runtimeRoot, "rust", "task-1", {
				diagnostic: "Task turn ended without complete_subagent.",
			});
			const persisted = await waitForTaskRecord(runtimeRoot, "task-1", (record) => record?.cwdSnapshot?.cwd === cwd);

			expect(updated?.status).toBe("needs_completion");
			expect(persisted.cwdSnapshot?.cwd).toBe(cwd);
			expect(persisted.cwdSnapshot?.dirty).toBe(true);
			expect(persisted.cwdSnapshot?.status).toContain("?? dirty.txt");
			expect(persisted.cwdSnapshot?.lastCommit.subject).toBe("initial commit");
			expect(existsSync(fsmonitorSentinel)).toBe(false);
			expect(persisted.diagnostics).toContain("Task turn ended without complete_subagent.");

			const rendered = formatTaskRecordResult(persisted);
			expect(rendered).toContain("### CWD Snapshot");
			expect(rendered).toContain("HEAD:");
			expect(rendered).toContain("Last commit: initial commit");
		} finally {
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("markTaskNeedsCompletion disables local signature verification hooks", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		replaceHeadWithFakeSignedCommit(cwd);
		const gpgSentinel = installGpgTrap(cwd);
		try {
			await seedPaneTask(runtimeRoot, cwd, "task-gpg");

			const updated = await markTaskNeedsCompletion(runtimeRoot, "rust", "task-gpg", {
				diagnostic: "Task turn ended without complete_subagent.",
			});
			const persisted = await waitForTaskRecord(runtimeRoot, "task-gpg", (record) => record?.cwdSnapshot?.lastCommit.subject === "fake signed commit");

			expect(updated?.status).toBe("needs_completion");
			expect(persisted.cwdSnapshot?.lastCommit.subject).toBe("fake signed commit");
			expect(existsSync(gpgSentinel)).toBe(false);
		} finally {
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("markTaskNeedsCompletion avoids local clean filters while collecting dirty state", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		const filterSentinel = installCleanFilterTrap(cwd);
		try {
			await seedPaneTask(runtimeRoot, cwd, "task-filter");

			const updated = await markTaskNeedsCompletion(runtimeRoot, "rust", "task-filter", {
				diagnostic: "Task turn ended without complete_subagent.",
			});
			const persisted = await waitForTaskRecord(runtimeRoot, "task-filter", (record) => record?.cwdSnapshot?.status.includes(" M tracked.txt") === true);

			expect(updated?.status).toBe("needs_completion");
			expect(persisted.cwdSnapshot?.status).toContain(" M tracked.txt");
			expect(existsSync(filterSentinel)).toBe(false);
		} finally {
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("markTaskNeedsCompletion returns before cwd snapshot patch completes", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempDir("needs-completion-cwd-");
		try {
			await seedPaneTask(runtimeRoot, cwd, "task-slow");
			setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
				void command;
				void args;
				void options;
				void callback;
				return new EventEmitter() as any;
			}) as any);

			const result = await Promise.race([
				markTaskNeedsCompletion(runtimeRoot, "rust", "task-slow", { cwd, diagnostic: "missing completion" }),
				new Promise<"timed-out">((resolve) => setTimeout(() => resolve("timed-out"), 25)),
			]);
			const persisted = (await readTaskRegistry(runtimeRoot))["task-slow"]!;

			expect(result).not.toBe("timed-out");
			expect((result as PaneTaskRecord | undefined)?.status).toBe("needs_completion");
			expect((result as PaneTaskRecord | undefined)?.cwdSnapshot).toBeUndefined();
			expect(persisted.status).toBe("needs_completion");
			expect(persisted.diagnostics).toContain("missing completion");
		} finally {
			setGitExecFileForTests();
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("pollPaneCompletions snapshots parsed needs_completion outbox", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		try {
			await seedPaneTask(runtimeRoot, cwd, "task-polled");
			const outboxFile = join(runtimeRoot, "outbox", "rust", "task-polled.json");
			mkdirSync(dirname(outboxFile), { recursive: true });
			writeFileSync(outboxFile, JSON.stringify({
				agent: "rust",
				reason: "turn-ended-without-complete-subagent",
				status: "needs_completion",
				summary: "synthetic missing completion",
				taskId: "task-polled",
			}), "utf8");
			const emitted: Array<{ name: string; payload: any }> = [];

			const count = await pollPaneCompletions(runtimeRoot, {
				events: { emit: (name: string, payload: any) => emitted.push({ name, payload }) },
				sendMessage: () => undefined,
			} as any);
			const persisted = (await readTaskRegistry(runtimeRoot))["task-polled"]!;
			const needsCompletion = emitted.find((event) => event.name === "subagents:needs_completion");
			const needsCompletionSnapshot = emitted.find((event) => event.name === "subagents:needs_completion" && event.payload.cwdSnapshot);

			expect(count).toBe(1);
			expect(persisted.status).toBe("needs_completion");
			expect(persisted.cwdSnapshot?.cwd).toBe(cwd);
			expect(persisted.cwdSnapshot?.lastCommit.subject).toBe("initial commit");
			expect(needsCompletion?.payload.reason).toBe("turn-ended-without-complete-subagent");
			expect(needsCompletionSnapshot?.payload.cwdSnapshot?.cwd).toBe(cwd);
		} finally {
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("pollPaneCompletions leaves completion outbox retryable when terminal registry write times out", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		try {
			await seedPaneTask(runtimeRoot, cwd, "task-lock-completed");
			const outboxFile = join(runtimeRoot, "outbox", "rust", "task-lock-completed.json");
			mkdirSync(dirname(outboxFile), { recursive: true });
			writeFileSync(outboxFile, JSON.stringify({
				agent: "rust",
				filesChanged: [],
				status: "completed",
				summary: "done under contention",
				taskId: "task-lock-completed",
				validation: [],
			}), "utf8");
			const emitted: Array<{ name: string; payload: any }> = [];
			const lockDir = holdTaskRegistryLock(runtimeRoot);
			forceFastRegistryLockTimeout();

			const lockedCount = await pollPaneCompletions(runtimeRoot, {
				events: { emit: (name: string, payload: any) => emitted.push({ name, payload }) },
				sendMessage: () => undefined,
			} as any);
			const lockedRecord = (await readTaskRegistry(runtimeRoot))["task-lock-completed"]!;

			expect(lockedCount).toBe(0);
			expect(lockedRecord.status).toBe("running");
			expect(existsSync(outboxFile)).toBe(true);
			expect(emitted).toHaveLength(0);

			setFileLockOptionsForTests();
			rmSync(lockDir, { force: true, recursive: true });
			const retryCount = await pollPaneCompletions(runtimeRoot, {
				events: { emit: (name: string, payload: any) => emitted.push({ name, payload }) },
				sendMessage: () => undefined,
			} as any);
			const persisted = (await readTaskRegistry(runtimeRoot))["task-lock-completed"]!;

			expect(retryCount).toBe(1);
			expect(persisted.status).toBe("completed");
			expect(persisted.summary).toBe("done under contention");
			expect(persisted.completionSourcePath).toBe(outboxFile);
			expect(persisted.completionArchivePath).toContain(join(runtimeRoot, "processed", "rust"));
			expect(existsSync(outboxFile)).toBe(false);
			expect(emitted.some((event) => event.name === "subagents:completed")).toBe(true);
		} finally {
			setFileLockOptionsForTests();
			rmSync(`${taskRegistryPath(runtimeRoot)}.lock`, { force: true, recursive: true });
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("pollPaneCompletions repairs archive path after post-archive registry lock timeout", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		let lockDir: string | undefined;
		try {
			await seedPaneTask(runtimeRoot, cwd, "task-archive-repair");
			const outboxFile = join(runtimeRoot, "outbox", "rust", "task-archive-repair.json");
			mkdirSync(dirname(outboxFile), { recursive: true });
			writeFileSync(outboxFile, JSON.stringify({
				agent: "rust",
				filesChanged: ["x.ts"],
				status: "completed",
				summary: "done with archive repair",
				taskId: "task-archive-repair",
				validation: ["ok"],
			}), "utf8");
			const emitted: Array<{ name: string; payload: any }> = [];
			setAfterCompletionArchiveForTests(({ runtimeRoot: hookRuntimeRoot }) => {
				lockDir = holdTaskRegistryLock(hookRuntimeRoot);
				forceFastRegistryLockTimeout();
				setAfterCompletionArchiveForTests();
			});

			const firstCount = await pollPaneCompletions(runtimeRoot, {
				events: { emit: (name: string, payload: any) => emitted.push({ name, payload }) },
				sendMessage: () => undefined,
			} as any);
			const firstPersisted = (await readTaskRegistry(runtimeRoot))["task-archive-repair"]!;

			expect(firstCount).toBe(1);
			expect(firstPersisted.status).toBe("completed");
			expect(firstPersisted.completionArchivePath).toBeUndefined();
			expect(firstPersisted.completionSourcePath).toBe(outboxFile);
			expect(existsSync(outboxFile)).toBe(true);
			expect(emitted.filter((event) => event.name === "subagents:completed")).toHaveLength(1);

			setFileLockOptionsForTests();
			if (lockDir) rmSync(lockDir, { force: true, recursive: true });
			const retryCount = await pollPaneCompletions(runtimeRoot, {
				events: { emit: (name: string, payload: any) => emitted.push({ name, payload }) },
				sendMessage: () => undefined,
			} as any);
			const repaired = (await readTaskRegistry(runtimeRoot))["task-archive-repair"]!;

			expect(retryCount).toBe(0);
			expect(repaired.status).toBe("completed");
			expect(repaired.completionArchivePath).toContain(join(runtimeRoot, "processed", "rust"));
			expect(existsSync(repaired.completionArchivePath!)).toBe(true);
			expect(existsSync(outboxFile)).toBe(false);
			expect(emitted.filter((event) => event.name === "subagents:completed")).toHaveLength(1);
		} finally {
			setAfterCompletionArchiveForTests();
			setFileLockOptionsForTests();
			if (lockDir) rmSync(lockDir, { force: true, recursive: true });
			rmSync(`${taskRegistryPath(runtimeRoot)}.lock`, { force: true, recursive: true });
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("pollPaneCompletions preserves existing archive path when duplicate poll archive persistence fails", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		let lockDir: string | undefined;
		try {
			const seeded = await seedPaneTask(runtimeRoot, cwd, "task-duplicate-archive");
			const outboxFile = join(runtimeRoot, "outbox", "rust", "task-duplicate-archive.json");
			const existingArchivePath = join(runtimeRoot, "processed", "rust", "task-duplicate-archive-existing.json");
			mkdirSync(dirname(outboxFile), { recursive: true });
			mkdirSync(dirname(existingArchivePath), { recursive: true });
			writeFileSync(existingArchivePath, JSON.stringify({
				agent: "rust",
				status: "completed",
				summary: "done by faster poller",
				taskId: "task-duplicate-archive",
			}), "utf8");
			writeFileSync(outboxFile, JSON.stringify({
				agent: "rust",
				filesChanged: ["x.ts"],
				status: "completed",
				summary: "done by slower duplicate poller",
				taskId: "task-duplicate-archive",
				validation: ["ok"],
			}), "utf8");
			const emitted: Array<{ name: string; payload: any }> = [];
			setBeforeCompletionRegistryUpdateForTests(async () => {
				await writeTaskRegistry(runtimeRoot, {
					"task-duplicate-archive": {
						...seeded,
						completedAt: "2026-05-20T00:00:02.000Z",
						completionArchivePath: existingArchivePath,
						completionSourcePath: outboxFile,
						status: "completed",
						summary: "done by faster poller",
						updatedAt: "2026-05-20T00:00:02.000Z",
					},
				});
				setBeforeCompletionRegistryUpdateForTests();
			});
			setAfterCompletionArchiveForTests(({ runtimeRoot: hookRuntimeRoot }) => {
				lockDir = holdTaskRegistryLock(hookRuntimeRoot);
				forceFastRegistryLockTimeout();
				setAfterCompletionArchiveForTests();
			});

			const count = await pollPaneCompletions(runtimeRoot, {
				events: { emit: (name: string, payload: any) => emitted.push({ name, payload }) },
				sendMessage: () => undefined,
			} as any);
			const persisted = (await readTaskRegistry(runtimeRoot))["task-duplicate-archive"]!;

			expect(count).toBe(1);
			expect(persisted.status).toBe("completed");
			expect(persisted.completionArchivePath).toBe(existingArchivePath);
			expect(persisted.completionSourcePath).toBe(outboxFile);
			expect(existsSync(existingArchivePath)).toBe(true);
			expect(existsSync(outboxFile)).toBe(true);
			expect(emitted.filter((event) => event.name === "subagents:completed")).toHaveLength(1);
		} finally {
			setAfterCompletionArchiveForTests();
			setBeforeCompletionRegistryUpdateForTests();
			setFileLockOptionsForTests();
			if (lockDir) rmSync(lockDir, { force: true, recursive: true });
			rmSync(`${taskRegistryPath(runtimeRoot)}.lock`, { force: true, recursive: true });
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("pollPaneCompletions snapshots malformed completion outbox", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		try {
			await seedPaneTask(runtimeRoot, cwd, "task-poll-malformed");
			const outboxFile = join(runtimeRoot, "outbox", "rust", "task-poll-malformed.json");
			mkdirSync(dirname(outboxFile), { recursive: true });
			writeFileSync(outboxFile, "{", "utf8");
			fs.utimesSync(outboxFile, new Date(0), new Date(0));
			const emitted: Array<{ name: string; payload: any }> = [];

			const count = await pollPaneCompletions(runtimeRoot, {
				events: { emit: (name: string, payload: any) => emitted.push({ name, payload }) },
				sendMessage: () => undefined,
			} as any);
			const persisted = await waitForTaskRecord(
				runtimeRoot,
				"task-poll-malformed",
				(record) => record?.cwdSnapshot?.cwd === cwd && record.diagnostics?.some((diagnostic) => diagnostic.includes("Malformed completion JSON")) === true,
			);
			const needsCompletion = emitted.find((event) => event.name === "subagents:needs_completion");

			expect(count).toBe(0);
			expect(persisted.status).toBe("needs_completion");
			expect(persisted.outboxFile).toBe(outboxFile);
			expect(persisted.cwdSnapshot?.lastCommit.subject).toBe("initial commit");
			expect(persisted.cwdSnapshot?.status).toContain("?? dirty.txt");
			expect(persisted.diagnostics?.join("\n")).toContain("Malformed completion JSON");
			expect(needsCompletion?.payload.summary).toContain("Malformed completion JSON");
		} finally {
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("markTaskNeedsCompletion tolerates malformed registry cwd", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		try {
			await writePaneRegistry(runtimeRoot, {
				rust: {
					agent: "rust",
					cwd: { bad: true } as unknown as string,
					launcherFile: join(runtimeRoot, "launcher.sh"),
					paneId: "%1",
					promptFile: join(runtimeRoot, "prompt.md"),
					sessionFile: join(runtimeRoot, "session.jsonl"),
					startedAt: "2026-05-20T00:00:00.000Z",
					windowName: "rust-agent",
				},
			});
			await writeTaskRegistry(runtimeRoot, {
				"task-bad-cwd": {
					agent: "rust",
					createdAt: "2026-05-20T00:00:00.000Z",
					kind: "pane",
					status: "running",
					task: "Do work",
					taskId: "task-bad-cwd",
				},
			});

			const updated = await markTaskNeedsCompletion(runtimeRoot, "rust", "task-bad-cwd", { diagnostic: "missing completion" });

			expect(updated?.status).toBe("needs_completion");
			expect(updated?.cwdSnapshot).toBeUndefined();
			expect(updated?.diagnostics).toContain("missing completion");
		} finally {
			rmSync(runtimeRoot, { force: true, recursive: true });
		}
	});

	test("recordTaskDispatchFailure snapshots cwd when requeue restore fails", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		try {
			const processing = join(runtimeRoot, "processing", "rust", "task-dispatch.md");
			const source = join(runtimeRoot, "missing-inbox-parent", "rust", "task-dispatch.md");
			mkdirSync(dirname(processing), { recursive: true });
			writeFileSync(processing, "Do work", "utf8");
			await seedPaneTask(runtimeRoot, cwd, "task-dispatch", {
				inboxFile: source,
				processingFile: processing,
			});

			const result = await recordTaskDispatchFailure(runtimeRoot, "task-dispatch", { processing, source }, "dispatch failed");
			const persisted = (await readTaskRegistry(runtimeRoot))["task-dispatch"]!;

			expect(result).toEqual({ restoredToInbox: false, status: "needs_completion" });
			expect(persisted.status).toBe("needs_completion");
			expect(persisted.processingFile).toBe(processing);
			expect(persisted.cwdSnapshot?.cwd).toBe(cwd);
			expect(persisted.cwdSnapshot?.lastCommit.subject).toBe("initial commit");
			expect(persisted.diagnostics).toContain("dispatch failed");
		} finally {
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("refreshTaskDiagnostics snapshots done-without-outbox", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		try {
			const doneFile = join(runtimeRoot, "done", "rust", "task-done.md");
			mkdirSync(dirname(doneFile), { recursive: true });
			writeFileSync(doneFile, "Do work", "utf8");
			const record = await seedPaneTask(runtimeRoot, cwd, "task-done", { doneFile });

			const refreshed = await refreshTaskDiagnostics(runtimeRoot, record);
			const persisted = (await readTaskRegistry(runtimeRoot))["task-done"]!;

			expect(refreshed.record.status).toBe("needs_completion");
			expect(refreshed.record.cwdSnapshot?.cwd).toBe(cwd);
			expect(refreshed.record.cwdSnapshot?.lastCommit.subject).toBe("initial commit");
			expect(refreshed.diagnostics.join("\n")).toContain("Expected outbox");
			expect(persisted.cwdSnapshot).toEqual(refreshed.record.cwdSnapshot);
		} finally {
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("refreshTaskDiagnostics snapshots malformed outbox", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		try {
			const outboxFile = join(runtimeRoot, "outbox", "rust", "task-malformed.json");
			mkdirSync(dirname(outboxFile), { recursive: true });
			writeFileSync(outboxFile, "{", "utf8");
			const record = await seedPaneTask(runtimeRoot, cwd, "task-malformed", { outboxFile });

			const refreshed = await refreshTaskDiagnostics(runtimeRoot, record);
			const persisted = (await readTaskRegistry(runtimeRoot))["task-malformed"]!;

			expect(refreshed.record.status).toBe("needs_completion");
			expect(refreshed.record.cwdSnapshot?.cwd).toBe(cwd);
			expect(refreshed.record.cwdSnapshot?.status).toContain("?? dirty.txt");
			expect(refreshed.record.diagnostics?.join("\n")).toContain("Malformed completion JSON");
			expect(persisted.cwdSnapshot).toEqual(refreshed.record.cwdSnapshot);
		} finally {
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("refreshTaskDiagnostics returns fallback diagnostics when registry update lock times out", async () => {
		const runtimeRoot = tempDir("needs-completion-runtime-");
		const cwd = tempGitRepo();
		try {
			const doneFile = join(runtimeRoot, "done", "rust", "task-refresh-lock.md");
			mkdirSync(dirname(doneFile), { recursive: true });
			writeFileSync(doneFile, "done", "utf8");
			const record = await seedPaneTask(runtimeRoot, cwd, "task-refresh-lock", { doneFile });
			holdTaskRegistryLock(runtimeRoot);
			forceFastRegistryLockTimeout();

			const refreshed = await refreshTaskDiagnostics(runtimeRoot, record);
			const persisted = (await readTaskRegistry(runtimeRoot))["task-refresh-lock"]!;

			expect(refreshed.record.status).toBe("needs_completion");
			expect(refreshed.diagnostics.join("\n")).toContain("Task registry refresh skipped");
			expect(refreshed.diagnostics.join("\n")).toContain("Expected outbox");
			expect(persisted.status).toBe("running");
		} finally {
			setFileLockOptionsForTests();
			rmSync(`${taskRegistryPath(runtimeRoot)}.lock`, { force: true, recursive: true });
			rmSync(runtimeRoot, { force: true, recursive: true });
			rmSync(cwd, { force: true, recursive: true });
		}
	});
});
