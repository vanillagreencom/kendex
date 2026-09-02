import { describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import piHooks, { GUARD_SETTING_NAMES } from "../extensions/hooks.ts";
import { registeredHooks, renderedName, TOOL_CALL_LISTENER } from "../extensions/registry.ts";
import { claudeToolInput, claudeToolName, PI_BUILTIN_TOOLS } from "../extensions/vocab.ts";
import {
	CONFIG_ID,
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

			// It is code the project ships, so it is behind Pi's trust answer
			// exactly as a project script is.
			writeFileSync(log, "");
			expect(await handler({ toolName: "bash", input: { command: "git push" } }, { cwd: project, isProjectTrusted: () => false })).toBeUndefined();
			expect(readLog(log)).toBe("");
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

	test("the registration's matcher decides which tool calls it judges", async () => {
		const project = initCleanRustRepo("pi-hooks-matcher-");
		const reads = join(project, "reads.log");
		const every = join(project, "every.log");
		try {
			const root = join(project, ".pi");
			registerRendered(root, "tool_call", "Read", customCommand(reads, "reads only", 0));
			registerRendered(root, "tool_call", undefined, customCommand(every, "every tool", 0));
			const handler = installToolCallHandler();

			// kendex writes the matcher in the hook author's words and Pi names
			// the tool in its own: `Read` covers `read` and nothing else.
			await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project));
			expect(readLog(reads)).toBe("");
			expect(JSON.parse(readLog(every))).toEqual({ tool_name: "Bash", tool_input: { command: "ls" } });

			writeFileSync(every, "");
			await handler({ toolName: "read", input: { path: "/etc/hosts" } }, trusted(project));
			// Pi keys it `path`; the hook was authored against Claude Code's
			// `file_path`, and that is what reaches it.
			expect(JSON.parse(readLog(reads))).toEqual({ tool_name: "Read", tool_input: { file_path: "/etc/hosts" } });
			expect(readLog(every)).not.toBe("");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// The registration asks for a budget in seconds and the setting is the
	// person's ceiling over it, so a hook runs to the time it declares and
	// nothing runs past what the person allowed.
	test("the declared timeout bounds the run, and the setting bounds the declaration", async () => {
		const project = initCleanRustRepo("pi-hooks-budget-registry-");
		try {
			const root = join(project, ".pi");
			registerRendered(root, "tool_call", "Bash", "cat > /dev/null; sleep 5", 1);
			const handler = installToolCallHandler();
			const declared = await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project)) as { reason?: string };
			expect(declared.reason).toContain("timed out after 1000ms");

			// The same declaration under a lower ceiling is cut at the ceiling.
			writeFileSync(join(root, "settings.json"), JSON.stringify({
				kendex: { extensionManager: { config: { [CONFIG_ID]: { hookTimeoutMs: 300 } } } },
			}));
			const capped = await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project)) as { reason?: string };
			expect(capped.reason).toContain("timed out after 300ms");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// The registry is written under the listener name kendex restates the hook
	// event as, and read under the one this carrier names. A rename on either
	// side would be every hook silently off, so the two are held together.
	test("the listener the carrier reads is the one caps.rs maps PreToolUse onto", () => {
		const caps = readFileSync(join(import.meta.dir, "..", "..", "..", "crates", "core", "src", "harness", "caps.rs"), "utf8");
		const map = caps.match(/pub fn pi_listener\(event: &str\) -> Option<&'static str> \{([\s\S]*?)\n\}/);
		expect(map, "pi_listener not found in crates/core/src/harness/caps.rs").not.toBeNull();
		const arm = map![1]!.match(/"PreToolUse" => Some\("([^"]+)"\)/);
		expect(arm, `no PreToolUse arm in pi_listener: ${map![1]}`).not.toBeNull();
		expect(TOOL_CALL_LISTENER).toBe(arm![1]!);
	});

	// A hook of kendex's own is spawned at the path its registry anchors rather
	// than through the command that names it, so the carrier has to recognise
	// that command — and recognise nothing else, or a custom hook naming a
	// script would spawn it instead of running. The renderer writes the command;
	// its own templates are filled here and read back.
	test("the commands the recognizer accepts are the ones targets.rs writes", () => {
		const targets = readFileSync(join(import.meta.dir, "..", "..", "..", "crates", "core", "src", "engine", "targets.rs"), "utf8");
		const body = targets.match(/fn pi_hook\(env: &Env, scope: &Scope, name: &str\) -> HookTarget \{([\s\S]*?)\n\}/);
		expect(body, "fn pi_hook not found in crates/core/src/engine/targets.rs").not.toBeNull();
		const templates = [...body![1]!.matchAll(/"(bash \\"[^"]*\{\}[^"]*\\")"/g)].map(([, template]) => template!.replaceAll('\\"', '"'));
		expect(templates.length, `no command templates in fn pi_hook: ${body![1]}`).toBe(2);
		const root = "/x/.pi/kendex";
		for (const template of templates) {
			// The global template's `{}` is the whole path; the project's is the
			// tail under `.pi/`, which is where the renderer splits them.
			const filled = template.replace("{}", template.includes("$(git") ? "kendex/hooks/guard.sh" : `${root}/hooks/guard.sh`);
			expect(renderedName(root, filled), template).toBe("guard");
		}

		// And a command of the person's that names one is not one of ours.
		expect(renderedName(root, 'grep kendex/hooks/guard.sh .')).toBe("");
		expect(renderedName(root, 'bash "/opt/kendex/hooks/guard.sh"')).toBe("");
	});
});

describe("pi-hooks registry dispatch: the path a rendered hook is spawned at", () => {
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
});

describe("pi-hooks registry dispatch: one installation runs once", () => {
	test("the project's copy of a rendered guard answers, and the global copy does not", async () => {
		const project = initCleanRustRepo("pi-hooks-shadow-");
		const agentDir = mkdtempSync(join(tmpdir(), "pi-hooks-shadow-global-"));
		const projectLog = join(project, "project.log");
		const globalLog = join(agentDir, "global.log");
		const savedAgentDir = process.env.PI_CODING_AGENT_DIR;
		process.env.PI_CODING_AGENT_DIR = agentDir;
		try {
			// The project's copy allows and the global one refuses, so the
			// verdict says which ran: were both dispatched, the global copy
			// would refuse a call the project's had already let through.
			renderStub(project, "pre-commit-check", { exitCode: 0, log: projectLog });
			renderUserStub(agentDir, "pre-commit-check", { exitCode: 2, stderr: "global copy refused", log: globalLog });
			const handler = installToolCallHandler();
			expect(await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project))).toBeUndefined();
			expect(readLog(projectLog)).toContain("git commit -m x");
			expect(readLog(globalLog)).toBe("");
		} finally {
			if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
			rmSync(project, { recursive: true, force: true });
			rmSync(agentDir, { recursive: true, force: true });
		}
	});

	// Two commands of the person's own are two hooks: nothing but the command
	// identifies them, so neither shadows the other.
	test("two command-bodied hooks under one matcher both run", async () => {
		const project = initCleanRustRepo("pi-hooks-two-custom-");
		const first = join(project, "first.log");
		const second = join(project, "second.log");
		try {
			const root = join(project, ".pi");
			registerRendered(root, "tool_call", "Bash", customCommand(first, "first", 0));
			registerRendered(root, "tool_call", "Bash", customCommand(second, "second", 0));
			const handler = installToolCallHandler();
			expect(await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project))).toBeUndefined();
			expect(readLog(first)).not.toBe("");
			expect(readLog(second)).not.toBe("");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});
});

