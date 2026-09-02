import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { isAbsolute, resolve } from "node:path";

import { getBool, getNumber, projectRoot, projectTrusted, readConfig, recordProjectTrust } from "./config.js";
import { agentLine, type HookResult, personLine, runListener, unreadableLine } from "./dispatch.js";
import { deliverDrift, runDriftCheck } from "./drift-check.js";
import { workspaceClippyOutcome } from "./lint-hooks.js";
import { SESSION_START_LISTENER, TOOL_CALL_LISTENER, TOOL_RESULT_LISTENER, TURN_END_LISTENER } from "./registry.js";
import { claudeSessionSource, claudeToolInput, claudeToolName } from "./vocab.js";

const INSTALL_SYMBOL = Symbol.for("kendex.pi-hooks.installed");

export { GUARD_SETTING_NAMES } from "./dispatch.js";

/** A `tool_call` verdict: `undefined` allows, `block` refuses with a reason. */
type Verdict = { block: true; reason: string } | undefined;

/**
 * One registered hook's verdict on a tool call. Exit 2 is the refusal, and its
 * stderr is the reason. A hook writes an advisory to stderr and still exits 0
 * (`pre-commit-check` does this for a commit aimed at another repository);
 * that reaches the person through the UI, never the agent. Any other non-zero
 * status means the guard did not reach a verdict, and a guard that did not run
 * does not stand aside: the command is refused. So is a hook that never ran at
 * all — a missing render, or a run past its budget.
 *
 * Refusals name `hook.label`, never the command: a command-bodied hook is text
 * the person wrote, it can hold a credential inline, and a reason is read by
 * the model.
 */
