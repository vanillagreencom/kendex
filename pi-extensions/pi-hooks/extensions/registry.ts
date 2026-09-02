import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

import { piUserDir } from "./config.js";

/**
 * The registry key a `PreToolUse` hook is rendered under. Pi has no per-hook
 * runner, so kendex restates each hook event as the listener Pi fires
 * (`crates/core/src/harness/caps.rs::pi_listener`) and keys the rendered
 * registry by that name. tests/registry.test.ts holds this to that map: a
 * rename on either side is a registry written under one key and read under
 * another, which is every hook silently off.
 */
export const TOOL_CALL_LISTENER = "tool_call";

/** One hook the rendered registry asks the carrier to run. */
export interface RegisteredHook {
	/** The registered command, run through a shell exactly as kendex wrote it. */
	command: string;
	/**
	 * The rendered guard's script name when the command names one, `""` when it
	 * does not — a command-bodied hook is the person's own words and has no
	 * script of ours behind it. The per-guard settings are keyed by this name.
	 */
	name: string;
	/**
	 * How a refusal names this hook. A command-bodied hook is named by where it
	 * is registered, never by its own text: that text is the person's, it can
	 * hold a credential written inline, and a reason reaches the model. The
	 * ordinal counts registrations in the file, not the ones this call matched,
	 * so the person can find the entry the reason names.
	 */
	label: string;
	/**
	 * The script that command runs, for a hook kendex rendered: the file under
	 * the same root the registration was read from, spawned directly.
	 *
	 * The command kendex writes for a project-scope hook spells its path
	 * `$(git rev-parse --show-toplevel)/.pi/…`, and git's answer is not always
	 * kendex's: a vendored checkout inside a project is its own git root while
	 * kendex renders — and this reads — at the project above it, and a project
	 * with no git at all has no answer to give. Both would run the wrong file
	 * or none, and the substitution is a shell expansion this never has to
	 * perform. So a hook of ours is spawned at the path the registry it came
	 * from anchors, which is where kendex wrote it. A command that is not ours
	 * has no such path and is run as written.
	 */
	script?: string;
	/**
	 * A rendered hook whose script no scope holds. Still refused, kendex having
	 * registered it — but under a reason naming the render and its repair,
	 * rather than bash's exit-127 text from a spawn that judged nothing.
	 */
	missing?: true;
	/** Milliseconds the registration asks for, from its `timeout` in seconds. */
	budgetMs?: number;
}

/** What the registries say about one tool call. */
export interface RegistryRead {
	hooks: RegisteredHook[];
	/**
	 * A registry that exists and could not be read, named with its cause. The
	 * caller refuses on it: kendex labels these hooks enforced, and a file only
	 * kendex writes failing to parse is not the person standing their guards
	 * down.
	 */
	unreadable?: string;
	/**
	 * How many registrations the project's registry holds under this listener,
	 * where trust withheld them. Counted before the matcher, so the number is
	 * what the project has installed rather than what this one call happened
	 * to match — a notice given once has to be right the first time.
	 */
	withheld: number;
}

/**
 * Whether a registration's matcher covers the tool being called. Absent, empty
 * and `*` cover every tool, as they do for the Claude Code registry this shape
 * comes from; anything else is a whole-string regex, compared against the tool
 * said in Claude's own words so the pattern is read exactly as its author
 * wrote it (`vocab.ts`).
 *
 * A pattern that will not compile judges the call rather than skipping it. It
 * is a matcher kendex registered and labels enforced, and the alternative is a
 * guard that is silently off for every tool. Nothing here says which matcher
 * failed to compile: the hook runs, so its own verdict is what the person
 * sees. The flags are Claude Code's — none — so a matcher that compiles and
 * matches there compiles and matches here.
 */
