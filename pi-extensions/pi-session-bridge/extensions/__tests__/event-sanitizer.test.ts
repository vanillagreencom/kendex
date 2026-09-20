import { describe, expect, test } from "bun:test";
import { Buffer } from "node:buffer";

import {
	DEFAULT_MAX_EVENT_BYTES,
	DEFAULT_PREVIEW_BYTES,
	sanitizeBridgeEvent,
} from "../event-sanitizer.js";

const baseConfig = { maxEventBytes: DEFAULT_MAX_EVENT_BYTES, previewBytes: DEFAULT_PREVIEW_BYTES };

describe("sanitizeBridgeEvent", () => {
	const cumulativeMessage = (bytes: number) => ({ id: "msg_42", role: "assistant", content: [{ type: "text", text: "c".repeat(bytes) }] });

	for (const row of [
		{
			name: "top-level delta",
			payload: { role: "assistant", contentIndex: 0, type: "text", delta: "Hello world" },
			expected: { role: "assistant", type: "text", contentIndex: 0, deltaLength: 11, deltaBytes: 11, deltaPreview: "Hello world" },
			previewBytes: DEFAULT_PREVIEW_BYTES,
			originalBytes: 11,
		},
		{
			name: "delta beside a cumulative message",
			payload: { message: cumulativeMessage(200_000), assistantMessageEvent: { type: "text_delta", contentIndex: 2, delta: "token ", partial: cumulativeMessage(200_000) } },
			expected: { role: "assistant", type: "text_delta", messageId: "msg_42", contentIndex: 2, deltaLength: 6, deltaBytes: 6, deltaPreview: "token " },
			previewBytes: DEFAULT_PREVIEW_BYTES,
			originalBytes: 6,
		},
		{
			name: "delta longer than the preview",
			payload: { role: "assistant", contentIndex: 0, delta: "x".repeat(500_000) },
			expected: { role: "assistant", contentIndex: 0, deltaLength: 500_000, deltaBytes: 500_000, deltaPreview: "x".repeat(64), deltaTruncated: true },
			previewBytes: 64,
			originalBytes: 500_000,
		},
		{
			name: "block end carrying the finished block",
			payload: { message: cumulativeMessage(200_000), assistantMessageEvent: { type: "text_end", contentIndex: 0, content: "c".repeat(200_000), partial: cumulativeMessage(200_000) } },
			expected: { role: "assistant", type: "text_end", messageId: "msg_42", contentIndex: 0 },
			previewBytes: DEFAULT_PREVIEW_BYTES,
			originalBytes: 0,
		},
		{
			name: "null delta",
			payload: { role: "assistant", assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: null } },
			expected: { role: "assistant", type: "text_delta", contentIndex: 0 },
			previewBytes: DEFAULT_PREVIEW_BYTES,
			originalBytes: 0,
		},
		{
			name: "stream event carrying no delta",
			payload: { message: cumulativeMessage(200_000), assistantMessageEvent: { type: "text_start", contentIndex: 0, partial: cumulativeMessage(200_000) } },
			expected: { role: "assistant", type: "text_start", messageId: "msg_42", contentIndex: 0 },
			previewBytes: DEFAULT_PREVIEW_BYTES,
			originalBytes: 0,
		},
	]) {
		test(`message update ${row.name}`, () => {
			const result = sanitizeBridgeEvent("message_update", row.payload, { ...baseConfig, previewBytes: row.previewBytes });
			// toEqual pins both directions: no cumulative message, partial or
			// content field may ride along in the published descriptor.
			expect(result.data).toEqual(row.expected);
			expect(result.originalBytes).toBe(row.originalBytes);
			expect(result.truncated).toBe(true);
			expect(result.raw).toBeUndefined();
		});
	}

	test("message update descriptor and byte count ignore the cumulative message size", () => {
		const update = (bytes: number) => ({ assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "tok", partial: cumulativeMessage(bytes) }, message: cumulativeMessage(bytes) });
		const small = sanitizeBridgeEvent("message_update", update(1_000), baseConfig);
		const large = sanitizeBridgeEvent("message_update", update(1_000_000), baseConfig);
		expect(large.data).toEqual(small.data);
		expect(large.originalBytes).toBe(small.originalBytes);
		expect(large.originalBytes).toBe(3);
	});

	test("a message update descriptor past the event cap is replaced, still with no raw payload", () => {
		const result = sanitizeBridgeEvent("message_update", { role: "assistant", contentIndex: 0, delta: "d".repeat(400) }, { maxEventBytes: 40, previewBytes: 256 });
		expect(result.data).toEqual({ summary: "message_update payload omitted (exceeded 40 bytes)", truncated: true, originalBytes: 400, maxBytes: 40 });
		expect(result.truncated).toBe(true);
		expect(result.originalBytes).toBe(400);
		expect(result.raw).toBeUndefined();
	});

	for (const event of ["message_update", "tool_execution_update"]) {
		test(`${event} passes a non-record payload through untouched`, () => {
			for (const payload of [undefined, null, "delta", 42]) {
				const result = sanitizeBridgeEvent(event, payload, baseConfig);
				expect(result.data).toEqual(payload);
				expect(result.truncated).toBe(false);
				expect(result.raw).toBeUndefined();
			}
		});
	}

	for (const event of ["session_compact", "session_tree"]) {
		test(`${event} is reduced to a size and a preview`, () => {
			const payload = { nodes: Array.from({ length: 400 }, (_, index) => ({ id: index, title: `node ${index}` })) };
			const result = sanitizeBridgeEvent(event, payload, { ...baseConfig, previewBytes: 24 });
			const data = result.data as Record<string, unknown>;
			expect(data.bytes).toBe(Buffer.byteLength(JSON.stringify(payload), "utf8"));
			expect((data.preview as string).length).toBeLessThanOrEqual(24);
			expect(data.truncated).toBe(true);
			expect("nodes" in data).toBe(false);
			expect(result.truncated).toBe(true);
			expect(result.raw).toEqual(payload);
		});
	}

	test("tool_execution_update keeps the call identity and drops the growing partial result", () => {
		const payload = { toolCallId: "tcl_9", toolName: "Bash", args: { command: "ls -la" }, partialResult: { output: "y".repeat(300_000) } };
		const result = sanitizeBridgeEvent("tool_execution_update", payload, baseConfig);
		expect(result.data).toEqual({ toolName: "Bash", toolUseId: "tcl_9" });
		expect(result.originalBytes).toBe(0);
		expect(result.truncated).toBe(true);
		expect(result.raw).toBeUndefined();
	});

	test("tool_execution_end compacts heavy result and surfaces byte counts", () => {
		const heavyResult = { text: "y".repeat(120_000) };
		const payload = {
			toolName: "Bash",
			toolUseId: "tool_42",
			status: "success",
			input: { command: "ls" },
			result: heavyResult,
			artifactPath: "/var/log/run.log",
		};
		const result = sanitizeBridgeEvent("tool_execution_end", payload, { ...baseConfig, previewBytes: 32 });
		const data = result.data as Record<string, unknown>;
		expect(data.toolName).toBe("Bash");
		expect(data.toolUseId).toBe("tool_42");
		expect(data.status).toBe("success");
		expect(data.artifactPath).toBe("/var/log/run.log");
		expect(typeof data.resultBytes).toBe("number");
		expect(data.resultBytes).toBeGreaterThan(100_000);
		expect((data.resultPreview as string).length).toBeLessThanOrEqual(32);
		expect("result" in data).toBe(false);
		expect(result.truncated).toBe(true);
		expect(result.raw).toEqual(payload);
	});

	test("agent_end compacts a long message list to a preview + count", () => {
		const messages = Array.from({ length: 60 }, (_, index) => ({
			role: index % 2 === 0 ? "user" : "assistant",
			content: [{ type: "text", text: `chunk ${index} `.repeat(200) }],
		}));
		const payload = {
			status: "ended",
			stopReason: "end_turn",
			willRetry: false,
			usage: { inputTokens: 1024, outputTokens: 2048 },
			messages,
		};
		const result = sanitizeBridgeEvent("agent_end", payload, baseConfig);
		const data = result.data as Record<string, unknown>;
		expect(data.status).toBe("ended");
		expect(data.stopReason).toBe("end_turn");
		expect(data.willRetry).toBe(false);
		expect(data.usage).toEqual({ inputTokens: 1024, outputTokens: 2048 });
		expect(data.messagesCount).toBe(60);
		expect(typeof data.finalTextPreview).toBe("string");
		expect((data.finalTextPreview as string).length).toBeLessThanOrEqual(DEFAULT_PREVIEW_BYTES);
		expect("messages" in data).toBe(false);
	});

	for (const row of [
		{ name: "streaming extension input", payload: { text: "please adjust the current plan " + "x".repeat(200), source: "extension", streamingBehavior: "followUp", images: [{ source: { type: "base64", data: "image-data" } }] }, previewBytes: 48, streamed: true },
		{ name: "idle interactive input", payload: { text: "idle prompt", source: "interactive" }, previewBytes: DEFAULT_PREVIEW_BYTES, streamed: false },
	]) {
		test(row.name, () => {
			const result = sanitizeBridgeEvent("input", row.payload, { ...baseConfig, previewBytes: row.previewBytes });
			const data = result.data as Record<string, unknown>;
			expect(data.source).toBe(row.payload.source);
			if (row.streamed) {
				expect(data.streamingBehavior).toBe("followUp");
				expect(data.imagesCount).toBe(1);
				expect(data.textBytes).toBe(Buffer.byteLength(row.payload.text, "utf8"));
				expect(data.textLength).toBe(row.payload.text.length);
				expect((data.textPreview as string).length).toBeLessThanOrEqual(48);
				expect(data.textTruncated).toBe(true);
				expect("text" in data).toBe(false);
				expect("images" in data).toBe(false);
				expect(result.truncated).toBe(true);
				expect(result.raw).toEqual(row.payload);
			} else {
				expect(data.textPreview).toBe("idle prompt");
				expect("streamingBehavior" in data).toBe(false);
			}
		});
	}

	for (const row of [
		{ name: "small unknown event", event: "bridge_pong", payload: { ok: true, count: 3 }, maxEventBytes: DEFAULT_MAX_EVENT_BYTES, truncated: false },
		{ name: "large unknown event", event: "custom_heavy_event", payload: { blob: "z".repeat(1_500_000) }, maxEventBytes: 1024, truncated: true },
	]) {
		test(row.name, () => {
			const result = sanitizeBridgeEvent(row.event, row.payload, { ...baseConfig, maxEventBytes: row.maxEventBytes });
			expect(result.truncated).toBe(row.truncated);
			if (row.truncated) {
				const data = result.data as Record<string, unknown>;
				expect(data.truncated).toBe(true);
				expect(typeof data.originalBytes).toBe("number");
				expect(data.maxBytes).toBe(1024);
				expect(result.raw).toEqual(row.payload);
			} else {
				expect(result.data).toEqual(row.payload);
				expect(result.raw).toBeUndefined();
			}
		});
	}

	for (const row of [
		{ label: "ordinary name", name: "Rename the bridge registry", previewBytes: DEFAULT_PREVIEW_BYTES, truncated: false },
		{ label: "oversized name", name: `named session ${"x".repeat(500)}`, previewBytes: 32, truncated: true },
		{ label: "cleared name", name: undefined, previewBytes: DEFAULT_PREVIEW_BYTES, truncated: false },
		{ label: "non-string name", name: 7, previewBytes: DEFAULT_PREVIEW_BYTES, truncated: false },
	]) {
		test(`session info ${row.label}`, () => {
			const payload = { type: "session_info_changed", name: row.name };
			const result = sanitizeBridgeEvent("session_info_changed", payload, { ...baseConfig, previewBytes: row.previewBytes });
			const data = result.data as Record<string, unknown>;
			expect(result.truncated).toBe(true);
			expect("name" in data).toBe(false);
			expect("type" in data).toBe(false);
			if (typeof row.name === "string") {
				expect(data.nameBytes).toBe(Buffer.byteLength(row.name, "utf8"));
				expect(data.nameLength).toBe(row.name.length);
				expect((data.namePreview as string).length).toBeLessThanOrEqual(row.previewBytes);
				if (row.truncated) expect(data.nameTruncated).toBe(true);
				else {
					expect(data.namePreview).toBe(row.name);
					expect("nameTruncated" in data).toBe(false);
				}
				expect(result.raw).toEqual(payload);
			} else {
				expect(data).toEqual({});
			}
		});
	}

	test("session_info_changed passes non-record payloads through untouched", () => {
		for (const payload of [undefined, null, "renamed", 42, ["renamed"]]) {
			const result = sanitizeBridgeEvent("session_info_changed", payload, baseConfig);
			expect(result.data).toEqual(payload);
			expect(result.truncated).toBe(false);
			expect(result.raw).toBeUndefined();
		}
	});



	for (const row of [
		{ name: "camel id", event: "tool_execution_start", payload: { toolName: "Read", toolCallId: "tcl_1", input: { path: "/x" } }, expected: { toolUseId: "tcl_1" }, errorBytes: false },
		{ name: "snake id", event: "tool_execution_update", payload: { tool_name: "Bash", tool_call_id: "tcl_2", output: "ok" }, expected: { toolUseId: "tcl_2" }, errorBytes: false },
		{ name: "nested id", event: "tool_execution_end", payload: { toolCall: { name: "Edit", id: "tcl_3", status: "error", isError: true }, error: "boom" }, expected: { toolName: "Edit", toolUseId: "tcl_3", status: "error", isError: true }, errorBytes: true },
	]) {
		test(`tool execution ${row.name}`, () => {
			const data = sanitizeBridgeEvent(row.event, row.payload, baseConfig).data as Record<string, unknown>;
			expect(data).toMatchObject(row.expected);
			if (row.errorBytes) expect(typeof data.errorBytes).toBe("number");
		});
	}

	for (const row of [
		{ name: "string content", payload: { status: "ended", usage: { inputTokens: 1 }, content: "final body " + "x".repeat(500) }, expected: { status: "ended" } },
		{ name: "array content", payload: { status: "ended", content: [{ type: "text", text: "alpha" }, { type: "text", text: "omega" }] }, expected: { finalTextPreview: "omega" } },
		{ name: "single message", payload: { status: "ended", message: { role: "assistant", content: [{ type: "text", text: "from .message" }] } }, expected: { messagesCount: 1, finalTextPreview: "from .message" } },
	]) {
		test(`agent end ${row.name}`, () => {
			const data = sanitizeBridgeEvent("agent_end", row.payload, baseConfig).data as Record<string, unknown>;
			expect(data).toMatchObject(row.expected);
			expect(typeof data.finalTextPreview).toBe("string");
			expect((data.finalTextPreview as string).length).toBeGreaterThan(0);
		});
	}

	test("originalBytes reflects raw JSON length", () => {
		const payload = { text: "abc", source: "interactive" };
		const result = sanitizeBridgeEvent("input", payload, baseConfig);
		expect(result.originalBytes).toBe(Buffer.byteLength(JSON.stringify(payload), "utf8"));
	});
});

