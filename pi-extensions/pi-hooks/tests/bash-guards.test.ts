import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import { isBareCd, isGitCommit, preCommitGate } from "../extensions/bash-guards.ts";

// The marker the growth-guards installer ends its delegating line with, and
// the only thing that makes a hook file ours as far as this gate is
// concerned. Assembled so this file is not itself mistaken for a shim.
const GG_MARK = "# kendex-" + "guards-hook";

function runGit(args: string[], cwd: string): void {
	const result = spawnSync("git", args, { cwd, encoding: "utf8" });
	if (result.status !== 0) {
		throw new Error(`git ${args.join(" ")} failed: ${result.stderr || result.stdout}`);
	}
}

function initRepo(root: string, name: string): string {
	const dir = join(root, name);
	mkdirSync(dir, { recursive: true });
	runGit(["init", "-q"], dir);
	return dir;
}

// A hook file git would run, carrying the marker; `executable: false` leaves
// the marker in place and takes the bit git needs away.
function writeHook(dir: string, lane: string, executable = true): void {
	const file = join(dir, lane);
	writeFileSync(file, `#!/bin/sh\nexit 0 ${GG_MARK}\n`);
	chmodSync(file, executable ? 0o755 : 0o644);
}

// Every fixture carries a package script that would announce itself if
// anything ran it. Nothing may: this gate defers to an armed hook or refuses,
// and never runs a repository's own scripts on its behalf.
function plantAnnouncingScript(repo: string, log: string): void {
	const scripts = join(repo, ".agents", "skills", "growth-guards", "scripts");
	mkdirSync(scripts, { recursive: true });
	writeFileSync(join(scripts, "pre-commit"), `#!/usr/bin/env bash\necho 'the repository script ran' >>"${log}"\nexit 0\n`);
	chmodSync(join(scripts, "pre-commit"), 0o755);
}

