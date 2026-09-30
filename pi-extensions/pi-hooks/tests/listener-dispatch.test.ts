import { describe, expect, mock, spyOn, test } from "bun:test";
import { chmodSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SESSION_START_LISTENER, TOOL_RESULT_LISTENER, TURN_END_LISTENER } from "../extensions/registry.ts";
import { initRustRepo, installCarrier, readLog, projectCommand, registerRendered, renderedHookPath, runGit, SESSION_ID, sessionManager, toolResultEvent, trusted, useIsolatedGitEnv, writePiConfig } from "./harness.ts";
import { useSettledSessions } from "./session-fixture.ts";

import * as dispatch from "../extensions/dispatch.ts";

useIsolatedGitEnv();
const settle = useSettledSessions();

/**
 * The Pi event the carrier reads the `turn_end` registry key on. `Stop` and
 * `TaskCompleted` are Claude Code's end of a response, and Pi's `turn_end` is
 * inside the tool loop, one per LLM turn, so the registry is dispatched from
 * `agent_before_settle`, the final boundary of a run, where a handler can ask
 * for one more model request. The key kendex renders under is unchanged.
 */
const SETTLE_LISTENER = "agent_before_settle";

/** An `agent_before_settle` event as Pi hands it to a handler: what earlier
 * handlers proposed, nothing by default. */
function boundary(entries: unknown[] = [], proceed = false): Record<string, unknown> {
	return { type: SETTLE_LISTENER, entries, continue: proceed, outcome: "completed" };
}

/** The entry the carrier appends for one line a `Stop` hook said. */
function stopEntry(content: string): Record<string, unknown> {
	return { type: "custom_message", customType: "kendex-hook", content, display: false };
}

type BoundaryAnswer = { entries: { content: string }[]; continue?: boolean } | undefined;

/** A committed git repository, so a rendered guard's own registration resolves
 * the way it does in a real project. */
function initCleanRustRepo(prefix: string): string {
	const dir = initRustRepo(prefix);
	runGit(["-c", "user.email=pi-hooks@example.com", "-c", "user.name=pi-hooks", "commit", "-q", "-m", "init"], dir);
	return dir;
}

/** A hook body of the person's own: no script of kendex's behind it, so it
 * exists nowhere but the registry and can only run from there. */
function customCommand(log: string, stderr: string, exitCode: number): string {
	return `cat >> ${JSON.stringify(log)}; echo ${JSON.stringify(stderr)} >&2; exit ${exitCode}`;
}

/** The `Stop` payload one `agent_before_settle` dispatch writes to a hook's stdin. */
function stopPayload(stopHookActive: boolean): string {
	return JSON.stringify({ hook_event_name: "Stop", stop_hook_active: stopHookActive, session_id: SESSION_ID });
}

/** A rendered guard of kendex's on any listener, registered the way kendex
 * registers a project-scope one — so its per-guard setting is keyed by its
 * name, which is the whole point of the map that holds those settings. */
function renderRegisteredGuard(project: string, listener: string, name: string, log: string): void {
	const script = renderedHookPath(project, name);
	mkdirSync(join(script, ".."), { recursive: true });
	writeFileSync(script, `#!/usr/bin/env bash\nset -euo pipefail\ncat >> ${JSON.stringify(log)}\nexit 0\n`);
	chmodSync(script, 0o755);
	registerRendered(join(project, ".pi"), listener, undefined, projectCommand(`.pi/kendex/hooks/${name}.sh`));
}

/**
 * KEN-1189: the same defect KEN-941 closed on `tool_call`, on the three
 * listeners `pi_listener` also maps hook events onto. kendex rendered the
 * registration and labelled it enforced; the carrier read one key. Every case
 * here opens with the control — the same fixture with nothing registered —
 * because a hook that runs proves nothing unless the silence before it is real.
 *
 * Pi refuses nothing on any of these three, so what a hook says is delivered
 * rather than obeyed, each through the one channel its listener has.
 */
