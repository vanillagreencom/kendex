import assert from "node:assert/strict";
import { execFileSync, spawn as spawnChild } from "node:child_process";
import { EventEmitter } from "node:events";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test, { after } from "node:test";
import type { AgentConfig } from "../extensions/subagent/agents.js";
import {
	assignEphemeralSessionKeys,
	formatInventoryValidationError,
	mapWithConcurrencyLimit,
	validateAgentInventory,
} from "../extensions/subagent/dispatch.js";
import {
	DEFAULT_MODEL_CONTEXT_LIMIT_TOKENS,
	isContextLengthExceededEnvelope,
	isContextLengthExceededText,
	ONESHOT_SESSION_PREFIX,
	resolveBgSession,
	setSessionCompactorForTests,
} from "../extensions/subagent/sessions.js";
import { extractLastAssistantTextFromTranscriptContent } from "../extensions/subagent/format.js";
import { recordProjectTrust } from "../extensions/subagent/settings.js";
import {
	runSingleAgent,
	setBgSettledShutdownGraceMsForTests,
	setBgTimeoutKillGraceMsForTests,
	setGitExecFileForTests,
	setSingleAgentSpawnForTests,
} from "../extensions/subagent/runner.js";
import { waitForIdleTransition } from "../extensions/subagent/wait.js";
import type { SingleResult, SubagentDetails } from "../extensions/subagent/types.js";

const tempRuntimeDirs = new Set<string>();

function tempRuntime(): string {
	const dir = mkdtempSync(join(tmpdir(), "pi-agents-lanes-"));
	tempRuntimeDirs.add(dir);
	return dir;
}

after(() => {
	for (const dir of tempRuntimeDirs) rmSync(dir, { force: true, recursive: true });
});

function tempGitRepo(): string {
	const cwd = tempRuntime();
	execFileSync("git", ["init"], { cwd, stdio: "ignore" });
	writeFileSync(join(cwd, "tracked.txt"), "initial\n", "utf8");
	execFileSync("git", ["add", "tracked.txt"], { cwd, stdio: "ignore" });
	execFileSync("git", ["-c", "user.name=Pi Test", "-c", "user.email=pi-test@example.invalid", "commit", "--no-gpg-sign", "-m", "initial commit"], { cwd, stdio: "ignore" });
	writeFileSync(join(cwd, "dirty.txt"), "dirty\n", "utf8");
	return cwd;
}

function writeSettings(cwd: string, config: Record<string, unknown>) {
	mkdirSync(join(cwd, ".pi"), { recursive: true });
	writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({
		vstack: { extensionManager: { config: { "@vanillagreen/pi-agents-tmux": config } } },
	}), "utf8");
	recordProjectTrust({ cwd, isProjectTrusted: () => true });
}

function testAgent(): AgentConfig {
	return {
		name: "reviewer-test",
		description: "test reviewer",
		pane: false,
		systemPrompt: "",
		source: "project",
		filePath: "reviewer-test.md",
	};
}

