import { describe, expect, test } from "bun:test";
import { Buffer } from "node:buffer";

import {
	DEFAULT_MAX_EVENT_BYTES,
	DEFAULT_PREVIEW_BYTES,
	sanitizeBridgeEvent,
} from "../event-sanitizer.js";

const baseConfig = { maxEventBytes: DEFAULT_MAX_EVENT_BYTES, previewBytes: DEFAULT_PREVIEW_BYTES };

describe("sanitizeBridgeEvent", () => {
	test("message_update keeps role/contentIndex/delta length and short preview", () => {
		const payload = { role: "assistant", contentIndex: 0, type: "text", delta: "Hello world" };
		const result = sanitizeBridgeEvent("message_update", payload, baseConfig);
		expect(result.truncated).toBe(true);
		const data = result.data as Record<string, unknown>;
		expect(data.role).toBe("assistant");
		expect(data.type).toBe("text");
		expect(data.contentIndex).toBe(0);
		expect(data.deltaLength).toBe(11);
		expect(data.deltaBytes).toBe(11);
		expect(data.deltaPreview).toBe("Hello world");
		expect("delta" in data).toBe(false);
	});

	test("message_update truncates very large deltas to preview window", () => {
		const huge = "x".repeat(500_000);
		const payload = { role: "assistant", contentIndex: 0, delta: huge };
		const result = sanitizeBridgeEvent("message_update", payload, { ...baseConfig, previewBytes: 64 });
		const data = result.data as Record<string, unknown>;
		expect(data.deltaLength).toBe(500_000);
		expect(typeof data.deltaPreview).toBe("string");
		expect((data.deltaPreview as string).length).toBeLessThanOrEqual(64);
		expect(result.truncated).toBe(true);
		expect(result.raw).toEqual(payload);
		expect(result.originalBytes).toBeGreaterThan(100_000);
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
			usage: { inputTokens: 1024, outputTokens: 2048 },
			messages,
		};
		const result = sanitizeBridgeEvent("agent_end", payload, baseConfig);
		const data = result.data as Record<string, unknown>;
		expect(data.status).toBe("ended");
		expect(data.stopReason).toBe("end_turn");
		expect(data.usage).toEqual({ inputTokens: 1024, outputTokens: 2048 });
		expect(data.messagesCount).toBe(60);
		expect(typeof data.finalTextPreview).toBe("string");
		expect((data.finalTextPreview as string).length).toBeLessThanOrEqual(DEFAULT_PREVIEW_BYTES);
		expect("messages" in data).toBe(false);
	});

	test("unknown events pass through when under per-event budget", () => {
		const payload = { ok: true, count: 3 };
		const result = sanitizeBridgeEvent("bridge_pong", payload, baseConfig);
		expect(result.data).toEqual(payload);
		expect(result.truncated).toBe(false);
		expect(result.raw).toBeUndefined();
	});

	test("unknown events over per-event budget collapse to a descriptor", () => {
		const blob = "z".repeat(1_500_000);
		const payload = { blob };
		const result = sanitizeBridgeEvent("input", payload, { ...baseConfig, maxEventBytes: 1024 });
		const data = result.data as Record<string, unknown>;
		expect(result.truncated).toBe(true);
		expect(data.truncated).toBe(true);
		expect(typeof data.originalBytes).toBe("number");
		expect(data.maxBytes).toBe(1024);
		expect(result.raw).toEqual(payload);
	});

	test("message_update reads role/contentIndex/delta from assistantMessageEvent envelope", () => {
		const payload = {
			assistantMessageEvent: {
				message: {
					id: "msg_42",
					role: "assistant",
					contentIndex: 2,
					type: "text",
					text: "z".repeat(800),
				},
			},
		};
		const result = sanitizeBridgeEvent("message_update", payload, baseConfig);
		const data = result.data as Record<string, unknown>;
		expect(data.role).toBe("assistant");
		expect(data.contentIndex).toBe(2);
		expect(data.messageId).toBe("msg_42");
		expect(data.type).toBe("text");
		expect(data.deltaLength).toBe(800);
		expect(typeof data.deltaPreview).toBe("string");
		expect(result.truncated).toBe(true);
	});

	test("message_update falls back to message.content array text", () => {
		const payload = {
			message: {
				role: "assistant",
				content: [
					{ type: "text", text: "intro" },
					{ type: "text", text: "final body " + "y".repeat(400) },
				],
			},
		};
		const result = sanitizeBridgeEvent("message_update", payload, baseConfig);
		const data = result.data as Record<string, unknown>;
		expect(data.role).toBe("assistant");
		expect(typeof data.deltaPreview).toBe("string");
		expect((data.deltaPreview as string).length).toBeGreaterThan(0);
		expect(result.truncated).toBe(true);
	});

	test("tool_execution_* accepts toolCallId / tool_call_id / nested toolCall", () => {
		const camel = sanitizeBridgeEvent("tool_execution_start", { toolName: "Read", toolCallId: "tcl_1", input: { path: "/x" } }, baseConfig);
		expect((camel.data as Record<string, unknown>).toolUseId).toBe("tcl_1");

		const snake = sanitizeBridgeEvent("tool_execution_update", { tool_name: "Bash", tool_call_id: "tcl_2", output: "ok" }, baseConfig);
		expect((snake.data as Record<string, unknown>).toolUseId).toBe("tcl_2");

		const nested = sanitizeBridgeEvent("tool_execution_end", { toolCall: { name: "Edit", id: "tcl_3", status: "error", isError: true }, error: "boom" }, baseConfig);
		const nestedData = nested.data as Record<string, unknown>;
		expect(nestedData.toolName).toBe("Edit");
		expect(nestedData.toolUseId).toBe("tcl_3");
		expect(nestedData.status).toBe("error");
		expect(nestedData.isError).toBe(true);
		expect(typeof nestedData.errorBytes).toBe("number");
	});

	test("agent_end accepts content array or single message variants", () => {
		const stringContent = sanitizeBridgeEvent("agent_end", {
			status: "ended",
			usage: { inputTokens: 1 },
			content: "final body " + "x".repeat(500),
		}, baseConfig);
		const stringData = stringContent.data as Record<string, unknown>;
		expect(stringData.status).toBe("ended");
		expect(typeof stringData.finalTextPreview).toBe("string");
		expect((stringData.finalTextPreview as string).length).toBeGreaterThan(0);

		const arrayContent = sanitizeBridgeEvent("agent_end", {
			status: "ended",
			content: [
				{ type: "text", text: "alpha" },
				{ type: "text", text: "omega" },
			],
		}, baseConfig);
		expect((arrayContent.data as Record<string, unknown>).finalTextPreview).toBe("omega");

		const singleMessage = sanitizeBridgeEvent("agent_end", {
			status: "ended",
			message: { role: "assistant", content: [{ type: "text", text: "from .message" }] },
		}, baseConfig);
		const singleData = singleMessage.data as Record<string, unknown>;
		expect(singleData.messagesCount).toBe(1);
		expect(singleData.finalTextPreview).toBe("from .message");
	});

	test("originalBytes reflects raw JSON length", () => {
		const payload = { role: "assistant", contentIndex: 1, delta: "abc" };
		const result = sanitizeBridgeEvent("message_update", payload, baseConfig);
		expect(result.originalBytes).toBe(Buffer.byteLength(JSON.stringify(payload), "utf8"));
	});
});

