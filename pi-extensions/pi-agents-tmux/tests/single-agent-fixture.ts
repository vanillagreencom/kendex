// The neutral world every single-agent suite runs in: temp runtimes, the
// project settings writer, the two spawn mocks and the bridge event shapes.
// Nothing here plants a defect; a case that needs one builds it inline.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { guardReusedSessionBudget, resolveBgSession } from "../extensions/subagent/sessions.js";
import { clearPackageConfigCache, recordProjectTrust } from "../extensions/subagent/package-config.js";
import { runSingleDispatch } from "../extensions/subagent/dispatch.js";
import * as dispatch from "../extensions/subagent/dispatch.js";
import type { SubagentDashboardItem } from "../extensions/subagent/types.js";
import type { SingleResult, SubagentDetails } from "../extensions/subagent/types.js";

const tempRuntimeDirs = new Set<string>();

export function tempRuntime(): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-agents-lanes-"));
	tempRuntimeDirs.add(dir);
	return dir;
}

export function tempGitRepo(): string {
	const cwd = tempRuntime();
	execFileSync("git", ["init"], { cwd, stdio: "ignore" });
	writeFileSync(join(cwd, "tracked.txt"), "initial\n", "utf8");
	execFileSync("git", ["add", "tracked.txt"], { cwd, stdio: "ignore" });
	execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", "commit", "--no-gpg-sign", "-m", "initial commit"], { cwd, stdio: "ignore" });
	writeFileSync(join(cwd, "dirty.txt"), "dirty\n", "utf8");
	return cwd;
}

export function writeSettings(cwd: string, config: Record<string, unknown>) {
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({
		kendex: { extensionManager: { config: { "@vanillagreen/pi-agents-tmux": config } } },
	}), "utf8");
	recordProjectTrust({ cwd, isProjectTrusted: () => true });
	// What pi-extension-manager's settings-changed event does after a write.
	clearPackageConfigCache();
}

export function testAgent(): AgentConfig {
	return {
		name: "reviewer-test",
		description: "test reviewer",
		pane: false,
		systemPrompt: "",
		source: "project",
		filePath: "reviewer-test.md",
	};
}

/** Drive the real dispatcher and capture its final panel update. */
export async function dispatchOutcome(options: {
	cwd?: string;
	runtimeRoot?: string;
	sessionKey?: string;
	sameSession?: boolean;
	signal?: AbortSignal;
	run?: typeof runSingleDispatch;
} = {}) {
	const cwd = options.cwd ?? tempRuntime();
	const rows: SubagentDashboardItem[] = [];
	const events: Array<{ name: string; payload: unknown }> = [];
	const result = await (options.run ?? runSingleDispatch)({
		agents: [testAgent()], cwd, runtimeRoot: options.runtimeRoot ?? tempRuntime(),
		parentSessionId: "test", pi: mockPiEvents(events),
		agent: "reviewer-test", task: "new task", sessionKey: options.sessionKey,
		sameSession: options.sameSession, signal: options.signal,
		makeDetails: (mode) => (results) => ({ mode, agentScope: "project", projectAgentsDir: null, results }),
		removeDashboardAgent: () => undefined, updateDashboard: (item) => { rows.push(item); },
	});
	return { result, row: rows.at(-1)!, events };
}

/** Capture the real cancellation producer, optionally replaying its envelope through a real mapper copy. */
export async function assertStoppedActivity(mapper?: typeof import("../extensions/subagent/activity.js")) {
	const key = Symbol.for("kendex.pi.activity");
	const globals = globalThis as unknown as Record<symbol, unknown>;
	const previous = globals[key];
	const published: Array<{ type: string }> = [];
	globals[key] = { publish: (event: { type: string }) => { published.push(event); } };
	const controller = new AbortController();
	controller.abort();
	installMockSpawn([{ stdout: bridgeStdout([bridgeEvent("agent_end", { content: [] })]) }]);
	try {
		const { events } = await dispatchOutcome({ signal: controller.signal });
		const stopped = events.find(({ name }) => name === "subagents:failed");
		assert.equal((stopped?.payload as { status: string })?.status, "stopped");
		if (mapper) {
			published.length = 0;
			mapper.publishSubagentActivity(stopped!.name, stopped!.payload as Record<string, unknown>);
		}
		assert.deepEqual(published.filter((event) => event.type === "agent.task_failed"), []);
	} finally {
		setSingleAgentSpawnForTests();
		if (previous === undefined) delete globals[key];
		else globals[key] = previous;
	}
}