function installMockSpawn(scenarios: Array<{ code?: number | null; delayMs?: number; error?: Error | string; signal?: string; stderr?: string; stdout?: string }>) {
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

function installLifecycleMockSpawn(options: {
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

function bridgeStdout(events: unknown[]): string {
	return `${events.map((event) => JSON.stringify(event)).join("\n")}\n`;
}

function bridgeEvent(event: string, data: Record<string, unknown> = {}): Record<string, unknown> {
	return { type: "event", event, data };
}

type StreamShape = "nested-event" | "bridge-event" | "top-level";

function shapedStreamEvent(shape: StreamShape, event: string, data: Record<string, unknown> = {}): Record<string, unknown> {
	if (shape === "nested-event") return { event: { type: event, ...data } };
	if (shape === "bridge-event") return { type: "event", event, data };
	return { type: event, ...data };
}

function transcriptEventName(event: any): string | undefined {
	if (typeof event?.event === "string") return event.event;
	if (event?.event && typeof event.event === "object" && typeof event.event.type === "string") return event.event.type;
	if (typeof event?.type === "string") return event.type;
	return undefined;
}

function findAgentStartTranscriptPayload(records: any[]): any {
	for (const record of records) {
		const event = record.event;
		if (event?.event && typeof event.event === "object" && event.event.type === "agent_start") return event.event;
		if (event?.type === "event" && event.event === "agent_start") return event.data;
		if (event?.type === "agent_start") return event;
	}
	return undefined;
}

function mockPiEvents(events: Array<{ name: string; payload: any }>) {
	return {
		getActiveTools: () => [],
		events: {
			emit: (name: string, payload: unknown) => events.push({ name, payload }),
		},
	} as any;
}

function makeDetails(results: any[]): SubagentDetails {
	return { mode: "single", agentScope: "project", projectAgentsDir: null, results };
}

function readTranscript(result: Pick<SingleResult, "transcriptPath">): string {
	const transcriptPath = result.transcriptPath;
	assert.ok(transcriptPath);
	return readFileSync(transcriptPath, "utf8");
}

function withPollutedEnv(fn: () => void) {
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

test("oneshot default mints unique lane per call in clean and polluted env", () => {
	const cleanRuntime = tempRuntime();
	const first = resolveBgSession(cleanRuntime, "reviewer-test");
	const second = resolveBgSession(cleanRuntime, "reviewer-test");
	assert.equal(first.explicit, false);
	assert.equal(second.explicit, false);
	assert.match(first.key, new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
	assert.match(second.key, new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
	assert.notEqual(first.key, second.key);
	assert.notEqual(first.path, second.path);
	const forwardedOneShot = resolveBgSession(cleanRuntime, "reviewer-test", first.key);
	assert.equal(forwardedOneShot.explicit, false);
	assert.equal(forwardedOneShot.ephemeral, true);
	assert.equal(forwardedOneShot.key, first.key);

	withPollutedEnv(() => {
		const pollutedRuntime = tempRuntime();
		const pollutedFirst = resolveBgSession(pollutedRuntime, "reviewer-test");
		const pollutedSecond = resolveBgSession(pollutedRuntime, "reviewer-test");
		assert.notEqual(pollutedFirst.key, pollutedSecond.key);
		assert.match(pollutedFirst.key, new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
	});
});

test("oneshot launches Pi with the agent name as startup session name", async () => {
	const calls = installMockSpawn([{ code: 0, stdout: bridgeStdout([
		shapedStreamEvent("top-level", "message_end", { message: { role: "assistant", content: [{ type: "text", text: "ok" }], usage: { input: 1, output: 1, totalTokens: 2 } } }),
	]) }]);
	try {
		const agent = testAgent();
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[agent],
			agent.name,
			"review task",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 0);
		const nameFlag = calls[0]!.args.indexOf("--name");
		assert.ok(nameFlag >= 0, "expected --name in child Pi args");
		assert.equal(calls[0]!.args[nameFlag + 1], "reviewer-test");
	} finally {
		setSingleAgentSpawnForTests(undefined);
	}
});

test("oneshot transcript filters message_update and enriches agent_start for supported stream shapes", async () => {
	const previousFull = process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	const shapes: StreamShape[] = ["nested-event", "bridge-event", "top-level"];
	for (const shape of shapes) {
		delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
		installMockSpawn([{ code: 0, stdout: bridgeStdout([
			shapedStreamEvent(shape, "agent_start"),
			shapedStreamEvent(shape, "message_start"),
			shapedStreamEvent(shape, "message_update", { message: { role: "assistant", content: [{ type: "text", text: `partial ${shape}` }] } }),
			shapedStreamEvent(shape, "message_end", { message: { role: "assistant", content: [{ type: "text", text: `final ${shape}` }], usage: { input: 3, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 5 }, model: "openai-codex/gpt-5.6-sol:xhigh" } }),
		]) }]);
		try {
			const agent = { ...testAgent(), model: "openai-codex/gpt-5.6-sol:xhigh" };
			const result = await runSingleAgent(
				tempRuntime(),
				tempRuntime(),
				[agent],
				agent.name,
				`review task ${shape}`,
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents([]),
				undefined,
				undefined,
				makeDetails,
			);

			assert.equal(result.exitCode, 0, shape);
			assert.equal(result.messages.at(-1)?.role, "assistant", shape);
			const content = readTranscript(result);
			assert.equal(content.includes("message_update"), false, shape);
			assert.match(content, /message_start/, shape);
			assert.match(content, /message_end/, shape);
			const records = content.trim().split(/\r?\n/).map((line) => JSON.parse(line));
			const agentStart = findAgentStartTranscriptPayload(records);
			assert.equal(agentStart.agent, "reviewer-test", shape);
			assert.equal(agentStart.model, "openai-codex/gpt-5.6-sol:xhigh", shape);
			assert.ok(Array.isArray(agentStart.args), shape);
			assert.ok(agentStart.args.includes("--model"), shape);
			assert.ok(agentStart.args.includes("openai-codex/gpt-5.6-sol:xhigh"), shape);
			assert.equal(agentStart.args.some((arg: string) => arg.startsWith("Task: ")), false, shape);
		} finally {
			setSingleAgentSpawnForTests();
		}
	}
	if (previousFull === undefined) delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	else process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL = previousFull;
});

test("failed oneshot transcript flushes latest filtered message_update after the last message_end", async () => {
	const previousFull = process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	const shapes: StreamShape[] = ["nested-event", "bridge-event", "top-level"];
	const failurePaths: Array<{ code?: number | null; error?: Error; expectedExitCode: number; kind: "nonzero_exit" | "process_error"; signal?: string }> = [
		{ code: 1, expectedExitCode: 1, kind: "nonzero_exit" },
		{ code: null, expectedExitCode: 1, kind: "nonzero_exit", signal: "SIGTERM" },
		{ error: new Error("mock process error"), expectedExitCode: 1, kind: "process_error" },
	];
	for (const shape of shapes) {
		for (const failure of failurePaths) {
			delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
			installMockSpawn([{ code: failure.code, error: failure.error, signal: failure.signal, stdout: bridgeStdout([
				shapedStreamEvent(shape, "message_update", { message: { role: "assistant", content: [{ type: "text", text: `pre-end partial ${shape} ${failure.kind}` }] } }),
				shapedStreamEvent(shape, "message_end", { message: { role: "assistant", content: [{ type: "text", text: `pre-end final ${shape} ${failure.kind}` }], usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2 } } }),
				shapedStreamEvent(shape, "message_update", { message: { role: "assistant", content: [{ type: "text", text: `stale failure ${shape} ${failure.kind}` }] } }),
				shapedStreamEvent(shape, "message_update", { message: { role: "assistant", content: [{ type: "text", text: `latest failure ${shape} ${failure.kind}` }] } }),
			]) }]);
			try {
				const result = await runSingleAgent(
					tempRuntime(),
					tempRuntime(),
					[testAgent()],
					"reviewer-test",
					`review task ${shape} ${failure.kind}`,
					undefined,
					undefined,
					undefined,
					undefined,
					mockPiEvents([]),
					undefined,
					undefined,
					makeDetails,
				);
				const content = readTranscript(result);
				const label = `${shape} ${failure.kind}`;
				assert.equal(result.exitCode, failure.expectedExitCode, label);
				assert.match(content, /message_update/, label);
				assert.equal(content.includes(`pre-end partial ${label}`), false, label);
				assert.equal(content.includes(`stale failure ${label}`), false, label);
				assert.match(content, new RegExp(`latest failure ${label}`), label);
				assert.match(content, /"buffered":true/, label);
				assert.match(content, new RegExp(`"reason":"${failure.kind}"`), label);
				if (failure.signal) assert.match(content, new RegExp(`"signal":"${failure.signal}"`), label);
				const updateRecords = content.trim().split(/\r?\n/).map((line) => JSON.parse(line)).filter((record) => record.event && transcriptEventName(record.event) === "message_update");
				assert.equal(updateRecords.length, 1, label);
			} finally {
				setSingleAgentSpawnForTests();
			}
		}
	}
	if (previousFull === undefined) delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	else process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL = previousFull;
});

test("full-stream transcript still records a reconstructed partial message on failure", async () => {
	const previousFull = process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL = "1";
	// Full-stream mode keeps the raw deltas, but no reader folds deltas, so without the
	// reconstruction the partial answer is just as unrecoverable here as in filtered mode.
	installMockSpawn([{ code: 1, stdout: bridgeStdout([
		shapedStreamEvent("top-level", "message_start"),
		shapedStreamEvent("top-level", "message_update", { assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "full mode " } }),
		shapedStreamEvent("top-level", "message_update", { assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "partial answer" } }),
	]) }]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review task full stream",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		const content = readTranscript(result);
		// Raw updates are still present in full mode...
		assert.match(content, /text_delta/);
		// ...and the summary path can now recover the answer.
		assert.equal(extractLastAssistantTextFromTranscriptContent(content), "full mode partial answer");
	} finally {
		setSingleAgentSpawnForTests();
	}
	if (previousFull === undefined) delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	else process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL = previousFull;
});

test("failed oneshot transcript keeps only the newest message's deltas across a message boundary", async () => {
	const previousFull = process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	// message_start must reset BOTH the accumulator and the pending event, or the flush pairs a
	// stale event with a fresh reconstruction.
	installMockSpawn([{ code: 1, stdout: bridgeStdout([
		shapedStreamEvent("top-level", "message_start"),
		shapedStreamEvent("top-level", "message_update", { assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "first message" } }),
		shapedStreamEvent("top-level", "message_end", { message: { role: "assistant", content: [{ type: "text", text: "first message" }], usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2 } } }),
		shapedStreamEvent("top-level", "message_start"),
		shapedStreamEvent("top-level", "message_update", { assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "second message" } }),
	]) }]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review task message boundary",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		const content = readTranscript(result);
		const flushed = content.trim().split(/\r?\n/).map((line) => JSON.parse(line)).filter((record) => record.buffered);
		assert.equal(flushed.length, 1);
		assert.deepEqual(flushed[0].partialMessage, { role: "assistant", content: [{ type: "text", text: "second message" }] });
		assert.equal(extractLastAssistantTextFromTranscriptContent(content), "second message");
	} finally {
		setSingleAgentSpawnForTests();
	}
	if (previousFull === undefined) delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	else process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL = previousFull;
});

test("failed oneshot transcript rebuilds the partial message from Pi 0.84 delta-only message_update events", async () => {
	const previousFull = process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	const shapes: StreamShape[] = ["nested-event", "bridge-event", "top-level"];
	for (const shape of shapes) {
		delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
		// Pi 0.84.0 strips the cumulative `message`/`partial` snapshots from the JSON wire event,
		// so the flushed record must carry text rebuilt from the deltas rather than one token.
		installMockSpawn([{ code: 1, stdout: bridgeStdout([
			shapedStreamEvent(shape, "message_start"),
			shapedStreamEvent(shape, "message_update", { assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: `rebuilt ${shape} ` } }),
			shapedStreamEvent(shape, "message_update", { assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "partial answer" } }),
		]) }]);
		try {
			const result = await runSingleAgent(
				tempRuntime(),
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				`review task deltas ${shape}`,
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents([]),
				undefined,
				undefined,
				makeDetails,
			);
			const content = readTranscript(result);
			const flushed = content.trim().split(/\r?\n/).map((line) => JSON.parse(line)).filter((record) => record.buffered);
			assert.equal(flushed.length, 1, shape);
			assert.deepEqual(flushed[0].partialMessage, { role: "assistant", content: [{ type: "text", text: `rebuilt ${shape} partial answer` }] }, shape);
			// The observable that matters: the readers which back the task summary and the dashboard
			// must recover the rebuilt text. Asserting only the record field passed while the
			// summary path still returned nothing.
			assert.equal(extractLastAssistantTextFromTranscriptContent(content), `rebuilt ${shape} partial answer`, shape);
		} finally {
			setSingleAgentSpawnForTests();
		}
	}
	if (previousFull === undefined) delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	else process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL = previousFull;
});

