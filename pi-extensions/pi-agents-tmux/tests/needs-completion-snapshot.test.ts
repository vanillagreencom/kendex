// Every path into needs_completion attaches a snapshot of the pane's cwd
// (HEAD, last commit, dirty status) and its own diagnostic, and the git the
// snapshot runs is read-only and hook-free.

import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { chmodSync, existsSync, mkdirSync, utimesSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test, { after } from "node:test";
import { setGitExecFileForTests } from "../extensions/subagent/cwd-snapshot.js";
import { formatTaskRecordResult } from "../extensions/subagent/renderers.js";
import { markTaskNeedsCompletion, pollPaneCompletions, readTaskRegistry, recordTaskDispatchFailure, refreshTaskDiagnostics } from "../extensions/subagent/tasks.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";
import { ABSENT, cleanupNeedsCompletionWorlds, type Emitted, eventNames, fakePi, git, seedPaneTask, tempGitRepo, tempRuntimeRoot, waitForTaskRecord, writeOutbox } from "./needs-completion-fixture.js";

after(cleanupNeedsCompletionWorlds);

const DIAGNOSTIC = "Task turn ended without complete_subagent.";

// The snapshot as one line: the repo it names (`repo` when it is the pane's), the
// dirty flag, HEAD read as `sha` when it is a 40-hex id, the commit subject and
// the status lines.
function snapshot(record: PaneTaskRecord | undefined, repo: string): string {
	const s = record?.cwdSnapshot;
	if (!s) return ABSENT;
	return `cwd=${s.cwd === repo ? "repo" : s.cwd} dirty=${s.dirty} head=${/^[0-9a-f]{40}$/.test(s.head) ? "sha" : s.head} commit=${JSON.stringify(s.lastCommit.subject)} status=${JSON.stringify(s.status)}`;
}

const hasSnapshot = (record: PaneTaskRecord | undefined) => Boolean(record?.cwdSnapshot);
const diag = (record: PaneTaskRecord | undefined, needle: string) => `diag(${needle})=${record?.diagnostics?.some((d) => d.includes(needle)) ?? false}`;

type Entry = (runtimeRoot: string, repo: string) => Promise<{ own: string; persisted: PaneTaskRecord | undefined }>;

const DIRTY = 'cwd=repo dirty=true head=sha commit="initial commit" status="?? dirty.txt"';

// label | entry into needs_completion | expect the entry's own outcome | expect the persisted snapshot
const rows: Array<[string, Entry, string, string]> = [
	["markTaskNeedsCompletion snapshots the pane registry cwd", async (root, repo) => {
		await seedPaneTask(root, repo, "task-1");
		const updated = await markTaskNeedsCompletion(root, "rust", "task-1", { diagnostic: DIAGNOSTIC });
		const persisted = await waitForTaskRecord(root, "task-1", hasSnapshot);
		return { own: `returned=${updated?.status} ${diag(persisted, DIAGNOSTIC)}`, persisted };
	}, "returned=needs_completion diag(Task turn ended without complete_subagent.)=true", DIRTY],
	["a parsed needs_completion outbox: the event carries the reason, a second event the snapshot", async (root, repo) => {
		await seedPaneTask(root, repo, "task-polled");
		writeOutbox(root, "task-polled", { agent: "rust", reason: "turn-ended-without-complete-subagent", status: "needs_completion", summary: "synthetic missing completion", taskId: "task-polled" });
		const emitted: Emitted = [];
		const count = await pollPaneCompletions(root, fakePi(emitted));
		const persisted = (await readTaskRegistry(root))["task-polled"];
		const events = emitted.map((event) => `${event.name.replace(/^subagents:/, "")}(${event.payload.reason ?? "-"},${event.payload.cwdSnapshot ? (event.payload.cwdSnapshot.cwd === repo ? "snapshot" : "wrong-snapshot") : "-"})`).join(",");
		return { own: `count=${count} status=${persisted?.status} events=${events}`, persisted };
	}, "count=1 status=needs_completion events=needs_completion(turn-ended-without-complete-subagent,-),needs_completion(turn-ended-without-complete-subagent,snapshot)", DIRTY],
	["a malformed outbox past the grace period", async (root, repo) => {
		await seedPaneTask(root, repo, "task-poll-malformed");
		const outboxFile = writeOutbox(root, "task-poll-malformed", "{");
		utimesSync(outboxFile, new Date(0), new Date(0));
		const emitted: Emitted = [];
		const count = await pollPaneCompletions(root, fakePi(emitted));
		const persisted = await waitForTaskRecord(root, "task-poll-malformed", (record) => hasSnapshot(record) && record?.diagnostics?.some((d) => d.includes("Malformed completion JSON")) === true);
		const summary = emitted.find((event) => event.name === "subagents:needs_completion")?.payload.summary ?? "";
		return { own: `count=${count} status=${persisted.status} outbox=${persisted.outboxFile === outboxFile} ${diag(persisted, "Malformed completion JSON")} event-summary~Malformed=${summary.includes("Malformed completion JSON")}`, persisted };
	}, "count=0 status=needs_completion outbox=true diag(Malformed completion JSON)=true event-summary~Malformed=true", DIRTY],
	["a malformed outbox inside the grace period is left alone", async (root, repo) => {
		await seedPaneTask(root, repo, "task-poll-fresh");
		const outboxFile = writeOutbox(root, "task-poll-fresh", "{");
		const emitted: Emitted = [];
		// The poller reads the mtime against its own wall clock; an mtime a minute
		// ahead keeps the file inside the 1.5 s grace however long the worker pauses.
		const ahead = new Date(Date.now() + 60_000);
		utimesSync(outboxFile, ahead, ahead);
		const count = await pollPaneCompletions(root, fakePi(emitted));
		const persisted = (await readTaskRegistry(root))["task-poll-fresh"];
		return { own: `count=${count} status=${persisted?.status} outbox=${existsSync(outboxFile) ? "present" : "gone"} events=${eventNames(emitted)}`, persisted };
	}, "count=0 status=running outbox=present events=none", ABSENT],
	["a dispatch failure whose requeue restore fails", async (root, repo) => {
		const processing = join(root, "processing", "rust", "task-dispatch.md");
		const source = join(root, "missing-inbox-parent", "rust", "task-dispatch.md");
		mkdirSync(dirname(processing), { recursive: true });
		writeFileSync(processing, "Do work", "utf8");
		await seedPaneTask(root, repo, "task-dispatch", { inboxFile: source, processingFile: processing });
		const result = await recordTaskDispatchFailure(root, "task-dispatch", { processing, source }, "dispatch failed");
		const persisted = (await readTaskRegistry(root))["task-dispatch"];
		return { own: `result=${JSON.stringify(result)} status=${persisted?.status} processing=${persisted?.processingFile === processing} ${diag(persisted, "dispatch failed")}`, persisted };
	}, 'result={"restoredToInbox":false,"status":"needs_completion"} status=needs_completion processing=true diag(dispatch failed)=true', DIRTY],
	["a dispatch failure whose requeue restore succeeds is queued, not snapshotted", async (root, repo) => {
		const processing = join(root, "processing", "rust", "task-requeue.md");
		const source = join(root, "inbox", "rust", "task-requeue.md");
		mkdirSync(dirname(processing), { recursive: true });
		mkdirSync(dirname(source), { recursive: true });
		writeFileSync(processing, "Do work", "utf8");
		await seedPaneTask(root, repo, "task-requeue", { inboxFile: source, processingFile: processing });
		const result = await recordTaskDispatchFailure(root, "task-requeue", { processing, source }, "dispatch failed");
		const persisted = (await readTaskRegistry(root))["task-requeue"];
		return { own: `result=${JSON.stringify(result)} status=${persisted?.status} processing=${persisted?.processingFile ?? ABSENT} inbox=${existsSync(source)} ${diag(persisted, "dispatch failed")}`, persisted };
	}, 'result={"restoredToInbox":true,"status":"queued"} status=queued processing=ABSENT inbox=true diag(dispatch failed)=true', ABSENT],
	["refreshTaskDiagnostics on a done file without an outbox", async (root, repo) => {
		const doneFile = join(root, "done", "rust", "task-done.md");
		mkdirSync(dirname(doneFile), { recursive: true });
		writeFileSync(doneFile, "Do work", "utf8");
		const seeded = await seedPaneTask(root, repo, "task-done", { doneFile });
		const refreshed = await refreshTaskDiagnostics(root, seeded);
		const persisted = (await readTaskRegistry(root))["task-done"];
		return { own: `status=${refreshed.record.status} ${diag(refreshed.record, "Task fully settled but no completion record")} returned-snapshot=${snapshot(refreshed.record, repo) === snapshot(persisted, repo) ? "persisted" : "differs"}`, persisted };
	}, "status=needs_completion diag(Task fully settled but no completion record)=true returned-snapshot=persisted", DIRTY],
	["refreshTaskDiagnostics on a malformed outbox", async (root, repo) => {
		const seeded = await seedPaneTask(root, repo, "task-malformed");
		writeOutbox(root, "task-malformed", "{");
		const refreshed = await refreshTaskDiagnostics(root, seeded);
		const persisted = (await readTaskRegistry(root))["task-malformed"];
		return { own: `status=${refreshed.record.status} ${diag(refreshed.record, "Malformed completion JSON")} returned-snapshot=${snapshot(refreshed.record, repo) === snapshot(persisted, repo) ? "persisted" : "differs"}`, persisted };
	}, "status=needs_completion diag(Malformed completion JSON)=true returned-snapshot=persisted", DIRTY],
	["a clean repo snapshots as clean", async (root, repo) => {
		git(repo, "add", "dirty.txt");
		git(repo, "commit", "--no-gpg-sign", "-m", "keep dirty.txt");
		await seedPaneTask(root, repo, "task-clean");
		const updated = await markTaskNeedsCompletion(root, "rust", "task-clean", { diagnostic: DIAGNOSTIC });
		const persisted = await waitForTaskRecord(root, "task-clean", hasSnapshot);
		return { own: `returned=${updated?.status}`, persisted };
	}, "returned=needs_completion", 'cwd=repo dirty=false head=sha commit="keep dirty.txt" status=""'],
	// The two rows below expect no snapshot write, so they cannot wait on one; the
	// pause is a quiescence wait for the fire-and-forget patch, not the assertion
	// (the patch's own status guard is what keeps the record untouched).
	["a malformed registry cwd yields no snapshot and keeps the diagnostic", async (root) => {
		await seedPaneTask(root, { bad: true }, "task-bad-cwd");
		const updated = await markTaskNeedsCompletion(root, "rust", "task-bad-cwd", { diagnostic: "missing completion" });
		await new Promise((resolve) => setTimeout(resolve, 50));
		const persisted = (await readTaskRegistry(root))["task-bad-cwd"];
		return { own: `returned=${updated?.status} returned-snapshot=${snapshot(updated, "")} ${diag(updated, "missing completion")}`, persisted };
	}, "returned=needs_completion returned-snapshot=ABSENT diag(missing completion)=true", ABSENT],
	["a terminal record is never marked", async (root, repo) => {
		await seedPaneTask(root, repo, "task-terminal", { status: "completed", completedAt: "2026-05-20T00:00:02.000Z" });
		const updated = await markTaskNeedsCompletion(root, "rust", "task-terminal", { diagnostic: "late" });
		await new Promise((resolve) => setTimeout(resolve, 50));
		const persisted = (await readTaskRegistry(root))["task-terminal"];
		return { own: `returned=${updated?.status} ${diag(persisted, "late")}`, persisted };
	}, "returned=completed diag(late)=false", ABSENT],
];

test("entering needs_completion", async () => {
	for (const [label, entry, expectOwn, expectSnapshot] of rows) {
		const root = tempRuntimeRoot();
		const repo = tempGitRepo();
		const { own, persisted } = await entry(root, repo);
		assert.equal(`${own} | ${snapshot(persisted, repo)}`, `${expectOwn} | ${expectSnapshot}`, label);
	}
});

test("markTaskNeedsCompletion returns before the snapshot patch completes", async () => {
	const root = tempRuntimeRoot();
	const repo = tempGitRepo();
	await seedPaneTask(root, repo, "task-slow");
	// A git that never answers: the patch can only complete if mark waited for it.
	setGitExecFileForTests((() => new EventEmitter() as any) as any);
	try {
		const result = await markTaskNeedsCompletion(root, "rust", "task-slow", { cwd: repo, diagnostic: "missing completion" });
		const persisted = (await readTaskRegistry(root))["task-slow"];
		assert.equal(`returned=${result?.status} returned-snapshot=${snapshot(result, repo)} persisted=${persisted?.status} ${diag(persisted, "missing completion")}`, "returned=needs_completion returned-snapshot=ABSENT persisted=needs_completion diag(missing completion)=true");
	} finally {
		setGitExecFileForTests();
	}
});

// A trap script that logs its invocation; the row reads whether git ran it.
function trap(cwd: string, name: string, body: string): { script: string; sentinel: string } {
	const sentinel = join(cwd, `${name}-invoked.log`);
	const script = join(cwd, `${name}.sh`);
	writeFileSync(script, `#!/bin/sh\necho invoked >> ${JSON.stringify(sentinel)}\n${body}\n`, "utf8");
	chmodSync(script, 0o755);
	return { script, sentinel };
}

// The clean filter only runs when git hashes the working file, and git skips a
// file whose size differs from the index; the edit keeps HEAD's length.
function editKeepingLength(cwd: string): void {
	writeFileSync(join(cwd, "tracked.txt"), "initiaL\n", "utf8");
}

function fakeSignedHead(cwd: string): void {
	const tree = git(cwd, "write-tree");
	const branch = git(cwd, "symbolic-ref", "--short", "HEAD");
	const body = [`tree ${tree}`, "author Pi Test <pi-test@example.invalid> 1700000000 +0000", "committer Pi Test <pi-test@example.invalid> 1700000000 +0000", "gpgsig -----BEGIN PGP SIGNATURE-----", " ", " fake", " -----END PGP SIGNATURE-----", "", "fake signed commit", ""].join("\n");
	writeFileSync(join(cwd, "fake-signed-commit.txt"), body, "utf8");
	const commit = git(cwd, "hash-object", "-t", "commit", "-w", "fake-signed-commit.txt");
	git(cwd, "update-ref", `refs/heads/${branch}`, commit);
}

// label | arm the repo, return the sentinel | expect `invoked=<bool> commit=<subject> status~tracked=<bool>`
const gitRows: Array<[string, (cwd: string) => string, string]> = [
	["core.fsmonitor is not run", (cwd) => {
		const { script, sentinel } = trap(cwd, "fsmonitor", "exit 0");
		git(cwd, "config", "core.fsmonitor", script);
		return sentinel;
	}, 'invoked=false commit="initial commit" status~tracked=false'],
	["log.showSignature's gpg program is not run", (cwd) => {
		fakeSignedHead(cwd);
		const { script, sentinel } = trap(cwd, "gpg", "exit 1");
		git(cwd, "config", "log.showSignature", "true");
		git(cwd, "config", "gpg.program", script);
		return sentinel;
	}, 'invoked=false commit="fake signed commit" status~tracked=false'],
	// Accepted: a clean driver lives in .git/config, which clone never copies, so a
	// hostile repo cannot ship one; the only shipped producer is the user's own git-lfs.
	["the repo's own clean filter does run while collecting dirty state", (cwd) => {
		writeFileSync(join(cwd, ".gitattributes"), "tracked.txt filter=trap\n", "utf8");
		git(cwd, "add", ".gitattributes");
		git(cwd, "commit", "--no-gpg-sign", "-m", "add attrs");
		const { script, sentinel } = trap(cwd, "clean-filter", "cat");
		git(cwd, "config", "filter.trap.clean", script);
		editKeepingLength(cwd);
		return sentinel;
	}, 'invoked=true commit="add attrs" status~tracked=true'],
];

test("the snapshot's git runs no local hook it is not meant to", async () => {
	for (const [index, [label, arm, expect]] of gitRows.entries()) {
		const root = tempRuntimeRoot();
		const repo = tempGitRepo();
		const sentinel = arm(repo);
		const taskId = `task-git-${index}`;
		await seedPaneTask(root, repo, taskId);
		await markTaskNeedsCompletion(root, "rust", taskId, { diagnostic: DIAGNOSTIC });
		const persisted = await waitForTaskRecord(root, taskId, hasSnapshot);
		assert.equal(`invoked=${existsSync(sentinel)} commit=${JSON.stringify(persisted.cwdSnapshot!.lastCommit.subject)} status~tracked=${persisted.cwdSnapshot!.status.includes(" M tracked.txt")}`, expect, label);
	}
});

test("the result text carries the snapshot section", async () => {
	const root = tempRuntimeRoot();
	const repo = tempGitRepo();
	await seedPaneTask(root, repo, "task-render");
	await markTaskNeedsCompletion(root, "rust", "task-render", { diagnostic: DIAGNOSTIC });
	const persisted = await waitForTaskRecord(root, "task-render", hasSnapshot);
	const section = formatTaskRecordResult(persisted).split("### CWD Snapshot\n")[1]?.split("\n").slice(0, 3).map((line) => line.replace(/^HEAD: [0-9a-f]{12}/, "HEAD: <sha12>").replace(repo, "<repo>"));
	assert.deepEqual(section, ["CWD: <repo>", "HEAD: <sha12> (dirty)", "Last commit: initial commit"]);
});