/** Exercise returned handoff keys after answer truncation in every dispatch return path. */
export async function assertSessionMetadata(runtime: typeof dispatch, mode: "single" | "parallel" | "chain", ending: "completed" | "failed" | "needs_completion" = "completed", explicitSibling = false) {
	const cwd = tempRuntime();
	const root = tempRuntime();
	writeSettings(cwd, { reusedSessionContextLimitTokens: 100, reusedSessionBudgetThreshold: 0.8, resultMaxBytes: 1024, resultMaxLines: 40 });
	const session = resolveBgSession(root, "reviewer-test", "reuse");
	mkdirSync(join(root, "sessions"), { recursive: true });
	writeFileSync(session.path, `${JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "prior result" }] } })}\n`.padEnd(432, " "));
	const answer = bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "fresh answer\n".repeat(2000) }] } })]);
	const second = ending === "failed"
		? bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [], stopReason: "error", errorMessage: "403 forbidden" } })])
		: ending === "needs_completion" ? bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: [] })]) : answer;
	const calls = installMockSpawn(mode === "single" ? [{ stdout: answer }] : [{ stdout: answer }, { stdout: second }]);
	const rows: SubagentDashboardItem[] = [];
	const flow = {
		agents: [testAgent()], cwd, runtimeRoot: root, parentSessionId: "test", pi: mockPiEvents([]),
		makeDetails: (dispatchMode: "single" | "parallel" | "chain") => (results: SingleResult[]): SubagentDetails => ({ mode: dispatchMode, agentScope: "project", projectAgentsDir: null, results }),
		removeDashboardAgent: () => undefined, updateDashboard: (item: SubagentDashboardItem) => { rows.push(item); },
	};
	try {
		const result = mode === "single"
			? await runtime.runSingleDispatch({ ...flow, agent: "reviewer-test", task: "new task", sessionKey: "reuse" })
			: mode === "parallel"
				? await runtime.runParallelDispatch({ ...flow, tasks: [{ agent: "reviewer-test", task: "first", sessionKey: "reuse" }, { agent: "reviewer-test", task: "second", sessionKey: explicitSibling ? "follow-up" : undefined }] })
				: await runtime.runChainDispatch({ ...flow, chain: [{ agent: "reviewer-test", task: "first", sessionKey: "reuse" }, { agent: "reviewer-test", task: "second {previous}", sessionKey: explicitSibling ? "follow-up" : undefined }, ...(ending === "completed" ? [] : [{ agent: "reviewer-test", task: "must not run" }])] });
		assert.equal(calls.length, mode === "single" ? 1 : 2);
		assert.notEqual(result.details.results[0]!.sessionKey, "reuse");
		assert.equal(result.details.results[0]!.truncation?.truncated, true);
		const text = result.content.map((part) => part.text).join("\n");
		for (const [index, child] of result.details.results.entries()) {
			assert.ok(child.sessionKey);
			const reusable = index === 0 || explicitSibling;
			assert.equal(child.sessionKeyExplicit, reusable);
			const position = mode === "chain" ? ` step=${index + 1}` : mode === "parallel" ? ` item=${index + 1}` : "";
			assert.equal(text.includes(`Session: agent=${child.agent}${position} sessionKey=${child.sessionKey}`), reusable, `${mode}/${ending} advertises only explicit keys for executed item ${index + 1}`);
		}
	} finally { setSingleAgentSpawnForTests(); }
}

