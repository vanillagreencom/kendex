import type {
	AgentBeforeSettleEvent,
	AgentBeforeSettleEventResult,
	CustomMessageEntryDraft,
	ExtensionAPI,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { isAbsolute, resolve } from "node:path";

import { getBool, getNumber, projectRoot, readConfig, recordProjectTrust } from "./config.js";
import { installSettingsCacheRefresh, projectTrusted } from "./package-config.js";
import { agentLine, boundForAgent, deliver, type HookResult, type ListenerRun, personLine, runListener, unreadableLine } from "./dispatch.js";
import { deliverDrift, runDriftCheck } from "./drift-check.js";
import { workspaceClippyOutcome } from "./lint-hooks.js";
import { SESSION_END_LISTENER, SESSION_START_LISTENER, STOP_FAILURE_LISTENER, TOOL_CALL_LISTENER, TOOL_RESULT_LISTENER, TURN_END_LISTENER } from "./registry.js";
import { claudeFailureFields, claudeSessionEndReason, claudeSessionFields, claudeSessionSource, claudeToolInput, claudeToolName, piContextFields, piSubagentName } from "./vocab.js";

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
	const outcome = result.outcome;
	if (!outcome.ran || outcome.exitCode !== 0) {
		// Dispatch owns each diagnostic on every listener. Failed outcomes
		// always have a message; only a successful silent hook returns none.
		const reason = agentLine(result, ctx);
		if (reason === undefined) throw new Error("failed hook outcome has no diagnostic");
		return { block: true, reason };
	}
	return undefined;
}

/**
 * The line a host too old for the `Stop` listener gets, or `undefined` on a
 * host that has it. Pi fires `agent_before_settle` from 0.87.0, and below that
 * every `Stop`, `TaskCompleted` and `StopFailure` registration is skipped with
 * no error. The Pi peer range names the floor, but neither kendex nor Pi checks
 * peers when it installs an extension, so this says it instead. It serves Pi
 * 0.74.0, the first `@earendil-works` release, to 0.86.x. Remove it once no Pi
 * below 0.87.0 can load this package. A version that does not parse as
 * `major.minor` is not called old.
 *
 * The host's `VERSION` is read here, at a fresh start, and not when this
 * module loads: inside Pi the package name resolves through Pi's own loader,
 * and a load outside Pi, such as kendex's carrier test under bare bun, has no
 * such package to resolve. There this names nothing.
 */
async function unsupportedHostLine(): Promise<string | undefined> {
	let version: string;
	try {
		({ VERSION: version } = await import("@earendil-works/pi-coding-agent"));
	} catch {
		return undefined;
	}
	const [major, minor] = version.split(".").map(Number);
	if (major === 0 && minor !== undefined && minor < 87) {
		return `hook-host-unsupported=pi ${version}\nStop, TaskCompleted and StopFailure hooks do not run on this Pi. Upgrade Pi to 0.87.0 or later.`;
	}
	return undefined;
}