test("failed oneshot transcript does not flush a message_update finalized by message_end", async () => {
	const previousFull = process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	const failurePaths: Array<{ code?: number; error?: Error; kind: "nonzero_exit" | "process_error" }> = [
		{ code: 1, kind: "nonzero_exit" },
		{ error: new Error("mock process error"), kind: "process_error" },
	];
	for (const failure of failurePaths) {
		delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
		installMockSpawn([{ code: failure.code, error: failure.error, stdout: bridgeStdout([
			shapedStreamEvent("top-level", "message_update", { message: { role: "assistant", content: [{ type: "text", text: `finalized partial ${failure.kind}` }] } }),
			shapedStreamEvent("top-level", "message_end", { message: { role: "assistant", content: [{ type: "text", text: `finalized final ${failure.kind}` }], usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2 } } }),
		]) }]);
		try {
			const result = await runSingleAgent(
				tempRuntime(),
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				`review task finalized ${failure.kind}`,
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents([]),
				undefined,
				undefined,
				makeDetails,
			);
			const content = readTranscript(result);
			assert.equal(result.exitCode, 1, failure.kind);
			assert.equal(content.includes("message_update"), false, failure.kind);
			assert.equal(content.includes(`finalized partial ${failure.kind}`), false, failure.kind);
			assert.match(content, new RegExp(`finalized final ${failure.kind}`), failure.kind);
			assert.equal(content.includes('"buffered":true'), false, failure.kind);
		} finally {
			setSingleAgentSpawnForTests();
		}
	}
	if (previousFull === undefined) delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	else process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL = previousFull;
});

test("bg one-shot timeout returns failed result and kills hung child", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 5 });
	const runtimeRoot = tempRuntime();
	const events: Array<{ name: string; payload: any }> = [];
	setBgTimeoutKillGraceMsForTests(1);
	const calls = installLifecycleMockSpawn({
		stdout: bridgeStdout([
			shapedStreamEvent("top-level", "message_update", { message: { role: "assistant", content: [{ type: "text", text: "stuck in tool loop" }] } }),
		]),
	});
	try {
		const result = await runSingleAgent(
			cwd,
			runtimeRoot,
			[testAgent()],
			"reviewer-test",
			"hang forever",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(events),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 1);
		assert.equal(result.status, "failed");
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.match(result.errorMessage ?? "", /exceeded bg task timeout/);
		assert.match(result.errorMessage ?? "", /Timeout termination SIGTERM: SIGTERM child delivered/);
		assert.match(result.errorMessage ?? "", /Timeout termination SIGKILL: SIGKILL child delivered/);
		assert.match(result.errorMessage ?? "", /Timeout termination unconfirmed/);
		assert.equal(calls.length, 1);
		assert.deepEqual(calls[0]?.kills, ["SIGTERM", "SIGKILL"]);
		const content = readTranscript(result);
		assert.match(content, /stuck in tool loop/);
		assert.match(content, /"buffered":true/);
		assert.match(content, /"reason":"timeout"/);
		assert.match(content, /Timeout termination SIGTERM/);
		assert.match(content, /Timeout termination SIGKILL/);
		const failed = events.find((event) => event.name === "subagents:failed");
		assert.equal(failed?.payload.reason, "unresponsive_timeout");
		assert.equal(failed?.payload.status, "failed");
		assert.match(failed?.payload.error ?? "", /Timeout termination unconfirmed/);
	} finally {
		setSingleAgentSpawnForTests();
		setBgTimeoutKillGraceMsForTests();
	}
});

test("bg one-shot timeout records termination failure diagnostics", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 5 });
	setBgTimeoutKillGraceMsForTests(1);
	const calls = installLifecycleMockSpawn({ kill: () => false });
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"ignore termination",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.deepEqual(calls[0]?.kills, ["SIGTERM", "SIGKILL"]);
		assert.match(result.errorMessage ?? "", /SIGTERM child failed: proc.kill returned false/);
		assert.match(result.errorMessage ?? "", /SIGKILL child failed: proc.kill returned false/);
		assert.match(readTranscript(result), /proc.kill returned false/);
	} finally {
		setSingleAgentSpawnForTests();
		setBgTimeoutKillGraceMsForTests();
	}
});

test("bg one-shot timeout still terminates and resolves when its update callback throws", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 5 });
	setBgTimeoutKillGraceMsForTests(1);
	const calls = installLifecycleMockSpawn();
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"throw from timeout update",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			() => { throw new Error("update callback exploded"); },
			makeDetails,
		);
		assert.equal(result.exitCode, 1);
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.deepEqual(calls[0]?.kills, ["SIGTERM", "SIGKILL"]);
		assert.match(result.errorMessage ?? "", /Timeout update callback failed: Error: update callback exploded/);
	} finally {
		setSingleAgentSpawnForTests();
		setBgTimeoutKillGraceMsForTests();
	}
});

test("bg one-shot timeout uses detached process-group termination when pid is available", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 5 });
	setBgTimeoutKillGraceMsForTests(1);
	const calls = installLifecycleMockSpawn({ pid: 12345 });
	const processKillCalls: Array<{ pid: number; signal?: string | number }> = [];
	const previousKill = process.kill;
	(process as unknown as { kill: typeof process.kill }).kill = ((pid: number, signal?: string | number) => {
		processKillCalls.push({ pid, signal });
		return true;
	}) as typeof process.kill;
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"hang with pid",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.equal(calls[0]?.detached, process.platform !== "win32");
		assert.deepEqual(calls[0]?.kills, []);
		assert.deepEqual(processKillCalls, [
			{ pid: -12345, signal: "SIGTERM" },
			{ pid: -12345, signal: "SIGKILL" },
		]);
		assert.match(result.errorMessage ?? "", /SIGTERM process-group delivered/);
		assert.match(result.errorMessage ?? "", /SIGKILL process-group delivered/);
	} finally {
		(process as unknown as { kill: typeof process.kill }).kill = previousKill;
		setSingleAgentSpawnForTests();
		setBgTimeoutKillGraceMsForTests();
	}
});

test("bg one-shot timeout falls back to child kill when process-group signal fails", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 5 });
	setBgTimeoutKillGraceMsForTests(1);
	const calls = installLifecycleMockSpawn({ pid: 12345 });
	const previousKill = process.kill;
	(process as unknown as { kill: typeof process.kill }).kill = ((pid: number, signal?: string | number) => {
		throw new Error(`cannot signal ${pid} with ${String(signal)}`);
	}) as typeof process.kill;
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"hang with failed process group",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.equal(calls[0]?.detached, process.platform !== "win32");
		assert.deepEqual(calls[0]?.kills, ["SIGTERM", "SIGKILL"]);
		assert.match(result.errorMessage ?? "", /SIGTERM process-group failed: .*cannot signal -12345/);
		assert.match(result.errorMessage ?? "", /SIGTERM child delivered/);
		assert.match(result.errorMessage ?? "", /SIGKILL process-group failed: .*cannot signal -12345/);
		assert.match(result.errorMessage ?? "", /SIGKILL child delivered/);
	} finally {
		(process as unknown as { kill: typeof process.kill }).kill = previousKill;
		setSingleAgentSpawnForTests();
		setBgTimeoutKillGraceMsForTests();
	}
});

test("bg one-shot timeout observes close after SIGTERM without escalating to SIGKILL", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 5 });
	setBgTimeoutKillGraceMsForTests(20);
	const events: Array<{ name: string; payload: any }> = [];
	const calls = installLifecycleMockSpawn({ closeOnSignal: "SIGTERM" });
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"close after timeout term",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(events),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 1);
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
		assert.match(result.errorMessage ?? "", /Timeout termination SIGTERM/);
		assert.doesNotMatch(result.errorMessage ?? "", /Timeout termination SIGKILL/);
		assert.doesNotMatch(result.errorMessage ?? "", /Timeout termination unconfirmed/);
		const failed = events.find((event) => event.name === "subagents:failed");
		assert.match(failed?.payload.error ?? "", /Timeout termination SIGTERM/);
		assert.doesNotMatch(failed?.payload.error ?? "", /Timeout termination SIGKILL/);
		const content = readTranscript(result);
		assert.match(content, /Timeout termination SIGTERM/);
		assert.doesNotMatch(content, /Timeout termination SIGKILL/);
		assert.doesNotMatch(content, /Timeout termination unconfirmed/);
	} finally {
		setSingleAgentSpawnForTests();
		setBgTimeoutKillGraceMsForTests();
	}
});