/** Only advertised keys can arm redispatch through model-facing metadata. */
export async function assertNoEphemeralMetadata(runtime: typeof dispatch, mode: "single" | "parallel" | "chain") {
	const cwd = tempRuntime();
	const root = tempRuntime();
	writeSettings(cwd, { reusedSessionContextLimitTokens: 100, reusedSessionBudgetThreshold: 0.8 });
	const calls = installMockSpawn([{}, {}]);
	const flow = {
		agents: [testAgent()], cwd, runtimeRoot: root, parentSessionId: "test", pi: mockPiEvents([]),
		makeDetails: (dispatchMode: "single" | "parallel" | "chain") => (results: SingleResult[]): SubagentDetails => ({ mode: dispatchMode, agentScope: "project", projectAgentsDir: null, results }),
		removeDashboardAgent: () => undefined, updateDashboard: () => undefined,
	};
	try {
		const task = { agent: "reviewer-test", task: "map", sameSession: true };
		const result = mode === "single" ? await runtime.runSingleDispatch({ ...flow, ...task })
			: mode === "parallel" ? await runtime.runParallelDispatch({ ...flow, tasks: [task] })
				: await runtime.runChainDispatch({ ...flow, chain: [task] });
		const child = result.details.results[0]!;
		assert.equal(child.sessionKeyExplicit, false);
		assert.ok(child.sessionPath);
		writeFileSync(child.sessionPath, "x".repeat(432));
		assert.equal((await guardReusedSessionBudget(child.sessionPath, child.agent, undefined, cwd)).ok, false);
		const advertised = result.content[0]!.text.match(/Session: agent=reviewer-test(?: (?:item|step)=1)? sessionKey=(\S+)/)?.[1];
		if (advertised) {
			const echoed = { ...task, sessionKey: advertised };
			const replay = mode === "single" ? await runtime.runSingleDispatch({ ...flow, ...echoed })
				: mode === "parallel" ? await runtime.runParallelDispatch({ ...flow, tasks: [echoed] })
					: await runtime.runChainDispatch({ ...flow, chain: [echoed] });
			assert.equal(replay.details.results[0]!.sessionPath, child.sessionPath);
		}
		assert.equal(calls.length, 1, "advertising an internal key must not enable an unguarded same-session redispatch");
		assert.equal(advertised, undefined);
	} finally { setSingleAgentSpawnForTests(); }
}

/** Assert the outcome independently in model-facing data and the panel. */
export async function assertDispatchOutcome(status: "refused" | "stopped" | "failed", options: Parameters<typeof dispatchOutcome>[0], diagnostic: string) {
	const { result, row, events } = await dispatchOutcome(options);
	assert.deepEqual([row.status, result.isError, row.message?.includes(diagnostic), result.content[0]?.text.includes(diagnostic)], [status, true, true, true]);
	if (status !== "refused") assert.equal((events.findLast(({ name }) => name === "subagents:failed" || name === "subagents:completed")?.payload as { status: string })?.status, status);
	return { result, row, events };
}

export function installMockSpawn(scenarios: Array<{ code?: number | null; delayMs?: number; error?: Error | string; signal?: string; stderr?: string; stdout?: string }>, install = setSingleAgentSpawnForTests) {
	const calls: Array<{ args: string[]; prompt: string; promptFiles: string[]; kills: string[]; flow: { stdout: string[]; stderr: string[] } }> = [];
	install(((command: string, args: string[]) => {
		void command;
		const input = args.at(-1)!;
		const systemIndex = args.indexOf("--append-system-prompt");
		const promptFiles = [...(systemIndex < 0 ? [] : [args[systemIndex + 1]!]), ...(input.startsWith("@") ? [input.slice(1)] : [])];
		const call = { args, prompt: input.startsWith("@") ? readFileSync(input.slice(1), "utf8") : input, promptFiles, kills: [] as string[], flow: { stdout: [] as string[], stderr: [] as string[] } };
		calls.push(call);
		const proc = new EventEmitter() as any;
		// A readable's flow control, recorded rather than enforced.
		for (const name of ["stdout", "stderr"] as const) {
			proc[name] = new EventEmitter();
			proc[name].pause = () => { call.flow[name].push("pause"); };
			proc[name].resume = () => { call.flow[name].push("resume"); };
		}
		proc.killed = false;
		proc.kill = (signal?: string) => {
			proc.killed = true;
			call.kills.push(signal ?? "SIGTERM");
			return true;
		};
		const scenario = scenarios.shift();
		const finish = () => {
			if (scenario?.stdout) proc.stdout.emit("data", Buffer.from(scenario.stdout));
			if (scenario?.stderr) proc.stderr.emit("data", Buffer.from(scenario.stderr));
			if (scenario?.error) {
				proc.emit("error", scenario.error instanceof Error ? scenario.error : new Error(scenario.error));
				return;
			}
			proc.emit("close", scenario?.signal ? (scenario.code ?? null) : (scenario?.code ?? 0), scenario?.signal ?? null);
		};
		if (scenario?.delayMs !== undefined) setTimeout(finish, scenario.delayMs);
		else queueMicrotask(finish);
		return proc;
	}) as any);
	return calls;
}

