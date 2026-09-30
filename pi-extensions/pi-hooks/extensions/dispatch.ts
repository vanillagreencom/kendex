import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { getBool, type HookKey, type kendexConfig } from "./config.js";
import { runCommandAsync } from "./process.js";
import { type RegisteredHook, registeredHooks } from "./registry.js";

/**
 * The rendered guards the settings surface names one by one. A registration
 * running one of them is armed by its own setting; everything else the
 * registry names — a custom hook above all, which is a command of the person's
 * own with no script of ours behind it — has no toggle and rides the master
 * switch. An unrecognised name therefore runs, which is the direction a guard
 * has to fail in.
 *
 * `session-drift-check` and `task-completed-check` are here because this
 * carrier also ports them natively, on the same two listeners, behind these
 * same two settings — so one switch turns the guard off however it arrives,
 * and neither copy is silently on while the surface says otherwise. Both ports
 * stay: no catalog hook of kendex's names Pi in its own `harnesses:` line for
 * either, so nothing registers them for Pi and nothing doubles. A person who
 * registers their own copy anyway gets both, and this setting turns off both.
 *
 * A `Map`, not an object: a hook's name is its own file name, and an object
 * would answer `toString`, `constructor` and six other inherited words with a
 * function — truthy, so the lookup succeeds, `getBool` returns undefined for a
 * setting `DEFAULTS` does not hold, and a hook named any of them is skipped in
 * silence. tests/registry.test.ts renders one and holds it to refusing.
 */
const GUARD_SETTINGS = new Map<string, HookKey>([
	["block-bare-cd", "blockBareCd"],
	["block-repo-copy", "blockRepoCopy"],
	["pre-commit-check", "preCommitCheck"],
	["session-drift-check", "sessionDriftCheck"],
	["task-completed-check", "taskCompletedCheck"],
]);

/** The guard names that surface has, for the coupling test and nothing else. */
export const GUARD_SETTING_NAMES = [...GUARD_SETTINGS.keys()];

/**
 * What one registered hook did. A hook that reached no verdict says which of
 * the two ways it did not run, and the listener writes its own consequence
 * around those facts: only `tool_call` has a call to refuse.
 */
export type HookOutcome =
	| { ran: false; missing: string }
	| { ran: false; timedOutAfterMs: number }
	| { ran: true; exitCode: number; stdout: string; stderr: string };

/**
 * The budget for a registration that declares no `timeout`: the 60 seconds
 * Claude Code gives such a hook, so one registry means one budget everywhere.
 */
const DEFAULT_BUDGET_MS = 60_000;

/**
 * Spawn one registered hook and say what happened. The budget is the
 * registration's own `timeout`, or [`DEFAULT_BUDGET_MS`] where it names none.
 *
 * The budget is read BEFORE any exit code, because a killed process still has
 * one. `runCommandAsync` sends SIGTERM at the budget and the child gets a
 * grace period to die, so a hook that traps the signal and exits 0 — or one
 * whose last statement happens to succeed as it is torn down — settles as
 * `stoppedBy: "timeout", exitCode: 0`. Read in the other order, that was a clean
 * run: the one status this must never take from a run that was cut off. A hook
 * stopped part way judged nothing, whatever it managed to exit with.
 *
 * A missing render is not spawned: bash's own "No such file or directory" says
 * nothing about which render is missing or how to put it back. Only a hook of
 * kendex's is named that way, because only that has a render to name — a
 * command-bodied hook is the person's own text, which can hold a credential
 * inline and never reaches a message. That is the test rather than the flag
 * alone: `registry.ts` sets `missing` only where a script exists, and a hook
 * carrying the flag without one goes to the spawn, whose status names its own
 * cause.
 *
 * The render is spawned directly, the registry it was read from anchoring it
 * rather than the walk its command carries. A command that sets an environment
 * for that script is run as written instead: the assignments exist only in the
 * command, so the direct spawn would run the script with none of them.
 */