test("bg one-shot timeout disabled preserves a delayed successful exit", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 0 });
	const events: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, delayMs: 10, stdout: bridgeStdout([
			bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "done after delay" }], usage: { input: 1, output: 1, totalTokens: 2 } } }),
		]) },
	]);
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"finish after disabled timeout",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(events),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 0);
		assert.notEqual(result.stopReason, "unresponsive_timeout");
		assert.deepEqual(calls[0]?.kills, []);
		assert.equal(events.some((event) => event.name === "subagents:failed"), false);
		assert.equal(events.find((event) => event.name === "subagents:completed")?.payload.status, "completed");
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot agent_settled stops a lingering print process and completes successfully", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 100 });
	const events: Array<{ name: string; payload: any }> = [];
	setBgSettledShutdownGraceMsForTests(1);
	const calls = installLifecycleMockSpawn({
		closeOnSignal: "SIGTERM",
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("message_end", {
				message: {
					role: "assistant",
					content: [{ type: "text", text: "done before the print process exits" }],
					usage: { input: 1, output: 1, totalTokens: 2 },
					stopReason: "stop",
				},
			}),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "done before the print process exits" }] }),
			bridgeEvent("agent_settled"),
		]),
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"finish semantically before process exit",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(events),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 0);
		assert.equal(result.stopReason, "stop");
		assert.equal(result.errorMessage, undefined);
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
		assert.equal(events.some((event) => event.name === "subagents:failed"), false);
		assert.equal(events.find((event) => event.name === "subagents:completed")?.payload.status, "completed");
		const content = readTranscript(result);
		assert.match(content, /"type":"settled_shutdown"/);
		assert.match(content, /"semanticCompletion":"agent_settled"/);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot activity after agent_settled cancels the pending process shutdown", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 100 });
	setBgSettledShutdownGraceMsForTests(5);
	const calls = installLifecycleMockSpawn({
		closeAfterMs: 20,
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("message_end", {
				message: {
					role: "assistant",
					content: [{ type: "text", text: "first settled response" }],
					usage: { input: 1, output: 1, totalTokens: 2 },
					stopReason: "stop",
				},
			}),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "first settled response" }] }),
			bridgeEvent("agent_settled"),
			bridgeEvent("agent_start"),
			bridgeEvent("turn_start"),
			bridgeEvent("message_end", {
				message: {
					role: "assistant",
					content: [{ type: "text", text: "extension-started continuation" }],
					usage: { input: 1, output: 1, totalTokens: 2 },
					stopReason: "stop",
				},
			}),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "extension-started continuation" }] }),
		]),
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"continue after settling",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 0);
		assert.deepEqual(calls[0]?.kills, []);
		assert.equal(result.messages.at(-1)?.role, "assistant");
		assert.deepEqual(result.messages.at(-1)?.content, [{ type: "text", text: "extension-started continuation" }]);
		assert.doesNotMatch(readTranscript(result), /"type":"settled_shutdown"/);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot activity after agent_settled restores task timeout ownership", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 5 });
	setBgSettledShutdownGraceMsForTests(20);
	const calls = installLifecycleMockSpawn({
		closeAfterMs: 20,
		closeOnSignal: "SIGTERM",
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "first response" }] }),
			bridgeEvent("agent_settled"),
			bridgeEvent("agent_start"),
			bridgeEvent("turn_start"),
		]),
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"hang after continuation cancels settled shutdown",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 1);
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot settled cancellation re-arms at the ORIGINAL deadline, not a fresh window", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 300 });
	// Grace far beyond the test window: settlement suspends the timeout but
	// never delivers its SIGTERM, so the only kill can come from the timeout.
	setBgSettledShutdownGraceMsForTests(10_000);
	setBgTimeoutKillGraceMsForTests(1);
	// Margins are deliberately wide (>=140ms between every ordered pair) so
	// only an extreme event-loop stall could reorder them: the immediate
	// re-armed timeout at ~320ms races the 460ms close, and the 460ms close
	// must land before a fresh-window mutant's 620ms deadline.
	const calls = installLifecycleMockSpawn({
		closeAfterMs: 460,
		closeOnSignal: "SIGTERM",
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "first response" }] }),
		]),
		stdoutChunks: [
			{ delayMs: 10, text: bridgeStdout([bridgeEvent("agent_settled")]) },
			{ delayMs: 320, text: bridgeStdout([bridgeEvent("agent_start"), bridgeEvent("turn_start")]) },
		],
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"cancel settled shutdown after the original deadline passed",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		// Settlement at 10ms suspends the 300ms deadline; the continuation at
		// 320ms re-arms AGAINST THAT ORIGINAL deadline, which has already
		// passed, so the timeout fires immediately — before the 460ms close.
		// A fresh-window re-arm (320ms + 300ms = 620ms) would let close(0) at
		// 460ms win and report success.
		assert.equal(result.exitCode, 1);
		assert.equal(result.stopReason, "unresponsive_timeout");
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setBgTimeoutKillGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot abort during settled grace clears the pending settled SIGTERM", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 0 });
	setBgSettledShutdownGraceMsForTests(60);
	setBgTimeoutKillGraceMsForTests(10_000);
	const controller = new AbortController();
	const calls = installLifecycleMockSpawn({
		closeAfterMs: 100,
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "done" }] }),
		]),
		stdoutChunks: [
			{ delayMs: 5, text: bridgeStdout([bridgeEvent("agent_settled")]) },
		],
	});
	setTimeout(() => controller.abort(), 25);
	try {
		// The abort at 25ms lands inside the settled grace window (armed at
		// 5ms, SIGTERM due at 65ms). Abort must take over the lifecycle: the
		// run rejects as aborted — never a settled semantic completion — and
		// exactly one SIGTERM is delivered by the abort path; a surviving
		// settled grace timer would deliver a second one at 65ms before the
		// 100ms close.
		await assert.rejects(
			runSingleAgent(
				cwd,
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				"abort while a settled shutdown is pending",
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents([]),
				controller.signal,
				undefined,
				makeDetails,
			),
			/Agent was aborted/,
		);
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setBgTimeoutKillGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot activity emitted after delivered settled SIGTERM cannot cancel shutdown", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 0 });
	setBgSettledShutdownGraceMsForTests(1);
	setBgTimeoutKillGraceMsForTests(500);
	const childPath = join(cwd, "sigterm-disposal-child.mjs");
	writeFileSync(childPath, `
const emit = (event, data = {}, callback) => process.stdout.write(JSON.stringify({ type: "event", event, data }) + "\\n", callback);
process.on("SIGTERM", () => {
	emit("agent_start");
	emit("turn_start");
	emit("agent_end", { content: [{ type: "text", text: "signal disposal" }] });
	emit("agent_settled", {}, () => {
		clearInterval(keepalive);
		process.exitCode = 143;
	});
});
emit("agent_start");
emit("agent_end", { content: [{ type: "text", text: "done" }] });
emit("agent_settled");
const keepalive = setInterval(() => {}, 1000);
`, "utf8");
	let child: ReturnType<typeof spawnChild> | undefined;
	setSingleAgentSpawnForTests(((_command: string, _args: string[], spawnOptions?: { detached?: boolean }) => {
		child = spawnChild(process.execPath, [childPath], {
			cwd,
			detached: spawnOptions?.detached,
			stdio: ["ignore", "pipe", "pipe"],
		});
		return child;
	}) as any);
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"ignore disposal activity after settled SIGTERM",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 0);
		assert.equal(result.messages.length, 0);
		const content = readTranscript(result);
		assert.match(content, /"type":"settled_shutdown_cancellation_skipped"/);
		assert.match(content, /"reason":"signal_delivered"/);
		assert.match(content, /"type":"settled_shutdown_skipped"/);
		assert.doesNotMatch(content, /"type":"settled_shutdown_cancelled"/);
		assert.match(content, /"semanticCompletion":"agent_settled"/);
	} finally {
		if (child?.exitCode === null && child.pid) {
			try {
				if (process.platform === "win32") child.kill("SIGKILL");
				else process.kill(-child.pid, "SIGKILL");
			} catch {
				child.kill("SIGKILL");
			}
		}
		setBgSettledShutdownGraceMsForTests();
		setBgTimeoutKillGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot ignores stale agent_settled after a continuation starts", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 100 });
	setBgSettledShutdownGraceMsForTests(1);
	const calls = installLifecycleMockSpawn({
		closeOnSignal: "SIGTERM",
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("message_end", {
				message: {
					role: "assistant",
					content: [{ type: "text", text: "first response" }],
					usage: { input: 1, output: 1, totalTokens: 2 },
					stopReason: "stop",
				},
			}),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "first response" }] }),
			bridgeEvent("agent_start"),
			bridgeEvent("turn_start"),
			bridgeEvent("agent_settled"),
		]),
		stdoutChunks: [{
			delayMs: 10,
			text: bridgeStdout([
				bridgeEvent("message_end", {
					message: {
						role: "assistant",
						content: [{ type: "text", text: "continuation response" }],
						usage: { input: 1, output: 1, totalTokens: 2 },
						stopReason: "stop",
					},
				}),
				bridgeEvent("agent_end", { content: [{ type: "text", text: "continuation response" }] }),
				bridgeEvent("agent_settled"),
			]),
		}],
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"continue before stale settlement is published",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 0);
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
		assert.deepEqual(result.messages.at(-1)?.content, [{ type: "text", text: "continuation response" }]);
		const content = readTranscript(result);
		assert.match(content, /"type":"settled_shutdown_skipped"/);
		assert.match(content, /"reason":"agent_active"/);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot accepts one settlement after multiple low-level agent runs", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 100 });
	setBgSettledShutdownGraceMsForTests(1);
	const calls = installLifecycleMockSpawn({
		closeOnSignal: "SIGTERM",
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "retryable response" }] }),
			bridgeEvent("agent_start"),
			bridgeEvent("message_end", {
				message: {
					role: "assistant",
					content: [{ type: "text", text: "final response" }],
					usage: { input: 1, output: 1, totalTokens: 2 },
					stopReason: "stop",
				},
			}),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "final response" }] }),
			bridgeEvent("agent_settled"),
		]),
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"settle after retry chain",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 0);
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
		assert.deepEqual(result.messages.at(-1)?.content, [{ type: "text", text: "final response" }]);
		assert.doesNotMatch(readTranscript(result), /"type":"settled_shutdown_skipped"/);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot valid settlement owns shutdown before the task timeout", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 1 });
	setBgSettledShutdownGraceMsForTests(5);
	setBgTimeoutKillGraceMsForTests(5);
	const events: Array<{ name: string; payload: any }> = [];
	const calls = installLifecycleMockSpawn({
		closeOnSignal: "SIGKILL",
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("message_end", {
				message: {
					role: "assistant",
					content: [{ type: "text", text: "settled before timeout" }],
					usage: { input: 1, output: 1, totalTokens: 2 },
					stopReason: "stop",
				},
			}),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "settled before timeout" }] }),
			bridgeEvent("agent_settled"),
		]),
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"settle before timeout ownership",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(events),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 0);
		assert.equal(result.stopReason, "stop");
		assert.deepEqual(calls[0]?.kills, ["SIGTERM", "SIGKILL"]);
		assert.equal(events.some((event) => event.name === "subagents:failed"), false);
		assert.doesNotMatch(readTranscript(result), /"type":"timeout"/);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setBgTimeoutKillGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot failed settled shutdown delivery preserves a later nonzero exit", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 0 });
	setBgSettledShutdownGraceMsForTests(1);
	const events: Array<{ name: string; payload: any }> = [];
	const calls = installLifecycleMockSpawn({
		kill: (signal, _count, proc) => {
			if (signal === "SIGTERM") queueMicrotask(() => proc.emit("close", 1, null));
			return false;
		},
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("message_end", {
				message: {
					role: "assistant",
					content: [{ type: "text", text: "semantic response before failed shutdown" }],
					usage: { input: 1, output: 1, totalTokens: 2 },
					stopReason: "stop",
				},
			}),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "semantic response before failed shutdown" }] }),
			bridgeEvent("agent_settled"),
		]),
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"fail settled signal delivery",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(events),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 1);
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
		assert.equal(events.some((event) => event.name === "subagents:completed"), false);
		assert.equal(events.find((event) => event.name === "subagents:failed")?.payload.status, "failed");
		assert.doesNotMatch(readTranscript(result), /"semanticCompletion":"agent_settled"/);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot delivered settled signal does not mask an unrelated nonzero exit", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 0 });
	setBgSettledShutdownGraceMsForTests(1);
	const events: Array<{ name: string; payload: any }> = [];
	const calls = installLifecycleMockSpawn({
		kill: (signal, _count, proc) => {
			if (signal === "SIGTERM") queueMicrotask(() => proc.emit("close", 1, null));
			return true;
		},
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "done" }] }),
			bridgeEvent("agent_settled"),
		]),
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"close nonzero after delivered settled signal",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(events),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 1);
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
		assert.equal(events.some((event) => event.name === "subagents:completed"), false);
		assert.doesNotMatch(readTranscript(result), /"semanticCompletion":"agent_settled"/);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot failed settled SIGTERM and SIGKILL resolve as bounded failure", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 0 });
	setBgSettledShutdownGraceMsForTests(1);
	setBgTimeoutKillGraceMsForTests(1);
	const calls = installLifecycleMockSpawn({
		kill: () => false,
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "done" }] }),
			bridgeEvent("agent_settled"),
		]),
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"fail all settled shutdown signals",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 1);
		assert.deepEqual(calls[0]?.kills, ["SIGTERM", "SIGKILL"]);
		assert.match(result.errorMessage ?? "", /Settled shutdown failed/);
		assert.match(readTranscript(result), /"type":"settled_shutdown_failed"/);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setBgTimeoutKillGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot delivered settled signals without close resolve as bounded failure", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 0 });
	setBgSettledShutdownGraceMsForTests(1);
	setBgTimeoutKillGraceMsForTests(1);
	const calls = installLifecycleMockSpawn({
		kill: () => true,
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "done" }] }),
			bridgeEvent("agent_settled"),
		]),
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"deliver settled signals without close",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 1);
		assert.deepEqual(calls[0]?.kills, ["SIGTERM", "SIGKILL"]);
		assert.match(result.errorMessage ?? "", /did not emit close within .* after SIGKILL/);
		assert.match(readTranscript(result), /"type":"settled_shutdown_failed"/);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setBgTimeoutKillGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot terminal resolution clears pending settled kill escalation", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 0 });
	setBgSettledShutdownGraceMsForTests(1);
	setBgTimeoutKillGraceMsForTests(5);
	const calls = installLifecycleMockSpawn({
		kill: (signal, _count, proc) => {
			if (signal === "SIGTERM") queueMicrotask(() => proc.emit("error", new Error("mock process error")));
			return true;
		},
		stdout: bridgeStdout([
			bridgeEvent("agent_start"),
			bridgeEvent("agent_end", { content: [{ type: "text", text: "done" }] }),
			bridgeEvent("agent_settled"),
		]),
	});
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"resolve before settled kill escalation",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(result.exitCode, 1);
		await new Promise((resolve) => setTimeout(resolve, 10));
		assert.deepEqual(calls[0]?.kills, ["SIGTERM"]);
	} finally {
		setBgSettledShutdownGraceMsForTests();
		setBgTimeoutKillGraceMsForTests();
		setSingleAgentSpawnForTests();
	}
});

