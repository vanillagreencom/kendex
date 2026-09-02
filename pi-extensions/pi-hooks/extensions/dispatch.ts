import type { ExtensionContext } from "@earendil-works/pi-coding-agent";

import { getBool, getNumber, type HookKey, type kendexConfig } from "./config.js";
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
 * Spawn one registered hook and say what happened. The budget is the
 * registration's own `timeout`, capped by `ceilingMs` (`hookTimeoutMs` from
 * settings).
 *
 * The budget is read BEFORE any exit code, because a killed process still has
 * one. `runCommandAsync` sends SIGTERM at the budget and the child gets a
 * grace period to die, so a hook that traps the signal and exits 0 — or one
 * whose last statement happens to succeed as it is torn down — settles as
 * `timedOut: true, exitCode: 0`. Read in the other order, that was a clean
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
 */
export async function runHook(hook: RegisteredHook, payload: string, ctx: ExtensionContext, ceilingMs: number): Promise<HookOutcome> {
	if (hook.missing && hook.script !== undefined) return { ran: false, missing: hook.script };
	const budgetMs = Math.min(hook.budgetMs ?? ceilingMs, ceilingMs);
	const args = hook.script === undefined ? ["-c", hook.command] : [hook.script];
	const result = await runCommandAsync("bash", args, ctx.cwd, budgetMs, payload);
	if (result.timedOut) return { ran: false, timedOutAfterMs: budgetMs };
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
	payload: string,
	ctx: ExtensionContext,
	cfg: kendexConfig,
	project: string | undefined,
	trusted: boolean,
	stop?: (result: HookResult) => boolean,
): Promise<ListenerRun> {
	const registry = registeredHooks(listener, subject, project, trusted);
	if (registry.unreadable !== undefined) return { results: [], unreadable: registry.unreadable };
	const ceilingMs = getNumber(cfg, "hookTimeoutMs");
	const results: HookResult[] = [];
	for (const hook of registry.hooks) {
		const setting = GUARD_SETTINGS.get(hook.name);
		if (setting !== undefined && !getBool(cfg, setting)) continue;
		const result = { hook, outcome: await runHook(hook, payload, ctx, ceilingMs) };
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
			? `pi-hooks: ${name} is registered and its rendered script is missing (${outcome.missing}), so it did not run; run kendex refresh.`
			: `pi-hooks: ${name} timed out after ${outcome.timedOutAfterMs}ms in ${ctx.cwd}, so it did not run to a verdict.`;
	}
	if (outcome.exitCode === 0) return outcome.stdout === "" ? undefined : outcome.stdout;
	if (outcome.exitCode === 2) return outcome.stderr === "" ? `pi-hooks: ${name} refused, saying nothing.` : outcome.stderr;
	return `pi-hooks: ${name} exited ${outcome.exitCode} without reaching a verdict${outcome.stderr === "" ? "." : `: ${outcome.stderr}`}`;
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
	return `pi-hooks: the rendered hook registry could not be read, so no ${listener} hook ran. ${cause}`;
}
