import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync } from "node:fs";
import { isAbsolute, join, resolve } from "node:path";

import { actionableUserDir, getBool, getNumber, projectRoot, projectTrusted, readConfig, recordProjectTrust } from "./config.js";
import { deliverDrift, runDriftCheck } from "./drift-check.js";
import { workspaceClippyOutcome } from "./lint-hooks.js";
import { runCommandAsync } from "./process.js";

const INSTALL_SYMBOL = Symbol.for("kendex.pi-hooks.installed");

/** How long a rendered hook may run before the command counts as unjudged. The
 * bash hooks declare `timeout: 60` in their own frontmatter. */
const HOOK_BUDGET_MS = 60_000;

/**
 * Where kendex renders a Pi hook: `<project>/.pi/kendex/hooks/<name>.sh`, then
 * the global `<PI_CODING_AGENT_DIR or ~/.pi/agent>/kendex/hooks/<name>.sh`
 * (docs/adapters/pi.md). Both roots come from the same helpers the rest of
 * these extensions use, so a session started in a subdirectory finds the same
 * project as one started at its root.
 *
 * The project script is EXECUTED, so it is behind Pi's project trust: a clone
 * the person has not trusted must not get its own code run on the first bash
 * call of the session. Untrusted, the project root is skipped and the global
 * root still answers — the person's own scripts are not the project's.
 *
 * That last sentence is an assumption, and `actionableUserDir` is what makes it
 * true. The global branch never asks about trust, so it must not be able to
 * point back into the workspace: an empty or relative `PI_CODING_AGENT_DIR`
 * roots the global scope at the session's own cwd, and an untrusted clone's
 * `kendex/hooks/<name>.sh` would then be spawned through the branch that skips
 * the trust gate. Where the global root is not the person's own there is no
 * global root here at all, and an untrusted workspace contributes nothing.
 *
 * A name neither root holds is a hook this project has not installed, and the
 * caller allows the command. runRenderedHook says why that is the right answer.
 */
function renderedHook(name: string, ctx: ExtensionContext): string | undefined {
	const trusted = projectTrusted(ctx);
	const global = actionableUserDir(ctx.cwd, trusted);
	const roots: string[] = [];
	if (trusted) roots.push(join(projectRoot(ctx.cwd), ".pi", "kendex"));
	if (global !== undefined) roots.push(join(global, "kendex"));
	for (const root of roots) {
		const script = resolve(root, "hooks", `${name}.sh`);
		if (existsSync(script)) return script;
	}
	return undefined;
}

/** A `tool_call` verdict: `undefined` allows, `block` refuses with a reason. */
type Verdict = { block: true; reason: string } | undefined;

/**
 * Run one rendered kendex hook on a bash command and map its exit status.
 *
 * The scripts under `.pi/kendex/hooks/` are the hooks — the same bytes Claude
 * Code and Codex run — and this spawns them with the payload Claude Code sends
 * a PreToolUse hook. Exit 2 is the refusal, and its stderr is the reason. That
 * removes the second implementation these guards used to carry in TypeScript.
 * Two scanners, each documented as a copy of the other, are two policies the
 * moment one of them changes.
 *
 * A hook writes an advisory to stderr and still exits 0 (`pre-commit-check`
 * does this for a commit aimed at another repository); that reaches the person
 * through the UI, never the agent. Any other non-zero status means the guard
 * did not reach a verdict, and a guard that did not run does not stand aside:
 * the command is refused, as the scripts themselves do when they cannot read
 * their input. A run past the budget is refused ahead of all of that, because
 * a killed process still carries an exit code and a hook that traps the signal
 * can exit 0 on its way out — which is a run that judged nothing wearing the
 * status of one that allowed.
 *
 * `budgetMs` exists so a suite can prove that path in milliseconds rather than
 * in a minute; nothing but a test passes it.
 *
 * No script at either root allows the command, and that is deliberate. It means
 * kendex has not installed this hook here — the package is installable from npm
 * on its own, and refusing every bash call in a project that never asked for
 * the guard would make it unusable. The case that used to hide behind this
 * answer was a resolution failure rather than an absence, and that is fixed
 * above: the roots are now the adapter's own. What is left is a script kendex
 * rendered and something later deleted, which is drift in the render tree;
 * `kendex check` and this extension's own session-start report own that, and a
 * repository does not defend against edits to its own kendex renders. Reading
 * `.pi/kendex/hooks.json` to tell "not installed" from "installed and missing"
 * would put a second model of the install state in here, which is the mistake
 * this change removes.
 */
export async function runRenderedHook(name: string, command: string, ctx: ExtensionContext, budgetMs: number = HOOK_BUDGET_MS): Promise<Verdict> {
	const script = renderedHook(name, ctx);
	if (!script) return undefined;

	const payload = JSON.stringify({ tool_name: "Bash", tool_input: { command } });
	const result = await runCommandAsync("bash", [script], ctx.cwd, budgetMs, payload);
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
		if (event.toolName !== "bash") return undefined;

		const command = typeof (event.input as { command?: unknown })?.command === "string"
			? (event.input as { command: string }).command
			: "";
		if (!command) return undefined;

		// Each guard is the rendered script kendex delivered, run in order and
		// keyed by the setting that arms it.
		for (const [setting, name] of [
			["blockBareCd", "block-bare-cd"],
			["blockRepoCopy", "block-repo-copy"],
			["preCommitCheck", "pre-commit-check"],
		] as const) {
			if (!getBool(cfg, setting)) continue;
			const verdict = await runRenderedHook(name, command, ctx);
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