test("bg one-shot normal exits before active timeout keep original lifecycle", async () => {
	const cwd = tempRuntime();
	writeSettings(cwd, { bgTaskTimeoutMs: 250 });
	const cases: Array<{ code?: number | null; expectedEvent: string; expectedExitCode: number; expectedStatus: string; label: string; signal?: string }> = [
		{ code: 0, expectedEvent: "subagents:completed", expectedExitCode: 0, expectedStatus: "completed", label: "success" },
		{ code: 2, expectedEvent: "subagents:failed", expectedExitCode: 2, expectedStatus: "failed", label: "nonzero" },
		{ code: null, expectedEvent: "subagents:failed", expectedExitCode: 1, expectedStatus: "failed", label: "signal", signal: "SIGTERM" },
	];
	for (const item of cases) {
		const events: Array<{ name: string; payload: any }> = [];
		const calls = installMockSpawn([{ code: item.code, delayMs: 5, signal: item.signal }]);
		try {
			const result = await runSingleAgent(
				cwd,
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				`finish before timeout ${item.label}`,
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents(events),
				undefined,
				undefined,
				makeDetails,
			);
			assert.equal(result.exitCode, item.expectedExitCode, item.label);
			assert.notEqual(result.stopReason, "unresponsive_timeout", item.label);
			assert.deepEqual(calls[0]?.kills, [], item.label);
			const lifecycle = events.find((event) => event.name === item.expectedEvent);
			assert.equal(lifecycle?.payload.status, item.expectedStatus, item.label);
			assert.notEqual(lifecycle?.payload.reason, "unresponsive_timeout", item.label);
		} finally {
			setSingleAgentSpawnForTests();
		}
	}
});