describe("pre-commit gate: the bash hook's contract", () => {
	const root = mkdtempSync(join(tmpdir(), "pi-hooks-gate-"));
	const ranLog = join(root, "ran.log");
	let unarmed: string;
	let armed: string;
	let armedByPath: string;
	let disarmed: string;
	let disarmedByPath: string;
	let hooksOff: string;
	let halfArmed: string;
	let markedNotExec: string;
	let notARepo: string;
	// Bare PATH: the armed hook gates a commit with no binary involved, and the
	// refusal for an unarmed one needs none either.
	let savedPath: string | undefined;

	beforeAll(() => {
		unarmed = initRepo(root, "unarmed");

		armed = initRepo(root, "armed");
		for (const lane of ["pre-commit", "commit-msg"]) writeHook(join(armed, ".git", "hooks"), lane);

		armedByPath = initRepo(root, "armed-by-path");
		const customHooks = join(root, "custom-hooks");
		mkdirSync(customHooks);
		for (const lane of ["pre-commit", "commit-msg"]) writeHook(customHooks, lane);
		runGit(["config", "core.hooksPath", customHooks], armedByPath);

		// A hook file git will not run: present, execute bit off. Git skips it
		// silently, so it must not count as armed.
		disarmed = initRepo(root, "disarmed");
		writeHook(join(disarmed, ".git", "hooks"), "pre-commit", false);

		disarmedByPath = initRepo(root, "disarmed-by-path");
		const disarmedHooks = join(root, "disarmed-hooks");
		mkdirSync(disarmedHooks);
		writeHook(disarmedHooks, "pre-commit", false);
		runGit(["config", "core.hooksPath", disarmedHooks], disarmedByPath);

		// core.hooksPath set and EMPTY switches hooks off, and git's answer
		// about it misleads: `rev-parse --git-path hooks` reports `./`, so the
		// directory resolves to the repository root. This fixture puts an
		// executable `pre-commit` exactly there, the trap, while git runs
		// nothing at all.
		hooksOff = initRepo(root, "hooks-off");
		runGit(["config", "core.hooksPath", ""], hooksOff);
		writeFileSync(join(hooksOff, "pre-commit"), "#!/bin/sh\nexit 0\n");
		chmodSync(join(hooksOff, "pre-commit"), 0o755);

		// One lane armed and not the other. Deferring here would hand the
		// commit to a gate that checks content and accepts any message.
		halfArmed = initRepo(root, "half-armed");
		writeHook(join(halfArmed, ".git", "hooks"), "pre-commit");

		// Marked on both lanes, and one of them is a file git will not execute.
		markedNotExec = initRepo(root, "marked-not-exec");
		writeHook(join(markedNotExec, ".git", "hooks"), "pre-commit", false);
		writeHook(join(markedNotExec, ".git", "hooks"), "commit-msg");

		notARepo = join(root, "plain");
		mkdirSync(notARepo);

		for (const repo of [unarmed, armed, armedByPath, disarmed, disarmedByPath, hooksOff, halfArmed, markedNotExec]) {
			plantAnnouncingScript(repo, ranLog);
		}

		const bin = join(root, "no-kendex-bin");
		mkdirSync(bin);
		for (const tool of ["git", "sh", "bash"]) {
			const found = spawnSync("sh", ["-c", `command -v ${tool}`], { encoding: "utf8" }).stdout.trim();
			if (found) spawnSync("ln", ["-sf", found, join(bin, tool)]);
		}
		savedPath = process.env.PATH;
		process.env.PATH = bin;
	});

	afterAll(() => {
		if (savedPath === undefined) delete process.env.PATH;
		else process.env.PATH = savedPath;
		rmSync(root, { recursive: true, force: true });
	});

	async function gate(cwd: string, command: string) {
		const verdict = await preCommitGate(command, cwd);
		let ran = "";
		try {
			ran = readFileSync(ranLog, "utf8");
		} catch {
			// Nothing ran, so nothing wrote the log.
		}
		return { verdict, ran };
	}

	test("detection is word order, never shell parsing", () => {
		expect(isGitCommit("ls -la")).toBe(false);
		expect(isGitCommit("git commit -m test")).toBe(true);
		expect(isGitCommit("git -C /somewhere/else commit -m test")).toBe(true);
		// Real whitespace separates words, as JSON's escapes do in the bash hook.
		expect(isGitCommit("cargo fmt\ngit commit -m x")).toBe(true);
		expect(isGitCommit("cd sub\tgit commit -m x")).toBe(true);
		expect(isGitCommit("cargo fmt\r\ngit commit -m x")).toBe(true);
		// Over-matching is the design: a miss skips a refusal, never a check.
		expect(isGitCommit("echo git commit")).toBe(true);
		expect(isGitCommit("git status && echo commit")).toBe(true);
	});

	test("a non-commit command is left alone", async () => {
		const { verdict, ran } = await gate(unarmed, "ls -la");
		expect(verdict).toEqual({ kind: "allow" });
		expect(ran).toBe("");
	});

	test("a plain git commit in an unarmed repository is refused, never stood in for", async () => {
		for (const command of ["git commit -m test", "git -C /somewhere/else commit -m test", "cargo fmt\ngit commit -m x"]) {
			const { verdict, ran } = await gate(unarmed, command);
			expect(verdict.kind).toBe("refuse");
			if (verdict.kind !== "refuse") throw new Error("unreachable");
			expect(verdict.reason).toContain("not armed by kendex");
			expect(verdict.reason).toContain("kendex guard install");
			expect(verdict.reason).toContain("kendex guard check");
			expect(ran).toBe("");
		}
	});

	test("an armed .git/hooks pair gates the commit itself", async () => {
		expect((await gate(armed, "git commit -m test")).verdict).toEqual({ kind: "allow" });
		expect((await gate(armed, "git commit -am test")).verdict).toEqual({ kind: "allow" });
		expect((await gate(armed, "git commit -m test")).ran).toBe("");
	});

	test("a core.hooksPath hook is not armed by this gate", async () => {
		const { verdict, ran } = await gate(armedByPath, "git commit -m test");
		expect(verdict.kind).toBe("refuse");
		expect(ran).toBe("");
	});

	test("a hook file git will not run is not armed", async () => {
		for (const repo of [disarmed, disarmedByPath, markedNotExec]) {
			const { verdict, ran } = await gate(repo, "git commit -m test");
			expect(verdict.kind).toBe("refuse");
			if (verdict.kind !== "refuse") throw new Error("unreachable");
			expect(verdict.reason).toContain("not armed by kendex");
			expect(ran).toBe("");
		}
	});

	test("one lane armed is not an armed repository", async () => {
		const { verdict, ran } = await gate(halfArmed, "git commit -m test");
		expect(verdict.kind).toBe("refuse");
		if (verdict.kind !== "refuse") throw new Error("unreachable");
		expect(verdict.reason).toContain("not armed by kendex");
		expect(ran).toBe("");
	});

	test("an empty core.hooksPath is hooks off, not a hooks directory", async () => {
		const { verdict, ran } = await gate(hooksOff, "git commit -m test");
		expect(verdict.kind).toBe("refuse");
		if (verdict.kind !== "refuse") throw new Error("unreachable");
		expect(verdict.reason).toContain("not armed by kendex");
		expect(verdict.reason).toContain("kendex guard check");
		expect(ran).toBe("");
	});

	test("bypassing the armed hook is refused, not half-checked", async () => {
		for (const command of [
			"git commit --no-verify -m x",
			"git commit --no-verif -m x",
			"git commit -n -m x",
			"git commit -anm x",
			"git -c core.hooksPath=/dev/null commit -m x",
			"git -c core.hookspath=/dev/null commit -m x",
			"git -c include.path=/tmp/alt.config commit -m x",
			"git --config-env=core.hooksPath=HP commit -m x",
			"GIT_CONFIG_KEY_0=Core.HooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x",
			"GIT_CONFIG_COUNT=1 git commit -m x",
			"git config --local core.hooksPath /dev/null && git commit -m x",
			"git config --local --type path --includes --show-scope core.hooksPath /dev/null && git commit -m x",
		]) {
			const { verdict, ran } = await gate(armed, command);
			expect(verdict.kind).toBe("refuse");
			if (verdict.kind !== "refuse") throw new Error("unreachable");
			expect(verdict.reason).toContain("bypasses this repository's armed git hooks");
			expect(ran).toBe("");
		}
		const named = await gate(armed, "git commit --no-verify -m x");
		if (named.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(named.verdict.reason).toContain("'--no-verify' bypasses");

		const byPath = await gate(armedByPath, "git commit --no-verify -m x");
		expect(byPath.verdict.kind).toBe("refuse");
		expect(byPath.ran).toBe("");
	});

	test("the gate judges its working directory only", async () => {
		// From an armed directory it defers whatever the target; from an
		// unarmed one it judges itself and says so.
		expect((await gate(armed, `git -C ${unarmed} commit -m x`)).verdict).toEqual({ kind: "allow" });

		const fromUnarmed = await gate(unarmed, `git -C ${armed} commit -m x`);
		expect(fromUnarmed.verdict.kind).toBe("refuse");
		if (fromUnarmed.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(fromUnarmed.verdict.reason).toContain(`judged ${unarmed} only`);
		expect(fromUnarmed.verdict.reason).toContain("moves repositories");
		expect(fromUnarmed.ran).toBe("");

		const leadingCd = await gate(unarmed, 'cd "$dir" && git commit -m x');
		if (leadingCd.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(leadingCd.verdict.reason).toContain("moves repositories");

		const inPlace = await gate(unarmed, "git commit -m x");
		if (inPlace.verdict.kind !== "refuse") throw new Error("unreachable");
		expect(inPlace.verdict.reason).not.toContain("moves repositories");

		const outside = await gate(notARepo, `git -C ${unarmed} commit -m x`);
		expect(outside.verdict.kind).toBe("allow");
		if (outside.verdict.kind !== "allow") throw new Error("unreachable");
		expect(outside.verdict.notice).toContain("moves repositories");
	});

	test("shell forms the old parser refused pass through an armed repository", async () => {
		for (const command of [
			'git -C "$repo" commit -m x',
			'repo=$(git rev-parse --show-toplevel) && git -C "$repo" commit -m x',
			'cd "$dir" && git commit -m x',
			"git -C `pwd` commit -m x",
			"(cd /target && git commit -m x)",
			"git --git-dir=/t/.git --work-tree=/t commit -m x",
			'git -C "/tmp/my repo" commit -m x',
		]) {
			const { verdict } = await gate(armed, command);
			expect(verdict).toEqual({ kind: "allow" });
		}
		expect((await gate(unarmed, 'git -C "/tmp/my repo" commit -m x')).verdict.kind).toBe("refuse");
	});
});

describe("bare cd detection", () => {
	test("matches a bare cd but not a scoped or chained one", () => {
		expect(isBareCd("cd /tmp")).toBe(true);
		expect(isBareCd("  cd sub/dir")).toBe(true);
		expect(isBareCd("(cd /tmp && ls)")).toBe(false);
		expect(isBareCd("cd /tmp && ls")).toBe(false);
	});

	test("a cd with no target is the same permanent move", () => {
		expect(isBareCd("cd")).toBe(true);
		expect(isBareCd("  cd  ")).toBe(true);
		expect(isBareCd("cdr --version")).toBe(false);
		expect(isBareCd("echo cd")).toBe(false);
	});

	test("read-only searches with backtick-bearing patterns are never bare cd (kendex#668)", () => {
		expect(isBareCd('rg -n "`kendex refresh`" skills/')).toBe(false);
		expect(isBareCd("rg -n '`kendex refresh`' skills/")).toBe(false);
		expect(isBareCd("rg -n '\\x60kendex refresh\\x60' skills/")).toBe(false);
		expect(isBareCd("rg -n '[\\x60]jq' skills/")).toBe(false);
	});
});
