import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { isAbsolute, resolve } from "node:path";

import { getBool, getNumber, projectRoot, projectTrusted, readConfig, recordProjectTrust } from "./config.js";
import { agentLine, deliver, type HookResult, personLine, runListener, unreadableLine } from "./dispatch.js";
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
	 * How many times the `Stop` registrations have been consulted about the
	 * response now ending, and whether this carrier is the reason another one
	 * followed.
	 *
	 * A message sent with `triggerTurn: true` makes the agent answer, and that
	 * answer settles in its turn — so a dispatch that steers is a dispatch that
	 * asks to be run again, against on-disk state nothing has changed. Left
	 * unbounded, one hook that keeps speaking drives an unattended run through
	 * LLM calls and subprocess spawns for as long as it has to say it, and two
	 * shapes need no author error at all: a registry that will not parse and a
	 * registration whose rendered script is absent both say their piece every
	 * time and can never stop saying it.
	 *
	 * So the steer is spent once per consultation. The words go into the run on
	 * the first dispatch and are recorded without steering on the dispatch that
	 * steer caused, which ends the chain at two dispatches and one extra run.
	 * `settles` therefore rides across a continuation and resets on any settle
	 * this carrier did not cause — not on `agent_start` or `turn_start`, since
	 * a steered turn is a new turn and a steered run a new run, but the same
	 * consultation.
	 */
	let settles = 0;
	let steeredThisRun = false;

	/** The person's channel: a UI notification, where there is a UI to take it. */
	const notify = (ctx: ExtensionContext, level: "info" | "warning") => (content: string) => {
		if (ctx.hasUI) ctx.ui.notify(content, level);
	};

	/**
	 * Everything one registered hook said on a listener Pi gives no verdict to.
	 * `toAgent` is the listener's own way of putting words in front of the
	 * model — a patched tool result, a steered message, a session's opening
	 * context — and stderr beside a clean exit goes to the person instead.
	 *
	 * Each delivery goes through `deliver`, so one channel that is gone — the
	 * session replaced under a `session_start` report that is still in flight —
	 * costs its own line and not the rest of the listener's output.
	 */
	const report = (results: HookResult[], ctx: ExtensionContext, toAgent: (content: string) => void): void => {
		for (const result of results) {
			const forAgent = agentLine(result, ctx);
			if (forAgent !== undefined) deliver(toAgent, forAgent);
			const forPerson = personLine(result);
			if (forPerson !== undefined) deliver(notify(ctx, "info"), forPerson);
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
			if (run.unreadable !== undefined) deliver(speak, unreadableLine(SESSION_START_LISTENER, run.unreadable));
			report(run.results, ctx, speak);
			// Nothing awaits this chain, so it terminates in a catch: every
			// hook here runs to its own budget while the session opens, and by
			// the time the last one settles the session may have been replaced
			// — at which point `pi` and `ctx` throw, and an unhandled rejection
			// ends the process rather than reaching a handler Pi can absorb.
			// Whichever channel is still alive says what was caught.
		}).catch((error: unknown) => {
			const line = `pi-hooks: the ${SESSION_START_LISTENER} hooks were not reported: ${
				error instanceof Error ? error.message : String(error)
			}`;
			deliver(speak, line);
			deliver(notify(ctx, "info"), line);
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

	// `Stop` and `TaskCompleted` fire when Claude Code's agent has finished
	// responding, and Pi's word for that is `agent_settled` — documented as the
	// point Pi "will not continue running automatically". `turn_end` sits
	// inside the tool loop — Pi's extension reference draws it inside the
	// block marked "turn (repeats while LLM calls tools)" — so reading the
	// registry there would run every `Stop`
	// registration once per LLM turn — a subprocess per round for the checks
	// people put on `Stop`, and a request taking K tool-calling rounds paying
	// K+1 of them. kendex still renders those registrations under the
	// `turn_end` key (`caps.rs::pi_listener`); this is the listener that reads
	// that key, and the clippy lane below is what `turn_end` is still for.
	pi.on("agent_settled", async (_event, ctx: ExtensionContext) => {
		const project = ctx.cwd ? projectRoot(ctx.cwd) : undefined;
		recordProjectTrust(ctx, project);
		const cfg = readConfig(ctx.cwd, project);
		if (!getBool(cfg, "enabled")) return undefined;

		// A settle this carrier's own steer caused continues one consultation;
		// any other settle opens a new one.
		if (!steeredThisRun) settles = 0;
		steeredThisRun = false;
		const stopHookActive = settles > 0;
		settles += 1;

		// Pi discards this handler's return value and blocks nothing here, so
		// a hook's refusal is delivered rather than obeyed. Since pi#8022 a
		// `triggerTurn: false` message is recorded without steering, which a
		// headless run that is ending never reads, so `triggerTurn: true` is
		// the only delivery that reaches the agent in every mode — and it is
		// spent on the first dispatch of a consultation, because steering
		// again is what makes the loop.
		//
		// `display: false` leaves interactive rendering to the notification
		// beside it, which a headless session never sees.
		const say = (content: string) => {
			if (!stopHookActive) steeredThisRun = true;
			pi.sendMessage({ customType: "kendex-hook", content, display: false }, { triggerTurn: !stopHookActive });
			if (ctx.hasUI) ctx.ui.notify(content, "warning");
		};

		// `Stop` and `TaskCompleted` take no matcher on Claude Code either, so
		// every registration on this listener covers the response. The payload
		// is Claude Code's, `stop_hook_active` included, and it is true exactly
		// when this dispatch is running because the last one steered — which is
		// what the field is for: a hook reading it knows it is already the
		// reason the agent kept going, and can stand down the way it does on
		// Claude Code.
		const run = await runListener(
			TURN_END_LISTENER,
			undefined,
			JSON.stringify({ hook_event_name: "Stop", stop_hook_active: stopHookActive }),
			ctx,
			cfg,
			project,
			projectTrusted(ctx),
		);
		if (run.unreadable !== undefined) deliver(say, unreadableLine(TURN_END_LISTENER, run.unreadable));
		report(run.results, ctx, say);
		return undefined;
	});

	pi.on("turn_end", async (_event, ctx: ExtensionContext) => {
		const project = ctx.cwd ? projectRoot(ctx.cwd) : undefined;
		recordProjectTrust(ctx, project);
		const cfg = readConfig(ctx.cwd, project);
		if (!getBool(cfg, "enabled")) return undefined;
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
