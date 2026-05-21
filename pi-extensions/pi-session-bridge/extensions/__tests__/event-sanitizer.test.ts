import { describe, expect, test } from "bun:test";
import { Buffer } from "node:buffer";

import {
	DEFAULT_MAX_EVENT_BYTES,
	DEFAULT_PREVIEW_BYTES,
	sanitizeBridgeEvent,
	trimEnvelopesByBytes,
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

	test("originalBytes reflects raw JSON length", () => {
		const payload = { role: "assistant", contentIndex: 1, delta: "abc" };
		const result = sanitizeBridgeEvent("message_update", payload, baseConfig);
		expect(result.originalBytes).toBe(Buffer.byteLength(JSON.stringify(payload), "utf8"));
	});
});

describe("trimEnvelopesByBytes", () => {
	test("returns all when under cap", () => {
		const envelopes = [
			{ type: "event", event: "a", timestamp: "t1", data: { v: 1 } },
			{ type: "event", event: "b", timestamp: "t2", data: { v: 2 } },
		];
		const result = trimEnvelopesByBytes(envelopes, 1024);
		expect(result.events).toEqual(envelopes);
		expect(result.truncated).toBe(false);
	});

	test("drops older entries until under cap", () => {
		const big = (i: number) => ({ type: "event", event: `e${i}`, timestamp: `t${i}`, data: { text: "x".repeat(400) } });
		const envelopes = [big(1), big(2), big(3), big(4)];
		const oneSize = Buffer.byteLength(JSON.stringify(big(1)), "utf8");
		const result = trimEnvelopesByBytes(envelopes, oneSize * 2 + 4);
		expect(result.truncated).toBe(true);
		expect(result.events.length).toBeLessThanOrEqual(2);
		expect((result.events.at(-1) as { event: string }).event).toBe("e4");
	});

	test("always returns at least the most recent envelope when oversized", () => {
		const envelopes = [
			{ type: "event", event: "small", timestamp: "t1", data: {} },
			{ type: "event", event: "huge", timestamp: "t2", data: { text: "y".repeat(50_000) } },
		];
		const result = trimEnvelopesByBytes(envelopes, 100);
		expect(result.events).toHaveLength(1);
		expect((result.events[0] as { event: string }).event).toBe("huge");
		expect(result.truncated).toBe(true);
	});

	test("returns the single oversized envelope without marking truncated when only one exists", () => {
		const envelopes = [
			{ type: "event", event: "huge", timestamp: "t1", data: { text: "y".repeat(50_000) } },
		];
		const result = trimEnvelopesByBytes(envelopes, 100);
		expect(result.events).toHaveLength(1);
		expect(result.truncated).toBe(false);
	});

	test("empty input returns empty result", () => {
		expect(trimEnvelopesByBytes([], 1024)).toEqual({ events: [], truncated: false });
	});
});