export async function runHook(hook: RegisteredHook, payload: string, ctx: ExtensionContext): Promise<HookOutcome> {
	if (hook.missing && hook.script !== undefined) return { ran: false, missing: hook.script };
	const budgetMs = hook.budgetMs ?? DEFAULT_BUDGET_MS;
	const args = hook.script === undefined || hook.assigns === true ? ["-c", hook.command] : [hook.script];
	const result = await runCommandAsync("bash", args, ctx.cwd, budgetMs, { stdin: payload });
	switch (result.stoppedBy) {
		case "timeout":
			return { ran: false, timedOutAfterMs: budgetMs };
		case "abort":
			throw new Error("hook run reports an abort, and no abort signal was given to it");
		case null:
			break;
		default:
			throw new Error(`hook run stopped by ${JSON.stringify(result.stoppedBy satisfies never)}, which dispatch does not know`);
	}
	return { ran: true, exitCode: result.exitCode, stdout: result.stdout.trim(), stderr: result.stderr.trim() };
}

/** One registered hook and what it did. */
export interface HookResult {
	hook: RegisteredHook;
	outcome: HookOutcome;
}

/** What the registry had to say about one event. */
export interface ListenerRun {
	results: HookResult[];
	/** A registry that exists and could not be read, named with its cause. */
	unreadable?: string;
}

/**
 * Every hook the rendered registry names for this listener, run in the order
 * it names them. `subject` is what a registration's matcher is compared
 * against, `undefined` where the listener has no matcher vocabulary.
 *
 * `payload` is called once, when the first hook is about to run, and never
 * for an event no enabled registration matches: a listener fires on every
 * tool call, and most calls have no hook to read what it would build.
 *
 * `stop` ends the run early and is the `tool_call` gate's: a refusal is the
 * answer and the guards behind it are not asked. The listeners Pi gives no
 * verdict to pass none — the event has already happened, so every hook
 * declared on it gets to speak.
 *
 * A registry that exists and did not answer stops the run before any hook: the
 * caller says what that means where it can, and none of the hooks it named ran.
 */
export async function runListener(
	listener: string,
	subject: string | undefined,
	payload: () => string,
	ctx: ExtensionContext,
	cfg: kendexConfig,
	project: string | undefined,
	trusted: boolean,
	stop?: (result: HookResult) => boolean,
): Promise<ListenerRun> {
	const registry = registeredHooks(listener, subject, project, trusted);
	if (registry.unreadable !== undefined) return { results: [], unreadable: registry.unreadable };
	const results: HookResult[] = [];
	let built: string | undefined;
	for (const hook of registry.hooks) {
		const setting = GUARD_SETTINGS.get(hook.name);
		if (setting !== undefined && !getBool(cfg, setting)) continue;
		built ??= payload();
		const result = { hook, outcome: await runHook(hook, built, ctx) };
		results.push(result);
		if (stop?.(result)) break;
	}
	return { results };
}

/**
 * What a hook has to say to the agent on a listener Pi gives no verdict to —
 * `tool_result`, `turn_end`, `session_start` — or `undefined` where it said
 * nothing. One rule for all three, because Pi refuses nothing on any of them
 * and delivering the words is the whole consequence available:
 *
 * - Exit 0: stdout is what the hook contributes, which is the one stream
 *   Claude Code ever routes into a model's context (`SessionStart`). Silence
 *   is silence. Anything on stderr beside a 0 is an advisory for the person,
 *   and `personLine` carries it instead.
 * - Exit 2: the refusal Claude Code's own `PostToolUse`, `Stop` and
 *   `SessionStart` hooks make, and its stderr is written for the model. Pi
 *   gates none of these events, so it is delivered rather than obeyed, which
 *   `docs/adapters/pi.md` sets out per listener.
 * - Anything else: a hook that judged nothing, said plainly. Nothing here can
 *   stand aside on its behalf, so the agent is told rather than left to read a
 *   silence as an all-clear.
 *
 * A hook that did not run at all is the carrier's own account, named with its
 * repair — never bash's exit-127 text from a spawn, and never nothing.
 */
