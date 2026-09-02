import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { isAbsolute, resolve } from "node:path";

import { getBool, getNumber, type HookKey, readConfig, recordProjectTrust } from "./config.js";
import { deliverDrift, runDriftCheck } from "./drift-check.js";
import { workspaceClippyOutcome } from "./lint-hooks.js";
import { runCommandAsync } from "./process.js";
import { type RegisteredHook, registeredHooks, TOOL_CALL_LISTENER } from "./registry.js";

const INSTALL_SYMBOL = Symbol.for("kendex.pi-hooks.installed");

/**
 * The rendered guards the settings surface names one by one. A registration
 * running one of them is armed by its own setting; everything else the
 * registry names — a custom hook above all, which is a command of the person's
 * own with no script of ours behind it — has no toggle and rides the master
 * switch. An unrecognised name therefore runs, which is the direction a guard
 * has to fail in.
 */
const GUARD_SETTINGS: Record<string, HookKey> = {
	"block-bare-cd": "blockBareCd",
	"block-repo-copy": "blockRepoCopy",
	"pre-commit-check": "preCommitCheck",
};

/** A `tool_call` verdict: `undefined` allows, `block` refuses with a reason. */
type Verdict = { block: true; reason: string } | undefined;

/**
 * The tool named the way a Claude Code hook payload names it, which is the way
 * a hook author writes a matcher: Pi's `bash` is that payload's `Bash`. Only
 * the case differs for the tools both name, and nothing but a hook reading
 * `.tool_name` sees it — the matcher itself is read case insensitively.
 */
function payloadToolName(toolName: string): string {
	return toolName.charAt(0).toUpperCase() + toolName.slice(1);
}

/**
 * Run one registered kendex hook and map its exit status.
 *
 * The hook is the one kendex rendered into `kendex/hooks.json`, handed the
 * payload Claude Code sends a PreToolUse hook. A hook of kendex's own is the
 * script under `kendex/hooks/` — the same bytes Claude Code and Codex run,
 * which is why these guards carry no second implementation in TypeScript — and
 * `RegisteredHook.script` says why it is spawned by path rather than through
 * the command that names it. Anything else is the person's own command, which
 * exists nowhere but the registry, and is run through a shell as written.
 *
 * Exit 2 is the refusal, and its stderr is the reason. A hook writes an
 * advisory to stderr and still exits 0 (`pre-commit-check` does this for a
 * commit aimed at another repository); that reaches the person through the UI,
 * never the agent. Any other non-zero status means the guard did not reach a
 * verdict, and a guard that did not run does not stand aside: the command is
 * refused, as the scripts themselves do when they cannot read their input. A
 * run past the budget is refused ahead of all of that, because a killed process
 * still carries an exit code and a hook that traps the signal can exit 0 on its
 * way out — which is a run that judged nothing wearing the status of one that
 * allowed.
 *
 * A registry naming no hook for this call allows it, and that is deliberate: it
 * means kendex has not installed one here. The package is installable from npm
 * on its own, and refusing every bash call in a project that never asked for a
 * guard would make it unusable.
 *
 * The budget is the registration's own `timeout`, capped by `ceilingMs` —
 * `hookTimeoutMs` from settings, the same route the clippy and drift budgets
 * take. The bash hooks declare `timeout: 60` in their own frontmatter and
 * DEFAULTS matches it, so a rendered guard runs to the budget it asks for and
 * nothing runs past the person's own ceiling.
 */
export async function runRegisteredHook(hook: RegisteredHook, payload: string, ctx: ExtensionContext, ceilingMs: number): Promise<Verdict> {
	const name = hook.name || hook.command;
	const budgetMs = Math.min(hook.budgetMs ?? ceilingMs, ceilingMs);
	const args = hook.script === undefined ? ["-c", hook.command] : [hook.script];
	const result = await runCommandAsync("bash", args, ctx.cwd, budgetMs, payload);
	const stderr = result.stderr.trim();

	// The budget is read BEFORE any exit code, because a killed process still
	// has one. `runCommandAsync` sends SIGTERM at the budget and the child gets
	// a grace period to die, so a hook that traps the signal and exits 0 — or
	// one whose last statement happens to succeed as it is torn down — settles
	// as `timedOut: true, exitCode: 0`. Read in the other order, that was an
	// allow: the one status this must never take from a run that was cut off.
	// A hook stopped part way judged nothing, whatever it managed to exit with.
	if (result.timedOut) {
		return {
			block: true,
			reason: `pi-hooks: ${name} timed out after ${budgetMs}ms in ${ctx.cwd}, so this command was not judged; a guard that did not run does not stand aside.`,
		};
	}
	if (result.exitCode === 2) return { block: true, reason: stderr || `${name} refused this command.` };
	if (result.exitCode !== 0) {
		return {
			block: true,
			reason: `pi-hooks: ${name} exited ${result.exitCode} without judging this command${stderr ? `: ${stderr}` : "."}`,
		};
	}
	if (stderr && ctx.hasUI) ctx.ui.notify(stderr, "info");
	return undefined;
}