export function installLifecycleMockSpawn(options: {
	closeAfterMs?: number;
	closeOnSignal?: string;
	kill?: (signal: string, count: number, proc: EventEmitter) => boolean;
	pid?: number;
	stdout?: string;
	stdoutChunks?: Array<{ delayMs: number; text: string }>;
} = {}) {
	const calls: Array<{ args: string[]; detached?: boolean; kills: string[] }> = [];
	setSingleAgentSpawnForTests(((command: string, args: string[], spawnOptions?: { detached?: boolean }) => {
		void command;
		const call = { args, detached: spawnOptions?.detached, kills: [] as string[] };
		calls.push(call);
		const proc = new EventEmitter() as any;
		proc.stdout = new EventEmitter();
		proc.stderr = new EventEmitter();
		if (options.pid) proc.pid = options.pid;
		proc.killed = false;
		proc.kill = (signal?: string) => {
			proc.killed = true;
			const normalizedSignal = signal ?? "SIGTERM";
			call.kills.push(normalizedSignal);
			const delivered = options.kill?.(normalizedSignal, call.kills.length, proc) ?? true;
			if (delivered && options.closeOnSignal === normalizedSignal) {
				queueMicrotask(() => proc.emit("close", null, normalizedSignal));
			}
			return delivered;
		};
		if (options.stdout) queueMicrotask(() => proc.stdout.emit("data", Buffer.from(options.stdout!)));
		for (const chunk of options.stdoutChunks ?? []) {
			setTimeout(() => proc.stdout.emit("data", Buffer.from(chunk.text)), chunk.delayMs);
		}
		if (options.closeAfterMs !== undefined) setTimeout(() => proc.emit("close", 0, null), options.closeAfterMs);
		return proc;
	}) as any);
	return calls;
}

export function bridgeStdout(events: unknown[]): string {
	return `${events.map((event) => JSON.stringify(event)).join("\n")}\n`;
}

export function bridgeEvent(event: string, data: Record<string, unknown> = {}): Record<string, unknown> {
	return { type: "event", event, data };
}

export type StreamShape = "nested-event" | "bridge-event" | "top-level";

export function shapedStreamEvent(shape: StreamShape, event: string, data: Record<string, unknown> = {}): Record<string, unknown> {
	if (shape === "nested-event") return { event: { type: event, ...data } };
	if (shape === "bridge-event") return { type: "event", event, data };
	return { type: event, ...data };
}

export function transcriptEventName(event: any): string | undefined {
	if (typeof event?.event === "string") return event.event;
	if (event?.event && typeof event.event === "object" && typeof event.event.type === "string") return event.event.type;
	if (typeof event?.type === "string") return event.type;
	return undefined;
}

export function findAgentStartTranscriptPayload(records: any[]): any {
	for (const record of records) {
		const event = record.event;
		if (event?.event && typeof event.event === "object" && event.event.type === "agent_start") return event.event;
		if (event?.type === "event" && event.event === "agent_start") return event.data;
		if (event?.type === "agent_start") return event;
	}
	return undefined;
}

export function mockPiEvents(events: Array<{ name: string; payload: any }>) {
	return {
		getActiveTools: () => [],
		events: {
			emit: (name: string, payload: unknown) => events.push({ name, payload }),
		},
	} as any;
}

