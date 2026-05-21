import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import * as fs from "node:fs";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, expect, test } from "bun:test";
import { formatTaskRecordResult } from "../extensions/subagent/renderers.js";
import { setGitExecFileForTests, snapshotCwdGitState } from "../extensions/subagent/cwd-snapshot.js";
import {
	markTaskNeedsCompletion,
	pollPaneCompletions,
	readTaskRegistry,
	recordTaskDispatchFailure,
	refreshTaskDiagnostics,
	writePaneRegistry,
	writeTaskRegistry,
} from "../extensions/subagent/tasks.js";
import type { PaneTaskRecord } from "../extensions/subagent/types.js";

function tempDir(prefix: string): string {
	return mkdtempSync(join(tmpdir(), prefix));
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

function indexDebugEntry(filePath: string, index = 1, size = 1): string {
	return [
		`${filePath}\0`,
		"  ctime: 1:0\n",
		"  mtime: 1:0\n",
		`  dev: 1\tino: ${index}\n`,
		"  uid: 1\tgid: 1\n",
		`  size: ${size}\tflags: 0\n`,
	].join("");
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

	test("snapshot dirty scan reports incomplete when tracked-file cap is hit", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		const originalNow = Date.now;
		const originalLstat = fs.promises.lstat;
		let lstatCalls = 0;
		const longName = "x".repeat(160);
		const debugEntries = Array.from({ length: 2_005 }, (_, index) => [
			`file-${longName}-${index}.txt\0`,
			"  ctime: 1:0\n",
			"  mtime: 1:0\n",
			`  dev: 1\tino: ${index}\n`,
			"  uid: 1\tgid: 1\n",
			"  size: 1\tflags: 0\n",
		].join("")).join("");
		setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
			void command;
			const cb = typeof options === "function" ? options : callback;
			const joined = args.join(" ");
			const stdout = joined.includes("rev-parse --is-inside-work-tree")
				? "true"
				: joined.includes("rev-parse HEAD")
					? "a".repeat(40)
					: joined.includes("log -1")
						? "initial commit"
						: joined.includes("ls-files --debug")
							? debugEntries
							: "";
			const maxBuffer = Number(options?.maxBuffer ?? 0);
			const error = maxBuffer > 0 && Buffer.byteLength(stdout) > maxBuffer ? new Error("stdout maxBuffer length exceeded") : null;
			queueMicrotask(() => cb(error, stdout, ""));
			return new EventEmitter() as any;
		}) as any);
		Date.now = (() => 0) as typeof Date.now;
		(fs.promises as any).lstat = async () => {
			lstatCalls += 1;
			return { ctimeNs: 1_000_000_000n, mtimeNs: 1_000_000_000n, size: 1n };
		};
		try {
			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(Buffer.byteLength(debugEntries)).toBeGreaterThan(256 * 1024);
			expect(snapshot?.head).toBe("a".repeat(40));
			expect(lstatCalls).toBe(2_000);
			expect(diagnostics).toContain("cwdSnapshot dirty scan incomplete: checked 2000 tracked paths; 5 skipped by file cap");
			expect(diagnostics.join("\n")).not.toContain("unable to lstat tracked path");
		} finally {
			Date.now = originalNow;
			(fs.promises as any).lstat = originalLstat;
			setGitExecFileForTests();
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("snapshot dirty scan reports malformed index debug output", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
			void command;
			const cb = typeof options === "function" ? options : callback;
			const joined = args.join(" ");
			const stdout = joined.includes("rev-parse --is-inside-work-tree")
				? "true"
				: joined.includes("rev-parse HEAD")
					? "a".repeat(40)
					: joined.includes("log -1")
						? "initial commit"
						: joined.includes("ls-files --debug")
							? "broken.txt\0  ctime: not-a-number\n"
							: "";
			queueMicrotask(() => cb(null, stdout, ""));
			return new EventEmitter() as any;
		}) as any);
		try {
			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(snapshot?.head).toBe("a".repeat(40));
			expect(diagnostics.join("\n")).toContain("unable to parse git ls-files --debug metadata for broken.txt");
		} finally {
			setGitExecFileForTests();
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("snapshot dirty scan reports tracked path lstat failures", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		const debugEntries = [
			"missing.txt\0",
			"  ctime: 1:0\n",
			"  mtime: 1:0\n",
			"  dev: 1\tino: 1\n",
			"  uid: 1\tgid: 1\n",
			"  size: 1\tflags: 0\n",
		].join("");
		setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
			void command;
			const cb = typeof options === "function" ? options : callback;
			const joined = args.join(" ");
			const stdout = joined.includes("rev-parse --is-inside-work-tree")
				? "true"
				: joined.includes("rev-parse HEAD")
					? "a".repeat(40)
					: joined.includes("log -1")
						? "initial commit"
						: joined.includes("ls-files --debug")
							? debugEntries
							: "";
			queueMicrotask(() => cb(null, stdout, ""));
			return new EventEmitter() as any;
		}) as any);
		try {
			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(snapshot?.head).toBe("a".repeat(40));
			expect(diagnostics.join("\n")).toContain("unable to lstat tracked path missing.txt");
		} finally {
			setGitExecFileForTests();
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("snapshot dirty scan lstat checks tracked symlinks without following missing targets", async () => {
		if (process.platform === "win32") return;
		const cwd = tempDir("needs-completion-cwd-");
		const externalDir = tempDir("needs-completion-external-");
		const target = join(externalDir, "target.txt");
		try {
			execFileSync("git", ["init"], { cwd, stdio: "ignore" });
			writeFileSync(target, "outside\n", "utf8");
			fs.symlinkSync(target, join(cwd, "tracked-link"));
			execFileSync("git", ["add", "tracked-link"], { cwd, stdio: "ignore" });
			execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", "commit", "--no-gpg-sign", "-m", "add symlink"], { cwd, stdio: "ignore" });
			rmSync(target, { force: true });

			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(diagnostics).toEqual([]);
			expect(snapshot?.dirty).toBe(false);
			expect(snapshot?.status).not.toContain("tracked-link");
		} finally {
			rmSync(cwd, { force: true, recursive: true });
			rmSync(externalDir, { force: true, recursive: true });
		}
	});

	test("snapshot dirty scan lstat checks tracked symlinks without following existing targets", async () => {
		if (process.platform === "win32") return;
		const cwd = tempDir("needs-completion-cwd-");
		const externalDir = tempDir("needs-completion-external-");
		const target = join(externalDir, "target.txt");
		try {
			execFileSync("git", ["init"], { cwd, stdio: "ignore" });
			writeFileSync(target, "outside\n", "utf8");
			fs.symlinkSync(target, join(cwd, "tracked-link"));
			execFileSync("git", ["add", "tracked-link"], { cwd, stdio: "ignore" });
			execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", "commit", "--no-gpg-sign", "-m", "add symlink"], { cwd, stdio: "ignore" });
			writeFileSync(target, "outside changed and longer\n", "utf8");

			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(diagnostics).toEqual([]);
			expect(snapshot?.dirty).toBe(false);
			expect(snapshot?.status).not.toContain("tracked-link");
		} finally {
			rmSync(cwd, { force: true, recursive: true });
			rmSync(externalDir, { force: true, recursive: true });
		}
	});

	test("snapshot dirty scan skips tracked paths under symlinked parents before final lstat", async () => {
		if (process.platform === "win32") return;
		const cwd = tempDir("needs-completion-cwd-");
		const externalDir = tempDir("needs-completion-external-");
		const originalLstat = fs.promises.lstat;
		const lstatPaths: string[] = [];
		const debugEntries = [
			"linkdir/target.txt\0",
			"  ctime: 1:0\n",
			"  mtime: 1:0\n",
			"  dev: 1\tino: 1\n",
			"  uid: 1\tgid: 1\n",
			"  size: 1\tflags: 0\n",
		].join("");
		setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
			void command;
			const cb = typeof options === "function" ? options : callback;
			const joined = args.join(" ");
			const stdout = joined.includes("rev-parse --is-inside-work-tree")
				? "true"
				: joined.includes("rev-parse HEAD")
					? "a".repeat(40)
					: joined.includes("log -1")
						? "initial commit"
						: joined.includes("ls-files --debug")
							? debugEntries
							: "";
			queueMicrotask(() => cb(null, stdout, ""));
			return new EventEmitter() as any;
		}) as any);
		(fs.promises as any).lstat = async (targetPath: fs.PathLike, options?: any) => {
			lstatPaths.push(String(targetPath));
			return originalLstat.call(fs.promises, targetPath, options);
		};
		try {
			writeFileSync(join(externalDir, "target.txt"), "outside changed and longer\n", "utf8");
			fs.symlinkSync(externalDir, join(cwd, "linkdir"));

			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(snapshot?.head).toBe("a".repeat(40));
			expect(snapshot?.dirty).toBe(false);
			expect(snapshot?.status).not.toContain("linkdir/target.txt");
			expect(diagnostics.join("\n")).toContain("tracked path linkdir/target.txt is under symlinked parent linkdir; skipping lstat probe");
			expect(lstatPaths).toContain(join(cwd, "linkdir"));
			expect(lstatPaths).not.toContain(join(cwd, "linkdir", "target.txt"));
		} finally {
			(fs.promises as any).lstat = originalLstat;
			setGitExecFileForTests();
			rmSync(cwd, { force: true, recursive: true });
			rmSync(externalDir, { force: true, recursive: true });
		}
	});

	test("snapshot dirty scan skips nested tracked paths under symlinked parents before final lstat", async () => {
		if (process.platform === "win32") return;
		const cwd = tempDir("needs-completion-cwd-");
		const externalDir = tempDir("needs-completion-external-");
		const originalLstat = fs.promises.lstat;
		const lstatPaths: string[] = [];
		setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
			void command;
			const cb = typeof options === "function" ? options : callback;
			const joined = args.join(" ");
			const stdout = joined.includes("rev-parse --is-inside-work-tree")
				? "true"
				: joined.includes("rev-parse HEAD")
					? "a".repeat(40)
					: joined.includes("log -1")
						? "initial commit"
						: joined.includes("ls-files --debug")
							? indexDebugEntry("dir/linkdir/target.txt")
							: "";
			queueMicrotask(() => cb(null, stdout, ""));
			return new EventEmitter() as any;
		}) as any);
		(fs.promises as any).lstat = async (targetPath: fs.PathLike, options?: any) => {
			lstatPaths.push(String(targetPath));
			return originalLstat.call(fs.promises, targetPath, options);
		};
		try {
			mkdirSync(join(cwd, "dir"), { recursive: true });
			writeFileSync(join(externalDir, "target.txt"), "outside changed and longer\n", "utf8");
			fs.symlinkSync(externalDir, join(cwd, "dir", "linkdir"));

			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(snapshot?.head).toBe("a".repeat(40));
			expect(snapshot?.dirty).toBe(false);
			expect(snapshot?.status).not.toContain("dir/linkdir/target.txt");
			expect(diagnostics.join("\n")).toContain("tracked path dir/linkdir/target.txt is under symlinked parent dir/linkdir; skipping lstat probe");
			expect(lstatPaths).toContain(join(cwd, "dir"));
			expect(lstatPaths).toContain(join(cwd, "dir", "linkdir"));
			expect(lstatPaths).not.toContain(join(cwd, "dir", "linkdir", "target.txt"));
		} finally {
			(fs.promises as any).lstat = originalLstat;
			setGitExecFileForTests();
			rmSync(cwd, { force: true, recursive: true });
			rmSync(externalDir, { force: true, recursive: true });
		}
	});

	test("snapshot dirty scan skips real repo directory replacements under symlinked parents before final lstat", async () => {
		if (process.platform === "win32") return;
		const cwd = tempDir("needs-completion-cwd-");
		const externalDir = tempDir("needs-completion-external-");
		const originalLstat = fs.promises.lstat;
		const lstatPaths: string[] = [];
		try {
			execFileSync("git", ["init"], { cwd, stdio: "ignore" });
			mkdirSync(join(cwd, "dir", "linkdir"), { recursive: true });
			writeFileSync(join(cwd, "dir", "linkdir", "target.txt"), "initial\n", "utf8");
			execFileSync("git", ["add", "dir/linkdir/target.txt"], { cwd, stdio: "ignore" });
			execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", "commit", "--no-gpg-sign", "-m", "initial commit"], { cwd, stdio: "ignore" });
			rmSync(join(cwd, "dir", "linkdir"), { force: true, recursive: true });
			writeFileSync(join(externalDir, "target.txt"), "outside changed and longer\n", "utf8");
			fs.symlinkSync(externalDir, join(cwd, "dir", "linkdir"));
			(fs.promises as any).lstat = async (targetPath: fs.PathLike, options?: any) => {
				lstatPaths.push(String(targetPath));
				return originalLstat.call(fs.promises, targetPath, options);
			};

			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(snapshot?.head).toMatch(/^[0-9a-f]{40}$/);
			expect(snapshot?.status).not.toContain(" M dir/linkdir/target.txt");
			expect(diagnostics.join("\n")).toContain("tracked path dir/linkdir/target.txt is under symlinked parent dir/linkdir; skipping lstat probe");
			expect(lstatPaths).toContain(join(cwd, "dir"));
			expect(lstatPaths).toContain(join(cwd, "dir", "linkdir"));
			expect(lstatPaths).not.toContain(join(cwd, "dir", "linkdir", "target.txt"));
		} finally {
			(fs.promises as any).lstat = originalLstat;
			rmSync(cwd, { force: true, recursive: true });
			rmSync(externalDir, { force: true, recursive: true });
		}
	});

	test("snapshot dirty scan rejects unsafe tracked paths before lstat probes", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		const originalLstat = fs.promises.lstat;
		const lstatPaths: string[] = [];
		const unsafePaths = ["/outside.txt", "C:\\outside\\target.txt", "../outside.txt", "dir//target.txt", "dir\\target.txt"];
		const debugEntries = unsafePaths.map((filePath, index) => indexDebugEntry(filePath, index)).join("");
		setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
			void command;
			const cb = typeof options === "function" ? options : callback;
			const joined = args.join(" ");
			const stdout = joined.includes("rev-parse --is-inside-work-tree")
				? "true"
				: joined.includes("rev-parse HEAD")
					? "a".repeat(40)
					: joined.includes("log -1")
						? "initial commit"
						: joined.includes("ls-files --debug")
							? debugEntries
							: "";
			queueMicrotask(() => cb(null, stdout, ""));
			return new EventEmitter() as any;
		}) as any);
		(fs.promises as any).lstat = async (targetPath: fs.PathLike) => {
			lstatPaths.push(String(targetPath));
			throw new Error(`unexpected lstat ${String(targetPath)}`);
		};
		try {
			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(snapshot?.head).toBe("a".repeat(40));
			expect(snapshot?.dirty).toBe(false);
			expect(lstatPaths).toEqual([]);
			for (const unsafePath of unsafePaths) {
				expect(diagnostics.join("\n")).toContain(`unsafe tracked path ${unsafePath}; skipping lstat probe`);
			}
		} finally {
			(fs.promises as any).lstat = originalLstat;
			setGitExecFileForTests();
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("snapshot dirty scan stops parent lstat walk when tracked-file deadline expires", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		const originalLstat = fs.promises.lstat;
		const originalNow = Date.now;
		const lstatPaths: string[] = [];
		const nowValues = [0, 0, 0, 751];
		Date.now = (() => nowValues.shift() ?? 751) as typeof Date.now;
		setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
			void command;
			const cb = typeof options === "function" ? options : callback;
			const joined = args.join(" ");
			const stdout = joined.includes("rev-parse --is-inside-work-tree")
				? "true"
				: joined.includes("rev-parse HEAD")
					? "a".repeat(40)
					: joined.includes("log -1")
						? "initial commit"
						: joined.includes("ls-files --debug")
							? indexDebugEntry("a/b/c/target.txt")
							: "";
			queueMicrotask(() => cb(null, stdout, ""));
			return new EventEmitter() as any;
		}) as any);
		(fs.promises as any).lstat = async (targetPath: fs.PathLike) => {
			lstatPaths.push(String(targetPath));
			return { ctimeNs: 1_000_000_000n, isSymbolicLink: () => false, mtimeNs: 1_000_000_000n, size: 1n };
		};
		try {
			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(snapshot?.head).toBe("a".repeat(40));
			expect(snapshot?.dirty).toBe(false);
			expect(lstatPaths).toEqual([join(cwd, "a")]);
			expect(diagnostics.join("\n")).toContain("dirty scan incomplete: checked 1 tracked paths before 750ms deadline");
		} finally {
			Date.now = originalNow;
			(fs.promises as any).lstat = originalLstat;
			setGitExecFileForTests();
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("snapshot dirty scan stops final lstat when tracked-file deadline expires", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		const originalLstat = fs.promises.lstat;
		const originalNow = Date.now;
		const lstatPaths: string[] = [];
		const nowValues = [0, 0, 751];
		Date.now = (() => nowValues.shift() ?? 751) as typeof Date.now;
		setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
			void command;
			const cb = typeof options === "function" ? options : callback;
			const joined = args.join(" ");
			const stdout = joined.includes("rev-parse --is-inside-work-tree")
				? "true"
				: joined.includes("rev-parse HEAD")
					? "a".repeat(40)
					: joined.includes("log -1")
						? "initial commit"
						: joined.includes("ls-files --debug")
							? indexDebugEntry("target.txt")
							: "";
			queueMicrotask(() => cb(null, stdout, ""));
			return new EventEmitter() as any;
		}) as any);
		(fs.promises as any).lstat = async (targetPath: fs.PathLike) => {
			lstatPaths.push(String(targetPath));
			throw new Error(`unexpected lstat ${String(targetPath)}`);
		};
		try {
			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(snapshot?.head).toBe("a".repeat(40));
			expect(snapshot?.dirty).toBe(false);
			expect(lstatPaths).toEqual([]);
			expect(diagnostics.join("\n")).toContain("dirty scan incomplete: checked 1 tracked paths before 750ms deadline");
		} finally {
			Date.now = originalNow;
			(fs.promises as any).lstat = originalLstat;
			setGitExecFileForTests();
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("snapshot dirty scan reports incomplete when tracked-file deadline is hit", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		writeFileSync(join(cwd, "file-0.txt"), "tracked\n", "utf8");
		const debugEntries = Array.from({ length: 2 }, (_, index) => [
			`file-${index}.txt\0`,
			"  ctime: 1:0\n",
			"  mtime: 1:0\n",
			`  dev: 1\tino: ${index}\n`,
			"  uid: 1\tgid: 1\n",
			"  size: 1\tflags: 0\n",
		].join("")).join("");
		const originalNow = Date.now;
		const nowValues = [0, 0, 751];
		Date.now = (() => nowValues.shift() ?? 751) as typeof Date.now;
		setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
			void command;
			const cb = typeof options === "function" ? options : callback;
			const joined = args.join(" ");
			const stdout = joined.includes("rev-parse --is-inside-work-tree")
				? "true"
				: joined.includes("rev-parse HEAD")
					? "a".repeat(40)
					: joined.includes("log -1")
						? "initial commit"
						: joined.includes("ls-files --debug")
							? debugEntries
							: "";
			queueMicrotask(() => cb(null, stdout, ""));
			return new EventEmitter() as any;
		}) as any);
		try {
			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(snapshot?.head).toBe("a".repeat(40));
			expect(diagnostics.join("\n")).toContain("dirty scan incomplete: checked 1 tracked paths before 750ms deadline");
		} finally {
			Date.now = originalNow;
			setGitExecFileForTests();
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("snapshot dirty status includes staged edits and tracked deletions", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		try {
			execFileSync("git", ["init"], { cwd, stdio: "ignore" });
			writeFileSync(join(cwd, "staged.txt"), "initial\n", "utf8");
			writeFileSync(join(cwd, "deleted.txt"), "initial\n", "utf8");
			execFileSync("git", ["add", "staged.txt", "deleted.txt"], { cwd, stdio: "ignore" });
			execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", "commit", "--no-gpg-sign", "-m", "initial commit"], { cwd, stdio: "ignore" });
			writeFileSync(join(cwd, "staged.txt"), "changed\n", "utf8");
			execFileSync("git", ["add", "staged.txt"], { cwd, stdio: "ignore" });
			rmSync(join(cwd, "deleted.txt"), { force: true });

			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(diagnostics).toEqual([]);
			expect(snapshot?.dirty).toBe(true);
			expect(snapshot?.status).toContain("M  staged.txt");
			expect(snapshot?.status).toContain(" D deleted.txt");
		} finally {
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
});
