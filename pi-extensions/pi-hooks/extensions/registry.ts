import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { piUserDir, projectRoot, projectTrusted } from "./config.js";

/**
 * The registry key a `PreToolUse` hook is rendered under. Pi has no per-hook
 * runner, so kendex restates each hook event as the listener Pi fires
 * (`crates/core/src/harness/caps.rs::pi_listener`) and keys the rendered
 * registry by that name. tests/hooks.test.ts holds this to that map: a rename
 * on either side is a registry written under one key and read under another,
 * which is every hook silently off.
 */
export const TOOL_CALL_LISTENER = "tool_call";

/** One hook the rendered registry asks the carrier to run. */
export interface RegisteredHook {
	/** The registered command, run through a shell exactly as kendex wrote it. */
	command: string;
	/**
	 * The rendered guard's script name when the command names one, `""` when it
	 * does not — a command-bodied hook is the person's own words and has no
	 * script of ours behind it. The per-guard settings and the refusal reasons
	 * are written in this name.
	 */
	name: string;
	/**
	 * The script that command runs, for a hook kendex rendered: the file under
	 * the same root the registration was read from, spawned directly.
	 *
	 * The command kendex writes for a project-scope hook spells its path
	 * `$(git rev-parse --show-toplevel)/.pi/…`, and git's answer is not always
	 * kendex's: a vendored checkout inside a project is its own git root while
	 * kendex renders — and this reads — at the project above it, and a project
	 * with no git at all has no answer to give. Both would run the wrong file
	 * or none. So a hook of ours is spawned at the path the registry it came
	 * from anchors, which is where kendex wrote it. A command that is not ours
	 * has no such path and is run as written.
	 */
	script?: string;
	/** Milliseconds the registration asks for, from its `timeout` in seconds. */
	budgetMs?: number;
}

/**
 * Whether a registration's matcher covers the tool being called. Absent, empty
 * and `*` cover every tool, as they do for the Claude Code registry this shape
 * comes from; anything else is a whole-string regex. It is read case
 * insensitively because kendex renders the matcher in the hook author's words
 * (`Bash`) and Pi names the tool in its own (`bash`) — the same two spellings
 * of one tool. A pattern no engine can compile falls back to comparing it as a
 * literal, so a matcher with a stray bracket runs its hook for the tool it
 * names rather than for none.
 */
function matches(matcher: unknown, toolName: string): boolean {
	if (typeof matcher !== "string") return true;
	const pattern = matcher.trim();
	if (pattern === "" || pattern === "*") return true;
	try {
		return new RegExp(`^(?:${pattern})$`, "iu").test(toolName);
	} catch {
		return pattern.toLowerCase() === toolName.toLowerCase();
	}
}

/**
 * The guard name a registered command runs, or `""` where the command is not
 * one kendex wrote for a hook of its own.
 *
 * `engine::targets::pi_hook` registers a rendered script as the whole command
 * `bash "<path>/kendex/hooks/<name>.sh"` at both scopes, so the whole command
 * is what is read: a custom hook that merely mentions such a path — grepping
 * for one, say — is the person's own command and must run as written rather
 * than spawn the script it names. tests/registry.test.ts fills the renderer's
 * own templates and holds this to them; a render this stops recognising falls
 * to the shell lane, which is where a command of the person's already goes.
 */
export function renderedName(command: string): string {
	return command.trim().match(/^bash "(?:[^"]*\/)?kendex\/hooks\/([^/"]+)\.sh"$/u)?.[1] ?? "";
}

/** The registrations one scope root holds for a listener, in file order. */
function readRegistry(root: string, listener: string, toolName: string): RegisteredHook[] {
	let parsed: unknown;
	try {
		parsed = JSON.parse(readFileSync(resolve(root, "hooks.json"), "utf8"));
	} catch {
		// No registry is kendex having installed no hook here, and an
		// unreadable one is a file only kendex writes: neither is a verdict
		// this can reach, and neither is the person's to answer for.
		return [];
	}
	const groups = (parsed as { hooks?: Record<string, unknown> } | null)?.hooks?.[listener];
	if (!Array.isArray(groups)) return [];

	const found: RegisteredHook[] = [];
	for (const group of groups) {
		const entry = group as { matcher?: unknown; hooks?: unknown };
		if (!matches(entry.matcher, toolName) || !Array.isArray(entry.hooks)) continue;
		for (const registration of entry.hooks) {
			const hook = registration as { type?: unknown; command?: unknown; timeout?: unknown };
			if (hook.type !== "command" || typeof hook.command !== "string" || hook.command === "") continue;
			const timeout = typeof hook.timeout === "number" && Number.isFinite(hook.timeout) && hook.timeout > 0
				? hook.timeout * 1000
				: undefined;
			const name = renderedName(hook.command);
			found.push({
				command: hook.command,
				name,
				script: name === "" ? undefined : resolve(root, "hooks", `${name}.sh`),
				budgetMs: timeout,
			});
		}
	}
	return found;
}

/**
 * Every hook the rendered registries ask for on this listener and this tool:
 * the project's `<project>/.pi/kendex/hooks.json` first, then the global
 * `<root-anchored PI_CODING_AGENT_DIR or ~/.pi/agent>/kendex/hooks.json`. The
 * project is `projectRoot`, the renderer's own walk, so a session started in a
 * subdirectory reads the registry rendered at the root above it.
 *
 * The registry is the render itself, not a model of it: what a hook runs is
 * the command kendex wrote there, which is how the same declaration reaches
 * Claude Code and Codex. That is the whole reason a custom hook — whose
 * command exists nowhere else — can run here at all.
 *
 * The project registry names commands the project ships, so it is behind Pi's
 * project trust: a clone the person has not trusted must not get its own code
 * run on the first tool call of the session. Pi's answer covers the folder and
 * its ancestors alike. Untrusted, the project scope contributes nothing and the
 * global registry still answers: the person's own hooks are not the project's.
 *
 * One installation of a guard runs once. Where both scopes register the same
 * rendered script, the project's is the one that answers, as it was before the
 * carrier read the registry at all; two command-bodied hooks are two hooks and
 * both run, because nothing but the person's own command identifies them.
 */
export function registeredHooks(listener: string, toolName: string, ctx: ExtensionContext): RegisteredHook[] {
	const roots: string[] = [];
	const project = projectTrusted(ctx) ? projectRoot(ctx.cwd) : undefined;
	if (project !== undefined) roots.push(resolve(project, ".pi", "kendex"));
	roots.push(resolve(piUserDir(), "kendex"));

	const found: RegisteredHook[] = [];
	const seen = new Set<string>();
	for (const root of roots) {
		for (const hook of readRegistry(root, listener, toolName)) {
			if (hook.name !== "") {
				if (seen.has(hook.name)) continue;
				seen.add(hook.name);
			}
			found.push(hook);
		}
	}
	return found;
}
