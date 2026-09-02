import { describe, expect, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { GUARD_SETTING_NAMES } from "../extensions/hooks.ts";
import {
	renderedName,
	SESSION_START_LISTENER,
	TOOL_CALL_LISTENER,
	TOOL_RESULT_LISTENER,
	TURN_END_LISTENER,
} from "../extensions/registry.ts";
import { claudeSessionSource, claudeToolName, PI_BUILTIN_TOOLS, PI_SESSION_REASONS } from "../extensions/vocab.ts";
import {
	type Carrier,
	initRustRepo,
	installCarrier,
	installToolCallHandler,
	readLog,
	projectCommand,
	registerProjectHook,
	registerRendered,
	renderStub,
	renderUserStub,
	runGit,
	toolResultEvent,
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

/** The session-start dispatch is fire-and-forget, like the drift report beside
 * it: wait for `sent` to reach `n`, or ~2s. */
async function waitForSent(sent: unknown[], n: number): Promise<void> {
	for (let i = 0; i < 100 && sent.length < n; i++) await new Promise((r) => setTimeout(r, 20));
}

/** Enough time for a hook that was going to speak to have spoken. */
async function grace(): Promise<void> {
	await new Promise((r) => setTimeout(r, 300));
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

			registerRendered(join(project, ".pi"), "tool_call", "Bash", customCommand(log, "audit: this branch is protected", 2));
			const refused = await handler({ toolName: "bash", input: { command: "git push" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(refused).toEqual({ block: true, reason: "audit: this branch is protected" });
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
			renderStub(project, "audit", { exitCode: 2, stderr: "audit: refused", log });
			const handler = installToolCallHandler();
			const refused = await handler({ toolName: "bash", input: { command: "git push" } }, trusted(project)) as { block?: boolean; reason?: string };
			expect(refused).toEqual({ block: true, reason: "audit: refused" });
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

	// The second Done-when of KEN-941 and of KEN-1189: the carrier reads the
	// names kendex renders, so a move on either side reds here rather than
	// turning a hook silently off. Five pins, one case: the listener keys, the
	// session vocabulary, the command, the tool vocabulary and the per-guard
	// settings.
	test("the names the carrier reads are the ones kendex renders", () => {
		const crate = join(import.meta.dir, "..", "..", "..", "crates", "core", "src");

		const caps = readFileSync(join(crate, "harness", "caps.rs"), "utf8");
		const listeners = caps.match(/pub fn pi_listener\(event: &str\) -> Option<&'static str> \{([\s\S]*?)\n\}/);
		expect(listeners, "pi_listener not found in crates/core/src/harness/caps.rs").not.toBeNull();
		// Every key `pi_listener` can return, against the constant the carrier
		// dispatches it under. A key on one side and not the other is a hook
		// kendex registers and labels enforced with nothing to run it — the
		// defect KEN-941 closed on `tool_call` and KEN-1189 on the other three.
		const listenerArms = new Map([...listeners![1]!.matchAll(/"(\w+)"(?:\s*\|\s*"(\w+)")* => Some\("([^"]+)"\)/g)]
			.map(([, first, , listener]) => [first!, listener!]));
		expect([...new Set(listenerArms.values())].sort(), `arms read: ${listeners![1]}`).toEqual(
			[SESSION_START_LISTENER, TOOL_CALL_LISTENER, TOOL_RESULT_LISTENER, TURN_END_LISTENER].sort(),
		);
		expect(listenerArms.get("PreToolUse")).toBe(TOOL_CALL_LISTENER);
		expect(listenerArms.get("PostToolUse")).toBe(TOOL_RESULT_LISTENER);
		expect(listenerArms.get("Stop")).toBe(TURN_END_LISTENER);
		expect(listenerArms.get("SessionStart")).toBe(SESSION_START_LISTENER);

		// And the session vocabulary: every reason Pi's `session_start` carries
		// has a `SessionStart` source, or a hook matchered on one Claude Code
		// word never fires for the Pi reason that means it.
		for (const reason of PI_SESSION_REASONS) {
			expect(["startup", "resume", "clear"], reason).toContain(claudeSessionSource(reason));
		}
		expect(claudeSessionSource("startup")).toBe("startup");
		expect(claudeSessionSource("resume")).toBe("resume");
		expect(claudeSessionSource("reload")).toBe("resume");
		expect(claudeSessionSource("new")).toBe("clear");
		expect(claudeSessionSource("fork")).toBe("clear");

		const targets = readFileSync(join(crate, "engine", "targets.rs"), "utf8");
		const piHook = targets.match(/fn pi_hook\(env: &Env, scope: &Scope, name: &str\) -> HookTarget \{([\s\S]*?)\n\}/);
		expect(piHook, "fn pi_hook not found in crates/core/src/engine/targets.rs").not.toBeNull();
		// The global arm writes the path outright; the project arm hands the
		// script's place under the project to `project_command`, which is what
		// `projectCommand` renders here out of that function. A rename or a
		// respelling on the Rust side throws there.
		const globalTemplate = piHook![1]!.match(/format!\("(bash \\"\{\}\\")"/);
		expect(globalTemplate, `no global command template in fn pi_hook: ${piHook![1]}`).not.toBeNull();
		expect(piHook![1]!, "fn pi_hook no longer renders its project command through project_command").toContain("project_command(&format!(");

		const project = "/x";
		const root = `${project}/.pi/kendex`;
		const script = `${root}/hooks/guard.sh`;
		expect(renderedName(root, globalTemplate![1]!.replaceAll('\\"', '"').replace("{}", script), undefined)).toBe("guard");
		expect(renderedName(root, projectCommand(".pi/kendex/hooks/guard.sh"), project)).toBe("guard");
		// A project command read out of the global registry names a file no
		// scope anchors, and is the person's own as far as this can tell.
		expect(renderedName(root, projectCommand(".pi/kendex/hooks/guard.sh"), undefined)).toBe("");
		// A command of the person's that names a file some other root holds is
		// not ours, nor is one naming a script outside the rendered directory —
		// and one spelling of this root is every spelling of it.
		expect(renderedName(root, 'bash "/opt/kendex/hooks/guard.sh"', undefined)).toBe("");
		expect(renderedName(root, projectCommand(".pi/kendex/guard.sh"), project)).toBe("");
		expect(renderedName("/srv/pi-agent/kendex", 'bash "/srv/old/../pi-agent/kendex/hooks/guard.sh"', undefined)).toBe("guard");

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

/**
 * KEN-1189: the same defect KEN-941 closed on `tool_call`, on the three
 * listeners `pi_listener` also maps hook events onto. kendex rendered the
 * registration and labelled it enforced; the carrier read one key. Every case
 * here opens with the control — the same fixture with nothing registered —
 * because a hook that runs proves nothing unless the silence before it is real.
 *
 * Pi refuses nothing on any of these three, so what a hook says is delivered
 * rather than obeyed, each through the one channel its listener has.
 */
describe("pi-hooks registry dispatch on the listeners Pi gives no verdict to", () => {
	/** The hook's stdout, or its stderr on a refusal, in the tool result the
	 * model reads — Claude Code's own `PostToolUse` exit-2 consequence. */
	test("a registered PostToolUse hook runs and its word lands on the tool result", async () => {
		const project = initCleanRustRepo("pi-hooks-post-tool-");
		const log = join(project, "post.log");
		try {
			const onToolResult = installCarrier().handler(TOOL_RESULT_LISTENER);
			const call = () => onToolResult(toolResultEvent("bash", { command: "git push" }, "Everything up-to-date"), trusted(project));

			// The control: a registry with nothing under this listener.
			expect(await call()).toBeUndefined();
			expect(readLog(log)).toBe("");

			registerRendered(join(project, ".pi"), TOOL_RESULT_LISTENER, "Bash", customCommand(log, "audit: that push is logged", 2));
			const patched = await call() as { content?: { type: string; text: string }[] };
			expect(patched.content?.map((block) => block.text)).toEqual(["Everything up-to-date", "audit: that push is logged"]);
			expect(JSON.parse(readLog(log))).toEqual({
				hook_event_name: "PostToolUse",
				tool_name: "Bash",
				tool_input: { command: "git push" },
				tool_response: "Everything up-to-date",
			});
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/** `Stop` and `TaskCompleted` take no matcher on Claude Code, so a matcher
	 * on this listener covers the turn rather than deciding a hook does not
	 * run — the registration below carries one no turn could ever equal. */
	test("a registered Stop hook runs whatever its matcher says, and steers what it said", async () => {
		const project = initCleanRustRepo("pi-hooks-turn-end-");
		const log = join(project, "stop.log");
		try {
			const carrier = installCarrier();
			const onTurnEnd = carrier.handler(TURN_END_LISTENER);

			await onTurnEnd({}, trusted(project));
			expect(carrier.sent).toHaveLength(0);
			expect(readLog(log)).toBe("");

			registerRendered(join(project, ".pi"), TURN_END_LISTENER, "Bash", customCommand(log, "audit: this branch is unpushed", 2));
			await onTurnEnd({}, trusted(project));
			expect(carrier.sent).toHaveLength(1);
			expect(carrier.sent[0]!.message.content).toBe("audit: this branch is unpushed");
			// Since pi#8022 only `triggerTurn: true` reaches a headless run
			// that is ending, which is the whole delivery available here.
			expect(carrier.sent[0]!.options).toEqual({ triggerTurn: true });
			expect(JSON.parse(readLog(log))).toEqual({ hook_event_name: "Stop", stop_hook_active: false });
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/** A `SessionStart` hook's stdout is the context it contributes, which is
	 * the one stream Claude Code routes into a model's context. The session is
	 * never held for it: the run is started and the words arrive when they do. */
	test("a registered SessionStart hook runs, and its matcher reads Pi's reason in Claude Code's words", async () => {
		const project = initCleanRustRepo("pi-hooks-session-");
		const log = join(project, "session.log");
		try {
			const carrier = installCarrier();
			const onSessionStart = carrier.handler(SESSION_START_LISTENER);

			onSessionStart({ type: "session_start", reason: "startup" }, trusted(project));
			await grace();
			expect(carrier.sent).toHaveLength(0);
			expect(readLog(log)).toBe("");

			// Matchered `startup`, which is what Pi's own `startup` is said as.
			registerRendered(
				join(project, ".pi"),
				SESSION_START_LISTENER,
				"startup",
				`cat >> ${JSON.stringify(log)}; echo "kendex: 2 items are outdated"; exit 0`,
			);
			onSessionStart({ type: "session_start", reason: "startup" }, trusted(project));
			await waitForSent(carrier.sent, 1);
			expect(carrier.sent).toHaveLength(1);
			expect(carrier.sent[0]!.message.content).toBe("kendex: 2 items are outdated");
			expect(carrier.sent[0]!.options).toEqual({ triggerTurn: false });
			expect(JSON.parse(readLog(log))).toEqual({ hook_event_name: "SessionStart", source: "startup" });

			// And the matcher decides: Pi's `resume` is Claude Code's `resume`,
			// which this registration does not name, so nothing runs for it.
			rmSync(log, { force: true });
			onSessionStart({ type: "session_start", reason: "resume" }, trusted(project));
			await grace();
			expect(carrier.sent).toHaveLength(1);
			expect(readLog(log)).toBe("");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/** The rule the `tool_call` gate states, on a listener with no call to
	 * refuse: kendex labels these hooks enforced, so a registry that exists and
	 * did not answer is said rather than read as no hooks installed. */
	test("a registry that exists and cannot be read is reported, not passed over", async () => {
		const project = initCleanRustRepo("pi-hooks-turn-end-unreadable-");
		try {
			const carrier = installCarrier();
			const onTurnEnd = carrier.handler(TURN_END_LISTENER);
			registerRendered(join(project, ".pi"), TURN_END_LISTENER, undefined, "exit 0");

			// The control: the same fixture, readable.
			await onTurnEnd({}, trusted(project));
			expect(carrier.sent).toHaveLength(0);

			writeFileSync(join(project, ".pi", "kendex", "hooks.json"), '{"hooks": {"turn_end": [');
			await onTurnEnd({}, trusted(project));
			expect(carrier.sent).toHaveLength(1);
			expect(carrier.sent[0]!.message.content).toContain("could not be read");
			expect(carrier.sent[0]!.message.content).toContain(TURN_END_LISTENER);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});
});
