import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import * as fs from "node:fs";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "bun:test";
import { setGitExecFileForTests, snapshotCwdGitState } from "../extensions/subagent/cwd-snapshot.js";

function tempDir(prefix: string): string {
	return mkdtempSync(join(tmpdir(), prefix));
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

describe("cwd snapshot dirty scan", () => {
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
		const unsafePaths = ["/outside.txt", "C:\\outside\\target.txt", "C:/outside/target.txt", "../outside.txt", "dir//target.txt", "dir\\target.txt"];
		let debugEntries = "";
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
			for (const [index, unsafePath] of unsafePaths.entries()) {
				debugEntries = indexDebugEntry(unsafePath, index);
				lstatPaths.length = 0;
				const diagnostics: string[] = [];
				const snapshot = await snapshotCwdGitState(cwd, (diagnostic) => diagnostics.push(diagnostic));

				expect(snapshot?.head).toBe("a".repeat(40));
				expect(snapshot?.dirty).toBe(false);
				expect(lstatPaths).toEqual([]);
				expect(lstatPaths.some((targetPath) => !targetPath.startsWith(cwd))).toBe(false);
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
});
