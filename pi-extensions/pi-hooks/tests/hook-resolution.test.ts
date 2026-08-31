import { describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

import { piUserDir, readConfig } from "../extensions/config.ts";
import {
	CONFIG_ID,
	initRustRepo,
	installToolCallHandler,
	plantGlobalScript,
	readLog,
	renderStub,
	restoreAgentDir,
	trusted,
	useIsolatedGitEnv,
} from "./harness.ts";

useIsolatedGitEnv();

/* WHICH hook the carrier is allowed to find, as opposed to what it does with
 * one it found (hooks.test.ts). Two roots answer: the project's, behind Pi's
 * trust because spawning a script there executes what the project ships, and
 * the person's own global root, which is exempt from that question. Every case
 * here is about keeping that exemption honest — the global root has to be the
 * person's own for it to hold. */

describe("pi-hooks rendered-hook resolution", () => {
	// A project-scope hook is code the project ships, and spawning it is
	// executing it. Pi's trust answer is what stands between a fresh clone and
	// arbitrary code on the session's first bash call.
	test("an untrusted workspace does not run the project's script; a trusted one does", async () => {
		const project = initRustRepo("pi-hooks-trust-");
		const log = join(project, "payload.log");
		try {
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "the project's script ran", log });
			const handler = installToolCallHandler();

			// Untrusted: no spawn at all, so no refusal and an empty log.
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: project, isProjectTrusted: () => false })).toBeUndefined();
			expect(readLog(log)).toBe("");

			// A Pi with no trust method, and one whose trust method throws, are
			// both untrusted: only a plain true runs the project's code.
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: project })).toBeUndefined();
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: project, isProjectTrusted: () => { throw new Error("no answer"); } })).toBeUndefined();
			expect(readLog(log)).toBe("");

			// The control: the same script, the same command, trusted. Without
			// this the assertions above pass for a hook that never resolved.
			const result = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(result).toEqual({ block: true, reason: "the project's script ran" });
			expect(readLog(log)).toContain("git commit -m x");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// Resolving `.pi` under the cwd alone found nothing from a subdirectory, and
	// nothing found is allowed — so every guard silently switched off for a
	// session started anywhere but the repository root.
	test("a nested cwd resolves the same project hook as the root", async () => {
		const project = initRustRepo("pi-hooks-nested-");
		const log = join(project, "payload.log");
		const nested = join(project, "crates", "core", "src");
		mkdirSync(nested, { recursive: true });
		try {
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "refused from the project root", log });
			const handler = installToolCallHandler();

			const atRoot = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project)) as { block?: boolean };
			expect(atRoot.block).toBe(true);

			// The same command three directories down must reach the same script.
			const fromNested = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(nested)) as { block?: boolean; reason?: string };
			expect(fromNested).toEqual({ block: true, reason: "refused from the project root" });
			expect(readLog(log).split("}{").length).toBe(2);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("the global root honours PI_CODING_AGENT_DIR", async () => {
		const agentDir = mkdtempSync(join(tmpdir(), "pi-hooks-agentdir-"));
		const project = initRustRepo("pi-hooks-globalonly-");
		const log = join(agentDir, "payload.log");
		const saved = process.env.PI_CODING_AGENT_DIR;
		try {
			// Rendered at the global root only: nothing under the project.
			mkdirSync(join(agentDir, "kendex", "hooks"), { recursive: true });
			const script = join(agentDir, "kendex", "hooks", "pre-commit-check.sh");
			writeFileSync(script, `#!/usr/bin/env bash\nset -euo pipefail\ncat >> ${JSON.stringify(log)}\necho "the global hook ran" >&2\nexit 2\n`);
			chmodSync(script, 0o755);
			const handler = installToolCallHandler();

			// Unset, the relocated root is invisible and nothing runs.
			delete process.env.PI_CODING_AGENT_DIR;
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project))).toBeUndefined();
			expect(readLog(log)).toBe("");

			process.env.PI_CODING_AGENT_DIR = agentDir;
			const result = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(result).toEqual({ block: true, reason: "the global hook ran" });

			// The person's own scripts are not the project's, so the global root
			// answers whether or not the workspace is trusted.
			const untrusted = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: project, isProjectTrusted: () => false }) as { block?: boolean };
			expect(untrusted.block).toBe(true);
		} finally {
			if (saved === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = saved;
			rmSync(agentDir, { recursive: true, force: true });
			rmSync(project, { recursive: true, force: true });
		}
	});

	// Where the two halves used to disagree, restated after round 5. Round 4
	// made piUserDir follow the renderer for an empty or relative value, which
	// roots the global scope at the session's own cwd. Resolution following the
	// renderer is right and stays. ACTING on that root is what had to stop: the
	// global branch never asks about trust, so an untrusted checkout sitting in
	// the cwd got its own kendex/hooks/<name>.sh spawned through it, which is
	// executing the checkout's code. Both halves are pinned here, because the
	// first without the second is the hole and the second without the first is
	// round 4 undone.
	//
	// The verdict alone proves nothing in these: a hook that never resolved and
	// a hook that was refused both return undefined. The spawn log is the
	// assertion.
	test("an empty PI_CODING_AGENT_DIR resolves the renderer's root and runs nothing from it", async () => {
		const workspace = initRustRepo("pi-hooks-empty-untrusted-");
		const log = join(workspace, "payload.log");
		const saved = process.env.PI_CODING_AGENT_DIR;
		const savedCwd = process.cwd();
		try {
			// The hostile half: a checkout shipping the script the global branch
			// looks for, at the directory an empty value roots that branch in.
			plantGlobalScript(workspace, log, "the checkout's script ran");
			process.chdir(workspace);
			process.env.PI_CODING_AGENT_DIR = "";
			const handler = installToolCallHandler();

			// Round 4 intact: the root still follows the renderer, and the script
			// really is sitting under it, so what follows is a refusal to act and
			// not a path that missed.
			expect(existsSync(join(piUserDir(), "kendex", "hooks", "pre-commit-check.sh"))).toBe(true);

			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: workspace, isProjectTrusted: () => false })).toBeUndefined();
			expect(readLog(log)).toBe("");
		} finally {
			process.chdir(savedCwd);
			restoreAgentDir(saved);
			rmSync(workspace, { recursive: true, force: true });
		}
	});

	test("a relative PI_CODING_AGENT_DIR resolves the renderer's root and runs nothing from it", async () => {
		const workspace = initRustRepo("pi-hooks-relative-untrusted-");
		const log = join(workspace, "payload.log");
		const saved = process.env.PI_CODING_AGENT_DIR;
		const savedCwd = process.cwd();
		try {
			plantGlobalScript(join(workspace, "agent"), log, "the checkout's script ran");
			process.chdir(workspace);
			process.env.PI_CODING_AGENT_DIR = "agent";
			const handler = installToolCallHandler();

			expect(existsSync(join(piUserDir(), "kendex", "hooks", "pre-commit-check.sh"))).toBe(true);

			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: workspace, isProjectTrusted: () => false })).toBeUndefined();
			expect(readLog(log)).toBe("");
		} finally {
			process.chdir(savedCwd);
			restoreAgentDir(saved);
			rmSync(workspace, { recursive: true, force: true });
		}
	});

	// The control the two above are worthless without: an absolute root outside
	// the workspace is the person's own, and it still runs and still blocks in
	// an untrusted workspace, which is the whole reason the global branch skips
	// the trust gate.
	test("an absolute PI_CODING_AGENT_DIR outside the workspace still spawns and still blocks", async () => {
		const agentDir = mkdtempSync(join(tmpdir(), "pi-hooks-abs-owned-"));
		const workspace = initRustRepo("pi-hooks-abs-untrusted-");
		const log = join(agentDir, "payload.log");
		const saved = process.env.PI_CODING_AGENT_DIR;
		const savedCwd = process.cwd();
		try {
			plantGlobalScript(agentDir, log, "the person's own script ran");
			// Launched from inside the untrusted checkout, as the two above are.
			process.chdir(workspace);
			process.env.PI_CODING_AGENT_DIR = agentDir;
			const handler = installToolCallHandler();

			const result = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: workspace, isProjectTrusted: () => false }) as { block?: boolean; reason?: string };
			expect(result).toEqual({ block: true, reason: "the person's own script ran" });
			expect(readLog(log)).toContain("git commit -m x");
		} finally {
			process.chdir(savedCwd);
			restoreAgentDir(saved);
			rmSync(agentDir, { recursive: true, force: true });
			rmSync(workspace, { recursive: true, force: true });
		}
	});

	// The same door, opened by reading rather than running. The user scope is
	// merged unconditionally, so a checkout sitting where an empty value roots
	// that scope could ship a settings.json switching every guard off, which
	// needs no code execution at all to reach the same end.
	test("a checkout at an empty PI_CODING_AGENT_DIR cannot switch the guards off", async () => {
		const workspace = initRustRepo("pi-hooks-settings-untrusted-");
		const saved = process.env.PI_CODING_AGENT_DIR;
		const savedCwd = process.cwd();
		try {
			writeFileSync(join(workspace, "settings.json"), JSON.stringify({
				kendex: { extensionManager: { config: { [CONFIG_ID]: { enabled: false, preCommitCheck: false } } } },
			}));
			process.chdir(workspace);
			process.env.PI_CODING_AGENT_DIR = "";

			// Not false and not true: the key is absent, so DEFAULTS stand and
			// every guard in this package is on.
			const cfg = readConfig(workspace);
			expect(cfg.enabled).toBeUndefined();
			expect(cfg.preCommitCheck).toBeUndefined();
		} finally {
			process.chdir(savedCwd);
			restoreAgentDir(saved);
			rmSync(workspace, { recursive: true, force: true });
		}
	});

	// Decided rather than inherited: a name neither root holds means kendex did
	// not install this hook here, and the command passes. See runRenderedHook.
	test("a hook kendex never rendered allows the command", async () => {
		const project = initRustRepo("pi-hooks-norender-");
		try {
			const handler = installToolCallHandler();
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project))).toBeUndefined();
			expect(await handler({ toolName: "bash", input: { command: "cd /tmp" } }, trusted(project))).toBeUndefined();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});
	// An absolute value passes the first test and can still land inside the
	// workspace, because `resolve` normalizes `.` and `..` and stops there. The
	// comparison was on spelling; the spawn is the filesystem following the
	// link. Both sides are canonicalized now, and the root that comes back is
	// the canonical one, so what was compared is what gets opened.
	test("an absolute PI_CODING_AGENT_DIR symlinked into the workspace runs nothing", async () => {
		const outside = mkdtempSync(join(tmpdir(), "pi-hooks-symlink-outside-"));
		const workspace = initRustRepo("pi-hooks-symlink-untrusted-");
		const log = join(workspace, "payload.log");
		const saved = process.env.PI_CODING_AGENT_DIR;
		try {
			// The checkout's own script, and a link to it from a path that reads
			// as external to any comparison of strings.
			plantGlobalScript(join(workspace, "inside-agent"), log, "the checkout's script ran");
			const link = join(outside, "pi-agent");
			symlinkSync(join(workspace, "inside-agent"), link);
			process.env.PI_CODING_AGENT_DIR = link;
			const handler = installToolCallHandler();

			// The lexical root really does reach the checkout's script, so what
			// follows is the containment test refusing rather than a path missing.
			expect(existsSync(join(piUserDir(), "kendex", "hooks", "pre-commit-check.sh"))).toBe(true);

			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: workspace, isProjectTrusted: () => false })).toBeUndefined();
			expect(readLog(log)).toBe("");
		} finally {
			restoreAgentDir(saved);
			rmSync(outside, { recursive: true, force: true });
			rmSync(workspace, { recursive: true, force: true });
		}
	});

	// The same link, the reading door. Both callers go through one test, so
	// this fails with the one above and passes with it.
	test("settings reached through a symlinked root cannot switch the guards off", async () => {
		const outside = mkdtempSync(join(tmpdir(), "pi-hooks-symlink-cfg-"));
		const workspace = initRustRepo("pi-hooks-symlink-settings-");
		const saved = process.env.PI_CODING_AGENT_DIR;
		try {
			const inside = join(workspace, "inside-agent");
			mkdirSync(inside, { recursive: true });
			writeFileSync(join(inside, "settings.json"), JSON.stringify({
				kendex: { extensionManager: { config: { [CONFIG_ID]: { enabled: false, preCommitCheck: false } } } },
			}));
			const link = join(outside, "pi-agent");
			symlinkSync(inside, link);
			process.env.PI_CODING_AGENT_DIR = link;

			expect(existsSync(join(piUserDir(), "settings.json"))).toBe(true);

			const cfg = readConfig(workspace);
			expect(cfg.enabled).toBeUndefined();
			expect(cfg.preCommitCheck).toBeUndefined();
		} finally {
			restoreAgentDir(saved);
			rmSync(outside, { recursive: true, force: true });
			rmSync(workspace, { recursive: true, force: true });
		}
	});

	// A root the filesystem cannot answer for withholds the global scope, and
	// that costs nothing: there is no script under a path that does not resolve
	// and no settings.json either, so withholding it and searching it come to
	// the same answer. Pinned because the alternative — walking to the nearest
	// existing ancestor — would judge a path other than the one that gets
	// followed, and because a person whose ~/.pi/agent has never been created
	// must not notice this at all.
	test("a global root that does not resolve costs nothing that searching it would have found", async () => {
		const outside = mkdtempSync(join(tmpdir(), "pi-hooks-absent-root-"));
		const workspace = initRustRepo("pi-hooks-absent-untrusted-");
		const saved = process.env.PI_CODING_AGENT_DIR;
		try {
			process.env.PI_CODING_AGENT_DIR = join(outside, "never-created", "agent");
			const handler = installToolCallHandler();

			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(workspace))).toBeUndefined();
			// The project's own settings still merge, and the user scope
			// contributes exactly what a settings.json nobody could find
			// contributes: this is the whole of what initRustRepo writes.
			expect(readConfig(workspace)).toEqual({
				enabled: true,
				preCommitCheck: true,
				taskCompletedCheck: false,
				clippyTimeoutMs: 3000,
			});
		} finally {
			restoreAgentDir(saved);
			rmSync(outside, { recursive: true, force: true });
			rmSync(workspace, { recursive: true, force: true });
		}
	});

	// The workspace side of the containment comparison, and the same execution
	// path reached through it. The carrier walked for `.pi`, `.git` and the lock
	// file; kendex discovers a project by any of seven harness marker
	// directories (crates/core/src/discover.rs), so a project whose only marker
	// is `.agents/` was not found, the boundary was computed against the nested
	// cwd instead, and an absolute root symlinked into that project read as
	// outside it.
	test("a project marked only by .agents is a workspace a symlinked root cannot reach into", async () => {
		const outside = mkdtempSync(join(tmpdir(), "pi-hooks-agents-outside-"));
		const workspace = mkdtempSync(join(tmpdir(), "pi-hooks-agents-workspace-"));
		const log = join(workspace, "payload.log");
		const saved = process.env.PI_CODING_AGENT_DIR;
		try {
			// The only marker. No .pi, no .git, no lock file.
			mkdirSync(join(workspace, ".agents"), { recursive: true });
			const nested = join(workspace, "src", "deep");
			mkdirSync(nested, { recursive: true });
			plantGlobalScript(join(workspace, "inside-agent"), log, "the checkout's script ran");
			const link = join(outside, "pi-agent");
			symlinkSync(join(workspace, "inside-agent"), link);
			process.env.PI_CODING_AGENT_DIR = link;
			const handler = installToolCallHandler();

			expect(existsSync(join(piUserDir(), "kendex", "hooks", "pre-commit-check.sh"))).toBe(true);

			// From a subdirectory, so the walk has to find the .agents root to
			// draw the boundary at all.
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: nested, isProjectTrusted: () => false })).toBeUndefined();
			expect(readLog(log)).toBe("");
		} finally {
			restoreAgentDir(saved);
			rmSync(outside, { recursive: true, force: true });
			rmSync(workspace, { recursive: true, force: true });
		}
	});

	// The other direction of the same defect. `.git` was a marker here and is
	// not one for kendex, so a vendored checkout resolved as the project and the
	// hook rendered at the real root was never looked for: a guard that does not
	// run and says nothing, which is the failure this whole change exists to
	// remove.
	test("a nested .git is not the project, so the real project's hook still runs", async () => {
		const project = initRustRepo("pi-hooks-nested-git-");
		const log = join(project, "payload.log");
		try {
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "the project's hook ran", log });
			const vendored = join(project, "vendor", "nested");
			mkdirSync(join(vendored, ".git"), { recursive: true });
			const handler = installToolCallHandler();

			const result = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(vendored)) as { block?: boolean; reason?: string };
			expect(result).toEqual({ block: true, reason: "the project's hook ran" });
			expect(readLog(log)).toContain("git commit -m x");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// Not reported, found while matching the renderer, and live since round 6.
	// kendex refuses to call home a project however it is marked, and this did
	// not. Nearly everyone has a marker directory at home, so a session started
	// anywhere outside a real project resolved home as the workspace, and then
	// the global root — which lives under home — read as inside it and was
	// withheld. The person's own guards stopped running and said nothing.
	//
	// Run in a child process because bun resolves homedir() once from the
	// passwd entry rather than re-reading process.env.HOME, so relocating home
	// in-process does not reach the code under test. The child is the whole
	// carrier, not a helper: it installs the real handler and prints the real
	// verdict.
	test("home is not a workspace, so a session outside a project keeps its global guards", () => {
		const home = mkdtempSync(join(tmpdir(), "pi-hooks-home-"));
		const agentDir = join(home, ".pi", "agent");
		const log = join(agentDir, "payload.log");
		try {
			plantGlobalScript(agentDir, log, "the person's own script ran");
			const scratch = join(home, "scratch");
			mkdirSync(scratch, { recursive: true });
			const driver = join(home, "driver.mjs");
			writeFileSync(driver, [
				`const { default: piHooks } = await import(${JSON.stringify(join(import.meta.dir, "..", "extensions", "hooks.ts"))});`,
				"let handler;",
				'piHooks({ on(event, cb) { if (event === "tool_call") handler = cb; } });',
				`const verdict = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: ${JSON.stringify(scratch)}, isProjectTrusted: () => false });`,
				"console.log(JSON.stringify(verdict ?? null));",
			].join("\n"));

			const env = { ...process.env, HOME: home };
			delete env.PI_CODING_AGENT_DIR;
			const run = spawnSync(process.execPath, [driver], { encoding: "utf8", env });
			expect(run.status).toBe(0);
			expect(JSON.parse(run.stdout.trim())).toEqual({ block: true, reason: "the person's own script ran" });
			expect(readLog(log)).toContain("git commit -m x");
		} finally {
			rmSync(home, { recursive: true, force: true });
		}
	});

});