test("oneshot transcript keeps message_update snapshots when full stream env is enabled", async () => {
	const previousFull = process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL = "1";
	installMockSpawn([
		{ code: 0, stdout: bridgeStdout([
			{ type: "message_update", message: { role: "assistant", content: [{ type: "text", text: "partial" }] } },
			{ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "final" }], usage: { input: 1, output: 1, totalTokens: 2 } } },
		]) },
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review task",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents([]),
			undefined,
			undefined,
			makeDetails,
		);
		const content = readTranscript(result);
		assert.match(content, /message_update/);
	} finally {
		setSingleAgentSpawnForTests();
		if (previousFull === undefined) delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
		else process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL = previousFull;
	}
});

test("parallel tasks for same agent get distinct ephemeral lanes", () => {
	const tasks = assignEphemeralSessionKeys([
		{ agent: "reviewer-test", task: "one" },
		{ agent: "reviewer-test", task: "two" },
		{ agent: "reviewer-test", task: "three" },
	]);
	assert.equal(new Set(tasks.map((item) => item.sessionKey)).size, 3);
	for (const task of tasks) assert.match(task.sessionKey ?? "", new RegExp(`^${ONESHOT_SESSION_PREFIX}`));
});

test("explicit sessionKey reuses same lane", () => {
	const runtimeRoot = tempRuntime();
	const first = resolveBgSession(runtimeRoot, "reviewer-test", "issue-27");
	const second = resolveBgSession(runtimeRoot, "reviewer-test", "issue-27");
	assert.equal(first.explicit, true);
	assert.equal(first.ephemeral, false);
	assert.equal(first.key, "issue-27");
	assert.equal(second.key, "issue-27");
	assert.equal(first.path, second.path);
});

test("context_length_exceeded detection triggers one retry with fresh session", async () => {
	assert.equal(isContextLengthExceededText('Codex error: {"type":"error","error":{"type":"invalid_request_error","code":"context_length_exceeded"}}'), true);
	assert.equal(isContextLengthExceededText("Input length (265330) exceeds model's maximum context length (262144)."), true);
	assert.equal(isContextLengthExceededText("Your input exceeds the context window of this model"), true);
	assert.equal(isContextLengthExceededEnvelope({ type: "turn_end", message: { errorMessage: "context_length_exceeded" } }), true);
	const calls = installMockSpawn([
		{ code: 1, stdout: `${JSON.stringify({ error: { type: "invalid_request_error", code: "context_length_exceeded" } })}\n` },
		{ code: 0, stdout: `${JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "ok after retry" }], usage: { input: 1, output: 1, totalTokens: 2 } } })}\n` },
	]);
	try {
		const agent = testAgent();
		const result = await runSingleAgent(
			process.cwd(),
			tempRuntime(),
			[agent],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			{ getActiveTools: () => [], events: { emit: () => undefined } } as any,
			undefined,
			undefined,
			(results): SubagentDetails => ({ mode: "single", agentScope: "project", projectAgentsDir: null, results }),
		);
		assert.equal(calls.length, 2);
		assert.equal(result.exitCode, 0);
		assert.equal(result.attempt, 2);
		assert.equal(result.attempts?.length, 2);
		assert.notEqual(result.attempts?.[0]?.sessionKey, result.attempts?.[1]?.sessionKey);
		assert.match(result.attempts?.[0]?.errorEnvelope ?? "", /context_length_exceeded/);
		assert.match(result.stderr, /retrying once with fresh session/);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("default reused-session context limit tracks current Codex backend cap", () => {
	assert.equal(DEFAULT_MODEL_CONTEXT_LIMIT_TOKENS, 272_000);
});

test("context_length_exceeded text in normal tool output does not trigger retry", async () => {
	const stdout = bridgeStdout([
		{
			type: "tool_execution_end",
			toolCallId: "call-grep",
			toolName: "grep",
			result: {
				content: [
					{ type: "text", text: "tests/session-lanes.test.ts: context_length_exceeded detection triggers one retry" },
				],
			},
		},
		{
			type: "message_end",
			message: {
				role: "assistant",
				content: [{ type: "text", text: "Reviewed context_length_exceeded docs/tests; no runtime overflow." }],
				usage: { input: 1, output: 1, totalTokens: 2 },
			},
		},
	]);
	const calls = installMockSpawn([{ code: 0, stdout }]);
	try {
		const result = await runSingleAgent(
			process.cwd(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			{ getActiveTools: () => [], events: { emit: () => undefined } } as any,
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
		assert.equal(result.attempt, 1);
		assert.equal(result.attempts, undefined);
		assert.equal(result.errorEnvelope, undefined);
		assert.equal(result.errorMessage, undefined);
		assert.equal(result.stderr, "");
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("aborted oneshot emits failed event with summary", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([{ code: 0, stdout: bridgeStdout([
		shapedStreamEvent("top-level", "message_update", { message: { role: "assistant", content: [{ type: "text", text: "aborted partial" }] } }),
	]) }]);
	const controller = new AbortController();
	controller.abort();
	try {
		await assert.rejects(
			runSingleAgent(
				process.cwd(),
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				"review code",
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents(emitted),
				controller.signal,
				undefined,
				makeDetails,
			),
			/Agent was aborted/,
		);
		assert.equal(calls.length, 1);
		const failed = emitted.find((event) => event.name === "subagents:failed");
		assert.ok(failed);
		assert.equal(failed.payload.summary, "Agent was aborted before completion.");
		assert.equal(failed.payload.error, "Agent was aborted");
		const content = readFileSync(failed.payload.transcriptPath, "utf8");
		assert.match(content, /message_update/);
		assert.match(content, /aborted partial/);
		assert.match(content, /"buffered":true/);
		const updateRecords = content.trim().split(/\r?\n/).map((line) => JSON.parse(line)).filter((record) => record.event && transcriptEventName(record.event) === "message_update");
		assert.equal(updateRecords.length, 1);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("session_compact followed by empty agent_end emits synthetic needs_completion", async () => {
	const cwd = tempGitRepo();
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: [] })]) },
	]);
	try {
		const result = await runSingleAgent(
			cwd,
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
		assert.equal(result.status, "needs_completion");
		assert.equal(result.needsCompletionReason, "compact-then-empty");
		assert.equal(result.cwdSnapshot?.cwd, cwd);
		assert.match(result.cwdSnapshot?.head ?? "", /^[0-9a-f]{40}$/);
		assert.equal(result.cwdSnapshot?.dirty, true);
		assert.match(result.cwdSnapshot?.status ?? "", /\?\? dirty\.txt/);
		assert.equal(result.cwdSnapshot?.lastCommit.subject, "initial commit");
		assert.equal(existsSync(join(cwd, ".git", "index.lock")), false);

		const needsCompletion = emitted.find((event) => event.name === "subagents:needs_completion");
		assert.ok(needsCompletion);
		assert.equal(needsCompletion.payload.reason, "compact-then-empty");
		assert.equal(needsCompletion.payload.status, "needs_completion");
		assert.equal(needsCompletion.payload.cwdSnapshot?.cwd, cwd);
		assert.equal(emitted.some((event) => event.name === "subagents:completed" || event.name === "subagents:failed"), false);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("pre-compact assistant text does not mask compact-then-empty", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{
			code: 0,
			stdout: bridgeStdout([
				bridgeEvent("message_end", { message: { role: "assistant", content: [{ type: "text", text: "pre-compact progress" }] } }),
				bridgeEvent("session_compact"),
				bridgeEvent("agent_end", { content: [] }),
			]),
		},
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.status, "needs_completion");
		assert.equal(result.needsCompletionReason, "compact-then-empty");
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), true);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("compact-then-empty detection applies after context retry", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 1, stdout: `${JSON.stringify({ error: { type: "invalid_request_error", code: "context_length_exceeded" } })}\n` },
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: [] })]) },
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 2);
		assert.equal(result.attempt, 2);
		assert.equal(result.attempts?.length, 2);
		assert.equal(result.status, "needs_completion");
		assert.equal(result.needsCompletionReason, "compact-then-empty");
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), true);
		assert.equal(emitted.some((event) => event.name === "subagents:completed"), false);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("compact-then-empty treats null and omitted agent_end content as empty", async () => {
	for (const data of [{ content: null }, {}]) {
		const emitted: Array<{ name: string; payload: any }> = [];
		const calls = installMockSpawn([
			{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", data)]) },
		]);
		try {
			const result = await runSingleAgent(
				tempRuntime(),
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				"review code",
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents(emitted),
				undefined,
				undefined,
				makeDetails,
			);
			assert.equal(calls.length, 1);
			assert.equal(result.status, "needs_completion");
			assert.equal(result.needsCompletionReason, "compact-then-empty");
			assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), true);
		} finally {
			setSingleAgentSpawnForTests();
		}
	}
});