interface TurnState {
	rustFilesTouched: Set<string>;
}

function freshTurnState(): TurnState {
	return { rustFilesTouched: new Set<string>() };
}

export default function piHooks(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;

	let turn = freshTurnState();

	pi.on("turn_start", () => {
		turn = freshTurnState();
	});

	// Pi port of hooks/session-drift-check.sh. Fresh starts only: a resumed
	// session already carries the report and a reload re-runs extensions in
	// place. Fire-and-forget — an informational check never gates startup.
	pi.on("session_start", (event, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		if (event.reason === "reload" || event.reason === "resume") return;
		const cfg = readConfig(ctx.cwd);
		if (!getBool(cfg, "enabled") || !getBool(cfg, "sessionDriftCheck")) return;

		void deliverDrift(
			runDriftCheck(ctx.cwd, {
				timeoutMs: getNumber(cfg, "driftCheckTimeoutMs"),
			}),
			(message) =>
				pi.sendMessage(
					{ customType: "kendex-drift", content: message, display: true },
					{ triggerTurn: false },
				),
		);
	});

	pi.on("tool_call", async (event, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		const cfg = readConfig(ctx.cwd);
		if (!getBool(cfg, "enabled")) return undefined;

		// The registry kendex rendered is the list: every hook it names for
		// this listener and this tool runs, in the order it names them, and
		// the first refusal is the answer. Nothing here knows a hook's name in
		// advance, which is what lets a custom hook run at all.
		const registered = registeredHooks(TOOL_CALL_LISTENER, event.toolName, ctx);
		if (registered.length === 0) return undefined;

		const payload = JSON.stringify({
			tool_name: payloadToolName(event.toolName),
			tool_input: event.input ?? {},
		});
		const ceilingMs = getNumber(cfg, "hookTimeoutMs");
		for (const hook of registered) {
			const setting = GUARD_SETTINGS[hook.name];
			if (setting !== undefined && !getBool(cfg, setting)) continue;
			const verdict = await runRegisteredHook(hook, payload, ctx, ceilingMs);
			if (verdict) return verdict;
		}

		return undefined;
	});

	pi.on("tool_result", async (event, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		const cfg = readConfig(ctx.cwd);
		if (!getBool(cfg, "enabled")) return undefined;

		const tool = event.toolName.toLowerCase();
		if (tool !== "edit" && tool !== "write") return undefined;

		const rawPath = (event.input as { path?: unknown })?.path;
		const filePath = typeof rawPath === "string" ? rawPath : "";
		if (!filePath.endsWith(".rs")) return undefined;

		// Recorded for the end-of-turn check, which is the only lane that runs
		// clippy. A .rs write costs nothing here.
		turn.rustFilesTouched.add(isAbsolute(filePath) ? filePath : resolve(ctx.cwd, filePath));
		return undefined;
	});

	pi.on("turn_end", async (_event, ctx: ExtensionContext) => {
		recordProjectTrust(ctx);
		const cfg = readConfig(ctx.cwd);
		if (!getBool(cfg, "enabled")) return undefined;
		if (!getBool(cfg, "taskCompletedCheck")) return undefined;
		if (turn.rustFilesTouched.size === 0) return undefined;

		const outcome = workspaceClippyOutcome(ctx.cwd, getNumber(cfg, "clippyTimeoutMs"));
		if (outcome.kind === "clean") return undefined;
		const summary = outcome.kind === "errors"
			? `pi-hooks: clippy reported ${outcome.lines.length} workspace error(s) at turn end:\n${outcome.lines.slice(0, 5).join("\n")}`
			: `pi-hooks: end-of-turn clippy proved nothing about the tree: ${outcome.reason}.`;

		// Pi discards a turn_end handler's return value, and since pi#8022 a
		// `triggerTurn: false` message is recorded without steering, which a
		// headless run that is ending never reads. `triggerTurn: true` steers
		// the active run, so the loop drains it after this event and the agent
		// answers for its own errors in every mode. Every failing turn reports:
		// an agent that cannot fix an error hears the same advisory each turn,
		// which is noisy and self-correcting, where suppressing a repeat can
		// leave a headless turn told nothing when there was something to say.
		// The turn state above is the bound — a turn that writes no `.rs` file
		// runs no clippy — so a report costs an edit, not a loop.
		//
		// `display: false` leaves interactive rendering to the notification
		// below, which a headless session never sees.
		pi.sendMessage(
			{ customType: "kendex-clippy", content: summary, display: false },
			{ triggerTurn: true },
		);
		if (ctx.hasUI) ctx.ui.notify(summary, outcome.kind === "errors" ? "warning" : "info");
		return undefined;
	});
}
