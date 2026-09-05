// What a one-shot run writes to its transcript for each wire shape the
// bridge can emit, and what a failed run flushes.

import assert from "node:assert/strict";
import { join } from "node:path";
import { extractLastAssistantTextFromTranscriptContent } from "../extensions/subagent/format.js";
import { runSingleAgent, setSingleAgentSpawnForTests } from "../extensions/subagent/runner.js";
import test, { after } from "node:test";
import { cleanupTempRuntimes, tempRuntime, testAgent, installMockSpawn, bridgeStdout, shapedStreamEvent, transcriptEventName, findAgentStartTranscriptPayload, mockPiEvents, makeDetails, readTranscript } from "./single-agent-fixture.js";

after(cleanupTempRuntimes);

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
			shapedStreamEvent(shape, "message_end", { message: { role: "assistant", content: [{ type: "text", text: `final ${shape}` }], usage: { input: 3, output: 2, cacheRead: 0, cacheWrite: 0, totalTokens: 5 }, model: "openai-codex/gpt-6-astra:xhigh" } }),
		]) }]);
		try {
			const agent = { ...testAgent(), model: "openai-codex/gpt-6-astra:xhigh" };
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
			assert.equal(agentStart.model, "openai-codex/gpt-6-astra:xhigh", shape);
			assert.ok(Array.isArray(agentStart.args), shape);
			assert.ok(agentStart.args.includes("--model"), shape);
			assert.ok(agentStart.args.includes("openai-codex/gpt-6-astra:xhigh"), shape);
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

test("unrecognized wire shapes surface a diagnostic in both transcript modes", async () => {
	const previousFull = process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
	// The diagnostic is the ONLY signal when Pi's shapes move: reconstruction yields nothing,
	// so a mode that skips it writes an empty forensic record with no warning.
	for (const fullStream of [false, true]) {
		if (fullStream) process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL = "1";
		else delete process.env.PI_AGENTS_TMUX_TRANSCRIPT_FULL;
		const label = fullStream ? "full-stream" : "filtered";
		installMockSpawn([{ code: 1, stdout: bridgeStdout([
			shapedStreamEvent("top-level", "message_start"),
			shapedStreamEvent("top-level", "message_update", { assistantMessageEvent: { type: "prose_delta", contentIndex: 0, delta: "future Pi shape" } }),
			shapedStreamEvent("top-level", "message_update", { assistantMessageEvent: { type: "audio_delta", contentIndex: 1 } }),
		]) }]);
		try {
			const result = await runSingleAgent(
				tempRuntime(),
				tempRuntime(),
				[testAgent()],
				"reviewer-test",
				`review task unknown shapes ${label}`,
				undefined,
				undefined,
				undefined,
				undefined,
				mockPiEvents([]),
				undefined,
				undefined,
				makeDetails,
			);
			const diagnostics = (result.diagnostics ?? []).join(" ");
			assert.match(diagnostics, /could not be rebuilt/, label);
			assert.match(diagnostics, /prose_delta/, label);
			assert.match(diagnostics, /audio_delta/, label);
			assert.match(readTranscript(result), /could not be rebuilt/, label);
		} finally {
			setSingleAgentSpawnForTests();
		}
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