test("session_compact followed by text agent_end completes normally", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: [{ type: "text", text: "ok" }] })]) },
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
		assert.notEqual(result.status, "needs_completion");
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), false);
		assert.equal(emitted.some((event) => event.name === "subagents:completed"), true);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("empty agent_end without session_compact preserves existing completion behavior", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("agent_end", { content: [] })]) },
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
		assert.notEqual(result.status, "needs_completion");
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), false);
		assert.equal(emitted.some((event) => event.name === "subagents:completed"), true);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("bridge disconnect after session_compact does not classify compact-then-empty", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact")]) },
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.notEqual(result.status, "needs_completion");
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), false);
		assert.equal(emitted.some((event) => event.name === "subagents:completed"), true);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("malformed agent_end content is logged and skipped", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: "bad-shape" })]) },
	]);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.notEqual(result.status, "needs_completion");
		assert.match(result.diagnostics?.join("\n") ?? "", /malformed agent_end content/);
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), false);
		assert.equal(emitted.some((event) => event.name === "subagents:completed"), true);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("missing git binary omits cwdSnapshot but still emits compact-then-empty", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: [] })]) },
	]);
	setGitExecFileForTests(((command: string, args: string[], options: any, callback: any) => {
		void command;
		void args;
		const cb = typeof options === "function" ? options : callback;
		queueMicrotask(() => cb(Object.assign(new Error("spawn git ENOENT"), { code: "ENOENT" }), "", "spawn git ENOENT"));
		return new EventEmitter() as any;
	}) as any);
	try {
		const result = await runSingleAgent(
			tempRuntime(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			mockPiEvents(emitted),
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.status, "needs_completion");
		assert.equal(result.needsCompletionReason, "compact-then-empty");
		assert.equal(result.cwdSnapshot, undefined);
		assert.match(result.diagnostics?.join("\n") ?? "", /cwdSnapshot git failed/);
		const needsCompletion = emitted.find((event) => event.name === "subagents:needs_completion");
		assert.ok(needsCompletion);
		assert.equal(needsCompletion.payload.reason, "compact-then-empty");
		assert.equal(needsCompletion.payload.cwdSnapshot, undefined);
		assert.match(needsCompletion.payload.diagnostics?.join("\n") ?? "", /cwdSnapshot git failed/);
	} finally {
		setGitExecFileForTests();
		setSingleAgentSpawnForTests();
	}
});