export function agentLine(result: HookResult, ctx: ExtensionContext): string | undefined {
	const name = result.hook.label;
	const outcome = result.outcome;
	if (!outcome.ran) {
		return "missing" in outcome
			? `hook-missing=${outcome.missing}\n${name} did not run. Run kendex refresh.`
			: `hook-timeout-ms=${outcome.timedOutAfterMs}\n${name} did not reach a verdict in ${ctx.cwd}.`;
	}
	if (outcome.exitCode === 0) return outcome.stdout === "" ? undefined : outcome.stdout;
	if (outcome.exitCode === 2) return outcome.stderr === "" ? `hook-refused=${name}\nThe hook supplied no reason.` : outcome.stderr;
	return `hook-exit=${outcome.exitCode}\n${name} did not reach a verdict.${outcome.stderr === "" ? "" : `\n${outcome.stderr}`}`;
}

/** The advisory a hook wrote for the person rather than the agent: stderr
 * beside a clean exit, which every other status has already spoken through
 * `agentLine`. */
export function personLine(result: HookResult): string | undefined {
	const outcome = result.outcome;
	if (!outcome.ran || outcome.exitCode !== 0 || outcome.stderr === "") return undefined;
	return outcome.stderr;
}

/** What an unreadable registry means where there is no call to refuse: every
 * hook it named was skipped, and kendex labels those hooks enforced, so it is
 * said rather than read as no hooks installed. */
export function unreadableLine(listener: string, cause: string): string {
	return `hook-registry-unreadable=${listener}\nNo hook ran. ${cause}`;
}

/**
 * What the agent reads from one event's hooks, bounded the way Pi bounds a
 * tool's own output: Pi's `truncateTail` at its defaults, keeping the end,
 * where a failing command prints its error. Each hook may print up to the
 * 16 MiB per stream `runCommandAsync` keeps, and what reaches the agent stays
 * in the session for its whole life, so the bound is on the text all of an
 * event's hooks said together.
 *
 * Past the bound, the whole text is written to a file of its own in the
 * system temporary directory, as Pi's bash tool does with a long output, and
 * the kept tail is led by `hook-output-truncated=<that file>`; a file that
 * could not be written leads it with `hook-output-unsaved=<its cause>`
 * instead. Nothing a hook said is dropped unannounced.
 *
 * Pi's package is imported where the bound is taken, not when this module
 * loads, for the reason `hooks.ts::unsupportedHostLine` gives: kendex's
 * carrier test drives this file under bare bun, where the package does not
 * resolve. There nothing reads a session, and the text is returned whole.
 */
export async function boundForAgent(text: string): Promise<string> {
	let pi: typeof import("@earendil-works/pi-coding-agent");
	try {
		pi = await import("@earendil-works/pi-coding-agent");
	} catch {
		return text;
	}
	const cut = pi.truncateTail(text);
	if (!cut.truncated) return text;
	const kept = `The last ${cut.outputLines} of ${cut.totalLines} lines follow, ${pi.formatSize(cut.outputBytes)} of ${pi.formatSize(cut.totalBytes)}.`;
	const path = join(tmpdir(), `pi-hooks-output-${randomUUID()}.log`);
	try {
		// Owner-only: the directory is shared, and hook output can carry source
		// lines and environment values another local user must not read.
		await writeFile(path, text, { flag: "wx", mode: 0o600 });
	} catch (error) {
		return `hook-output-unsaved=${error instanceof Error ? error.message : String(error)}\n${kept} The full output could not be saved.\n${cut.content}`;
	}
	return `hook-output-truncated=${path}\n${kept} The full output is in that file.\n${cut.content}`;
}

/**
 * Say one line through one channel, whatever that channel does. Never throws.
 *
 * Pi's session-bound `pi` and `ctx` objects throw once the session is replaced
 * (`ctx.newSession`, `ctx.switchSession`, `ctx.fork`, `ctx.reload`), and a
 * `session_start` report is delivered long after its handler returned — nobody
 * awaits it, so a throw there is an unhandled rejection rather than a handler
 * error Pi absorbs, and Node from 22 on ends the process on one. Each delivery
 * is wrapped on its own, so a channel that is gone loses its own line rather
 * than the rest of what the listener had to say. `deliverDrift` states the same
 * invariant for the drift report beside it.
 */
export function deliver(send: (content: string) => void, content: string): void {
	try {
		send(content);
	} catch {
		// The channel itself is what failed; there is nowhere left to report it.
	}
}
