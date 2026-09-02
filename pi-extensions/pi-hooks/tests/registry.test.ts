import { describe, expect, test } from "bun:test";
import { readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { renderedName, TOOL_CALL_LISTENER } from "../extensions/registry.ts";
import {
	CONFIG_ID,
	initRustRepo,
	installToolCallHandler,
	readLog,
	registerRendered,
	renderStub,
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
			expect(JSON.parse(readLog(reads))).toEqual({ tool_name: "Read", tool_input: { path: "/etc/hosts" } });
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
		for (const template of templates) {
			expect(renderedName(template.replace("{}", "kendex/hooks/guard.sh")), template).toBe("guard");
		}

		// And a command of the person's that names one is not one of ours.
		expect(renderedName('rg -n kendex/hooks/guard.sh .')).toBe("");
	});
});