test("needs_completion emit failure is attached to result diagnostics", async () => {
	const emitted: Array<{ name: string; payload: any }> = [];
	const calls = installMockSpawn([
		{ code: 0, stdout: bridgeStdout([bridgeEvent("session_compact"), bridgeEvent("agent_end", { content: [] })]) },
	]);
	try {
		const result = await runSingleAgent(
			tempGitRepo(),
			tempRuntime(),
			[testAgent()],
			"reviewer-test",
			"review code",
			undefined,
			undefined,
			undefined,
			undefined,
			{
				getActiveTools: () => [],
				events: {
					emit: (name: string, payload: unknown) => {
						if (name === "subagents:needs_completion") throw new Error("bus disposed");
						emitted.push({ name, payload });
					},
				},
			} as any,
			undefined,
			undefined,
			makeDetails,
		);
		assert.equal(calls.length, 1);
		assert.equal(result.status, "needs_completion");
		assert.match(result.diagnostics?.join("\n") ?? "", /Failed to emit subagents:needs_completion/);
		assert.equal(emitted.some((event) => event.name === "subagents:needs_completion"), false);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("reused session budget guard refuses over-threshold explicit session by default without spawning", async () => {
	const runtimeRoot = tempRuntime();
	const cwd = tempRuntime();
	const session = resolveBgSession(runtimeRoot, "reviewer-test", "reuse");
	mkdirSync(dirname(session.path), { recursive: true });
	writeFileSync(session.path, "x".repeat(900_000), "utf8");
	const calls = installMockSpawn([{ code: 0 }]);
	try {
		const result = await runSingleAgent(
			cwd,
			runtimeRoot,
			[testAgent()],
			"reviewer-test",
			"reuse old context",
			undefined,
			undefined,
			undefined,
			undefined,
			{ getActiveTools: () => [], events: { emit: () => undefined } } as any,
			undefined,
			undefined,
			makeDetails,
			"reuse",
		);
		assert.equal(calls.length, 0);
		assert.equal(result.exitCode, 1);
		assert.equal(result.stopReason, "session_budget_exceeded");
		assert.equal(result.sessionMode, "resumed");
		assert.equal(result.sessionKey, "reuse");
		assert.match(result.errorMessage ?? "", /Refusing reused session/);
		assert.match(result.errorMessage ?? "", /exceeds 80% guard threshold/);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("reused session budget guard allows below-threshold explicit session", async () => {
	const runtimeRoot = tempRuntime();
	const cwd = tempRuntime();
	const session = resolveBgSession(runtimeRoot, "reviewer-test", "reuse-small");
	mkdirSync(dirname(session.path), { recursive: true });
	writeFileSync(session.path, "small", "utf8");
	const calls = installMockSpawn([
		{ code: 0, stdout: `${JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "ok" }], usage: { input: 1, output: 1, totalTokens: 2 } } })}\n` },
	]);
	try {
		const result = await runSingleAgent(
			cwd,
			runtimeRoot,
			[testAgent()],
			"reviewer-test",
			"reuse small context",
			undefined,
			undefined,
			undefined,
			undefined,
			{ getActiveTools: () => [], events: { emit: () => undefined } } as any,
			undefined,
			undefined,
			makeDetails,
			"reuse-small",
		);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("reused session compact-then-resume policy compacts then launches", async () => {
	const runtimeRoot = tempRuntime();
	const cwd = tempRuntime();
	writeSettings(cwd, {
		reusedSessionBudgetPolicy: "compact-then-resume",
		reusedSessionBudgetThreshold: 0.5,
		reusedSessionContextLimitTokens: 100,
	});
	const session = resolveBgSession(runtimeRoot, "reviewer-test", "reuse-compact");
	mkdirSync(dirname(session.path), { recursive: true });
	writeFileSync(session.path, "x".repeat(1_000), "utf8");
	let compactCalls = 0;
	setSessionCompactorForTests(async (request) => {
		compactCalls += 1;
		writeFileSync(request.sessionPath, "", "utf8");
		return { archivePath: `${request.sessionPath}.archive` };
	});
	const calls = installMockSpawn([
		{ code: 0, stdout: `${JSON.stringify({ type: "message_end", message: { role: "assistant", content: [{ type: "text", text: "ok" }], usage: { input: 1, output: 1, totalTokens: 2 } } })}\n` },
	]);
	try {
		const result = await runSingleAgent(
			cwd,
			runtimeRoot,
			[testAgent()],
			"reviewer-test",
			"compact old context",
			undefined,
			undefined,
			undefined,
			undefined,
			{ getActiveTools: () => [], events: { emit: () => undefined } } as any,
			undefined,
			undefined,
			makeDetails,
			"reuse-compact",
		);
		assert.equal(compactCalls, 1);
		assert.equal(calls.length, 1);
		assert.equal(result.exitCode, 0);
		assert.match(result.stderr, /Compacted reused session/);
	} finally {
		setSessionCompactorForTests();
		setSingleAgentSpawnForTests();
	}
});

test("inventory guard rejects unknown agent with structured available lists", () => {
	const projectAgent: AgentConfig = { name: "planner", description: "plan", pane: true, systemPrompt: "", source: "project", filePath: "planner.md" };
	const userAgent: AgentConfig = { name: "personal", description: "user", pane: false, systemPrompt: "", source: "user", filePath: "personal.md" };
	const validation = validateAgentInventory(["missing"], { allowed: [projectAgent], project: [projectAgent], user: [userAgent] }, "project");
	assert.ok(validation);
	assert.deepEqual(validation?.missing, ["missing"]);
	assert.deepEqual(validation?.available.project, ["planner"]);
	assert.deepEqual(validation?.available.user, ["personal"]);
	assert.match(formatInventoryValidationError(validation!), /Unknown subagent\(s\).*missing/);
	assert.match(formatInventoryValidationError(validation!), /Project agents: planner/);
	assert.match(formatInventoryValidationError(validation!), /User agents: personal/);
});

test("mapWithConcurrencyLimit returns empty array for empty input without invoking fn", async () => {
	let invoked = 0;
	const results = await mapWithConcurrencyLimit<number, number>([], 4, async () => {
		invoked += 1;
		return 0;
	});
	assert.deepEqual(results, []);
	assert.equal(invoked, 0);
});

test("mapWithConcurrencyLimit handles a single item with concurrency > items", async () => {
	let active = 0;
	let maxActive = 0;
	const results = await mapWithConcurrencyLimit([42], 8, async (item) => {
		active += 1;
		maxActive = Math.max(maxActive, active);
		await new Promise((resolve) => setTimeout(resolve, 1));
		active -= 1;
		return item * 2;
	});
	assert.deepEqual(results, [84]);
	assert.equal(maxActive, 1);
});

test("mapWithConcurrencyLimit caps active workers at items.length when items < concurrency", async () => {
	const items = [1, 2, 3];
	let active = 0;
	let maxActive = 0;
	const results = await mapWithConcurrencyLimit(items, 8, async (item) => {
		active += 1;
		maxActive = Math.max(maxActive, active);
		await new Promise((resolve) => setTimeout(resolve, 5));
		active -= 1;
		return item * 2;
	});
	assert.deepEqual(results, [2, 4, 6]);
	assert.equal(maxActive, 3);
});

test("mapWithConcurrencyLimit preserves submission order with items >> concurrency", async () => {
	const items = Array.from({ length: 24 }, (_, index) => index);
	let active = 0;
	let maxActive = 0;
	const results = await mapWithConcurrencyLimit(items, 4, async (item) => {
		active += 1;
		maxActive = Math.max(maxActive, active);
		await new Promise((resolve) => setTimeout(resolve, 1 + (item % 3)));
		active -= 1;
		return item * 2;
	});
	assert.deepEqual(results, items.map((item) => item * 2));
	assert.equal(maxActive, 4);
});

test("mapWithConcurrencyLimit keeps workers saturated across an uneven workload", async () => {
	// Every 4th task takes 5x as long as the others. The old batched
	// dispatch would idle 3 workers for the slow task's tail before the
	// next batch started; the flat pool should keep min(K, remaining)
	// workers active until all tasks complete.
	const items = Array.from({ length: 16 }, (_, index) => index);
	const fastMs = 5;
	const slowMs = 25;
	const concurrency = 4;
	let active = 0;
	let maxActive = 0;
	let started = 0;
	let finished = 0;
	let saturatedSamples = 0;
	let unsaturatedSamples = 0;
	const sampler = setInterval(() => {
		const remaining = items.length - finished;
		const expectedActive = Math.min(concurrency, remaining);
		if (remaining <= concurrency) return; // tail decrescendo is expected
		if (started < items.length && active < expectedActive) unsaturatedSamples += 1;
		else saturatedSamples += 1;
	}, 2);
	const start = Date.now();
	const results = await mapWithConcurrencyLimit(items, concurrency, async (item) => {
		started += 1;
		active += 1;
		maxActive = Math.max(maxActive, active);
		await new Promise((resolve) => setTimeout(resolve, item % 4 === 0 ? slowMs : fastMs));
		active -= 1;
		finished += 1;
		return item;
	});
	clearInterval(sampler);
	const elapsed = Date.now() - start;
	assert.deepEqual(results, items);
	assert.equal(maxActive, concurrency);
	// Flat-pool wall-clock is ~max(slowest_task, totalWork/K). The batched
	// baseline with batchSize=8 idled workers for slow-task tails between
	// batches; the flat pool removes that dead time. Generous bounds keep
	// the assertion stable on slow CI runners.
	const totalWork = items.reduce((sum, item) => sum + (item % 4 === 0 ? slowMs : fastMs), 0);
	const flatLowerBound = totalWork / concurrency;
	assert.ok(elapsed >= flatLowerBound * 0.5, `elapsed ${elapsed}ms below realistic flat-pool floor ${flatLowerBound}ms`);
	assert.ok(saturatedSamples > 0, "expected at least one saturated sample mid-run");
	// While remaining items > concurrency, the pool must stay saturated.
	// Allow a tiny number of races (sampler firing between a task's
	// completion-increment and the worker's next pickup).
	assert.ok(unsaturatedSamples <= 1, `flat pool dropped below concurrency mid-run (${unsaturatedSamples} unsaturated samples, ${saturatedSamples} saturated)`);
});

test("mapWithConcurrencyLimit rejects when the mapper throws (callers must catch)", async () => {
	const items = [0, 1, 2, 3];
	const invoked: number[] = [];
	await assert.rejects(
		mapWithConcurrencyLimit(items, 2, async (item) => {
			invoked.push(item);
			if (item === 1) throw new Error("boom");
			await new Promise((resolve) => setTimeout(resolve, 1));
			return item;
		}),
		/boom/,
	);
	// Helper does not swallow thrown mappers — this is why runParallelDispatch
	// wraps its per-task body in try/catch before handing it to the pool.
	assert.ok(invoked.includes(1), "mapper should have run for the throwing item before rejection");
});

test("dispatch-style try/catch wrapper drains the pool and keeps indexed order on throw", async () => {
	// Mirrors the wrapper pattern in runParallelDispatch: each task body is
	// wrapped in try/catch so a single thrown mapper becomes a failed entry
	// at its index instead of aborting the whole pool.
	const items = Array.from({ length: 8 }, (_, index) => index);
	let active = 0;
	let maxActive = 0;
	let completedAfterThrow = 0;
	const throwingIndex = 2;
	const wrap = async (index: number) => {
		active += 1;
		maxActive = Math.max(maxActive, active);
		try {
			if (index === throwingIndex) throw new Error(`task ${index} exploded`);
			await new Promise((resolve) => setTimeout(resolve, 2));
			if (index > throwingIndex) completedAfterThrow += 1;
			return { kind: "ok" as const, index };
		} catch (error) {
			return { kind: "failed" as const, index, errorMessage: (error as Error).message };
		} finally {
			active -= 1;
		}
	};
	const results = await mapWithConcurrencyLimit(items, 3, (item) => wrap(item));
	assert.deepEqual(results.map((r) => r.index), items, "result order must match submission order");
	assert.equal(maxActive, 3);
	for (const result of results) {
		if (result.index === throwingIndex) {
			assert.equal(result.kind, "failed");
			assert.equal((result as { kind: "failed"; errorMessage: string }).errorMessage, `task ${throwingIndex} exploded`);
		} else {
			assert.equal(result.kind, "ok");
		}
	}
	assert.ok(completedAfterThrow >= items.length - throwingIndex - 1, `every task after index ${throwingIndex} must still complete after a peer throws; saw ${completedAfterThrow}`);
});

test("wait_for_subagent_idle helper resolves on idle transition", async () => {
	const states = [{ isIdle: false }, { isIdle: false }, { isIdle: true }];
	const result = await waitForIdleTransition(async () => states.shift(), 1_000, 1);
	assert.equal(result.transitioned, true);
	assert.equal(result.timedOut, false);
	assert.equal(result.status, "idle-after-busy");
	assert.equal(result.samples, 3);
	assert.equal(result.lastState?.isIdle, true);
});

test("wait_for_subagent_idle distinguishes never-busy from idle-after-busy", async () => {
	const result = await waitForIdleTransition(async () => ({ isIdle: true }), 5, 1);
	assert.equal(result.transitioned, false);
	assert.equal(result.status, "never-busy");
	assert.equal(result.timedOut, true);
});