export function makeDetails(results: any[]): SubagentDetails {
	return { mode: "single", agentScope: "project", projectAgentsDir: null, results };
}

export function readTranscript(result: Pick<SingleResult, "transcriptPath">): string {
	const transcriptPath = result.transcriptPath;
	assert.ok(transcriptPath);
	return readFileSync(transcriptPath, "utf8");
}

export function withPollutedEnv(fn: () => void) {
	const previousParent = process.env.PI_SUBAGENT_PARENT_SESSION_ID;
	const previousChild = process.env.PI_SUBAGENT_CHILD_AGENT;
	const previousDir = process.env.PI_CODING_AGENT_DIR;
	try {
		process.env.PI_SUBAGENT_PARENT_SESSION_ID = "polluted-parent";
		process.env.PI_SUBAGENT_CHILD_AGENT = "polluted-child";
		process.env.PI_CODING_AGENT_DIR = join(tempRuntime(), "agent-dir");
		clearPackageConfigCache();
		fn();
	} finally {
		if (previousParent === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION_ID;
		else process.env.PI_SUBAGENT_PARENT_SESSION_ID = previousParent;
		if (previousChild === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
		else process.env.PI_SUBAGENT_CHILD_AGENT = previousChild;
		if (previousDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousDir;
		clearPackageConfigCache();
	}
}

/** Reuse above the configured guard must launch once with task plus prior result. */
export async function assertFreshHandoff(runtime: Pick<typeof import("../extensions/subagent/runner.js"), "runSingleAgent" | "setSingleAgentSpawnForTests">, transport: "mock" | "long-report" | "child-error" = "mock") {
	const cwd = tempRuntime();
	const root = tempRuntime();
	writeSettings(cwd, { reusedSessionContextLimitTokens: 100, reusedSessionBudgetThreshold: 0.8 });
	const session = resolveBgSession(root, "reviewer-test", "reuse");
	mkdirSync(join(root, "sessions"), { recursive: true });
	// Pi persists assistant reports as message entries. This report stays within
	// the prior-result reader's tail bound but exceeds Linux's single-argument bound.
	const priorResult = transport === "long-report" ? Array.from({ length: 4000 }, (_, index) => `Report ${index}: amber gearbox inspected.\n`).join("") : "handoff-proof: amber gearbox inspected";
	const prior = `${JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: priorResult }] } })}\n`.padEnd(432, " ");
	writeFileSync(session.path, prior);
	const calls = installMockSpawn([{ error: transport === "child-error" ? new Error("child launch failed") : undefined, stdout: bridgeStdout([bridgeEvent("agent_start"), bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "fresh answer" }] } })]) }], runtime.setSingleAgentSpawnForTests);
	const files: string[] = [];
	const agent = { ...testAgent(), systemPrompt: "System instructions stay separate." };
	const composed = `Task: new task\n\nPrior agent final result (${session.path}):\n${priorResult.trim()}`;
	if (transport === "long-report") {
		const child = join(root, "prompt-reader.cjs");
		writeFileSync(child, `
			const input = process.argv[2];
			const text = require("node:fs").readFileSync(input.slice(1), "utf8");
			console.log(JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text }] } }));
		`);
		runtime.setSingleAgentSpawnForTests(((_command: string, args: string[]) => {
			const input = args.at(-1)!;
			const systemFile = args[args.indexOf("--append-system-prompt") + 1]!;
			files.push(systemFile);
			if (input.startsWith("@")) files.push(input.slice(1));
			assert.equal(readFileSync(systemFile, "utf8"), agent.systemPrompt);
			// Exercise the real OS boundary. The consumer assertion reads the
			// documented file argument; Pi's file processing belongs to Pi's suite.
			return spawn(process.execPath, [child, input], { cwd, env: { PATH: "/usr/bin:/bin" }, stdio: ["ignore", "pipe", "pipe"] });
		}) as Parameters<typeof runtime.setSingleAgentSpawnForTests>[0]);
	}
	try {
		const result = await runtime.runSingleAgent(cwd, root, [agent], "reviewer-test", "new task", undefined, undefined, undefined, undefined, mockPiEvents([]), undefined, undefined, makeDetails, "reuse");
		assert.equal(result.exitCode, transport === "child-error" ? 1 : 0, result.errorMessage || result.stderr);
		assert.deepEqual([result.refused ?? false, result.sessionMode, result.sessionKey !== "reuse" && result.sessionKeyExplicit === true, readFileSync(session.path, "utf8") === prior], [false, "fresh", true, true]);
		if (transport === "long-report") {
			assert.ok(result.messages.at(-1)?.content.some(part => part.type === "text" && part.text === composed), "file transport retains the complete task and prior report");
		} else {
			assert.equal(calls.length, 1);
			assert.equal(calls[0]!.prompt, composed);
			assert.equal(result.reuseNotice, "reused as fresh (context 108%)");
			files.push(...calls[0]!.promptFiles);
			assert.ok(calls[0]!.args.at(-1)?.startsWith("@"));
			const records = readTranscript(result).trim().split("\n").map(line => JSON.parse(line));
			assert.equal(findAgentStartTranscriptPayload(records).args.some((arg: string) => arg.startsWith("@")), false, "start metadata excludes the temporary user prompt reference");
		}
		assert.equal(files.length, 2, "the system and user prompts have separate files");
		for (const file of files) {
			assert.ok(isAbsolute(file));
			assert.equal(existsSync(file), false, "prompt file is removed after the attempt");
			assert.equal(existsSync(dirname(file)), false, "owned prompt directory is removed after the attempt");
		}
	} finally {
		runtime.setSingleAgentSpawnForTests();
		// Disposable cleanup mutants may leave their owned directories behind.
		for (const file of files) rmSync(dirname(file), { force: true, recursive: true });
		for (const file of calls[0]?.promptFiles ?? []) rmSync(dirname(file), { force: true, recursive: true });
	}
}

