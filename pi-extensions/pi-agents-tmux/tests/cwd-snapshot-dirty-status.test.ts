import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { DIRTY_STATE_UNAVAILABLE, dirtyLabel, dirtyStateOf, setGitExecFileForTests, snapshotCwdGitState } from "../extensions/subagent/cwd-snapshot.js";
import { compactThenEmptySummary } from "../extensions/subagent/runner.js";
import { taskRecordDashboardMessage } from "../extensions/subagent/index.js";
import { formatTaskRecordResult } from "../extensions/subagent/renderers.js";

function tempDir(prefix: string): string {
	return mkdtempSync(join(tmpdir(), prefix));
}

describe("cwd snapshot dirty status", () => {
	test("snapshot dirty status reports staged, unstaged, deleted, renamed and untracked paths", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		try {
			execFileSync("git", ["init"], { cwd, stdio: "ignore" });
			writeFileSync(join(cwd, "staged.txt"), "initial\n", "utf8");
			writeFileSync(join(cwd, "deleted.txt"), "initial\n", "utf8");
			writeFileSync(join(cwd, "edited.txt"), "initial\n", "utf8");
			writeFileSync(join(cwd, "renamed.txt"), "initial\n", "utf8");
			execFileSync("git", ["add", "staged.txt", "deleted.txt", "edited.txt", "renamed.txt"], { cwd, stdio: "ignore" });
			execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", "commit", "--no-gpg-sign", "-m", "initial commit"], { cwd, stdio: "ignore" });

			// The four things a subagent leaves behind in its cwd.
			writeFileSync(join(cwd, "staged.txt"), "changed\n", "utf8");
			execFileSync("git", ["add", "staged.txt"], { cwd, stdio: "ignore" });
			rmSync(join(cwd, "deleted.txt"), { force: true });
			writeFileSync(join(cwd, "edited.txt"), "changed\n", "utf8");
			execFileSync("git", ["mv", "renamed.txt", "moved.txt"], { cwd, stdio: "ignore" });
			mkdirSync(join(cwd, "new-dir"), { recursive: true });
			writeFileSync(join(cwd, "new-dir", "untracked.txt"), "new\n", "utf8");

			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(diagnostics).toEqual([]);
			expect(snapshot?.dirty).toBe(true);
			expect(snapshot?.status).toContain("M  staged.txt");
			expect(snapshot?.status).toContain(" D deleted.txt");
			expect(snapshot?.status).toContain(" M edited.txt");
			expect(snapshot?.status).toContain("?? new-dir/untracked.txt");
			expect(snapshot?.status).toContain("R  renamed.txt -> moved.txt");
		} finally {
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("a git status that fails degrades the snapshot instead of discarding it", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		setGitExecFileForTests(((_command: string, args: string[], options: unknown, callback?: unknown) => {
			const cb = (typeof options === "function" ? options : callback) as (e: Error | null, out: string, err: string) => void;
			const joined = args.join(" ");
			if (joined.includes("status --porcelain")) {
				queueMicrotask(() => cb(new Error("Command failed: git status (timeout)"), "", "timed out"));
				return new EventEmitter() as never;
			}
			const stdout = joined.includes("rev-parse --is-inside-work-tree")
				? "true"
				: joined.includes("rev-parse HEAD")
					? "a".repeat(40)
					: joined.includes("log -1")
						? "initial commit"
						: "";
			queueMicrotask(() => cb(null, stdout, ""));
			return new EventEmitter() as never;
		}) as never);
		try {
			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(snapshot?.head).toBe("a".repeat(40));
			expect(snapshot?.lastCommit.subject).toBe("initial commit");
			expect(snapshot?.status).toBe(DIRTY_STATE_UNAVAILABLE);
			expect(diagnostics.join("\n")).toContain("status --porcelain");
			expect(diagnostics.join("\n")).toContain("dirty state unavailable");
			// The field alone would pass with the bug present: `dirty` is false
			// for a failed read and for a genuinely clean tree alike. What has to
			// hold is that no surface prints "clean" for the first one.
			expect(dirtyStateOf(snapshot)).toBe("unknown");
			expect(compactThenEmptySummary(snapshot)).toContain("(dirty state unknown)");
			expect(compactThenEmptySummary(snapshot)).not.toContain("(clean)");
		} finally {
			setGitExecFileForTests();
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	test("a conflicted merge reports the unmerged code", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		const git = (...args: string[]) => execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", ...args], { cwd, stdio: "ignore" });
		try {
			git("init");
			writeFileSync(join(cwd, "conflict.txt"), "base\n", "utf8");
			git("add", "conflict.txt");
			git("commit", "--no-gpg-sign", "-m", "base");
			git("checkout", "-b", "other");
			writeFileSync(join(cwd, "conflict.txt"), "other\n", "utf8");
			git("commit", "--no-gpg-sign", "-am", "other");
			git("checkout", "-");
			writeFileSync(join(cwd, "conflict.txt"), "main\n", "utf8");
			git("commit", "--no-gpg-sign", "-am", "main");
			try {
				git("merge", "other");
			} catch {
				// The conflict is the fixture.
			}

			const diagnostics: string[] = [];
			const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

			expect(diagnostics).toEqual([]);
			expect(snapshot?.dirty).toBe(true);
			expect(snapshot?.status).toContain("UU conflict.txt");
		} finally {
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	// git status does not detect copies without -C, so the C code cannot come
	// from a real repository here. It shares the rename branch's origin-record
	// lookahead, and getting that wrong silently mangles the next entry.
	test("a copy record consumes its origin field like a rename", async () => {
		const cwd = tempDir("needs-completion-cwd-");
		setGitExecFileForTests(((_command: string, args: string[], options: unknown, callback?: unknown) => {
			const cb = (typeof options === "function" ? options : callback) as (e: Error | null, out: string, err: string) => void;
			const joined = args.join(" ");
			const stdout = joined.includes("status --porcelain")
				? "C  copy.txt\0origin.txt\0 M after.txt\0"
				: joined.includes("rev-parse --is-inside-work-tree")
					? "true"
					: joined.includes("rev-parse HEAD")
						? "b".repeat(40)
						: joined.includes("log -1")
							? "initial commit"
							: "";
			queueMicrotask(() => cb(null, stdout, ""));
			return new EventEmitter() as never;
		}) as never);
		try {
			const snapshot = await snapshotCwdGitState(cwd, () => {});
			expect(snapshot?.status.split("\n")).toEqual(["C  origin.txt -> copy.txt", " M after.txt"]);
		} finally {
			setGitExecFileForTests();
			rmSync(cwd, { force: true, recursive: true });
		}
	});

	// The word all three renderers print, in one place so they cannot drift.
	test("dirtyLabel separates a failed read from a clean tree", () => {
		const base = { cwd: "/w", head: "a".repeat(40), lastCommit: { subject: "s" }, lastCommitSubject: "s" };
		expect(dirtyLabel({ ...base, dirty: false, status: "" })).toBe("clean");
		expect(dirtyLabel({ ...base, dirty: true, status: " M a.txt" })).toBe("dirty");
		expect(dirtyLabel({ ...base, dirty: false, status: DIRTY_STATE_UNAVAILABLE })).toBe("dirty state unknown");
		expect(dirtyLabel(undefined)).toBe("dirty state unknown");
	});

	// A correct helper cannot stop a call site bypassing it, so each surface
	// that prints the state is pinned on its rendered output, not on the helper.
	test("no rendering surface prints a degraded snapshot as clean", () => {
		const degraded = {
			cwd: "/w",
			dirty: false,
			dirtyStatus: DIRTY_STATE_UNAVAILABLE,
			head: "c".repeat(40),
			lastCommit: { subject: "last change" },
			lastCommitSubject: "last change",
			status: DIRTY_STATE_UNAVAILABLE,
		};
		const rendered = [
			compactThenEmptySummary(degraded),
			taskRecordDashboardMessage({ agent: "rust", cwdSnapshot: degraded, diagnostics: ["turn ended"], status: "needs_completion", taskId: "t1" } as never) ?? "",
			formatTaskRecordResult({ agent: "rust", cwdSnapshot: degraded, status: "needs_completion", taskId: "t1" } as never),
		];
		for (const text of rendered) {
			expect(text).toContain("dirty state unknown");
			expect(text).not.toContain("(clean)");
		}
	});
});
