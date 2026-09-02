import { readFileSync, statSync } from "node:fs";
import { basename, resolve } from "node:path";

import { piUserDir } from "./config.js";

/**
 * The registry keys kendex renders hooks under. Pi has no per-hook runner, so
 * kendex restates each hook event as the listener Pi fires
 * (`crates/core/src/harness/caps.rs::pi_listener`) and keys the rendered
 * registry by that name. tests/registry.test.ts holds these to that map: a
 * rename on either side is a registry written under one key and read under
 * another, which is every hook silently off.
 *
 * Every key `pi_listener` can return is dispatched. A key the carrier does not
 * read is a hook kendex registers and labels enforced and nothing runs, which
 * is the defect KEN-941 closed on `tool_call` and KEN-1189 on the other three.
 */
export const TOOL_CALL_LISTENER = "tool_call";
/** `PostToolUse`. */
export const TOOL_RESULT_LISTENER = "tool_result";
/** `Stop` and `TaskCompleted`, which Pi fires as one event. */
export const TURN_END_LISTENER = "turn_end";
/** `SessionStart`. */
export const SESSION_START_LISTENER = "session_start";

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
	 * hold a credential written inline, and a reason reaches the model.
	 */
	label: string;
	/**
	 * The script that command runs, for a hook kendex rendered: the file under
	 * the same root the registration was read from, spawned directly.
	 *
	 * The registry is the anchor, not the walk the command carries: a project
	 * the person copied elsewhere, or read through a symlink, is still the
	 * root this registration was just read out of, and the walk is a shell
	 * expansion this never has to perform. A command that is not one of ours
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
}

/**
 * Whether a registration's matcher covers this event. `subject` is the word
 * the matcher is written against: the tool being called on `tool_call` and
 * `tool_result`, the session's source on `session_start`, and `undefined` on
 * `turn_end`, whose Claude Code events (`Stop`, `TaskCompleted`) take no
 * matcher at all — there, every registration covers, because the alternative
 * is a matcher nobody wrote deciding a hook does not run.
 *
 * Absent, empty and `*` cover everything, as they do for the Claude Code
 * registry this shape comes from; anything else is a whole-string regex,
 * compared against the subject said in Claude's own words so the pattern is
 * read exactly as its author wrote it (`vocab.ts`).
 *
 * A pattern that will not compile judges the call rather than skipping it. It
 * is a matcher kendex registered and labels enforced, and the alternative is a
 * guard that is silently off for every tool. Nothing here says which matcher
 * failed to compile: the hook runs, so its own verdict is what the person
 * sees. The flags are Claude Code's — none — so a matcher that compiles and
 * matches there compiles and matches here.
 */
function matches(matcher: unknown, subject: string | undefined): boolean {
	if (subject === undefined) return true;
	if (typeof matcher !== "string") return true;
	const pattern = matcher.trim();
	if (pattern === "" || pattern === "*") return true;
	try {
		return new RegExp(`^(?:${pattern})$`).test(subject);
	} catch {
		return true;
	}
}

/**
 * The script a registered command runs, or `""` for a command kendex did not
 * write. `engine::targets` writes two shapes and no others: a global command
 * names the file outright, `bash "<path>"`, and a project command opens by
 * naming the file under the project it will go and find, `p='<path>'; …`.
 * Both are read here, and `anchor` is what a project path is relative to —
 * the project this registry was read from.
 */
function renderedScript(command: string, anchor: string | undefined): string {
	const relative = /^p='((?:[^']|'\\'')*)';/.exec(command);
	if (relative !== null) {
		return anchor === undefined ? "" : resolve(anchor, relative[1]!.replaceAll("'\\''", "'"));
	}
	const word = command.startsWith('bash "') && command.endsWith('"') ? command.slice(6, -1) : "";
	return word === "" ? "" : resolve(word);
}

/** The guard name a registered command runs, or `""` where `engine::targets::pi_hook` did not write that command for this root. */
export function renderedName(root: string, command: string, anchor: string | undefined): string {
	const script = renderedScript(command, anchor);
	// `resolve` spells the path the platform's way, so the file is taken off
	// it by the platform's separator too: a slice at `/` would hand back a
	// whole Windows path as the name.
	const file = basename(script);
	if (!file.endsWith(".sh")) return "";
	const name = file.slice(0, -3);
	if (name === "") return "";
	return script === resolve(root, "hooks", `${name}.sh`) ? name : "";
}