/** Parent cancellation owns the end even if the stream carried an overflow. */
export async function assertAbortNoRetry(runtime: Pick<typeof import("../extensions/subagent/runner.js"), "runSingleAgent" | "setSingleAgentSpawnForTests">) {
	const controller = new AbortController();
	controller.abort();
	const cwd = tempRuntime();
	const calls = installMockSpawn([{ stdout: bridgeStdout([{ error: { code: "context_length_exceeded" } }]) }, {}], runtime.setSingleAgentSpawnForTests);
	try {
		const result = await runtime.runSingleAgent(cwd, tempRuntime(), [testAgent()], "reviewer-test", "task", undefined, undefined, undefined, undefined, mockPiEvents([]), controller.signal, undefined, makeDetails);
		assert.deepEqual([calls.length, result.status, result.stopReason], [1, "stopped", "aborted"]);
	} finally { runtime.setSingleAgentSpawnForTests(); }
}

/** Old setting values remain readable and produce a migration warning. */
export async function assertBudgetMigration(guard: typeof guardReusedSessionBudget, policy: string) {
	const cwd = tempRuntime();
	writeSettings(cwd, { reusedSessionBudgetPolicy: policy });
	const result = await guard(join(cwd, "absent.jsonl"), "scout", undefined, cwd);
	assert.deepEqual([result.ok, result.migrationWarning?.includes(`reusedSessionBudgetPolicy=${policy}`)], [true, true]);
}

export function cleanupTempRuntimes() {
	for (const dir of tempRuntimeDirs) rmSync(dir, { force: true, recursive: true });
	tempRuntimeDirs.clear();
}