function matches(matcher: unknown, toolName: string): boolean {
	if (typeof matcher !== "string") return true;
	const pattern = matcher.trim();
	if (pattern === "" || pattern === "*") return true;
	try {
		return new RegExp(`^(?:${pattern})$`).test(toolName);
	} catch {
		return true;
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
	return command.trim().match(/^bash "(?:[^"]*\/)?kendex\/hooks\/([^/"]+)\.sh"$/)?.[1] ?? "";
}

/** A `readFileSync` failure that means the file is simply not there. */
function absent(error: unknown): boolean {
	const code = (error as { code?: unknown } | null)?.code;
	return code === "ENOENT" || code === "ENOTDIR";
}

/**
 * The registrations one scope root holds for a listener, in file order.
 * Position is counted before the matcher and the shape check, so both numbers
 * describe the file rather than this one call: the label points at an entry a
 * person can go and read, and `withheld` says what the project installed.
 */
function readRegistry(root: string, listener: string, toolName: string): RegistryRead {
	const path = resolve(root, "hooks.json");
	let parsed: unknown;
	try {
		parsed = JSON.parse(readFileSync(path, "utf8"));
	} catch (error) {
		// No registry is kendex having installed no hook here, and that is the
		// only reading that allows the call. Anything else — a permission the
		// session does not have, a directory in the file's place, a document
		// that will not parse — is a registry that exists and did not answer,
		// and a guard that did not run does not stand aside.
		if (absent(error)) return { hooks: [], withheld: 0 };
		return { hooks: [], withheld: 0, unreadable: `${path}: ${(error as Error).message}` };
	}
	const groups = (parsed as { hooks?: Record<string, unknown> } | null)?.hooks?.[listener];
	if (!Array.isArray(groups)) return { hooks: [], withheld: 0 };

	const hooks: RegisteredHook[] = [];
	let position = 0;
	for (const group of groups) {
		const entry = group as { matcher?: unknown; hooks?: unknown };
		if (!Array.isArray(entry.hooks)) continue;
		const covers = matches(entry.matcher, toolName);
		for (const registration of entry.hooks) {
			position += 1;
			const hook = registration as { type?: unknown; command?: unknown; timeout?: unknown };
			if (!covers || hook.type !== "command" || typeof hook.command !== "string" || hook.command === "") continue;
			const timeout = typeof hook.timeout === "number" && Number.isFinite(hook.timeout) && hook.timeout > 0
				? hook.timeout * 1000
				: undefined;
			const name = renderedName(hook.command);
			hooks.push({
				command: hook.command,
				name,
				label: name === "" ? `custom hook ${position} in ${path}` : name,
				script: name === "" ? undefined : resolve(root, "hooks", `${name}.sh`),
				budgetMs: timeout,
			});
		}
	}
	return { hooks, withheld: position };
}

/**
 * Every hook the rendered registries ask for on this listener and this tool:
 * the project's `<project>/.pi/kendex/hooks.json` first, then the global
 * `<root-anchored PI_CODING_AGENT_DIR or ~/.pi/agent>/kendex/hooks.json`.
 * `project` is the caller's already-resolved project root, or `undefined`
 * where the session is in none.
 *
 * The registry is the render itself, not a model of it: what a hook runs is
 * the command kendex wrote there, which is how the same declaration reaches
 * Claude Code and Codex. That is the whole reason a custom hook — whose
 * command exists nowhere else — can run here at all.
 *
 * The project registry names commands the project ships, so `trusted` is Pi's
 * answer for this workspace: a clone the person has not trusted must not get
 * its own code run on the first tool call of the session. Untrusted, the
 * project scope contributes nothing but its count, and the global registry
 * still answers: the person's own hooks are not the project's. That count has
 * one consumer, so `countWithheld` false skips the read entirely — work with
 * no consumer, on a file whose size an untrusted party chooses.
 *
 * One installation of a guard runs once. Where both scopes register the same
 * rendered script the project's answers — unless its script is not on disk,
 * which is a broken registration, and the healthy copy at the next scope
 * answers rather than being shadowed by it. Two command-bodied hooks are two
 * hooks and both run, nothing but the command identifying them.
 */
export function registeredHooks(listener: string, toolName: string, project: string | undefined, trusted: boolean, countWithheld = true): RegistryRead {
	const hooks: RegisteredHook[] = [];
	const byName = new Map<string, number>();
	let unreadable: string | undefined;
	let withheld = 0;

	const answering: RegistryRead[] = [];
	if (project !== undefined && (trusted || countWithheld)) {
		const read = readRegistry(resolve(project, ".pi", "kendex"), listener, toolName);
		// Untrusted, this registry says only how many hooks were withheld.
		// Its failure to parse is not carried: refusing on it would let a
		// clone nobody has trusted stop every tool call in the session.
		if (trusted) answering.push(read);
		else withheld += read.withheld;
	}
	answering.push(readRegistry(resolve(piUserDir(), "kendex"), listener, toolName));

	for (const read of answering) {
		unreadable ??= read.unreadable;
		for (const hook of read.hooks) {
			if (hook.name === "") {
				hooks.push(hook);
				continue;
			}
			const at = byName.get(hook.name);
			if (at === undefined) {
				byName.set(hook.name, hooks.length);
				hooks.push(hook);
				continue;
			}
			// A registration whose render is gone judges nothing, so it must
			// not stand in front of a healthy copy at the next scope down.
			if (hooks[at]!.script !== undefined && !existsSync(hooks[at]!.script!) && hook.script !== undefined && existsSync(hook.script)) {
				hooks[at] = hook;
			}
		}
	}
	// Stat-ed once, at the end, rather than per scope above it.
	for (const [, at] of byName) {
		const hook = hooks[at]!;
		if (hook.script !== undefined && !existsSync(hook.script)) hooks[at] = { ...hook, missing: true };
	}
	return { hooks, withheld, ...(unreadable === undefined ? {} : { unreadable }) };
}