describe("pi-hooks registry dispatch: a registry that did not answer", () => {
	// The rule this module already states for a hook: a guard that did not run
	// does not stand aside. A registry is a file only kendex writes, so it not
	// parsing is not the person standing their guards down — and this repo
	// commits its own .pi/kendex/hooks.json, where a rebase leaves markers.
	test("a registry that exists and cannot be read refuses the call", async () => {
		const project = initCleanRustRepo("pi-hooks-unreadable-");
		const registry = join(project, ".pi", "kendex", "hooks.json");
		try {
			renderStub(project, "pre-commit-check", { exitCode: 0, log: join(project, "unused.log") });
			const handler = installToolCallHandler();
			// The control: the same fixture, readable.
			expect(await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project))).toBeUndefined();

			const malformed = ['{"hooks": {"tool_call": {}}}', '{"hooks": {"tool_call": [{"matcher": "Bash", "hooks": {}}]}}'];
			for (const broken of ["<<<<<<< HEAD\n{}\n=======\n{}\n>>>>>>> main\n", '{"hooks": {"tool_call": [', ...malformed]) {
				writeFileSync(registry, broken);
				const refused = await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project)) as { block?: boolean; reason?: string };
				expect(refused.block, broken).toBe(true);
				expect(refused.reason).toContain("could not be read");
				expect(refused.reason).toContain(registry);
			}
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// ENOTDIR is the other shape of absent: a regular file standing where
	// `kendex/` should be a directory holds no registry, so the call is allowed
	// rather than refused for a document nobody wrote.
	test("a file where the kendex directory should be allows the call", async () => {
		const project = initCleanRustRepo("pi-hooks-notdir-");
		try {
			writeFileSync(join(project, ".pi", "kendex"), "not a directory\n");
			const handler = installToolCallHandler();
			expect(await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project))).toBeUndefined();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// An absent registry is the one reading that allows: kendex has installed
	// no hook here, and the package installs from npm on its own.
	test("no registry at all allows the call", async () => {
		const project = initCleanRustRepo("pi-hooks-absent-");
		try {
			const handler = installToolCallHandler();
			expect(await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project))).toBeUndefined();
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// An untrusted project's registry must not be able to stop the session:
	// refusing on its parse failure would hand a clone nobody trusted a switch
	// for every tool call.
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

describe("pi-hooks registry dispatch: names, matchers and budgets at their edges", () => {
	// A hook's name is its own file name, so the settings lookup must not
	// answer with what every object inherits. It did: `toString` resolved to a
	// function, the setting read as off, and the guard was skipped in silence.
	test("a guard named after an inherited property still runs", async () => {
		const project = initCleanRustRepo("pi-hooks-proto-");
		const log = join(project, "proto.log");
		try {
			for (const name of ["toString", "constructor", "hasOwnProperty"]) {
				writeFileSync(log, "");
				renderStub(project, name, { exitCode: 2, stderr: `${name}: refused`, log });
				const handler = installToolCallHandler();
				const refused = await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project)) as { block?: boolean; reason?: string };
				expect(refused, name).toEqual({ block: true, reason: `${name}: refused` });
				rmSync(join(project, ".pi", "kendex"), { recursive: true, force: true });
			}
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// Every guard the settings surface names one by one has to be a hook this
	// catalog ships, or a toggle names nothing and a hook has no toggle.
	test("every per-guard setting names a hook the commit-guards bundle carries", () => {
		const manifest = readFileSync(join(import.meta.dir, "..", "..", "..", "kendex.toml"), "utf8");
		const bundle = manifest.match(/\[bundles\.commit-guards\][\s\S]*?\nhooks = \[([\s\S]*?)\n\]/);
		expect(bundle, "[bundles.commit-guards] hooks not found in kendex.toml").not.toBeNull();
		const carried = [...bundle![1]!.matchAll(/"([^"]+)"/g)].map(([, name]) => name!);
		expect(carried.length).toBeGreaterThan(3);
		for (const name of GUARD_SETTING_NAMES) expect(carried, name).toContain(name);
	});

	test("an empty or star matcher runs for any tool, and one that will not compile judges the call", async () => {
		const project = initCleanRustRepo("pi-hooks-matchers-");
		try {
			const root = join(project, ".pi");
			for (const [matcher, log] of [["", "empty"], ["*", "star"], ["Bash[", "broken"]] as const) {
				const path = join(project, `${log}.log`);
				rmSync(join(root, "kendex"), { recursive: true, force: true });
				registerRendered(root, "tool_call", matcher, customCommand(path, `${log} ran`, 0));
				const handler = installToolCallHandler();
				await handler({ toolName: "read", input: { path: "/etc/hosts" } }, trusted(project));
				expect(readLog(path), matcher).not.toBe("");
			}
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("a non-command registration never spawns, and a zero timeout takes the ceiling", async () => {
		const project = initCleanRustRepo("pi-hooks-edges-");
		const log = join(project, "edges.log");
		try {
			const root = join(project, ".pi");
			const registry = join(root, "kendex", "hooks.json");
			mkdirSync(join(root, "kendex"), { recursive: true });
			writeFileSync(registry, JSON.stringify({
				hooks: { tool_call: [{ matcher: "Bash", hooks: [{ type: "http", command: customCommand(log, "must not run", 2) }] }] },
			}));
			const handler = installToolCallHandler();
			expect(await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project))).toBeUndefined();
			expect(readLog(log)).toBe("");

			// timeout: 0 asks for nothing, so the ceiling is the budget and the
			// hook runs rather than being cut off at zero.
			rmSync(join(root, "kendex"), { recursive: true, force: true });
			registerRendered(root, "tool_call", "Bash", customCommand(log, "ran to the ceiling", 2), 0);
			const refused = await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project)) as { reason?: string };
			expect(refused.reason).toBe("ran to the ceiling");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// A refusal reaches the model, and a command-bodied hook's text is the
	// person's — it can hold a credential written inline in kendex.toml.
	test("a refusal names where a command-bodied hook is registered, never its text", async () => {
		const project = initCleanRustRepo("pi-hooks-label-");
		const secret = "kendex-941-inline-token";
		try {
			// A registration this call does not match stands ahead of it in the
			// file, so the ordinal is a position in the file rather than in the
			// list this call happened to build — the label is there so a person
			// can find the entry, and a per-call number finds nothing.
			registerRendered(join(project, ".pi"), "tool_call", "Read", "exit 0");
			registerRendered(join(project, ".pi"), "tool_call", "Bash", `echo ${secret} > /dev/null; exit 3`);
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project)) as { reason?: string };
			expect(refused.reason).toContain("custom hook 2 in ");
			expect(refused.reason).not.toContain(secret);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// Pi names its tools its own way and a matcher is authored in Claude's.
	// A case fold is not that map: `find` is `Glob`, `ls` is `LS`.
	test("Pi's tool names are said the way a matcher writes them", () => {
		const vocab = readFileSync(join(import.meta.dir, "..", "..", "..", "crates", "core", "src", "render", "vocab", "mod.rs"), "utf8");
		const body = vocab.match(/pub fn claude_tool_name\(tool: &str\) -> String \{([\s\S]*?)\n\}/);
		expect(body, "claude_tool_name not found in crates/core/src/render/vocab/mod.rs").not.toBeNull();
		const arms = new Map<string, string>();
		for (const [, names, claude] of body![1]!.matchAll(/((?:"[a-z]+"\s*\|\s*)*"[a-z]+")\s*=> "([A-Za-z]+)"\.into\(\)/g)) {
			for (const [, name] of names!.matchAll(/"([a-z]+)"/g)) arms.set(name!, claude!);
		}
		expect(arms.get("find"), `arms read: ${[...arms].join(",")}`).toBe("Glob");
		for (const tool of PI_BUILTIN_TOOLS) {
			// An unmapped built-in keeps its own id, the Rust fallthrough.
			expect(claudeToolName(tool), tool).toBe(arms.get(tool) ?? tool);
		}
	});
});

// Trust withholds a project's hooks; saying nothing leaves that reading as
// "kendex installed none here", which is the one thing it is not.
test("an untrusted project's withheld hooks are named once, not on every call", async () => {
	const project = initCleanRustRepo("pi-hooks-withheld-");
	const notices: string[] = [];
	try {
		renderStub(project, "pre-commit-check", { exitCode: 2, stderr: "must not run", log: join(project, "withheld.log") });
		const handler = installToolCallHandler();
		const ctx = { cwd: project, isProjectTrusted: () => false, hasUI: true, ui: { notify: (message: string) => notices.push(message) } };
		expect(await handler({ toolName: "bash", input: { command: "ls" } }, ctx)).toBeUndefined();
		expect(notices).toHaveLength(1);
		expect(notices[0]).toContain("1 kendex hook(s)");
		expect(notices[0]).toContain("not running");
		expect(notices[0]).toContain(project);

		await handler({ toolName: "bash", input: { command: "ls" } }, ctx);
		expect(notices).toHaveLength(1);
	} finally {
		rmSync(project, { recursive: true, force: true });
	}
});

describe("pi-hooks registry dispatch: a rendered hook whose script is gone", () => {
	test("a healthy global guard answers over a broken project registration", async () => {
		const project = initCleanRustRepo("pi-hooks-broken-project-");
		const agentDir = mkdtempSync(join(tmpdir(), "pi-hooks-broken-global-"));
		const globalLog = join(agentDir, "global.log");
		const savedAgentDir = process.env.PI_CODING_AGENT_DIR;
		process.env.PI_CODING_AGENT_DIR = agentDir;
		try {
			// The project registers the guard and its render is gone — a partial
			// apply, or a registry committed from a machine whose renders this
			// clone does not carry. The person's own copy still judges.
			registerProjectHook(project, "pre-commit-check");
			renderUserStub(agentDir, "pre-commit-check", { exitCode: 2, stderr: "global copy refused", log: globalLog });
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "git commit -m x" } }, trusted(project)) as { reason?: string };
			expect(refused.reason).toBe("global copy refused");
			expect(readLog(globalLog)).toContain("git commit -m x");
		} finally {
			if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
			rmSync(project, { recursive: true, force: true });
			rmSync(agentDir, { recursive: true, force: true });
		}
	});

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

	test("a global registration's missing render is not said to be the project's", async () => {
		const agentDir = process.env.PI_CODING_AGENT_DIR!;
		const workspace = mkdtempSync(join(tmpdir(), "pi-hooks-global-gone-cwd-"));
		try {
			// A bare directory for a cwd, so there is no project scope at all and
			// the global registry is the one that named the hook.
			registerRendered(agentDir, "tool_call", "Bash", `bash "${join(agentDir, "kendex", "hooks", "audit.sh")}"`);
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "ls" } }, { cwd: workspace, isProjectTrusted: () => false }) as { block?: boolean; reason?: string };
			expect(refused.block).toBe(true);
			expect(refused.reason).toContain("rendered script is missing");
			expect(refused.reason).not.toContain("this project");
			// `kendex remove` without -g acts on the project, so it repairs nothing here.
			expect(refused.reason).not.toContain("kendex remove");
		} finally {
			rmSync(join(agentDir, "kendex"), { recursive: true, force: true });
			rmSync(workspace, { recursive: true, force: true });
		}
	});

	test("a render this session may not stat is left to the spawn", async () => {
		const project = initCleanRustRepo("pi-hooks-unreadable-render-");
		const hooksDir = join(project, ".pi", "kendex", "hooks");
		try {
			// The render is there and executable; its directory is not readable.
			// Calling that missing would send the person to kendex refresh, which
			// hits the same denial, and drop bash's own accurate 126.
			renderStub(project, "audit", { exitCode: 0, log: join(project, "audit.log") });
			chmodSync(hooksDir, 0o000);
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(refused.block).toBe(true);
			expect(refused.reason).not.toContain("rendered script is missing");
			expect(refused.reason).toContain("exited 126");
		} finally {
			chmodSync(hooksDir, 0o755);
			rmSync(project, { recursive: true, force: true });
		}
	});
});

describe("pi-hooks registry dispatch: the counts and the vocabulary", () => {
	// The notice fires once and is never corrected, so its number has to be
	// what the project installed rather than what the first call matched.
	test("the withheld count is the project's registrations, not this call's", async () => {
		const project = initCleanRustRepo("pi-hooks-count-");
		const notices: string[] = [];
		try {
			const root = join(project, ".pi");
			for (const matcher of ["Bash", "Bash", "Bash", "Read", "Read"]) {
				registerRendered(root, "tool_call", matcher, "exit 0");
			}
			// Nor what could never run: the notice says what trusting the
			// workspace would arm, and these five are all of it.
			const path = join(root, "kendex", "hooks.json");
			const registry = JSON.parse(readFileSync(path, "utf8"));
			registry.hooks.tool_call[0].hooks.push({ type: "prompt", command: "exit 0" }, { type: "command", command: "" }, "junk", 7);
			writeFileSync(path, JSON.stringify(registry));
			const handler = installToolCallHandler();
			// A read call, which two of the five match.
			await handler({ toolName: "read", input: { path: "/etc/hosts" } }, {
				cwd: project,
				isProjectTrusted: () => false,
				hasUI: true,
				ui: { notify: (message: string) => notices.push(message) },
			});
			expect(notices).toHaveLength(1);
			expect(notices[0]).toContain("5 kendex hook(s)");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("a global registry that cannot be read refuses too", async () => {
		const agentDir = mkdtempSync(join(tmpdir(), "pi-hooks-global-broken-"));
		const workspace = mkdtempSync(join(tmpdir(), "pi-hooks-global-broken-cwd-"));
		const savedAgentDir = process.env.PI_CODING_AGENT_DIR;
		process.env.PI_CODING_AGENT_DIR = agentDir;
		try {
			// The scope `sudo kendex apply -g` leaves root-owned.
			mkdirSync(join(agentDir, "kendex"), { recursive: true });
			writeFileSync(join(agentDir, "kendex", "hooks.json"), "{ not json");
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "ls" } }, { cwd: workspace, isProjectTrusted: () => false }) as { block?: boolean; reason?: string };
			expect(refused.block).toBe(true);
			expect(refused.reason).toContain(join(agentDir, "kendex", "hooks.json"));
		} finally {
			if (savedAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = savedAgentDir;
			rmSync(agentDir, { recursive: true, force: true });
			rmSync(workspace, { recursive: true, force: true });
		}
	});

	// The read is what happens once per project per session. A registry that
	// will not parse counts nothing, and re-reading it on every call is the
	// unbounded work on a file an untrusted party sizes that the skip prevents.
	test("an untrusted project's unparseable registry is read once a session", async () => {
		const project = initCleanRustRepo("pi-hooks-unparseable-once-");
		const notices: string[] = [];
		try {
			const path = join(project, ".pi", "kendex", "hooks.json");
			mkdirSync(join(path, ".."), { recursive: true });
			writeFileSync(path, "{ not json");
			const handler = installToolCallHandler();
			const ctx = { cwd: project, isProjectTrusted: () => false, hasUI: true, ui: { notify: (m: string) => notices.push(m) } };
			expect(await handler({ toolName: "bash", input: { command: "ls" } }, ctx)).toBeUndefined();

			// A registry a second read would count one hook from, and say so.
			rmSync(path);
			registerRendered(join(project, ".pi"), "tool_call", "Bash", "exit 0");
			expect(await handler({ toolName: "bash", input: { command: "ls" } }, ctx)).toBeUndefined();
			expect(notices).toEqual([]);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// The global registry is read second, so a project scope that answered must
	// not swallow its failure — that would allow every call in the session.
	test("a global registry that cannot be read refuses behind a healthy project", async () => {
		const project = initCleanRustRepo("pi-hooks-global-behind-");
		const agentDir = process.env.PI_CODING_AGENT_DIR!;
		try {
			registerRendered(join(project, ".pi"), "tool_call", "Bash", "exit 0");
			mkdirSync(join(agentDir, "kendex"), { recursive: true });
			writeFileSync(join(agentDir, "kendex", "hooks.json"), "{ not json");
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "ls" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(refused.block).toBe(true);
			expect(refused.reason).toContain(join(agentDir, "kendex", "hooks.json"));
		} finally {
			rmSync(join(agentDir, "kendex"), { recursive: true, force: true });
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("the vocabulary table covers exactly the tools Pi ships", () => {
		expect(PI_BUILTIN_TOOLS).toEqual(["bash", "edit", "find", "grep", "ls", "powershell", "read", "write"]);
		for (const [tool, claude] of [["bash", "Bash"], ["edit", "Edit"], ["find", "Glob"], ["grep", "Grep"], ["ls", "LS"], ["powershell", "powershell"], ["read", "Read"], ["write", "Write"]] as const) {
			expect(claudeToolName(tool), tool).toBe(claude);
		}
		// An extension's own tool keeps its id, so a matcher naming it matches.
		expect(claudeToolName("my_tool")).toBe("my_tool");
	});

	test("a matcher naming an extension's own tool matches it", async () => {
		const project = initCleanRustRepo("pi-hooks-extension-tool-");
		const log = join(project, "mytool.log");
		try {
			registerRendered(join(project, ".pi"), "tool_call", "my_tool", customCommand(log, "my_tool: refused", 2));
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "my_tool", input: { anything: 1 } }, trusted(project)) as { reason?: string };
			expect(refused.reason).toBe("my_tool: refused");
			// And the payload carries the id, not a name invented for it.
			expect(JSON.parse(readLog(log)).tool_name).toBe("my_tool");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	test("the path rename is per tool, and reshapes nothing else", () => {
		for (const tool of ["Read", "Write", "Edit"]) {
			expect(claudeToolInput(tool, { path: "/a", offset: 2 }), tool).toEqual({ file_path: "/a", offset: 2 });
		}
		// Not a path tool: Bash's own keys ride through untouched.
		expect(claudeToolInput("Bash", { command: "ls", path: "/a" })).toEqual({ command: "ls", path: "/a" });
		// Pi's edit shape is not Claude Code's, and is not mapped onto it.
		expect(claudeToolInput("Edit", { path: "/a", edits: [{ oldText: "x", newText: "y" }] }))
			.toEqual({ file_path: "/a", edits: [{ oldText: "x", newText: "y" }] });
		expect(claudeToolInput("Read", undefined)).toEqual({});
	});

	// The count has one consumer, the notice. With nobody to tell — a headless
	// session, or a project already told — an untrusted workspace's registry is
	// not parsed: work with no consumer, on a file whose size that untrusted
	// party chooses.
	test("an untrusted project's registry is not counted when nothing can say so", () => {
		const project = initCleanRustRepo("pi-hooks-nocount-");
		try {
			registerRendered(join(project, ".pi"), "tool_call", "Bash", "exit 0");
			expect(registeredHooks(TOOL_CALL_LISTENER, "Bash", project, false, true).withheld).toBe(1);
			expect(registeredHooks(TOOL_CALL_LISTENER, "Bash", project, false, false).withheld).toBe(0);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	// "Once per session" has to survive the session ending: this module outlives
	// one and can be installed more than once in a process.
	test("a fresh session is told again about withheld hooks", async () => {
		const project = initCleanRustRepo("pi-hooks-resession-");
		const notices: string[] = [];
		try {
			writeFileSync(join(project, ".pi", "settings.json"), JSON.stringify({
				kendex: { extensionManager: { config: { [CONFIG_ID]: { sessionDriftCheck: false } } } },
			}));
			registerRendered(join(project, ".pi"), "tool_call", "Bash", "exit 0");
			const handlers = new Map<string, (event: Record<string, unknown>, ctx: Record<string, unknown>) => Promise<unknown>>();
			piHooks({ on: (event: string, cb: never) => handlers.set(event, cb) } as never);
			const ctx = { cwd: project, isProjectTrusted: () => false, hasUI: true, ui: { notify: (m: string) => notices.push(m) } };

			await handlers.get("tool_call")!({ toolName: "bash", input: { command: "ls" } }, ctx);
			await handlers.get("tool_call")!({ toolName: "bash", input: { command: "ls" } }, ctx);
			expect(notices).toHaveLength(1);

			await handlers.get("session_start")!({ reason: "resume" }, ctx);
			await handlers.get("tool_call")!({ toolName: "bash", input: { command: "ls" } }, ctx);
			expect(notices).toHaveLength(2);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});
});