/** Pi progress must not displace diagnostics in preparation or saved output. */
export async function assertProviderProducer(runtime: Pick<typeof import("../extensions/subagent/runner.js"), "runSingleAgent" | "setSingleAgentSpawnForTests" | "prepareSingleResultForReturn">, source: "provider" | "stderr" | "completed" = "provider", textOverride?: string) {
	const diagnostic = `diagnostic-head\n${"diagnostic detail\n".repeat(2000)}github-copilot API error (403): 403 forbidden`;
	const progress = `progress-head\n${"partial progress\n".repeat(2000)}progress-tail`;
	const cwd = tempRuntime();
	const root = tempRuntime();
	writeSettings(cwd, { resultMaxBytes: 1024, resultMaxLines: 40, preserveFullOutput: true });
	const events: Array<{ name: string; payload: unknown }> = [];
	installMockSpawn([{ code: source === "stderr" ? 1 : 0, stderr: source === "provider" ? "secondary stderr" : diagnostic, stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: progress }], stopReason: source === "provider" ? "error" : "end", errorMessage: source === "provider" ? diagnostic : undefined } })]) }], runtime.setSingleAgentSpawnForTests);
	try {
		const result = await runtime.runSingleAgent(cwd, root, [testAgent()], "reviewer-test", "map", undefined, undefined, undefined, undefined, mockPiEvents(events), undefined, undefined, makeDetails);
		const completed = source === "completed";
		assert.deepEqual([events.at(-1)?.name, (events.at(-1)?.payload as { status: string })?.status], completed ? ["subagents:completed", "completed"] : ["subagents:failed", "failed"]);
		const prepared = await runtime.prepareSingleResultForReturn(result, root, cwd, "provider-output", textOverride);
		const selected = textOverride ?? (completed ? progress : diagnostic);
		if (selected.length > 1024) {
			assert.equal(prepared.truncation?.truncated, true);
			assert.ok(prepared.fullOutputPath);
			assert.equal(readFileSync(prepared.fullOutputPath, "utf8"), selected);
			assert.deepEqual([prepared.truncation.content.includes(completed ? "progress-head" : "403 forbidden"), prepared.truncation.content.includes(completed ? "progress-tail" : "diagnostic-head")], [true, false]);
		} else {
			assert.equal(prepared.text, selected, "an explicit override, including empty text, wins over diagnostics");
		}
		if (source === "stderr" && selected) assert.equal(prepared.result.errorMessage, prepared.text, "missing errorMessage derives from the selected diagnostics");
	} finally { runtime.setSingleAgentSpawnForTests(); }
}

/** Drive parallel's no-override path with the shipped message_end and stderr producers. */
export async function assertParallelPreparedOutput(source: "provider" | "stderr" | "completed") {
	const cwd = tempRuntime();
	const root = tempRuntime();
	writeSettings(cwd, { resultMaxBytes: 1024, resultMaxLines: 40, preserveFullOutput: true });
	const progress = `progress-head\n${"partial progress\n".repeat(2000)}progress-tail`;
	const diagnostic = `diagnostic-head\n${"diagnostic detail\n".repeat(2000)}github-copilot API error (403): 403 forbidden`;
	const calls = installMockSpawn([{ code: source === "stderr" ? 1 : 0, stderr: source === "provider" ? "secondary stderr" : diagnostic, stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: progress }], stopReason: source === "provider" ? "error" : "end", errorMessage: source === "provider" ? diagnostic : undefined } })]) }]);
	const rows: SubagentDashboardItem[] = [];
	try {
		const result = await dispatch.runParallelDispatch({
			agents: [testAgent()], cwd, runtimeRoot: root, parentSessionId: "test", pi: mockPiEvents([]),
			tasks: [{ agent: "reviewer-test", task: "map" }],
			makeDetails: mode => results => ({ mode, results, agentScope: "project", projectAgentsDir: null }),
			removeDashboardAgent: () => undefined, updateDashboard: item => { rows.push(item); },
		});
		const completed = source === "completed";
		const child = result.details.results[0]!;
		assert.equal(calls.length, 1);
		assert.equal(rows.at(-1)?.status, completed ? "completed" : "failed");
		assert.ok(rows.at(-1)?.message?.includes(completed ? "progress-head" : "403 forbidden"));
		assert.ok(result.content[0]?.text.includes(completed ? "progress-head" : "403 forbidden"));
		assert.ok(child.fullOutputPath);
		assert.equal(readFileSync(child.fullOutputPath, "utf8"), completed ? progress : diagnostic);
		assert.equal(child.truncation?.content.includes(completed ? "progress-head" : "403 forbidden"), true);
	} finally { setSingleAgentSpawnForTests(); }
}