/** A `readFileSync` failure that means the file is simply not there. */
function absent(error: unknown): boolean {
	const code = (error as { code?: unknown } | null)?.code;
	return code === "ENOENT" || code === "ENOTDIR";
}

/**
 * A rendered script that is not on disk. Only that: any other stat failure —
 * a directory this session may not read, say — leaves the hook to the spawn,
 * whose own exit status names the real cause.
 */
function scriptGone(script: string): boolean {
	try {
		statSync(script);
		return false;
	} catch (error) {
		return absent(error);
	}
}

/** The registrations one scope root holds for a listener, in file order. */
function readRegistry(root: string, listener: string, subject: string | undefined, anchor: string | undefined): RegistryRead {
	const path = resolve(root, "hooks.json");
	const hooks: RegisteredHook[] = [];
	let position = 0;
	try {
		const parsed = JSON.parse(readFileSync(path, "utf8")) as unknown;
		if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) throw new Error("not a JSON object");
		const registry = (parsed as { hooks?: unknown }).hooks;
		if (registry === undefined) return { hooks };
		if (typeof registry !== "object" || registry === null || Array.isArray(registry)) throw new Error("hooks is not an object");
		const groups = (registry as Record<string, unknown>)[listener];
		if (groups === undefined) return { hooks };
		if (!Array.isArray(groups)) throw new Error(`hooks.${listener} is not an array`);
		for (const group of groups) {
			const entry = group as { matcher?: unknown; hooks?: unknown };
			if (!Array.isArray(entry.hooks)) throw new Error(`hooks.${listener} holds a group whose hooks is not an array`);
			const covers = matches(entry.matcher, subject);
			for (const registration of entry.hooks) {
				position += 1;
				const hook = registration as { type?: unknown; command?: unknown; timeout?: unknown };
				if (hook.type !== "command" || typeof hook.command !== "string" || hook.command === "") continue;
				if (!covers) continue;
				const timeout = typeof hook.timeout === "number" && Number.isFinite(hook.timeout) && hook.timeout > 0
					? hook.timeout * 1000
					: undefined;
				const name = renderedName(root, hook.command, anchor);
				hooks.push({
					command: hook.command,
					name,
					label: name === "" ? `custom hook ${position} in ${path}` : name,
					script: name === "" ? undefined : resolve(root, "hooks", `${name}.sh`),
					budgetMs: timeout,
				});
			}
		}
	} catch (error) {
		// No registry is kendex having installed no hook here, and that is the
		// only reading that allows the call. Anything else — a permission the
		// session does not have, a directory in the file's place, a document
		// that will not parse — is a registry that exists and did not answer,
		// and a guard that did not run does not stand aside.
		if (absent(error)) return { hooks: [] };
		return { hooks: [], unreadable: `${path}: ${(error as Error).message}` };
	}
	return { hooks };
}

/**
 * Every hook the rendered registries ask for on this listener, whose matchers
 * cover `subject` — the tool on `tool_call` and `tool_result`, the session
 * source on `session_start`, and `undefined` on `turn_end`, where every
 * registration covers:
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
 * project scope contributes nothing and is not even read, and the global
 * registry still answers: the person's own hooks are not the project's.
 *
 * One installation of a guard runs once. Where both scopes register the same
 * rendered script the project's answers — unless its script is not on disk,
 * which is a broken registration, and the healthy copy at the next scope
 * answers rather than being shadowed by it. Two command-bodied hooks are two
 * hooks and both run, nothing but the command identifying them.
 */
export function registeredHooks(listener: string, subject: string | undefined, project: string | undefined, trusted: boolean): RegistryRead {
	const hooks: RegisteredHook[] = [];
	const byName = new Map<string, number>();
	let unreadable: string | undefined;

	const answering: RegistryRead[] = [];
	if (project !== undefined && trusted) {
		answering.push(readRegistry(resolve(project, ".pi", "kendex"), listener, subject, project));
	}
	answering.push(readRegistry(resolve(piUserDir(), "kendex"), listener, subject, undefined));

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
			if (hooks[at]!.script !== undefined && scriptGone(hooks[at]!.script!) && hook.script !== undefined && !scriptGone(hook.script)) {
				hooks[at] = hook;
			}
		}
	}
	// Stat-ed once, at the end, rather than per scope above it.
	for (const [, at] of byName) {
		const hook = hooks[at]!;
		if (hook.script !== undefined && scriptGone(hook.script)) hooks[at] = { ...hook, missing: true };
	}
	return { hooks, ...(unreadable === undefined ? {} : { unreadable }) };
}
