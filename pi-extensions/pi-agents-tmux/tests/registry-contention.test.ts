// What a poll does when the task registry is contended or another poller got
// there first: the outbox stays retryable until the record is durable, an
// archive path is repaired on the next pass, a duplicate never re-emits, and
// a refresh under a held lock answers from memory.

import assert from "node:assert/strict";
import { mkdirSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test, { after } from "node:test";
import { setFileLockOptionsForTests } from "../extensions/subagent/file-lock.js";
import { taskRegistryPath } from "../extensions/subagent/paths.js";
import { pollPaneCompletions, readTaskRegistry, refreshTaskDiagnostics, setAfterCompletionArchiveForTests, setBeforeCompletionRegistryUpdateForTests, writeTaskRegistry } from "../extensions/subagent/tasks.js";
import { cleanupNeedsCompletionWorlds, completionState, type Emitted, eventNames, fakePi, holdTaskRegistryLock, outboxPath, seedPaneTask, tempGitRepo, tempRuntimeRoot, writeOutbox } from "./needs-completion-fixture.js";

after(cleanupNeedsCompletionWorlds);

function forceFastRegistryLockTimeout(): void {
	setFileLockOptionsForTests({ retryMs: 1, staleMs: Number.POSITIVE_INFINITY, timeoutMs: 5 });
}

function releaseLock(root: string): void {
	setFileLockOptionsForTests();
	rmSync(`${taskRegistryPath(root)}.lock`, { force: true, recursive: true });
}

const completed = (taskId: string, summary: string) => ({ agent: "rust", filesChanged: ["x.ts"], status: "completed", summary, taskId, validation: ["ok"] });

// One poll, read back as `count=N <completion state> events=<names>`.
async function poll(root: string, taskId: string): Promise<string> {
	const emitted: Emitted = [];
	const count = await pollPaneCompletions(root, fakePi(emitted));
	return `count=${count} ${completionState(root, (await readTaskRegistry(root))[taskId], outboxPath(root, taskId))} events=${eventNames(emitted)}`;
}

type Scenario = { taskId: string; arm: (root: string, repo: string) => Promise<void>; first: string; retry?: string };

// label | scenario: the world, the first poll's outcome, and the retry poll's outcome after the lock is released
const rows: Array<[string, Scenario]> = [
	["a terminal registry write that times out leaves the outbox retryable, then lands whole", {
		taskId: "task-lock-completed",
		arm: async (root, repo) => {
			await seedPaneTask(root, repo, "task-lock-completed");
			// Older than the malformed-outbox grace period, so a lock error that fell
			// through to the malformed path would mark the task instead of retrying.
			utimesSync(writeOutbox(root, "task-lock-completed", completed("task-lock-completed", "done under contention")), new Date(0), new Date(0));
			holdTaskRegistryLock(root);
			forceFastRegistryLockTimeout();
		},
		first: 'count=0 status=running summary="ABSENT" source=ABSENT archive=ABSENT outbox=present events=none',
		retry: 'count=1 status=completed summary="done under contention" source=outbox/rust/task-lock-completed.json archive=processed/rust/<archive>-task-lock-completed.json present outbox=gone events=completed',
	}],
	["a lock timeout after archiving keeps the outbox and repairs the archive path on the next pass without a second event", {
		taskId: "task-archive-repair",
		arm: async (root, repo) => {
			await seedPaneTask(root, repo, "task-archive-repair");
			writeOutbox(root, "task-archive-repair", completed("task-archive-repair", "done with archive repair"));
			setAfterCompletionArchiveForTests(({ runtimeRoot }) => {
				holdTaskRegistryLock(runtimeRoot);
				forceFastRegistryLockTimeout();
				setAfterCompletionArchiveForTests();
			});
		},
		first: 'count=1 status=completed summary="done with archive repair" source=outbox/rust/task-archive-repair.json archive=ABSENT outbox=present events=completed',
		retry: 'count=0 status=completed summary="done with archive repair" source=outbox/rust/task-archive-repair.json archive=processed/rust/<archive>-task-archive-repair.json present outbox=gone events=none',
	}],
	["a faster poller's archive path survives the slower duplicate", {
		taskId: "task-duplicate-archive",
		arm: async (root, repo) => {
			const seeded = await seedPaneTask(root, repo, "task-duplicate-archive");
			const outboxFile = writeOutbox(root, "task-duplicate-archive", completed("task-duplicate-archive", "done by slower duplicate poller"));
			const existingArchivePath = join(root, "processed", "rust", "task-duplicate-archive-existing.json");
			mkdirSync(dirname(existingArchivePath), { recursive: true });
			writeFileSync(existingArchivePath, JSON.stringify({ agent: "rust", status: "completed", summary: "done by faster poller", taskId: "task-duplicate-archive" }), "utf8");
			setBeforeCompletionRegistryUpdateForTests(async () => {
				await writeTaskRegistry(root, { "task-duplicate-archive": { ...seeded, completedAt: "2026-05-20T00:00:02.000Z", completionArchivePath: existingArchivePath, completionSourcePath: outboxFile, status: "completed", summary: "done by faster poller", updatedAt: "2026-05-20T00:00:02.000Z" } });
				rmSync(outboxFile, { force: true });
				setBeforeCompletionRegistryUpdateForTests();
			});
		},
		first: 'count=0 status=completed summary="done by faster poller" source=outbox/rust/task-duplicate-archive.json archive=processed/rust/task-duplicate-archive-existing.json present outbox=gone events=none',
	}],
	["a terminal completion landing after needs_completion was persisted still completes", {
		taskId: "task-late-terminal",
		arm: async (root, repo) => {
			const seeded = await seedPaneTask(root, repo, "task-late-terminal");
			const outboxFile = writeOutbox(root, "task-late-terminal", completed("task-late-terminal", "late terminal completion"));
			setBeforeCompletionRegistryUpdateForTests(async () => {
				await writeTaskRegistry(root, { "task-late-terminal": { ...seeded, completedAt: "2026-05-20T00:00:02.000Z", completionSourcePath: outboxFile, status: "needs_completion", summary: "needs completion before late terminal", updatedAt: "2026-05-20T00:00:02.000Z" } });
				setBeforeCompletionRegistryUpdateForTests();
			});
		},
		first: 'count=1 status=completed summary="late terminal completion" source=outbox/rust/task-late-terminal.json archive=processed/rust/<archive>-task-late-terminal.json present outbox=gone events=completed',
	}],
	["an unknown-status outbox after needs_completion was persisted is archived without touching the record", {
		taskId: "task-late-unknown",
		arm: async (root, repo) => {
			await seedPaneTask(root, repo, "task-late-unknown", {
				completedAt: "2026-05-20T00:00:02.000Z",
				completionSourcePath: outboxPath(root, "task-late-unknown-watchdog"),
				status: "needs_completion",
				summary: "needs completion before late malformed fallback",
				updatedAt: "2026-05-20T00:00:02.000Z",
			});
			writeOutbox(root, "task-late-unknown", { ...completed("task-late-unknown", "late malformed fallback"), status: "done-ish" });
		},
		first: 'count=0 status=needs_completion summary="needs completion before late malformed fallback" source=outbox/rust/task-late-unknown-watchdog.json archive=processed/rust/<archive>-task-late-unknown.json present outbox=gone events=none',
	}],
];

test("polling under registry contention", async () => {
	for (const [label, scenario] of rows) {
		const root = tempRuntimeRoot();
		const repo = tempGitRepo();
		try {
			await scenario.arm(root, repo);
			assert.equal(await poll(root, scenario.taskId), scenario.first, `${label}: first pass`);
			if (scenario.retry) {
				releaseLock(root);
				assert.equal(await poll(root, scenario.taskId), scenario.retry, `${label}: retry`);
			}
		} finally {
			setAfterCompletionArchiveForTests();
			setBeforeCompletionRegistryUpdateForTests();
			releaseLock(root);
		}
	}
});

test("a refresh under a held registry lock answers from memory and persists nothing", async () => {
	const root = tempRuntimeRoot();
	const repo = tempGitRepo();
	try {
		const doneFile = join(root, "done", "rust", "task-refresh-lock.md");
		mkdirSync(dirname(doneFile), { recursive: true });
		writeFileSync(doneFile, "done", "utf8");
		const seeded = await seedPaneTask(root, repo, "task-refresh-lock", { doneFile });
		holdTaskRegistryLock(root);
		forceFastRegistryLockTimeout();

		const refreshed = await refreshTaskDiagnostics(root, seeded);
		const persisted = (await readTaskRegistry(root))["task-refresh-lock"];
		const has = (needle: string) => refreshed.diagnostics.some((d) => d.includes(needle));
		assert.equal(
			`returned=${refreshed.record.status} skipped=${has("Task registry refresh skipped")} expected-outbox=${has(`Expected outbox: ${outboxPath(root, "task-refresh-lock")} (missing)`)} persisted=${persisted?.status}`,
			"returned=needs_completion skipped=true expected-outbox=true persisted=running",
		);
	} finally {
		releaseLock(root);
	}
});
