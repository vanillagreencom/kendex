import { describe, expect, spyOn, test } from "bun:test";
import { chmodSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { SESSION_START_LISTENER, TOOL_RESULT_LISTENER, TURN_END_LISTENER } from "../extensions/registry.ts";
import { initRustRepo, installCarrier, readLog, projectCommand, registerRendered, renderedHookPath, runGit, toolResultEvent, trusted, useIsolatedGitEnv, writePiConfig } from "./harness.ts";
import { useSettledSessions } from "./session-fixture.ts";

import * as dispatch from "../extensions/dispatch.ts";

useIsolatedGitEnv();
const settle = useSettledSessions();

/**
 * The Pi event the carrier reads the `turn_end` registry key on. `Stop` and
 * `TaskCompleted` are Claude Code's end of a response, and Pi's `turn_end` is
 * inside the tool loop — one per LLM turn — so the registry is dispatched from
 * `agent_settled`, the point Pi documents as "will not continue running
 * automatically". The key kendex renders under is unchanged.
 */
const SETTLED_LISTENER = "agent_settled";

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
			});
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/** `Stop` and `TaskCompleted` take no matcher on Claude Code, so a matcher
	 * on this listener covers the turn rather than deciding a hook does not
	 * run — the registration below carries one no turn could ever equal. */
	test("a registered Stop hook runs whatever its matcher says, and steers what it said", async () => {
		const project = initCleanRustRepo("pi-hooks-turn-end-");
		const log = join(project, "stop.log");
		try {
			const carrier = installCarrier();
			const onSettled = carrier.handler(SETTLED_LISTENER);

			await onSettled({}, trusted(project));
			expect(carrier.sent).toHaveLength(0);
			expect(readLog(log)).toBe("");

			registerRendered(join(project, ".pi"), TURN_END_LISTENER, "Bash", customCommand(log, "audit=unpushed", 2));
			await onSettled({}, trusted(project));
			expect(carrier.sent).toHaveLength(1);
			expect(carrier.sent[0]!.message.content).toBe("audit=unpushed");
			// Since pi#8022 only `triggerTurn: true` reaches a headless run
			// that is ending, which is the whole delivery available here.
			expect(carrier.sent[0]!.options).toEqual({ triggerTurn: true });
			expect(JSON.parse(readLog(log))).toEqual({ hook_event_name: "Stop", stop_hook_active: false });
		} finally {
			rmSync(project, { recursive: true, force: true });
		}
	});

	/**
	 * Steering makes the agent answer, and that answer settles — so a dispatch
	 * that steers asks to be run again over on-disk state nothing changed. The
	 * steer is therefore spent once per consultation, and the dispatch it
	 * caused says `stop_hook_active: true`, which is the field a `Stop` hook
	 * reads to know it is already the reason the agent kept going. Without
	 * both, a hook that never bails — or a registry that will not parse, which
	 * needs no hook at all — drives an unattended run forever.
	 */
	test("the settle a steer caused does not steer again, and tells the hook it is the reason", async () => {
		const project = initCleanRustRepo("pi-hooks-turn-end-bound-");
		const log = join(project, "bound.log");
		try {
			const carrier = installCarrier();
			const onSettled = carrier.handler(SETTLED_LISTENER);
			registerRendered(join(project, ".pi"), TURN_END_LISTENER, undefined, customCommand(log, "audit=dirty", 2));

			await onSettled({}, trusted(project));
			await onSettled({}, trusted(project));
			expect(carrier.sent).toHaveLength(2);
			expect(carrier.sent[0]!.options).toEqual({ triggerTurn: true });
			expect(carrier.sent[1]!.options).toEqual({ triggerTurn: false });
			expect(readLog(log)).toContain('"stop_hook_active":false');
			expect(readLog(log)).toContain('"stop_hook_active":true');

			// And a settle this carrier did not cause is a new consultation:
			// the second dispatch steered nothing, so nothing followed from it.
			await onSettled({}, trusted(project));
			expect(carrier.sent).toHaveLength(3);
			expect(carrier.sent[2]!.options).toEqual({ triggerTurn: true });
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
			expect(JSON.parse(readLog(log))).toEqual({ hook_event_name: "SessionStart", source: "startup" });

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
			expect(JSON.parse(readLog(cleared))).toEqual({ hook_event_name: "SessionStart", source: "clear" });
			expect(readLog(resumed)).toBe("");

			onSessionStart({ type: "session_start", reason: "reload" }, trusted(project));
			await settle();
			expect(carrier.sent.map((call) => call.message.content)).toEqual([
				"session=clear",
				"session=resume",
			]);
			expect(JSON.parse(readLog(resumed))).toEqual({ hook_event_name: "SessionStart", source: "resume" });
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
			const onSettled = carrier.handler(SETTLED_LISTENER);
			const onToolResult = carrier.handler(TOOL_RESULT_LISTENER);
			const onSessionStart = carrier.handler(SESSION_START_LISTENER);
			registerRendered(join(project, ".pi"), TURN_END_LISTENER, undefined, "exit 0");

			// The control: the same fixture, readable.
			await onSettled({}, trusted(project));
			expect(carrier.sent).toHaveLength(0);
			expect(await onToolResult(toolResultEvent("bash", { command: "ls" }, "ok"), trusted(project))).toBeUndefined();

			writeFileSync(join(project, ".pi", "kendex", "hooks.json"), '{"hooks": {"turn_end": [');
			await onSettled({}, trusted(project));
			expect(carrier.sent).toHaveLength(1);
			expect(carrier.sent[0]!.message.content.split("\n")[0]).toBe(`hook-registry-unreadable=${TURN_END_LISTENER}`);
			expect(carrier.sent[0]!.message.content).toContain(TURN_END_LISTENER);

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
			expect(carrier.sent).toHaveLength(2);
			expect(carrier.sent[1]!.message.content.split("\n")[0]).toBe(`hook-registry-unreadable=${SESSION_START_LISTENER}`);
			expect(carrier.sent[1]!.message.content).toContain(SESSION_START_LISTENER);
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
	test("a channel that is gone loses its own line, not the rest of the report", async () => {
		const project = initCleanRustRepo("pi-hooks-stale-session-");
		writePiConfig(project, { sessionDriftCheck: false });
		try {
			let stale = true;
			const carrier = installCarrier(() => {
				if (!stale) return;
				stale = false;
				throw new Error("session-bound pi is stale after replacement");
			});
			const root = join(project, ".pi");
			registerRendered(root, SESSION_START_LISTENER, undefined, 'echo "hook=first"');
			registerRendered(root, SESSION_START_LISTENER, undefined, 'echo "hook=second"');

			carrier.handler(SESSION_START_LISTENER)({ type: "session_start", reason: "startup" }, trusted(project));
			await settle();
			expect(carrier.sent.map((call) => call.message.content)).toEqual([
				"hook=first",
				"hook=second",
			]);
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
						await carrier.handler(SETTLED_LISTENER)({}, trusted(project));
					}
					if (on) expect(JSON.parse(readLog(log))).toEqual(listener === SESSION_START_LISTENER
						? { hook_event_name: "SessionStart", source: "resume" }
						: { hook_event_name: "Stop", stop_hook_active: false });
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
		{ listener: TOOL_RESULT_LISTENER, event: toolResultEvent("bash", { command: "ls" }, "ok"), payload: { hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: { command: "ls" }, tool_response: "ok" } },
		{ listener: TURN_END_LISTENER, event: {}, payload: { hook_event_name: "Stop", stop_hook_active: false } },
		{ listener: SESSION_START_LISTENER, event: { reason: "resume" }, payload: { hook_event_name: "SessionStart", source: "resume" } },
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
				const handler = row.listener === TURN_END_LISTENER ? SETTLED_LISTENER : row.listener;
				const result = await carrier.handler(handler)(row.event, { cwd: project, isProjectTrusted: () => false }) as { content: { text: string }[] } | undefined;
				await settle();
				expect(readLog(log)).toBe("");
				expect(JSON.parse(readLog(globalLog))).toEqual(row.payload);
				if (row.listener === TOOL_RESULT_LISTENER) expect(result?.content.at(-1)?.text).toBe("global-hook=ran");
				else expect(carrier.sent).toEqual([{
					message: { customType: "kendex-hook", content: "global-hook=ran", display: row.listener === SESSION_START_LISTENER },
					options: { triggerTurn: row.listener === TURN_END_LISTENER },
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
