// The neutral world every single-agent suite runs in: temp runtimes, the
// project settings writer, the two spawn mocks and the bridge event shapes.
// Nothing here plants a defect; a case that needs one builds it inline.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import { setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import { guardReusedSessionBudget, resolveBgSession } from "../extensions/subagent/sessions.js";
import { clearPackageConfigCache, recordProjectTrust } from "../extensions/subagent/package-config.js";
import { runSingleDispatch } from "../extensions/subagent/dispatch.js";
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
	const result = await (options.run ?? runSingleDispatch)({
		agents: [testAgent()], cwd, runtimeRoot: options.runtimeRoot ?? tempRuntime(),
		parentSessionId: "test", pi: mockPiEvents([]),
		agent: "reviewer-test", task: "new task", sessionKey: options.sessionKey,
		sameSession: options.sameSession, signal: options.signal,
		makeDetails: (mode) => (results) => ({ mode, agentScope: "project", projectAgentsDir: null, results }),
		removeDashboardAgent: () => undefined, updateDashboard: (item) => { rows.push(item); },
	});
	return { result, row: rows.at(-1)! };
}

/** Assert the outcome independently in model-facing data and the panel. */
export async function assertDispatchOutcome(status: "refused" | "stopped" | "failed", options: Parameters<typeof dispatchOutcome>[0], diagnostic: string) {
	const { result, row } = await dispatchOutcome(options);
	assert.deepEqual([row.status, result.isError, row.message?.includes(diagnostic), result.content[0]?.text.includes(diagnostic)], [status, true, true, true]);
	return { result, row };
}

export function installMockSpawn(scenarios: Array<{ code?: number | null; delayMs?: number; error?: Error | string; signal?: string; stderr?: string; stdout?: string }>, install = setSingleAgentSpawnForTests) {
	const calls: Array<{ args: string[]; kills: string[]; flow: { stdout: string[]; stderr: string[] } }> = [];
	install(((command: string, args: string[]) => {
		void command;
		const call = { args, kills: [] as string[], flow: { stdout: [] as string[], stderr: [] as string[] } };
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
export async function assertFreshHandoff(runtime: Pick<typeof import("../extensions/subagent/runner.js"), "runSingleAgent" | "setSingleAgentSpawnForTests">) {
	const cwd = tempRuntime();
	const root = tempRuntime();
	writeSettings(cwd, { reusedSessionContextLimitTokens: 100, reusedSessionBudgetThreshold: 0.8 });
	const session = resolveBgSession(root, "reviewer-test", "reuse");
	mkdirSync(join(root, "sessions"), { recursive: true });
	const prior = `${JSON.stringify({ type: "message", message: { role: "assistant", content: [{ type: "text", text: "prior final result" }] } })}\n`.padEnd(432, " ");
	writeFileSync(session.path, prior);
	const calls = installMockSpawn([{ stdout: bridgeStdout([bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "fresh answer" }] } })]) }], runtime.setSingleAgentSpawnForTests);
	try {
		const result = await runtime.runSingleAgent(cwd, root, [testAgent()], "reviewer-test", "new task", undefined, undefined, undefined, undefined, mockPiEvents([]), undefined, undefined, makeDetails, "reuse");
		assert.deepEqual([calls.length, result.exitCode, result.refused ?? false, result.sessionMode, result.reuseNotice, result.sessionKey !== "reuse" && result.sessionKeyExplicit === true, calls[0]?.args.at(-1)?.startsWith("Task: new task"), calls[0]?.args.at(-1)?.includes("prior final result"), readFileSync(session.path, "utf8") === prior], [1, 0, false, "fresh", "reused as fresh (context 108%)", true, true, true, true]);
	} finally { runtime.setSingleAgentSpawnForTests(); }
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

