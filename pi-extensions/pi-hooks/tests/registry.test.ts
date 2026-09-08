import { describe, expect, test } from "bun:test";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { initRustRepo, installToolCallHandler, readLog, registerProjectHook, registerRendered, renderedHookPath, renderStub, renderUserStub, runGit, trusted, useIsolatedGitEnv } from "./harness.ts";

useIsolatedGitEnv();

/** A committed git repository, so a rendered guard's own registration resolves
 * the way it does in a real project. */
function initCleanRustRepo(prefix: string): string {
	const dir = initRustRepo(prefix);
	runGit(["-c", "user.email=pi-hooks@example.com", "-c", "user.name=pi-hooks", "commit", "-q", "-m", "init"], dir);
	return dir;
}

/** A hook body of the person's own: no script of kendex's behind it, so it
 * exists nowhere but the registry and can only run from there. */
function customCommand(log: string, stderr: string, exitCode: number): string {
	return `cat >> ${JSON.stringify(log)}; echo ${JSON.stringify(stderr)} >&2; exit ${exitCode}`;
}

describe("pi-hooks registry dispatch", () => {
	// A `[[custom-hooks]]` entry has no file of its own because kendex registers
	// the person's command verbatim. Registry dispatch must not depend on a fixed
	// list of script names. The control has no registration.
	test("a custom PreToolUse hook runs, and nothing runs where the registry names it not", async () => {
		const project = initCleanRustRepo("pi-hooks-custom-");
		const log = join(project, "custom.log");
		try {
			const handler = installToolCallHandler();

			// The control first: a registry with nothing under this listener.
			expect(await handler({ toolName: "bash", input: { command: "git push" } }, trusted(project))).toBeUndefined();
			expect(readLog(log)).toBe("");

			registerRendered(join(project, ".pi"), "tool_call", "Bash", customCommand(log, "audit=protected", 2));
			const refused = await handler({ toolName: "bash", input: { command: "git push" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(refused).toEqual({ block: true, reason: "audit=protected" });
			expect(JSON.parse(readLog(log))).toEqual({ tool_name: "Bash", tool_input: { command: "git push" } });
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// A catalog hook can use a name the carrier does not know.
	test("a rendered hook the carrier has never heard of runs because the registry names it", async () => {
		const project = initCleanRustRepo("pi-hooks-unknown-");
		const log = join(project, "audit.log");
		try {
			renderStub(project, "audit", { exitCode: 2, stderr: "audit=refused", log });
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "git push" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(refused).toEqual({ block: true, reason: "audit=refused" });
			expect(readLog(log)).toContain("git push");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// A session started inside a vendored checkout is in its own git root,
	// where kendex rendered nothing. The project whose guards these are is the
	// one this registry was read from, and the script is the one it anchors.
	test("a session inside a nested git checkout still runs the project's guard", async () => {
		const project = initCleanRustRepo("pi-hooks-nested-");
		const nested = join(project, "vendor", "dep");
		const log = join(project, "nested.log");
		try {
			mkdirSync(nested, { recursive: true });
			runGit(["init", "-q"], nested);
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "pre-commit-check=refused", log });
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(nested)) as { block?: boolean; reason?: string };
			expect(refused).toEqual({ block: true, reason: "pre-commit-check=refused" });
			expect(readLog(log)).toContain("git commit -m x");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// And where that path holds nothing, the refusal is written here rather
	// than being bash's own text from a command run verbatim.
	test("a render no scope holds refuses naming the render, not bash's error", async () => {
		const project = initCleanRustRepo("pi-hooks-broken-only-");
		try {
			registerProjectHook(project, "pre-commit-check");
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(refused.block).toBe(true);
			expect(refused.reason?.split("\n")[0]).toBe(`hook-missing=${renderedHookPath(project, "pre-commit-check")}`);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// The rule this module already states for a hook: a guard that did not run
	// does not stand aside. A registry is a file only kendex writes, so it not
	// parsing — or parsing into a shape kendex never writes — is not the person
	// standing their guards down.
	test("a registry that exists and cannot be read refuses the call", async () => {
		const project = initCleanRustRepo("pi-hooks-unreadable-");
		const registry = join(project, ".pi", "kendex", "hooks.json");
		try {
			renderStub(project, "pre-commit-check", { exitCode: 0, log: join(project, "unused.log") });
			const handler = installToolCallHandler();
			// The control: the same fixture, readable.
			expect(await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project))).toBeUndefined();

			const broken = [
				"<<<<<<< HEAD\n{}\n=======\n{}\n>>>>>>> main\n",
				'{"hooks": {"tool_call": [',
				'{"hooks": {"tool_call": {}}}',
				'{"hooks": {"tool_call": [{"matcher": "Bash", "hooks": {}}]}}',
			];
			for (const document of broken) {
				writeFileSync(registry, document);
				const refused = await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project)) as { block?: boolean; reason?: string };
				expect(refused.block, document).toBe(true);
				expect(refused.reason?.split("\n")[0], document).toBe("hook-registry-unreadable=tool_call");
				expect(refused.reason, document).toContain(registry);
			}
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// An absent registry is the one reading that allows: kendex has installed
	// no hook here, and the package installs from npm on its own.
	test("no registry, and a file where the kendex directory should be, both allow the call", async () => {
		const project = initCleanRustRepo("pi-hooks-absent-");
		try {
			const handler = installToolCallHandler();
			expect(await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project))).toBeUndefined();

			// ENOTDIR is the other shape of absent.
			writeFileSync(join(project, ".pi", "kendex"), "not a directory\n");
			expect(await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project))).toBeUndefined();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// Running what a project's registry names is running code the project
	// ships, so a clone nobody has trusted gets nothing of its own — while the
	// person's own hooks answer in the same call, because they are not the
	// project's.
	test("an untrusted project's hooks do not run, and the person's own still answer", async () => {
		const project = initCleanRustRepo("pi-hooks-untrusted-");
		const log = join(project, "project.log");
		const agentDir = process.env.PI_CODING_AGENT_DIR!;
		const globalLog = join(agentDir, "global.log");
		try {
			registerRendered(join(project, ".pi"), "tool_call", "Bash", customCommand(log, "project-hook=refused", 2));
			renderUserStub(agentDir, "audit", { exitCode: 2, stderr: "global-hook=refused", log: globalLog });
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "git push" } }, { cwd: project, isProjectTrusted: () => false });
			expect(refused).toEqual({ block: true, reason: "global-hook=refused" });
			expect(readLog(log)).toBe("");
		} finally {
			rmSync(join(agentDir, "kendex"), { recursive: true, force: true });
			rmSync(project, { recursive: true, force: true });
		}
	});

	// That registry is never opened, so a clone nobody has trusted cannot stop
	// the session with a document that will not parse either.
	test("an untrusted project's unreadable registry neither runs nor refuses", async () => {
		const project = initCleanRustRepo("pi-hooks-untrusted-broken-");
		try {
			mkdirSync(join(project, ".pi", "kendex"), { recursive: true });
			writeFileSync(join(project, ".pi", "kendex", "hooks.json"), "not json");
			const handler = installToolCallHandler();
			expect(await handler({ toolName: "bash", input: { command: "ls" } }, { cwd: project, isProjectTrusted: () => false })).toBeUndefined();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});


});
