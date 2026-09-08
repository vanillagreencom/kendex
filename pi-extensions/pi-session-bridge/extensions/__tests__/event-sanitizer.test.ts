import { describe, expect, test } from "bun:test";
import { Buffer } from "node:buffer";

import {
	DEFAULT_MAX_EVENT_BYTES,
	DEFAULT_PREVIEW_BYTES,
	sanitizeBridgeEvent,
} from "../event-sanitizer.js";

const baseConfig = { maxEventBytes: DEFAULT_MAX_EVENT_BYTES, previewBytes: DEFAULT_PREVIEW_BYTES };

describe("sanitizeBridgeEvent", () => {
	for (const row of [
		{ name: "short delta", payload: { role: "assistant", contentIndex: 0, type: "text", delta: "Hello world" }, expected: { role: "assistant", contentIndex: 0, type: "text", deltaLength: 11, deltaBytes: 11, deltaPreview: "Hello world" }, previewBytes: DEFAULT_PREVIEW_BYTES, raw: false },
		{ name: "large delta", payload: { role: "assistant", contentIndex: 0, delta: "x".repeat(500_000) }, expected: { deltaLength: 500_000 }, previewBytes: 64, raw: true },
		{ name: "assistant message envelope", payload: { assistantMessageEvent: { message: { id: "msg_42", role: "assistant", contentIndex: 2, type: "text", text: "z".repeat(800) } } }, expected: { role: "assistant", contentIndex: 2, messageId: "msg_42", type: "text", deltaLength: 800 }, previewBytes: DEFAULT_PREVIEW_BYTES, raw: false },
		{ name: "message content array", payload: { message: { role: "assistant", content: [{ type: "text", text: "intro" }, { type: "text", text: "final body " + "y".repeat(400) }] } }, expected: { role: "assistant" }, previewBytes: DEFAULT_PREVIEW_BYTES, raw: false },
	]) {
		test(`message update ${row.name}`, () => {
			const result = sanitizeBridgeEvent("message_update", row.payload, { ...baseConfig, previewBytes: row.previewBytes });
			const data = result.data as Record<string, unknown>;
			expect(data).toMatchObject(row.expected);
			expect(typeof data.deltaPreview).toBe("string");
			expect((data.deltaPreview as string).length).toBeGreaterThan(0);
			expect((data.deltaPreview as string).length).toBeLessThanOrEqual(row.previewBytes);
			expect("delta" in data).toBe(false);
			expect(result.truncated).toBe(true);
			if (row.raw) {
				expect(result.raw).toEqual(row.payload);
				expect(result.originalBytes).toBeGreaterThan(100_000);
			}
		});
	}

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
		const payload = { role: "assistant", contentIndex: 1, delta: "abc" };
		const result = sanitizeBridgeEvent("message_update", payload, baseConfig);
		expect(result.originalBytes).toBe(Buffer.byteLength(JSON.stringify(payload), "utf8"));
	});
});

