import { describe, expect, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { GUARD_SETTING_NAMES } from "../extensions/hooks.ts";
import { renderedName, TOOL_CALL_LISTENER } from "../extensions/registry.ts";
import { claudeToolName, PI_BUILTIN_TOOLS } from "../extensions/vocab.ts";
import {
	initRustRepo,
	installToolCallHandler,
	readLog,
	registerProjectHook,
	registerRendered,
	renderStub,
	renderUserStub,
	runGit,
	trusted,
	useIsolatedGitEnv,
} from "./harness.ts";

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
	// The Done-when of KEN-941. A `[[custom-hooks]]` entry has no file of its
	// own — kendex registers the person's command verbatim — so a carrier
	// running a fixed list of script names reported it enforced and ran
	// nothing. The control is the same fixture with the registration absent.
	test("a custom PreToolUse hook runs, and nothing runs where the registry names it not", async () => {
		const project = initCleanRustRepo("pi-hooks-custom-");
		const log = join(project, "custom.log");
		try {
			const handler = installToolCallHandler();

			// The control first: a registry with nothing under this listener.
			expect(await handler({ toolName: "bash", input: { command: "git push" } }, trusted(project))).toBeUndefined();
			expect(readLog(log)).toBe("");

			registerRendered(join(project, ".pi"), "tool_call", "Bash", customCommand(log, "audit: this branch is protected", 2));
			const refused = await handler({ toolName: "bash", input: { command: "git push" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(refused).toEqual({ block: true, reason: "audit: this branch is protected" });
			expect(JSON.parse(readLog(log))).toEqual({ tool_name: "Bash", tool_input: { command: "git push" } });
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// The other half of the same defect: a catalog hook whose name is not one
	// of the three the carrier used to spell out.
	test("a rendered hook the carrier has never heard of runs because the registry names it", async () => {
		const project = initCleanRustRepo("pi-hooks-unknown-");
		const log = join(project, "audit.log");
		try {
			renderStub(project, "audit", { exitCode: 2, stderr: "audit: refused", log });
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "git push" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(refused).toEqual({ block: true, reason: "audit: refused" });
			expect(readLog(log)).toContain("git push");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// The command kendex registers for a project hook spells its path
	// `$(git rev-parse --show-toplevel)/.pi/…`. Running that command verbatim
	// would ask git which project this is, and git answers the nested checkout
	// — where kendex rendered nothing. The guard the project installed has to
	// run anyway, so the path comes from the registry's own root.
	test("a session inside a nested git checkout still runs the project's guard", async () => {
		const project = initCleanRustRepo("pi-hooks-nested-");
		const nested = join(project, "vendor", "dep");
		const log = join(project, "nested.log");
		try {
			mkdirSync(nested, { recursive: true });
			runGit(["init", "-q"], nested);
			renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "pre-commit-check: refused", log });
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(nested)) as { block?: boolean; reason?: string };
			expect(refused).toEqual({ block: true, reason: "pre-commit-check: refused" });
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
			expect(refused.reason).toContain("rendered script is missing");
			expect(refused.reason).toContain("kendex refresh");
			expect(refused.reason).not.toContain("No such file or directory");
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
				expect(refused.reason, document).toContain("could not be read");
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
			registerRendered(join(project, ".pi"), "tool_call", "Bash", customCommand(log, "the project's guard refused", 2));
			renderUserStub(agentDir, "audit", { exitCode: 2, stderr: "the global guard refused", log: globalLog });
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "git push" } }, { cwd: project, isProjectTrusted: () => false });
			expect(refused).toEqual({ block: true, reason: "the global guard refused" });
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

	// The issue's second Done-when: the carrier reads the names kendex renders,
	// so a move on either side reds here rather than turning a hook silently
	// off. Four pins, one case: the listener, the command, the tool vocabulary
	// and the per-guard settings.
	test("the names the carrier reads are the ones kendex renders", () => {
		const crate = join(import.meta.dir, "..", "..", "..", "crates", "core", "src");

		const caps = readFileSync(join(crate, "harness", "caps.rs"), "utf8");
		const listeners = caps.match(/pub fn pi_listener\(event: &str\) -> Option<&'static str> \{([\s\S]*?)\n\}/);
		expect(listeners, "pi_listener not found in crates/core/src/harness/caps.rs").not.toBeNull();
		const arm = listeners![1]!.match(/"PreToolUse" => Some\("([^"]+)"\)/);
		expect(arm, `no PreToolUse arm in pi_listener: ${listeners![1]}`).not.toBeNull();
		expect(TOOL_CALL_LISTENER).toBe(arm![1]!);

		const targets = readFileSync(join(crate, "engine", "targets.rs"), "utf8");
		const piHook = targets.match(/fn pi_hook\(env: &Env, scope: &Scope, name: &str\) -> HookTarget \{([\s\S]*?)\n\}/);
		expect(piHook, "fn pi_hook not found in crates/core/src/engine/targets.rs").not.toBeNull();
		const templates = [...piHook![1]!.matchAll(/"(bash \\"[^"]*\{\}[^"]*\\")"/g)].map(([, template]) => template!.replaceAll('\\"', '"'));
		expect(templates.length, `no command templates in fn pi_hook: ${piHook![1]}`).toBe(2);
		const root = "/x/.pi/kendex";
		for (const template of templates) {
			// The project template's `{}` is the tail under `.pi/`, the global's
			// the whole path — and each is kendex's only under its own scope.
			const project = template.includes("$(git");
			const filled = template.replace("{}", project ? "kendex/hooks/guard.sh" : `${root}/hooks/guard.sh`);
			expect(renderedName(root, filled, project ? "project" : "global"), template).toBe("guard");
			expect(renderedName(root, filled, project ? "global" : "project"), template).toBe("");
		}
		// A command of the person's that names such a path is not one of ours,
		// and one spelling of this root is every spelling of it.
		expect(renderedName(root, 'bash "/opt/kendex/hooks/guard.sh"', "global")).toBe("");
		expect(renderedName("/srv/pi-agent/kendex", 'bash "/srv/old/../pi-agent/kendex/hooks/guard.sh"', "global")).toBe("guard");

		const vocab = readFileSync(join(crate, "render", "vocab", "mod.rs"), "utf8");
		const table = vocab.match(/pub fn claude_tool_name\(tool: &str\) -> String \{([\s\S]*?)\n\}/);
		expect(table, "claude_tool_name not found in crates/core/src/render/vocab/mod.rs").not.toBeNull();
		const arms = new Map<string, string>();
		for (const [, names, claude] of table![1]!.matchAll(/((?:"[a-z]+"\s*\|\s*)*"[a-z]+")\s*=> "([A-Za-z]+)"\.into\(\)/g)) {
			for (const [, name] of names!.matchAll(/"([a-z]+)"/g)) arms.set(name!, claude!);
		}
		expect(arms.get("find"), `arms read: ${[...arms].join(",")}`).toBe("Glob");
		// An unmapped built-in keeps its own id, the Rust fallthrough.
		for (const tool of PI_BUILTIN_TOOLS) expect(claudeToolName(tool), tool).toBe(arms.get(tool) ?? tool);

		const manifest = readFileSync(join(import.meta.dir, "..", "..", "..", "kendex.toml"), "utf8");
		const bundle = manifest.match(/\[bundles\.commit-guards\][\s\S]*?\nhooks = \[([\s\S]*?)\n\]/);
		expect(bundle, "[bundles.commit-guards] hooks not found in kendex.toml").not.toBeNull();
		const carried = [...bundle![1]!.matchAll(/"([^"]+)"/g)].map(([, name]) => name!);
		for (const name of GUARD_SETTING_NAMES) expect(carried, name).toContain(name);
	});
});
