import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, isAbsolute, resolve } from "node:path";

import { getBool, getNumber, piRoots, projectTrusted, readConfig, recordProjectTrust } from "./config.js";
import { deliverDrift, runDriftCheck } from "./drift-check.js";
import { workspaceClippyOutcome } from "./lint-hooks.js";
import { runCommandAsync } from "./process.js";

const INSTALL_SYMBOL = Symbol.for("kendex.pi-hooks.installed");

/** How long a rendered hook may run before the command counts as unjudged. The
 * bash hooks declare `timeout: 60` in their own frontmatter. */
const HOOK_BUDGET_MS = 60_000;

/**
 * Where kendex renders a Pi hook: `<project>/.pi/kendex/hooks/<name>.sh`, then
 * the global `<absolute PI_CODING_AGENT_DIR or ~/.pi/agent>/kendex/hooks/<name>.sh`.
 *
 * The project script is EXECUTED, so it is behind Pi's project trust: a clone
 * the person has not trusted must not get its own code run on the first bash
 * call of the session. Untrusted, the project root is skipped and the global
 * root still answers — the person's own scripts are not the project's.
 *
 * Pi exposes trust only for the current project. An ancestor render therefore
 * proves a guard exists but cannot prove its code is trusted. Refuse instead of
 * applying the descendant's trust answer to it. A current-project render also
 * needs `.pi/settings.json`, a Pi-protected resource that prevents a hook-only
 * checkout from becoming trusted merely because the hook exists.
 */
function renderedHook(name: string, ctx: ExtensionContext): { script: string } | { refusal: string } | undefined {
	const exactProject = resolve(ctx.cwd);
	const home = resolve(homedir());
	let current = exactProject;
	while (current !== home) {
		const script = resolve(current, ".pi", "kendex", "hooks", `${name}.sh`);
		if (existsSync(script)) {
			if (current !== exactProject) {
				return { refusal: `pi-hooks: ${name} is installed for ancestor ${current}, but Pi cannot confirm trust for that exact project while the session is in ${exactProject}.` };
			}
			if (!existsSync(resolve(current, ".pi", "settings.json"))) {
				return { refusal: `pi-hooks: ${name} exists in ${current}, but that project has no .pi/settings.json trust companion.` };
			}
			if (!projectTrusted(ctx)) {
				return { refusal: `pi-hooks: ${name} exists in ${current}, but Pi does not report that exact project as trusted.` };
			}
			return { script };
		}
		const parent = dirname(current);
		if (parent === current) break;
		current = parent;
	}

	const global = piRoots(ctx.cwd, false).global;
	if (!global) return undefined;
	const script = resolve(global, "kendex", "hooks", `${name}.sh`);
	return existsSync(script) ? { script } : undefined;
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
 * No script at either scope means kendex has not installed this hook, so the
 * command passes. A project script found without exact authorization is
 * different: the guard exists, but executing its code is unsafe, so the
 * command is refused before spawn.
 */
export async function runRenderedHook(name: string, command: string, ctx: ExtensionContext): Promise<Verdict> {
	const rendered = renderedHook(name, ctx);
	if (!rendered) return undefined;
	if ("refusal" in rendered) return { block: true, reason: rendered.refusal };

	const payload = JSON.stringify({ tool_name: "Bash", tool_input: { command } });
	const result = await runCommandAsync("bash", [rendered.script], ctx.cwd, HOOK_BUDGET_MS, payload);
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
			reason: `pi-hooks: ${name} timed out after ${HOOK_BUDGET_MS}ms in ${ctx.cwd}, so this command was not judged; a guard that did not run does not stand aside.`,
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
