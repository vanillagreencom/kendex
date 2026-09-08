import { describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { PROJECT_LOCK_FILE, projectRoot, readConfig, recordProjectTrust } from "../extensions/config.ts";
import { CONFIG_ID, initRustRepo, installToolCallHandler, readLog, renderStub, renderUserStub, trusted, useIsolatedGitEnv } from "./harness.ts";

useIsolatedGitEnv();

function runHandlerChild(home: string, workspace: string, agentDir: string, trusted: boolean): ReturnType<typeof spawnSync> {
	const modulePath = join(import.meta.dir, "..", "extensions", "hooks.ts");
	const program = `
import piHooks from ${JSON.stringify(modulePath)};
let handler;
piHooks({ on(event, callback) { if (event === "tool_call") handler = callback; } });
const result = await handler(
	{ toolName: "bash", input: { command: "git commit -m x" } },
	{ cwd: ${JSON.stringify(workspace)}, isProjectTrusted: () => ${trusted} },
);
process.stdout.write(JSON.stringify(result ?? null));
`;
	return spawnSync(process.execPath, ["-e", program], {
		cwd: workspace,
		encoding: "utf8",
		env: { ...process.env, HOME: home, PI_CODING_AGENT_DIR: agentDir },
	});
}

/** `projectRoot` under a given HOME, in a child because homedir() reads the
 * process's own environment. */
function projectRootUnder(home: string, cwd: string): string | null {
	const child = spawnSync(process.execPath, ["-e", `
import { projectRoot } from ${JSON.stringify(join(import.meta.dir, "..", "extensions", "config.ts"))};
process.stdout.write(JSON.stringify(projectRoot(process.argv[1]) ?? null));
`, cwd], { encoding: "utf8", env: { ...process.env, HOME: home } });
	if (child.status !== 0) throw new Error(child.stderr);
	return JSON.parse(child.stdout) as string | null;
}

describe("pi-hooks root selection", () => {
	test("a subdirectory session runs the project's guard, and an untrusted one runs nothing of the project's", async () => {
		const project = initRustRepo("pi-hooks-subdir-");
		const nested = join(project, "crates", "core");
		const log = join(project, "payload.log");
		try {
			mkdirSync(nested, { recursive: true });
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "pre-commit-check=refused", log });
			const handler = installToolCallHandler();

			// Pi saves a trust decision for the folder or any parent, so its
			// answer covers this whole tree: the guard rendered at the root runs
			// from a subdirectory exactly as it does from the root.
			const refused = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(nested)) as { block?: boolean; reason?: string };
			expect(refused).toEqual({ block: true, reason: "pre-commit-check=refused" });
			expect(readLog(log)).toContain("git commit -m x");

			// Untrusted, the project contributes nothing and no global root
			// holds this name, so the command passes with nothing spawned.
			writeFileSync(log, "");
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, { cwd: nested, isProjectTrusted: () => false })).toBeUndefined();
			expect(readLog(log)).toBe("");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("a vendored checkout inside a project does not stop the walk", async () => {
		const project = initRustRepo("pi-hooks-vendor-");
		const nested = join(project, "vendor", "nested");
		const log = join(project, "payload.log");
		try {
			// Were `.git/` a marker the walk would stop here, find no script, and
			// allow the command with an empty spawn log: every guard off, silently.
			mkdirSync(join(nested, ".git"), { recursive: true });
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "pre-commit-check=refused", log });
			const handler = installToolCallHandler();
			const result = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(nested)) as { block?: boolean; reason?: string };
			expect(result).toEqual({ block: true, reason: "pre-commit-check=refused" });
			expect(readLog(log)).toContain("git commit -m x");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("a `.pi` file is not a project, and a marked one below it still is", () => {
		const outer = mkdtempSync(join(tmpdir(), "pi-hooks-shape-"));
		try {
			const inner = join(outer, "inner");
			mkdirSync(join(inner, "deep"), { recursive: true });
			writeFileSync(join(inner, ".pi"), "not a directory\n");
			expect(projectRoot(join(inner, "deep"))).toBeUndefined();
			mkdirSync(join(inner, ".claude"), { recursive: true });
			expect(projectRoot(join(inner, "deep"))).toBe(realpathSync(inner));
		} finally {
			rmSync(outer, { recursive: true, force: true });
		}
	});

	// Pi's global root lives under home, so a marker there must not make home the
	// project: that would spawn ~/.pi/kendex/hooks/<name>.sh, which kendex never
	// renders, and merge ~/.pi/settings.json over the kendex global scope. The
	// lock file is the one exception, and the renderer's exception too.
	test("home markers yield to an ancestor, and a home lock overrides it", () => {
		const outer = mkdtempSync(join(tmpdir(), "pi-hooks-home-"));
		const real = join(outer, "home");
		mkdirSync(real);
		mkdirSync(join(outer, ".claude"));
		const link = join(mkdtempSync(join(tmpdir(), "pi-hooks-link-")), "home");
		try {
			symlinkSync(real, link, "dir");
			mkdirSync(join(real, ".pi"), { recursive: true });
			mkdirSync(join(real, "notes"), { recursive: true });

			// Both spellings of one directory answer the same: `resolve` does not
			// dereference symlinks, so a spelling comparison would miss on any
			// machine whose home path carries one.
			for (const home of [real, link]) {
				expect(projectRootUnder(home, join(home, "notes"))).toBe(realpathSync(outer));
				expect(projectRootUnder(home, home)).toBe(realpathSync(outer));
			}

			// The lock file wins wherever it stands, home included — the renderer's
			// own rule, applied before it writes.
			writeFileSync(join(real, PROJECT_LOCK_FILE), "{}\n");
			for (const home of [real, link]) {
				expect(projectRootUnder(home, join(home, "notes"))).toBe(realpathSync(real));
			}
		} finally {
			rmSync(outer, { recursive: true, force: true });
			rmSync(dirname(link), { recursive: true, force: true });
		}
	});

	test("a relative global override is refused, and an absolute or blank one answers", () => {
		const home = mkdtempSync(join(tmpdir(), "pi-hooks-global-home-"));
		const workspace = mkdtempSync(join(tmpdir(), "pi-hooks-global-workspace-"));
		const absolute = mkdtempSync(join(tmpdir(), "pi-hooks-global-absolute-"));
		try {
			// A relative value would root the global scope at the session's own
			// directory, where a checkout's script reaches the branch that never
			// asks about trust. The default answers instead.
			const cases = [
				["relative/agent", join(home, ".pi", "agent")],
				["   ", join(home, ".pi", "agent")],
				[absolute, absolute],
			] as const;
			for (const [agentDir, root] of cases) {
				const log = join(root, "payload.log");
				renderUserStub(root, "pre-commit-check", { exitCode: 2, stderr: "global-hook=refused", log });
				const child = runHandlerChild(home, workspace, agentDir, false);
				expect(child.status, child.stderr).toBe(0);
				expect(JSON.parse(child.stdout)).toEqual({ block: true, reason: "global-hook=refused" });
				expect(readLog(log)).toContain("git commit -m x");
				rmSync(join(root, "kendex"), { recursive: true, force: true });
			}

			// The control: the same relative value with a script planted where
			// it would have pointed. Nothing is found, so nothing runs.
			const planted = join(workspace, "relative", "agent");
			const log = join(workspace, "planted.log");
			renderUserStub(planted, "pre-commit-check", { exitCode: 2, stderr: "fixture=forbidden", log });
			const child = runHandlerChild(home, workspace, "relative/agent", false);
			expect(child.status, child.stderr).toBe(0);
			expect(JSON.parse(child.stdout)).toBeNull();
			expect(readLog(log)).toBe("");
		} finally {
			for (const dir of [home, workspace, absolute]) rmSync(dir, { recursive: true, force: true });
		}
	});

	// readConfig, not the guard: the same answer gates merging the project's own
	// settings.json, and every default is on, so a read that should not have
	// happened turns a guard off.
	test("the project's settings are read only where Pi trusts the project", () => {
		const project = initRustRepo("pi-hooks-config-");
		const nested = join(project, "crates");
		try {
			mkdirSync(nested, { recursive: true });
			writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify({
				kendex: { extensionManager: { config: { [CONFIG_ID]: { enabled: false } } } },
			}));
			recordProjectTrust({ cwd: nested, isProjectTrusted: () => false });
			expect(readConfig(nested).enabled).toBeUndefined();
			recordProjectTrust({ cwd: nested, isProjectTrusted: () => true });
			expect(readConfig(nested).enabled).toBe(false);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});
});