export default function piHooks(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[INSTALL_SYMBOL]) return;
	guard[INSTALL_SYMBOL] = true;

	/**
	 * The `.rs` files edited since the last end-of-turn check that finished.
	 * A check the person ended before it finished proved nothing about them,
	 * so they stay here for the next turn's check, which runs even if that
	 * turn edits no `.rs` file. Pi fires `turn_end` with the run's signal
	 * already aborted when the person ends a run during its tool calls.
	 */
	let rustFilesTouched = new Set<string>();

	/**
	 * Whether the last `agent_before_settle` dispatch asked Pi for its one
	 * continuation. Pi runs that continuation inside the same run and asks
	 * again before the run settles, and that next dispatch reads this, clears
	 * it and says `stop_hook_active: true`.
	 *
	 * A continuation makes the agent answer against on-disk state nothing has
	 * changed, so one that is asked for every time drives an unattended run
	 * through model requests and hook spawns for as long as a hook speaks, and
	 * two shapes need no author error at all: a registry that will not parse
	 * and a registration whose rendered script is absent both say their piece
	 * every time. The dispatch that reads this set therefore records what it
	 * is told and asks for nothing, which ends a response at two dispatches and
	 * one extra model request. A run Pi ends before that second dispatch, an
	 * abort inside the continuation, clears it at `agent_settled`.
	 */
	let continued = false;

	/** The person's channel: a UI notification, where there is a UI to take it. */
	const notify = (ctx: ExtensionContext, level: "info" | "warning") => (content: string) => {
		if (ctx.hasUI) ctx.ui.notify(content, level);
	};

	/**
	 * The person's channel on `StopFailure` and `SessionEnd`, whose hooks speak
	 * to the person alone: a notification where a UI will show it, else stderr.
	 * A print-mode session has no UI, and a quit the person asks for stops
	 * Pi's TUI before Pi emits `session_shutdown` with reason `quit`; `uiGone`
	 * is the listener's word for the second, which `hasUI` does not say.
	 */
	const tellPerson = (ctx: ExtensionContext, uiGone: boolean) => (content: string) => {
		if (uiGone || !ctx.hasUI) process.stderr.write(`${content}\n`);
		else ctx.ui.notify(content, "warning");
	};

	/**
	 * Everything an event's hooks said outside a tool refusal's reason.
	 * `toListener` is the listener's own channel for what its hooks say: the
	 * model's on `tool_call`, `tool_result`, `turn_end` and `session_start` —
	 * a patched tool result, an entry the settle boundary appends, a session's
	 * opening context — and the person's on `StopFailure` and `SessionEnd`,
	 * whose hooks Claude Code reads nothing from. It is called at most once,
	 * with every hook's text and an unreadable registry's line joined and
	 * bounded by `boundForAgent`. Stderr beside a clean exit goes to
	 * `toPerson` instead.
	 *
	 * Each delivery goes through `deliver`, so one channel that is gone — the
	 * session replaced under a `session_start` report that is still in flight —
	 * costs its own text and not the rest of the listener's output.
	 */
	const report = async (
		listener: string,
		run: ListenerRun,
		ctx: ExtensionContext,
		toListener: (content: string) => void,
		toPerson: (content: string) => void = notify(ctx, "info"),
	): Promise<void> => {
		const forListener: string[] = [];
		if (run.unreadable !== undefined) forListener.push(unreadableLine(listener, run.unreadable));
		for (const result of run.results) {
			const said = agentLine(result, ctx);
			if (said !== undefined) forListener.push(said);
			const forPerson = personLine(result);
			if (forPerson !== undefined) deliver(toPerson, forPerson);
		}
		if (forListener.length > 0) deliver(toListener, await boundForAgent(forListener.join("\n")));
	};

	// Pi port of hooks/session-drift-check.sh. Fresh starts only: a resumed
	// session already carries the report and a reload re-runs extensions in
	// place. Fire-and-forget — an informational check never gates startup.
	//
	// The rendered registry is dispatched beside it, and neither waits: a
	// registered `SessionStart` hook runs to its own budget while the session
	// opens, and says what it has to say when it settles. Pi refuses no
	// session start, so nothing here could gate one even if it wanted to.
	installSettingsCacheRefresh(pi);
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
			() => JSON.stringify({ hook_event_name: "SessionStart", source, ...claudeSessionFields(ctx) }),
			ctx,
			cfg,
			project,
			projectTrusted(ctx),
		).then((run) => report(SESSION_START_LISTENER, run, ctx, speak))
			// Nothing awaits this chain, so it terminates in a catch: every
			// hook here runs to its own budget while the session opens, and by
			// the time the last one settles the session may have been replaced
			// — at which point `pi` and `ctx` throw, and an unhandled rejection
			// ends the process rather than reaching a handler Pi can absorb.
			// Whichever channel is still alive says what was caught.
			.catch((error: unknown) => {
				const line = `hook-report-failed=${SESSION_START_LISTENER}\n${
					error instanceof Error ? error.message : String(error)
				}`;
				deliver(speak, line);
				deliver(notify(ctx, "info"), line);
			});

		if (event.reason === "reload" || event.reason === "resume") return;
		// A fresh start alone, as the drift report below: a resumed session
		// already carries the line.
		void unsupportedHostLine().then((hostLine) => {
			if (hostLine === undefined) return;
			deliver(speak, hostLine);
			deliver(notify(ctx, "warning"), hostLine);
		});
		if (!getBool(cfg, "sessionDriftCheck")) return;
		// pi-agents-tmux children work on delegated tasks; the lead session
		// owns installation drift and receives the report instead.
		if (piSubagentName() !== undefined) return;

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
		// named and its input keyed the way a hook was authored to read them,
		// and only once a hook is about to read them.
		const toolName = claudeToolName(event.toolName);
		const payload = () => JSON.stringify({
			tool_name: toolName,
			tool_input: claudeToolInput(toolName, event.input, ctx.cwd),
			...claudeSessionFields(ctx),
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
				reason: unreadableLine(TOOL_CALL_LISTENER, run.unreadable),
			};
		}
		// Successful hooks contribute context even when a later guard refuses.
		// Pi owns delivery before the next model request in every session mode;
		// no new turn is needed because this tool call already has a follow-up.
		await report(
			TOOL_CALL_LISTENER,
			{ results: run.results.filter(({ outcome }) => outcome.ran && outcome.exitCode === 0) },
			ctx,
			(content) => pi.sendMessage({ customType: "kendex-hook", content, display: true }, { triggerTurn: false }),
		);
		// A refusal's reason is a hook's own stderr, and the model reads it.
		return verdict === undefined ? undefined : { block: true, reason: await boundForAgent(verdict.reason) };
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
			rustFilesTouched.add(isAbsolute(filePath) ? filePath : resolve(ctx.cwd, filePath));
		}

		// Claude Code's `PostToolUse` payload, in the words a hook authored
		// against it reads: the call it judged, plus what the tool answered.
		// `tool_response` is the result's text, which is the whole of it for
		// every tool a bash hook can read — an image block has no rendering a
		// JSON payload could carry and is left out rather than faked. It also
		// carries the model's `context_window`, as the `Stop` payload does, so
		// a hook judging the session's context after a tool call reads the
		// window from Pi and not from an earlier turn end's record. Built only
		// once a hook is about to read it: joining a large result costs every
		// tool call, and most calls have no hook.
		const toolName = claudeToolName(event.toolName);
		const payload = () => JSON.stringify({
			hook_event_name: "PostToolUse",
			tool_name: toolName,
			tool_input: claudeToolInput(toolName, event.input, ctx.cwd),
			tool_response: event.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("\n"),
			...claudeSessionFields(ctx),
			...piContextFields(ctx),
		});
		const run = await runListener(TOOL_RESULT_LISTENER, toolName, payload, ctx, cfg, project, projectTrusted(ctx));

		// The tool has already run, so nothing here refuses anything: what a
		// hook says is appended to the result the model reads, which is the
		// consequence Claude Code's own `PostToolUse` exit 2 has. `isError` is
		// left exactly as the tool set it — the call succeeded or failed on its
		// own terms, and a hook's opinion of it is not that answer.
		const added: { type: "text"; text: string }[] = [];
		await report(TOOL_RESULT_LISTENER, run, ctx, (text) => added.push({ type: "text", text }));
		if (added.length === 0) return undefined;
		return {
			content: [...event.content, ...added],
			// Hook context does not change the tool's own structured output.
			structuredContent: "structuredContent" in event ? event.structuredContent : undefined,
		};
	});

	// `Stop` and `TaskCompleted` fire when Claude Code's agent has finished
	// responding, and Pi's word for that is `agent_before_settle`: the final
	// boundary of a run, once no retry, recovery or queued message is left,
	// where a handler can append entries and ask for one more model request.
	// `turn_end` fires once per LLM turn inside the tool loop, so reading the
	// registry there would run every `Stop` registration once per tool-calling
	// round. kendex still renders those registrations under the `turn_end` key
	// (`caps.rs::pi_listener`); this is the listener that reads that key, and
	// the clippy lane below is what `turn_end` is still for.
	const consultStop = async (
		event: AgentBeforeSettleEvent,
		ctx: ExtensionContext,
	): Promise<AgentBeforeSettleEventResult | undefined> => {
		const project = ctx.cwd ? projectRoot(ctx.cwd) : undefined;
		recordProjectTrust(ctx, project);
		const cfg = readConfig(ctx.cwd, project);
		if (!getBool(cfg, "enabled")) return undefined;
		// Claude Code ends a subagent with `SubagentStop`, never `Stop`, and Pi
		// maps no `SubagentStop`. A pi-agents-tmux subagent is its own Pi
		// process, so its settle is a subagent's end, and the registrations
		// here, which judge the lead session, are not consulted for it.
		if (piSubagentName() !== undefined) return undefined;

		const stopHookActive = continued;
		continued = false;

		// Pi refuses nothing here, so a hook's refusal is delivered rather than
		// obeyed: what the hooks said becomes one session entry the next model
		// request reads, and a `display: false` one leaves interactive
		// rendering to the notification beside it, which a headless session
		// never sees.
		let said: CustomMessageEntryDraft | undefined;
		const say = (content: string) => {
			said = { type: "custom_message", customType: "kendex-hook", content, display: false };
			if (ctx.hasUI) ctx.ui.notify(content, "warning");
		};

		// `Stop` and `TaskCompleted` take no matcher on Claude Code either, so
		// every registration on this listener covers the response. The payload
		// is Claude Code's, `stop_hook_active` included, and it is true exactly
		// when this dispatch is running because the last one asked for the
		// continuation, which is what the field is for: a hook reading it knows
		// it is already the reason the agent kept going, and can stand down the
		// way it does on Claude Code. It also carries the model's
		// `context_window`, which Pi alone has to hand over: its session file
		// never names one.
		const run = await runListener(
			TURN_END_LISTENER,
			undefined,
			() => JSON.stringify({ hook_event_name: "Stop", stop_hook_active: stopHookActive, ...claudeSessionFields(ctx), ...piContextFields(ctx) }),
			ctx,
			cfg,
			project,
			projectTrusted(ctx),
		);
		await report(TURN_END_LISTENER, run, ctx, say);

		// `StopFailure` ends a turn an API error ended, which Pi says of a run
		// as `outcome: "error"`, and only there. Pi names no error kind, so
		// every registration covers it. Claude Code fires it in place of
		// `Stop`; here `Stop` above still runs on an errored run, because the
		// Pi lane's walled verdict reads that `Stop` row (`lane_row` in
		// `hooks/lane-mail-check.sh`, run at its `stop` arm, writes it through
		// `session_rows_lane_write`, which reads the transcript's
		// `stopReason`). A `Stop` row written after a `StopFailure` row lifts
		// it, so these run last in the settle, whatever the `Stop` dispatch
		// returns. Claude Code reads nothing a `StopFailure` hook says, so its
		// word goes to the person, never into the session as a continuation
		// the error would refuse again. It judges the lead alone, as `Stop`
		// does: the payload carries no `agent_id`, the field such a hook tells
		// a subagent's failure by. Its `last_assistant_message` is the failed
		// response's error text (`vocab.ts::claudeFailureFields`).
		if (event.outcome === "error") {
			const failed = await runListener(
				STOP_FAILURE_LISTENER,
				undefined,
				() => JSON.stringify({ hook_event_name: "StopFailure", ...claudeSessionFields(ctx), ...claudeFailureFields(event.context.contextMessages) }),
				ctx,
				cfg,
				project,
				projectTrusted(ctx),
			);
			const person = tellPerson(ctx, false);
			await report(STOP_FAILURE_LISTENER, failed, ctx, person, person);
		}

		if (said === undefined) return undefined;
		// Chained after what earlier handlers proposed, and `continue` is
		// returned only as `true`: a `false` here would cancel another
		// handler's continuation.
		const entries = [...event.entries, said];
		if (stopHookActive) return { entries };
		continued = true;
		return { entries, continue: true };
	};

	pi.on("agent_before_settle", consultStop);

	pi.on("agent_settled", () => {
		continued = false;
	});

	// `SessionEnd` is Pi's `session_shutdown`, which Pi awaits before it
	// replaces or disposes the session, so every registration runs while the
	// session still stands. Its reason is said in Claude Code's `SessionEnd`
	// words (`vocab.ts::claudeSessionEndReason`). Claude Code reads nothing a
	// `SessionEnd` hook says, and no turn is left for the agent, so what the
	// hooks say goes to the person, on stderr at a `quit` the person asks for,
	// whose UI is gone.
	pi.on("session_shutdown", async (event, ctx: ExtensionContext) => {
		const project = ctx.cwd ? projectRoot(ctx.cwd) : undefined;
		recordProjectTrust(ctx, project);
		const cfg = readConfig(ctx.cwd, project);
		if (!getBool(cfg, "enabled")) return;

		const reason = claudeSessionEndReason(event.reason);
		const run = await runListener(
			SESSION_END_LISTENER,
			reason,
			() => JSON.stringify({ hook_event_name: "SessionEnd", reason, ...claudeSessionFields(ctx) }),
			ctx,
			cfg,
			project,
			projectTrusted(ctx),
		);
		const person = tellPerson(ctx, event.reason === "quit");
		await report(SESSION_END_LISTENER, run, ctx, person, person);
	});

	pi.on("turn_end", async (_event, ctx: ExtensionContext) => {
		const touched = rustFilesTouched;
		rustFilesTouched = new Set<string>();
		const project = ctx.cwd ? projectRoot(ctx.cwd) : undefined;
		recordProjectTrust(ctx, project);
		const cfg = readConfig(ctx.cwd, project);
		if (!getBool(cfg, "enabled")) return undefined;
		if (!getBool(cfg, "taskCompletedCheck")) return undefined;
		if (touched.size === 0) return undefined;

		// Awaited, so the turn's report lands before the next turn starts, but
		// never on Pi's thread: input, timers and other listeners run while
		// cargo compiles. The turn's own signal stops it when the person ends
		// the turn.
		const outcome = await workspaceClippyOutcome(ctx.cwd, getNumber(cfg, "clippyTimeoutMs"), ctx.signal);
		let summary: string;
		switch (outcome.kind) {
			case "clean":
				return undefined;
			case "aborted":
				for (const path of touched) rustFilesTouched.add(path);
				return undefined;
			case "errors":
				summary = `clippy-errors=${outcome.lines.length}\n${outcome.lines.slice(0, 5).join("\n")}`;
				break;
			case "unavailable":
				summary = `clippy-${outcome.code}=${outcome.value}\n${outcome.reason}`;
				break;
			default:
				throw new Error(`clippy outcome ${JSON.stringify(outcome satisfies never)} is no outcome this check knows`);
		}

		// Every failing turn reports: an agent that cannot fix an error hears
		// the same advisory each turn, which is noisy and self-correcting,
		// where suppressing a repeat can leave a headless turn told nothing
		// when there was something to say. The edit set above is the bound —
		// a turn that writes no `.rs` file, and follows a check that finished,
		// runs no clippy — so a report costs an edit, not a loop.
		pi.sendMessage(
			{ customType: "kendex-clippy", content: summary, display: false },
			{ triggerTurn: true },
		);
		if (ctx.hasUI) ctx.ui.notify(summary, outcome.kind === "errors" ? "warning" : "info");
		return undefined;
	});
}