export function toolCallVerdict(result: HookResult, ctx: ExtensionContext): Verdict {
	const name = result.hook.label;
	const outcome = result.outcome;
	if (!outcome.ran) {
		return {
			block: true,
			reason: "missing" in outcome
				? `pi-hooks: ${name} is registered and its rendered script is missing (${outcome.missing}), so this command was not judged; run kendex refresh.`
				: `pi-hooks: ${name} timed out after ${outcome.timedOutAfterMs}ms in ${ctx.cwd}, so this command was not judged; a guard that did not run does not stand aside.`,
		};
	}
	if (outcome.exitCode === 2) return { block: true, reason: outcome.stderr || `${name} refused this command.` };
	if (outcome.exitCode !== 0) {
		return {
			block: true,
			reason: `pi-hooks: ${name} exited ${outcome.exitCode} without judging this command${outcome.stderr ? `: ${outcome.stderr}` : "."}`,
		};
	}
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

	/**
	 * Everything one registered hook said on a listener Pi gives no verdict to.
	 * `toAgent` is the listener's own way of putting words in front of the
	 * model — a patched tool result, a steered message, a session's opening
	 * context — and stderr beside a clean exit goes to the person instead.
	 */
	const report = (results: HookResult[], ctx: ExtensionContext, toAgent: (content: string) => void): void => {
		for (const result of results) {
			const forAgent = agentLine(result, ctx);
			if (forAgent !== undefined) toAgent(forAgent);
			const forPerson = personLine(result);
			if (forPerson !== undefined && ctx.hasUI) ctx.ui.notify(forPerson, "info");
		}
	};

	// Pi port of hooks/session-drift-check.sh. Fresh starts only: a resumed
	// session already carries the report and a reload re-runs extensions in
	// place. Fire-and-forget — an informational check never gates startup.
	//
	// The rendered registry is dispatched beside it, and neither waits: a
	// registered `SessionStart` hook runs to its own budget while the session
	// opens, and says what it has to say when it settles. Pi refuses no
	// session start, so nothing here could gate one even if it wanted to.
	pi.on("session_start", (event, ctx: ExtensionContext) => {
		const project = ctx.cwd ? projectRoot(ctx.cwd) : undefined;
		recordProjectTrust(ctx, project);
		const cfg = readConfig(ctx.cwd, project);
		if (!getBool(cfg, "enabled")) return;

		const speak = (content: string) => {
			pi.sendMessage({ customType: "kendex-hook", content, display: true }, { triggerTurn: false });
		};
		const source = claudeSessionSource(event.reason);
		void runListener(
			SESSION_START_LISTENER,
			source,
			JSON.stringify({ hook_event_name: "SessionStart", source }),
			ctx,
			cfg,
			project,
			projectTrusted(ctx),
		).then((run) => {
			if (run.unreadable !== undefined) speak(unreadableLine(SESSION_START_LISTENER, run.unreadable));
			report(run.results, ctx, speak);
		});

		if (event.reason === "reload" || event.reason === "resume") return;
		if (!getBool(cfg, "sessionDriftCheck")) return;

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
		// Resolved once and threaded through. The walk is an ancestor stat per
		// level, and trust, settings and the registries all want the same
		// answer for one event.
		const project = ctx.cwd ? projectRoot(ctx.cwd) : undefined;
		recordProjectTrust(ctx, project);
		const cfg = readConfig(ctx.cwd, project);
		if (!getBool(cfg, "enabled")) return undefined;

		// The registry kendex rendered is the list: every hook it names for
		// this listener and this tool runs, in the order it names them, and
		// the first refusal is the answer. Nothing here knows a hook's name in
		// advance, which is what lets a custom hook run at all. The tool is
		// named and its input keyed the way a hook was authored to read them.
		const toolName = claudeToolName(event.toolName);
		const payload = JSON.stringify({
			tool_name: toolName,
			tool_input: claudeToolInput(toolName, event.input),
		});
		let verdict: Verdict;
		const run = await runListener(
			TOOL_CALL_LISTENER,
			toolName,
			payload,
			ctx,
			cfg,
			project,
			projectTrusted(ctx),
			(result) => (verdict = toolCallVerdict(result, ctx)) !== undefined,
		);

		// A registry kendex wrote and this could not read is not the person
		// standing their guards down, and these hooks are labelled enforced.
		if (run.unreadable !== undefined) {
			return {
				block: true,
				reason: `pi-hooks: the rendered hook registry could not be read, so this command was not judged; a guard that did not run does not stand aside. ${run.unreadable}`,
			};
		}
		// Said whatever the answer is: a guard that let the call through with
		// something to tell the person told it before the guard behind it
		// refused, and a refusal is not a reason to swallow it.
		for (const result of run.results) {
			const advisory = personLine(result);
			if (advisory !== undefined && ctx.hasUI) ctx.ui.notify(advisory, "info");
		}
		return verdict;
	});

	pi.on("tool_result", async (event, ctx: ExtensionContext) => {
		const project = ctx.cwd ? projectRoot(ctx.cwd) : undefined;
		recordProjectTrust(ctx, project);
		const cfg = readConfig(ctx.cwd, project);
		if (!getBool(cfg, "enabled")) return undefined;

		const tool = event.toolName.toLowerCase();
		const rawPath = (event.input as { path?: unknown })?.path;
		const filePath = typeof rawPath === "string" ? rawPath : "";
		if ((tool === "edit" || tool === "write") && filePath.endsWith(".rs")) {
			// Recorded for the end-of-turn check, which is the only lane that
			// runs clippy. A .rs write costs nothing here.
			turn.rustFilesTouched.add(isAbsolute(filePath) ? filePath : resolve(ctx.cwd, filePath));
		}

		// Claude Code's `PostToolUse` payload, in the words a hook authored
		// against it reads: the call it judged, plus what the tool answered.
		// `tool_response` is the result's text, which is the whole of it for
		// every tool a bash hook can read — an image block has no rendering a
		// JSON payload could carry and is left out rather than faked.
		const toolName = claudeToolName(event.toolName);
		const payload = JSON.stringify({
			hook_event_name: "PostToolUse",
			tool_name: toolName,
			tool_input: claudeToolInput(toolName, event.input),
			tool_response: event.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("\n"),
		});
		const run = await runListener(TOOL_RESULT_LISTENER, toolName, payload, ctx, cfg, project, projectTrusted(ctx));

		// The tool has already run, so nothing here refuses anything: what a
		// hook says is appended to the result the model reads, which is the
		// consequence Claude Code's own `PostToolUse` exit 2 has. `isError` is
		// left exactly as the tool set it — the call succeeded or failed on its
		// own terms, and a hook's opinion of it is not that answer.
		const added: string[] = [];
		if (run.unreadable !== undefined) added.push(unreadableLine(TOOL_RESULT_LISTENER, run.unreadable));
		report(run.results, ctx, (content) => added.push(content));
		if (added.length === 0) return undefined;
		return { content: [...event.content, { type: "text" as const, text: added.join("\n") }] };
	});

	pi.on("turn_end", async (_event, ctx: ExtensionContext) => {
		const project = ctx.cwd ? projectRoot(ctx.cwd) : undefined;
		recordProjectTrust(ctx, project);
		const cfg = readConfig(ctx.cwd, project);
		if (!getBool(cfg, "enabled")) return undefined;

		// Pi discards a turn_end handler's return value, and since pi#8022 a
		// `triggerTurn: false` message is recorded without steering, which a
		// headless run that is ending never reads. `triggerTurn: true` steers
		// the active run, so the loop drains it after this event and the agent
		// answers for what a hook said in every mode. That is the whole of
		// what Pi offers here: `Stop` and `TaskCompleted` block on Claude Code
		// and nothing can block a turn ending on Pi, so a hook's refusal is
		// delivered rather than obeyed.
		//
		// `display: false` leaves interactive rendering to the notification
		// beside it, which a headless session never sees.
		const steer = (content: string) => {
			pi.sendMessage({ customType: "kendex-hook", content, display: false }, { triggerTurn: true });
			if (ctx.hasUI) ctx.ui.notify(content, "warning");
		};

		// `Stop` and `TaskCompleted` take no matcher on Claude Code either, so
		// every registration on this listener covers this turn. The payload is
		// Claude Code's: this carrier never re-enters a hook on its own reply,
		// so `stop_hook_active` is honestly false.
		const run = await runListener(
			TURN_END_LISTENER,
			undefined,
			JSON.stringify({ hook_event_name: "Stop", stop_hook_active: false }),
			ctx,
			cfg,
			project,
			projectTrusted(ctx),
		);
		if (run.unreadable !== undefined) steer(unreadableLine(TURN_END_LISTENER, run.unreadable));
		report(run.results, ctx, steer);

		if (!getBool(cfg, "taskCompletedCheck")) return undefined;
		if (turn.rustFilesTouched.size === 0) return undefined;

		const outcome = workspaceClippyOutcome(ctx.cwd, getNumber(cfg, "clippyTimeoutMs"));
		if (outcome.kind === "clean") return undefined;
		const summary = outcome.kind === "errors"
			? `pi-hooks: clippy reported ${outcome.lines.length} workspace error(s) at turn end:\n${outcome.lines.slice(0, 5).join("\n")}`
			: `pi-hooks: end-of-turn clippy proved nothing about the tree: ${outcome.reason}.`;

		// Every failing turn reports: an agent that cannot fix an error hears
		// the same advisory each turn, which is noisy and self-correcting,
		// where suppressing a repeat can leave a headless turn told nothing
		// when there was something to say. The turn state above is the bound —
		// a turn that writes no `.rs` file runs no clippy — so a report costs
		// an edit, not a loop.
		pi.sendMessage(
			{ customType: "kendex-clippy", content: summary, display: false },
			{ triggerTurn: true },
		);
		if (ctx.hasUI) ctx.ui.notify(summary, outcome.kind === "errors" ? "warning" : "info");
		return undefined;
	});
}
