import { expect } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import { preCommitGate } from "../extensions/bash-guards.ts";
import { runCommandAsync } from "../extensions/process.ts";

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

// A global init.templateDir can leave git init without a hooks directory,
// so the fixture makes the one it writes into.
function initRepo(root: string, name: string): string {
	const dir = join(root, name);
	mkdirSync(dir, { recursive: true });
	runGit(["init", "-q"], dir);
	mkdirSync(join(dir, ".git", "hooks"), { recursive: true });
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

const PROBE = "pi-hooks-path-probe";

/**
 * Prove the narrowed PATH is the one the gate's own spawns resolve against,
 * then take the probe back out so the directory holds git, sh and bash alone.
 * A narrowing that never reaches a child reads exactly like one that holds.
 * That is how a fake cargo sat unreachable while every assertion around it
 * passed (KEN-843), Bun's spawnSync having defaulted to a boot-time
 * environment snapshot. The probe runs through `runCommandAsync` because that
 * is the helper the gate spawns git with, so it answers for the gate's own
 * resolution and not for a lookup this file did itself.
 */
async function expectNarrowedPathReachable(bin: string, cwd: string): Promise<void> {
	const probe = join(bin, PROBE);
	writeFileSync(probe, "#!/bin/sh\nprintf reached\n");
	chmodSync(probe, 0o755);
	const result = await runCommandAsync(PROBE, [], cwd, 5000);
	expect([result.exitCode, result.stdout]).toEqual([0, "reached"]);
	rmSync(probe);
}

type Verdict = Awaited<ReturnType<typeof preCommitGate>>;

/**
 * The fixture set the pre-commit gate's suites judge against, and the two
 * helpers that read a verdict out of it. One suite alone outgrew the size
 * ratchet's cap for a test file, so the repositories, the environment
 * isolation and the narrowed PATH live here and every suite arms its own.
 */
export interface GateHarness {
	root: string;
	ranLog: string;
	unarmed: string;
	armed: string;
	armedByPath: string;
	disarmed: string;
	disarmedByPath: string;
	hooksOff: string;
	halfArmed: string;
	markedNotExec: string;
	foreign: string;
	mixed: string;
	notARepo: string;
	gate(cwd: string, command: string): Promise<{ verdict: Verdict; ran: string }>;
	both(command: string, wantArmed: "allow" | "refuse", wantUnarmed: "allow" | "refuse"): Promise<void>;
	disarm(): void;
}

export async function armGateFixtures(): Promise<GateHarness> {
	const root = mkdtempSync(join(tmpdir(), "pi-hooks-gate-"));
	const ranLog = join(root, "ran.log");
	// Narrowed PATH: git is the one binary this gate resolves, so the fixtures
	// run against a directory holding git, sh and bash and nothing else. A
	// resolution the gate is not supposed to make fails here rather than
	// quietly finding the developer's copy. Git also reads no config of the
	// developer's: a global core.hooksPath would disarm every fixture.
	const savedEnv: Record<string, string | undefined> = {};
	const isolatedEnv: Record<string, string> = { GIT_CONFIG_GLOBAL: "/dev/null", GIT_CONFIG_NOSYSTEM: "1" };

	for (const [name, value] of Object.entries(isolatedEnv)) {
		savedEnv[name] = process.env[name];
		process.env[name] = value;
	}

	const unarmed = initRepo(root, "unarmed");

	const armed = initRepo(root, "armed");
	for (const lane of ["pre-commit", "commit-msg"]) writeHook(join(armed, ".git", "hooks"), lane);

	const armedByPath = initRepo(root, "armed-by-path");
	const customHooks = join(root, "custom-hooks");
	mkdirSync(customHooks);
	for (const lane of ["pre-commit", "commit-msg"]) writeHook(customHooks, lane);
	runGit(["config", "core.hooksPath", customHooks], armedByPath);

	// A hook file git will not run: present, execute bit off. Git skips it
	// silently, so it must not count as armed.
	const disarmed = initRepo(root, "disarmed");
	writeHook(join(disarmed, ".git", "hooks"), "pre-commit", false);

	const disarmedByPath = initRepo(root, "disarmed-by-path");
	const disarmedHooks = join(root, "disarmed-hooks");
	mkdirSync(disarmedHooks);
	writeHook(disarmedHooks, "pre-commit", false);
	runGit(["config", "core.hooksPath", disarmedHooks], disarmedByPath);

	// core.hooksPath set and EMPTY switches hooks off, and git's answer
	// about it misleads: `rev-parse --git-path hooks` reports `./`, so the
	// directory resolves to the repository root. This fixture puts an
	// executable `pre-commit` exactly there, the trap, while git runs
	// nothing at all.
	const hooksOff = initRepo(root, "hooks-off");
	runGit(["config", "core.hooksPath", ""], hooksOff);
	writeFileSync(join(hooksOff, "pre-commit"), "#!/bin/sh\nexit 0\n");
	chmodSync(join(hooksOff, "pre-commit"), 0o755);

	// One lane armed and not the other. Deferring here would hand the
	// commit to a gate that checks content and accepts any message.
	const halfArmed = initRepo(root, "half-armed");
	writeHook(join(halfArmed, ".git", "hooks"), "pre-commit");

	// Marked on both lanes, and one of them is a file git will not execute.
	const markedNotExec = initRepo(root, "marked-not-exec");
	writeHook(join(markedNotExec, ".git", "hooks"), "pre-commit", false);
	writeHook(join(markedNotExec, ".git", "hooks"), "commit-msg");

	// Both lanes executable where git reads them, and neither is ours: a
	// hook somebody else installed is not kendex's arming.
	const foreign = initRepo(root, "foreign");
	for (const lane of ["pre-commit", "commit-msg"]) {
		writeFileSync(join(foreign, ".git", "hooks", lane), "#!/bin/sh\nexit 0\n");
		chmodSync(join(foreign, ".git", "hooks", lane), 0o755);
	}

	// Ours on the content lane, somebody else's on the message lane: the
	// marker has to be read on both, not on pre-commit alone.
	const mixed = initRepo(root, "mixed");
	writeHook(join(mixed, ".git", "hooks"), "pre-commit");
	writeFileSync(join(mixed, ".git", "hooks", "commit-msg"), "#!/bin/sh\nexit 0\n");
	chmodSync(join(mixed, ".git", "hooks", "commit-msg"), 0o755);

	const notARepo = join(root, "plain");
	mkdirSync(notARepo);

	for (const repo of [unarmed, armed, armedByPath, disarmed, disarmedByPath, hooksOff, halfArmed, markedNotExec, foreign, mixed]) {
		plantAnnouncingScript(repo, ranLog);
	}

	const bin = join(root, "git-only-bin");
	mkdirSync(bin);
	for (const tool of ["git", "sh", "bash"]) {
		const found = spawnSync("sh", ["-c", `command -v ${tool}`], { encoding: "utf8" }).stdout.trim();
		if (found) spawnSync("ln", ["-sf", found, join(bin, tool)]);
	}
	savedEnv.PATH = process.env.PATH;
	process.env.PATH = bin;
	await expectNarrowedPathReachable(bin, root);

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

	// Judge one form in both fixtures. The armed expectation says whether the git
	// argv carries a bypass; the unarmed one is the control proving the commit
	// was found at all, since a form the gate never sees passes there too.
	async function both(command: string, wantArmed: "allow" | "refuse", wantUnarmed: "allow" | "refuse"): Promise<void> {
		const a = await gate(armed, command);
		expect([command, a.verdict.kind]).toEqual([command, wantArmed]);
		if (a.verdict.kind === "refuse") expect(a.verdict.reason).toContain("bypasses this repository's armed git hooks");
		expect(a.ran).toBe("");
		const u = await gate(unarmed, command);
		expect([command, u.verdict.kind]).toEqual([command, wantUnarmed]);
		if (u.verdict.kind === "refuse") expect(u.verdict.reason).toContain("not armed by kendex");
		expect(u.ran).toBe("");
	}

	function disarm(): void {
		for (const [name, value] of Object.entries(savedEnv)) {
			if (value === undefined) delete process.env[name];
			else process.env[name] = value;
		}
		rmSync(root, { recursive: true, force: true });
	}

	return {
		root,
		ranLog,
		unarmed,
		armed,
		armedByPath,
		disarmed,
		disarmedByPath,
		hooksOff,
		halfArmed,
		markedNotExec,
		foreign,
		mixed,
		notARepo,
		gate,
		both,
		disarm,
	};
}