describe("pi-hooks registry dispatch on the listeners Pi gives no verdict to", () => {
	/** The hook's stdout, or its stderr on a refusal, in the tool result the
	 * model reads — Claude Code's own `PostToolUse` exit-2 consequence. */
	test("a registered PostToolUse hook runs and its word lands on the tool result", async () => {
		const project = initCleanRustRepo("pi-hooks-post-tool-");
		const log = join(project, "post.log");
		try {
			const onToolResult = installCarrier().handler(TOOL_RESULT_LISTENER);
			const call = () => onToolResult(toolResultEvent("bash", { command: "git push" }, "tool-result=unchanged"), trusted(project));

			// The control: a registry with nothing under this listener.
			expect(await call()).toBeUndefined();
			expect(readLog(log)).toBe("");

			registerRendered(join(project, ".pi"), TOOL_RESULT_LISTENER, "Bash", customCommand(log, "audit=push", 2));
			const patched = await call() as { content?: { type: string; text: string }[] };
			expect(patched.content?.map((block) => block.text)).toEqual(["tool-result=unchanged", "audit=push"]);
			expect(JSON.parse(readLog(log))).toEqual({
				hook_event_name: "PostToolUse",
				tool_name: "Bash",
				tool_input: { command: "git push" },
				tool_response: "tool-result=unchanged",
				session_id: SESSION_ID,
			});
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/** `Stop` and `TaskCompleted` take no matcher on Claude Code, so a matcher
	 * on this listener covers the turn rather than deciding a hook does not
	 * run — the registration below carries one no turn could ever equal. */
	test("a registered Stop hook runs whatever its matcher says, and asks for one continuation with what it said", async () => {
		const project = initCleanRustRepo("pi-hooks-turn-end-");
		const log = join(project, "stop.log");
		try {
			const carrier = installCarrier();
			const onSettle = carrier.handler(SETTLE_LISTENER);

			expect(await onSettle(boundary(), trusted(project))).toBeUndefined();
			expect(readLog(log)).toBe("");

			registerRendered(join(project, ".pi"), TURN_END_LISTENER, "Bash", customCommand(log, "audit=unpushed", 2));
			expect(await onSettle(boundary(), trusted(project))).toEqual({ entries: [stopEntry("audit=unpushed")], continue: true });
			expect(carrier.sent).toHaveLength(0);
			expect(readLog(log)).toBe(stopPayload(false));
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/** Pi names a session's context window nowhere a hook can read it but the
	 * session's own usage report, so the Stop payload carries it, and carries
	 * nothing where that report names no whole window. */
	test("a Stop payload carries the session's context window where Pi reports one", async () => {
		const project = initCleanRustRepo("pi-hooks-turn-end-window-");
		const log = join(project, "window.log");
		try {
			registerRendered(join(project, ".pi"), TURN_END_LISTENER, undefined, `cat >> ${JSON.stringify(log)}; exit 0`);
			const rows: { usage: { contextWindow: number } | undefined; fields: Record<string, number> }[] = [
				{ usage: { contextWindow: 272000 }, fields: { context_window: 272000 } },
				{ usage: undefined, fields: {} },
				{ usage: { contextWindow: 0 }, fields: {} },
			];
			for (const row of rows) {
				rmSync(log, { force: true });
				await installCarrier().handler(SETTLE_LISTENER)(boundary(), trusted(project, { getContextUsage: () => row.usage }));
				expect(JSON.parse(readLog(log))).toEqual({ hook_event_name: "Stop", stop_hook_active: false, session_id: SESSION_ID, ...row.fields });
			}
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/** Claude Code ends a subagent with `SubagentStop`, never `Stop`, so a Stop
	 * hook judges the lead alone. A pi-agents-tmux subagent is its own Pi
	 * process carrying its agent's name, and its settle is that subagent's end. */
	test("a Stop registration runs when the lead settles and not when a subagent does", async () => {
		const project = initCleanRustRepo("pi-hooks-turn-end-subagent-");
		const log = join(project, "subagent.log");
		try {
			registerRendered(join(project, ".pi"), TURN_END_LISTENER, undefined, `cat >> ${JSON.stringify(log)}; exit 0`);
			process.env.PI_SUBAGENT_CHILD_AGENT = "reviewer-correctness";
			await installCarrier().handler(SETTLE_LISTENER)(boundary(), trusted(project));
			expect(readLog(log)).toBe("");
			delete process.env.PI_SUBAGENT_CHILD_AGENT;
			await installCarrier().handler(SETTLE_LISTENER)(boundary(), trusted(project));
			expect(readLog(log)).toBe(stopPayload(false));
		} finally {
			delete process.env.PI_SUBAGENT_CHILD_AGENT;
			rmSync(project, { recursive: true, force: true });
		}
	});

	/**
	 * A continuation makes the agent answer over on-disk state nothing
	 * changed, so the carrier asks for one per response: the dispatch before
	 * the run it asked for settles says `stop_hook_active: true`, which is the
	 * field a `Stop` hook reads to know it is already the reason the agent
	 * kept going, and records what it is told without asking again. Without
	 * both, a hook that never bails, or a registry that will not parse, which
	 * needs no hook at all, drives an unattended run forever. Each dispatch
	 * keeps what an earlier handler proposed and never cancels its
	 * continuation, and a settle ends the response whether or not the
	 * continuation ran to its own boundary.
	 */
	test("the dispatch a continuation caused asks for none, and tells the hook it is the reason", async () => {
		const project = initCleanRustRepo("pi-hooks-turn-end-bound-");
		const log = join(project, "bound.log");
		try {
			const carrier = installCarrier();
			const onSettle = carrier.handler(SETTLE_LISTENER);
			const onSettled = carrier.handler("agent_settled");
			registerRendered(join(project, ".pi"), TURN_END_LISTENER, undefined, customCommand(log, "audit=dirty", 2));
			const prior = { type: "custom", customType: "other-extension" };

			expect(await onSettle(boundary(), trusted(project))).toEqual({ entries: [stopEntry("audit=dirty")], continue: true });
			const second = await onSettle(boundary([prior], true), trusted(project)) as BoundaryAnswer;
			expect(second).toEqual({ entries: [prior, stopEntry("audit=dirty")] });
			expect(second).not.toHaveProperty("continue");
			expect(readLog(log)).toBe(stopPayload(false) + stopPayload(true));
			onSettled({ type: "agent_settled" }, trusted(project));

			// A response whose continuation Pi ended before its boundary, an
			// abort, settles all the same, and the next response is its own.
			rmSync(log, { force: true });
			expect(await onSettle(boundary(), trusted(project))).toEqual({ entries: [stopEntry("audit=dirty")], continue: true });
			onSettled({ type: "agent_settled" }, trusted(project));
			expect(await onSettle(boundary(), trusted(project))).toEqual({ entries: [stopEntry("audit=dirty")], continue: true });
			expect(readLog(log)).toBe(stopPayload(false) + stopPayload(false));
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/** A `SessionStart` hook's stdout is the context it contributes, which is
	 * the one stream Claude Code routes into a model's context. The session is
	 * never held for it: the run is started and the words arrive when they do. */
	test("a registered SessionStart hook runs, and its matcher reads Pi's reason in Claude Code's words", async () => {
		const project = initCleanRustRepo("pi-hooks-session-");
		// The native drift report shares this listener and is not the subject.
		writePiConfig(project, { sessionDriftCheck: false });
		const log = join(project, "session.log");
		try {
			const carrier = installCarrier();
			const onSessionStart = carrier.handler(SESSION_START_LISTENER);

			onSessionStart({ type: "session_start", reason: "startup" }, trusted(project));
			await settle();
			expect(carrier.sent).toHaveLength(0);
			expect(readLog(log)).toBe("");

			// Matchered `startup`, which is what Pi's own `startup` is said as.
			registerRendered(
				join(project, ".pi"),
				SESSION_START_LISTENER,
				"startup",
				`cat >> ${JSON.stringify(log)}; echo "outdated=2"; exit 0`,
			);
			onSessionStart({ type: "session_start", reason: "startup" }, trusted(project));
			await settle();
			expect(carrier.sent).toHaveLength(1);
			expect(carrier.sent[0]!.message.content).toBe("outdated=2");
			expect(carrier.sent[0]!.options).toEqual({ triggerTurn: false });
			expect(JSON.parse(readLog(log))).toEqual({ hook_event_name: "SessionStart", source: "startup", session_id: SESSION_ID });

			// And the matcher decides: Pi's `resume` is Claude Code's `resume`,
			// which this registration does not name, so nothing runs for it.
			rmSync(log, { force: true });
			onSessionStart({ type: "session_start", reason: "resume" }, trusted(project));
			await settle();
			expect(carrier.sent).toHaveLength(1);
			expect(readLog(log)).toBe("");
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/**
	 * The half of the session vocabulary that actually translates, through the
	 * handler rather than as a table pin: Pi's `new` and `fork` are Claude
	 * Code's `clear`, and its `reload` is `resume`. A carrier passing Pi's own
	 * word through would run neither hook below, and one skipping reloaded and
	 * resumed sessions outright would run neither either.
	 */
	test("a matcher written in Claude Code's words fires for the Pi reason that means it", async () => {
		const project = initCleanRustRepo("pi-hooks-session-vocab-");
		// The native drift report shares this listener and is not the subject.
		writePiConfig(project, { sessionDriftCheck: false });
		const cleared = join(project, "cleared.log");
		const resumed = join(project, "resumed.log");
		try {
			const carrier = installCarrier();
			const onSessionStart = carrier.handler(SESSION_START_LISTENER);
			const root = join(project, ".pi");
			registerRendered(root, SESSION_START_LISTENER, "clear", `cat >> ${JSON.stringify(cleared)}; echo "session=clear"; exit 0`);
			registerRendered(root, SESSION_START_LISTENER, "resume", `cat >> ${JSON.stringify(resumed)}; echo "session=resume"; exit 0`);

			onSessionStart({ type: "session_start", reason: "new" }, trusted(project));
			await settle();
			expect(carrier.sent.map((call) => call.message.content)).toEqual(["session=clear"]);
			expect(JSON.parse(readLog(cleared))).toEqual({ hook_event_name: "SessionStart", source: "clear", session_id: SESSION_ID });
			expect(readLog(resumed)).toBe("");

			onSessionStart({ type: "session_start", reason: "reload" }, trusted(project));
			await settle();
			expect(carrier.sent.map((call) => call.message.content)).toEqual([
				"session=clear",
				"session=resume",
			]);
			expect(JSON.parse(readLog(resumed))).toEqual({ hook_event_name: "SessionStart", source: "resume", session_id: SESSION_ID });
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/** The rule the `tool_call` gate states, on a listener with no call to
	 * refuse: kendex labels these hooks enforced, so a registry that exists and
	 * did not answer is said rather than read as no hooks installed. */
	test("a registry that exists and cannot be read is reported on every listener, not passed over", async () => {
		const project = initCleanRustRepo("pi-hooks-turn-end-unreadable-");
		// The native drift report shares `session_start` and is not the subject.
		writePiConfig(project, { sessionDriftCheck: false });
		try {
			const carrier = installCarrier();
			const onSettle = carrier.handler(SETTLE_LISTENER);
			const onToolResult = carrier.handler(TOOL_RESULT_LISTENER);
			const onSessionStart = carrier.handler(SESSION_START_LISTENER);
			registerRendered(join(project, ".pi"), TURN_END_LISTENER, undefined, "exit 0");

			// The control: the same fixture, readable.
			expect(await onSettle(boundary(), trusted(project))).toBeUndefined();
			expect(await onToolResult(toolResultEvent("bash", { command: "ls" }, "ok"), trusted(project))).toBeUndefined();

			writeFileSync(join(project, ".pi", "kendex", "hooks.json"), '{"hooks": {"turn_end": [');
			const settled = await onSettle(boundary(), trusted(project)) as BoundaryAnswer;
			expect(settled?.continue).toBe(true);
			expect(settled?.entries[0]?.content.split("\n")[0]).toBe(`hook-registry-unreadable=${TURN_END_LISTENER}`);

			// The same rule on its two sibling call sites, which have their own
			// channel: the tool result the model reads, and the session's
			// opening context.
			const patched = await onToolResult(toolResultEvent("bash", { command: "ls" }, "ok"), trusted(project)) as {
				content?: { text: string }[];
			};
			expect(patched.content?.at(-1)?.text?.split("\n")[0]).toBe(`hook-registry-unreadable=${TOOL_RESULT_LISTENER}`);
			expect(patched.content?.at(-1)?.text).toContain(TOOL_RESULT_LISTENER);

			onSessionStart({ type: "session_start", reason: "startup" }, trusted(project));
			await settle();
			expect(carrier.sent).toHaveLength(1);
			expect(carrier.sent[0]!.message.content.split("\n")[0]).toBe(`hook-registry-unreadable=${SESSION_START_LISTENER}`);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/**
	 * Nobody awaits the session_start dispatch, and every hook on it runs to
	 * its own budget while the session opens — so by the time the last one
	 * settles the session may have been replaced, and Pi documents its captured
	 * session-bound `pi` as throwing from that point on. Unguarded that is an
	 * unhandled rejection rather than a handler error Pi absorbs: a probe under
	 * bun 1.3.14 with a throwing `sendMessage` ended the process on it, exit 1
	 * against exit 0 with the guard, and Node from 22 on — this package's
	 * engines floor — defaults to the same. Below the crash is the quieter
	 * half, which is what this case holds: one dead channel must lose its own
	 * line and not the rest of what the listener had to say.
	 */
	test("a channel that is gone loses its own text, not the rest of the report", async () => {
		const project = initCleanRustRepo("pi-hooks-stale-session-");
		writePiConfig(project, { sessionDriftCheck: false });
		try {
			const carrier = installCarrier(() => {
				throw new Error("session-bound pi is stale after replacement");
			});
			const root = join(project, ".pi");
			registerRendered(root, SESSION_START_LISTENER, undefined, 'echo "hook=agent"');
			registerRendered(root, SESSION_START_LISTENER, undefined, 'echo "hook=person" >&2');
			const notices: string[] = [];

			carrier.handler(SESSION_START_LISTENER)({ type: "session_start", reason: "startup" }, trusted(project, {
				hasUI: true, ui: { notify: (message: string) => notices.push(message) },
			}));
			await settle();
			expect(carrier.sent.map((call) => call.message.content)).toEqual(["hook=agent"]);
			expect(notices).toEqual(["hook=person"]);
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/**
	 * The three statuses that are neither a clean run nor a refusal, on a
	 * listener with no call to refuse: a rendered script no scope holds, a run
	 * past its budget, and a hook exiting anything else. kendex labels these
	 * hooks enforced, so each is reported rather than read as an all-clear —
	 * the direction the failure has to go.
	 */
	for (const row of [
		{ name: "missing render", command: projectCommand(".pi/kendex/hooks/audit.sh"), timeout: undefined, key: "hook-missing=" },
		{ name: "timeout", command: "sleep 30", timeout: 0.02, key: "hook-timeout-ms=20" },
		{ name: "bad exit", command: "exit 1", timeout: undefined, key: "hook-exit=1" },
	]) {
		test(`tool result reports ${row.name}`, async () => {
			const project = initCleanRustRepo("pi-hooks-no-verdict-");
			try {
				registerRendered(join(project, ".pi"), TOOL_RESULT_LISTENER, undefined, row.command, row.timeout);
				const result = await installCarrier().handler(TOOL_RESULT_LISTENER)(toolResultEvent("bash", { command: "ls" }, "ok"), trusted(project)) as { content: { text: string }[] };
				expect(result.content[0]?.text).toBe("ok");
				expect(result.content.at(-1)?.text.split("\n")[0]).toBe(row.key + (row.name === "missing render" ? renderedHookPath(project, "audit") : ""));
			} finally { rmSync(project, { recursive: true, force: true }); }
		});
	}

	/**
	 * The two guard settings this carrier also ports natively. The surface says
	 * off turns both off, so the registered copy has to read the same switch —
	 * and the switch is keyed by the hook's own rendered name, which is the
	 * whole of what the map holds.
	 */
	test("the setting for a natively ported guard turns off a registered copy of it", async () => {
		const project = initCleanRustRepo("pi-hooks-guard-settings-");
		const cases = [
			{ name: "session-drift-check", setting: "sessionDriftCheck", listener: SESSION_START_LISTENER },
			{ name: "task-completed-check", setting: "taskCompletedCheck", listener: TURN_END_LISTENER },
		];
		try {
			for (const { name, setting, listener } of cases) {
				const log = join(project, `${name}.log`);
				rmSync(join(project, ".pi", "kendex"), { recursive: true, force: true });
				renderRegisteredGuard(project, listener, name, log);

				for (const on of [true, false]) {
					rmSync(log, { force: true });
					writePiConfig(project, { [setting]: on });
					const carrier = installCarrier();
					if (listener === SESSION_START_LISTENER) {
						// `resume`: the registered copy covers every source, and the
						// native report the on leg would otherwise arm is not the subject.
						carrier.handler(SESSION_START_LISTENER)({ type: "session_start", reason: "resume" }, trusted(project));
						await settle();
					} else {
						await carrier.handler(SETTLE_LISTENER)(boundary(), trusted(project));
					}
					if (on) expect(JSON.parse(readLog(log))).toEqual(listener === SESSION_START_LISTENER
						? { hook_event_name: "SessionStart", source: "resume", session_id: SESSION_ID }
						: { hook_event_name: "Stop", stop_hook_active: false, session_id: SESSION_ID });
					else expect(readLog(log)).toBe("");
				}
			}
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/**
	 * The trust gate, on each listener this change newly dispatches. Before it,
	 * an untrusted clone's registry could only reach a spawn on a tool call;
	 * now it could reach one at session start, before the person has typed
	 * anything. The person's own global hook answers in the same fixture, so a
	 * carrier that dispatched nothing at all could not pass this.
	 */
	for (const row of [
		{ listener: TOOL_RESULT_LISTENER, event: toolResultEvent("bash", { command: "ls" }, "ok"), logged: JSON.stringify({ hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: { command: "ls" }, tool_response: "ok", session_id: SESSION_ID }) },
		{ listener: TURN_END_LISTENER, event: boundary(), logged: stopPayload(false) },
		{ listener: SESSION_START_LISTENER, event: { reason: "resume" }, logged: JSON.stringify({ hook_event_name: "SessionStart", source: "resume", session_id: SESSION_ID }) },
	]) {
		test(`untrusted project stays silent on ${row.listener}, global hook answers`, async () => {
			const project = initCleanRustRepo("pi-hooks-untrusted-listeners-");
			const log = join(project, "project.log");
			const agentDir = process.env.PI_CODING_AGENT_DIR!;
			const globalLog = join(agentDir, "global.log");
			try {
				registerRendered(join(project, ".pi"), row.listener, undefined, customCommand(log, "project-hook=ran", 2));
				registerRendered(agentDir, row.listener, undefined, customCommand(globalLog, "global-hook=ran", 2));
				const carrier = installCarrier();
				const handler = row.listener === TURN_END_LISTENER ? SETTLE_LISTENER : row.listener;
				const result = await carrier.handler(handler)(row.event, { cwd: project, isProjectTrusted: () => false, sessionManager }) as { content: { text: string }[] } | undefined;
				await settle();
				expect(readLog(log)).toBe("");
				expect(readLog(globalLog)).toBe(row.logged);
				if (row.listener === TOOL_RESULT_LISTENER) expect(result?.content.at(-1)?.text).toBe("global-hook=ran");
				else if (row.listener === TURN_END_LISTENER) expect(result).toEqual({ entries: [stopEntry("global-hook=ran")], continue: true });
				else expect(carrier.sent).toEqual([{
					message: { customType: "kendex-hook", content: "global-hook=ran", display: true },
					options: { triggerTurn: false },
				}]);
			} finally {
				rmSync(join(agentDir, "kendex"), { recursive: true, force: true });
				rmSync(globalLog, { force: true });
				rmSync(project, { recursive: true, force: true });
			}
		});
	}

});

// Pi can replace the session while its dispatch is in flight. An unexpected
// dispatcher rejection still reaches the remaining message channel.
test("unexpected session dispatch failure names the listener", async () => {
	const project = initCleanRustRepo("pi-hooks-dispatch-failure-");
	writePiConfig(project, { sessionDriftCheck: false });
	let delivered!: () => void;
	const delivery = new Promise<void>((resolve) => { delivered = resolve; });
	const run = spyOn(dispatch, "runListener").mockRejectedValueOnce(new Error("dispatch-failed"));
	try {
		const carrier = installCarrier(() => delivered());
		expect(carrier.handler(SESSION_START_LISTENER)({ reason: "startup" }, trusted(project))).toBeUndefined();
		await delivery;
		expect(carrier.sent[0]?.message.content.split("\n")[0]).toBe("hook-report-failed=session_start");
		expect(carrier.sent[0]?.options).toEqual({ triggerTurn: false });
	} finally {
		run.mockRestore();
		rmSync(project, { recursive: true, force: true });
	}
});

/**
 * Below Pi 0.87.0 Pi fires no `agent_before_settle`, so every `Stop` and
 * `TaskCompleted` registration is skipped, and neither kendex nor Pi checks
 * the peer range that says so. The carrier reads the host's `VERSION` export
 * at each fresh session start, so each row starts a session against a host
 * module reporting its version; the 0.87.0 row is the control.
 */
describe("a Pi without the Stop listener is named at session start", () => {
	const HOST = "@earendil-works/pi-coding-agent";
	const rows = [
		{ version: "0.86.1", said: "hook-host-unsupported=pi 0.86.1" },
		{ version: "0.87.0", said: undefined },
	];
	for (const row of rows) {
		test(`pi ${row.version}`, async () => {
			const project = initCleanRustRepo("pi-hooks-host-version-");
			writePiConfig(project, { sessionDriftCheck: false });
			const real = { ...(await import(HOST)) };
			mock.module(HOST, () => ({ ...real, VERSION: row.version }));
			try {
				const carrier = installCarrier();
				const notified: [string, string][] = [];
				let warned!: () => void;
				const warning = new Promise<void>((resolve) => { warned = resolve; });
				const ui = {
					notify: (content: string, level: string) => {
						notified.push([content, level]);
						if (level === "warning") warned();
					},
				};
				carrier.handler(SESSION_START_LISTENER)({ type: "session_start", reason: "startup" }, trusted(project, { hasUI: true, ui }));
				await settle();
				// The host version is read behind a dynamic import the carrier does
				// not hand back, so a row that is named waits for its warning, and
				// the control resolves the same module here and waits one timer turn
				// for the carrier's own read of it to finish.
				if (row.said !== undefined) {
					await warning;
				} else {
					await import(HOST);
					await Bun.sleep(0);
				}
				const spoken = carrier.sent.map((call) => call.message.content.split("\n")[0]);
				const shown = notified.map(([content, level]) => `${level} ${content.split("\n")[0]}`);
				if (row.said === undefined) {
					expect(spoken).toEqual([]);
					expect(shown).toEqual([]);
				} else {
					expect(spoken).toEqual([row.said]);
					expect(shown).toEqual([`warning ${row.said}`]);
				}
			} finally {
				mock.module(HOST, () => real);
				rmSync(project, { recursive: true, force: true });
			}
		});
	}
});
