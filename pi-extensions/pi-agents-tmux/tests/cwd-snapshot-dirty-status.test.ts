import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { setGitExecFileForTests, snapshotCwdGitState } from "../extensions/subagent/cwd-snapshot.js";

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

});
