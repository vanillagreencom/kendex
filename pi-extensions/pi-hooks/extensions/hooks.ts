import type {
	AgentBeforeSettleEvent,
	AgentBeforeSettleEventResult,
	CustomMessageEntryDraft,
	ExtensionAPI,
	ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { isAbsolute, resolve } from "node:path";

import { getBool, getNumber, projectRoot, projectTrusted, readConfig, recordProjectTrust } from "./config.js";
import { agentLine, deliver, type HookResult, personLine, runListener, unreadableLine } from "./dispatch.js";
import { deliverDrift, runDriftCheck } from "./drift-check.js";
import { workspaceClippyOutcome } from "./lint-hooks.js";
import { SESSION_START_LISTENER, TOOL_CALL_LISTENER, TOOL_RESULT_LISTENER, TURN_END_LISTENER } from "./registry.js";
import { claudeSessionFields, claudeSessionSource, claudeToolInput, claudeToolName, piContextFields, piSubagentName } from "./vocab.js";

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
 * every `Stop` and `TaskCompleted` registration is skipped with no error. The
 * Pi peer range names the floor, but neither kendex nor Pi checks peers when it
 * installs an extension, so this says it instead. It serves Pi 0.74.0, the
 * first `@earendil-works` release, to 0.86.x. Remove it once no Pi below
 * 0.87.0 can load this package. A version that does not parse as
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
		return `hook-host-unsupported=pi ${version}\nStop and TaskCompleted hooks do not run on this Pi. Upgrade Pi to 0.87.0 or later.`;
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
	 * Everything one registered hook said on a listener Pi gives no verdict to.
	 * `toAgent` is the listener's own way of putting words in front of the
	 * model — a patched tool result, an entry the settle boundary appends, a
	 * session's opening context — and stderr beside a clean exit goes to the
	 * person instead.
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
			JSON.stringify({ hook_event_name: "SessionStart", source, ...claudeSessionFields(ctx) }),
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
			tool_input: claudeToolInput(toolName, event.input, ctx.cwd),
			tool_response: event.content.flatMap((block) => (block.type === "text" ? [block.text] : [])).join("\n"),
			...claudeSessionFields(ctx),
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
		// obeyed: each line becomes a session entry the next model request
		// reads, and a `display: false` one leaves interactive rendering to the
		// notification beside it, which a headless session never sees.
		const said: CustomMessageEntryDraft[] = [];
		const say = (content: string) => {
			said.push({ type: "custom_message", customType: "kendex-hook", content, display: false });
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
			JSON.stringify({ hook_event_name: "Stop", stop_hook_active: stopHookActive, ...claudeSessionFields(ctx), ...piContextFields(ctx) }),
			ctx,
			cfg,
			project,
			projectTrusted(ctx),
		);
		if (run.unreadable !== undefined) deliver(say, unreadableLine(TURN_END_LISTENER, run.unreadable));
		report(run.results, ctx, say);
		if (said.length === 0) return undefined;
		// Chained after what earlier handlers proposed, and `continue` is
		// returned only as `true`: a `false` here would cancel another
		// handler's continuation.
		const entries = [...event.entries, ...said];
		if (stopHookActive) return { entries };
		continued = true;
		return { entries, continue: true };
	};

	pi.on("agent_before_settle", consultStop);

	pi.on("agent_settled", () => {
		continued = false;
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
			? `clippy-errors=${outcome.lines.length}\n${outcome.lines.slice(0, 5).join("\n")}`
			: `clippy-${outcome.code}=${outcome.value}\n${outcome.reason}`;

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
