// What a one-shot run keeps in memory while its child streams: bounded
// message previews and stderr, one representation per transcript record, and
// a transcript writer that pauses the child instead of queueing without bound.

import assert from "node:assert/strict";
import test, { after } from "node:test";
import { getFinalOutput } from "../extensions/subagent/format.js";
import {
	createTranscriptAppender,
	MAX_RESULT_MESSAGES,
	MAX_RESULT_STDERR_CHARS,
	runSingleAgent,
	setSingleAgentSpawnForTests,
	TRANSCRIPT_PENDING_MAX_BYTES,
} from "../extensions/subagent/runner.js";
import { DETAIL_STRING_MAX_CHARS } from "../extensions/subagent/types.js";
import { bridgeStdout, cleanupTempRuntimes, installMockSpawn, makeDetails, mockPiEvents, readTranscript, shapedStreamEvent, tempRuntime, testAgent } from "./single-agent-fixture.js";

after(cleanupTempRuntimes);

async function runOneShot() {
	const agent = testAgent();
	return await runSingleAgent(tempRuntime(), tempRuntime(), [agent], agent.name, "retention task", undefined, undefined, undefined, undefined, mockPiEvents([]), undefined, undefined, makeDetails);
}

test("a oneshot result keeps bounded assistant previews and the end of stderr; the transcript keeps every message once", async () => {
	const events: unknown[] = [];
	for (let i = 0; i < 1000; i++) {
		events.push(shapedStreamEvent("top-level", "message_end", { message: {
			role: "assistant",
			content: [
				{ type: "thinking", thinking: "t".repeat(2000) },
				{ type: "text", text: `answer ${i}` },
				{ type: "toolCall", id: `call-${i}`, name: "write", arguments: { path: `f${i}`, content: "c".repeat(DETAIL_STRING_MAX_CHARS * 4) } },
			],
			usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2 },
		} }));
		events.push(shapedStreamEvent("top-level", "message_end", { message: { role: "toolResult", toolCallId: `call-${i}`, content: [{ type: "text", text: "r".repeat(1000) }] } }));
	}
	installMockSpawn([{ code: 0, stdout: bridgeStdout(events), stderr: "e".repeat(MAX_RESULT_STDERR_CHARS * 2) + "tail" }]);
	try {
		const result = await runOneShot();
		const toolCall = result.messages.at(-1)!.content.find((part: any) => part.type === "toolCall") as any;
		assert.deepEqual({
			count: result.messages.length,
			roles: [...new Set(result.messages.map((message) => message.role))],
			parts: [...new Set(result.messages.flatMap((message: any) => message.content.map((part: any) => part.type)))].sort(),
			argsBounded: toolCall.arguments.content.length < DETAIL_STRING_MAX_CHARS * 2,
			finalOutput: getFinalOutput(result.messages),
			dropped: result.droppedMessages,
			turns: result.usage.turns,
			stderrLength: result.stderr.length,
			stderrTail: result.stderr.endsWith("tail"),
		}, {
			count: MAX_RESULT_MESSAGES,
			roles: ["assistant"],
			parts: ["text", "toolCall"],
			argsBounded: true,
			finalOutput: "answer 999",
			dropped: 1000 - MAX_RESULT_MESSAGES,
			turns: 1000,
			stderrLength: MAX_RESULT_STDERR_CHARS,
			stderrTail: true,
		});
		const records = readTranscript(result).trim().split("\n").map((line) => JSON.parse(line));
		const messageEnds = records.filter((record) => record.event?.type === "message_end");
		assert.equal(messageEnds.length, 2000);
		assert.equal(records.filter((record) => record.event !== undefined && "raw" in record).length, 0);
	} finally {
		setSingleAgentSpawnForTests();
	}
});

test("a oneshot result keeps the last text answer when the newest messages carry only tool calls", async () => {
	const assistant = (content: unknown[]) => shapedStreamEvent("top-level", "message_end", { message: { role: "assistant", content } });
	const toolCalls = MAX_RESULT_MESSAGES + 10;
	const events = [
		assistant([{ type: "text", text: "older answer" }]),
		assistant([{ type: "text", text: "final answer" }]),
		...Array.from({ length: toolCalls }, (_, i) => assistant([{ type: "toolCall", id: `call-${i}`, name: "read", arguments: { path: `f${i}` } }])),
	];
	installMockSpawn([{ code: 0, stdout: bridgeStdout(events) }]);
	try {
		const result = await runOneShot();
		assert.deepEqual({
			finalOutput: getFinalOutput(result.messages),
			count: result.messages.length,
			dropped: result.droppedMessages,
		}, {
			finalOutput: "final answer",
			count: MAX_RESULT_MESSAGES + 1,
			dropped: toolCalls + 2 - MAX_RESULT_MESSAGES - 1,
		});
	} finally {
		setSingleAgentSpawnForTests();
	}
});

// Either output stream can outpace the transcript writer; whichever one does,
// both streams stop until the writer catches up.
const outpacingProducers: Array<{ producer: "stdout" | "stderr"; scenario: () => { stdout?: string; stderr?: string } }> = [
	{ producer: "stdout", scenario: () => {
		const text = "x".repeat(64 * 1024);
		const events = Array.from({ length: Math.ceil((TRANSCRIPT_PENDING_MAX_BYTES * 2) / text.length) }, (_, i) =>
			shapedStreamEvent("top-level", "message_end", { message: { role: "toolResult", toolCallId: `call-${i}`, content: [{ type: "text", text }] } }));
		return { stdout: bridgeStdout(events) };
	} },
	{ producer: "stderr", scenario: () => ({ stderr: "e".repeat(TRANSCRIPT_PENDING_MAX_BYTES * 2) }) },
];

for (const { producer, scenario } of outpacingProducers) {
	test(`a child whose ${producer} outpaces its transcript is paused until the writer catches up`, async () => {
		const calls = installMockSpawn([{ code: 0, ...scenario() }]);
		try {
			await runOneShot();
			assert.deepEqual(calls[0]!.flow, { stdout: ["pause", "resume"], stderr: ["pause", "resume"] });
		} finally {
			setSingleAgentSpawnForTests();
		}
	});
}

test("the transcript appender reports backpressure past its pending bound and drains in order", async () => {
	const written: string[] = [];
	const releases: Array<() => void> = [];
	const appender = createTranscriptAppender("/transcript", (_path, data) => new Promise<void>((resolve) => {
		releases.push(() => { written.push(data); resolve(); });
	}), undefined, 100);
	const accepted = [appender.append({ n: 1, pad: "p".repeat(40) }), appender.append({ n: 2, pad: "p".repeat(40) })];
	let drained = false;
	void appender.drained().then(() => { drained = true; });
	for (let step = 0; releases.length > 0 || step < 3; step++) {
		releases.shift()?.();
		await new Promise((resolve) => setImmediate(resolve));
	}
	await appender.settled();
	assert.deepEqual({ accepted, drained, order: written.map((line) => JSON.parse(line).n) }, { accepted: [true, false], drained: true, order: [1, 2] });
});
