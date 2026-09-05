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
import { recordProjectTrust } from "../extensions/subagent/settings.js";
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

export function installMockSpawn(scenarios: Array<{ code?: number | null; delayMs?: number; error?: Error | string; signal?: string; stderr?: string; stdout?: string }>) {
	const calls: Array<{ args: string[]; kills: string[] }> = [];
	setSingleAgentSpawnForTests(((command: string, args: string[]) => {
		void command;
		const call = { args, kills: [] as string[] };
		calls.push(call);
		const proc = new EventEmitter() as any;
		proc.stdout = new EventEmitter();
		proc.stderr = new EventEmitter();
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
		fn();
	} finally {
		if (previousParent === undefined) delete process.env.PI_SUBAGENT_PARENT_SESSION_ID;
		else process.env.PI_SUBAGENT_PARENT_SESSION_ID = previousParent;
		if (previousChild === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
		else process.env.PI_SUBAGENT_CHILD_AGENT = previousChild;
		if (previousDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = previousDir;
	}
}

export function cleanupTempRuntimes() {
	for (const dir of tempRuntimeDirs) rmSync(dir, { force: true, recursive: true });
	tempRuntimeDirs.clear();
}

