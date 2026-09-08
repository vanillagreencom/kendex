import { describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { BridgeHistory, type HistoryLimits } from "../event-history.js";
import { defaultLimits, makeEnvelope, spillPath, useHistoryFixture } from "./lib/history-fixture.ts";

useHistoryFixture();

describe("BridgeHistory.buildResponse", () => {
	function pushSeries(history: BridgeHistory, count: number): void {
		for (let i = 0; i < count; i++) {
			history.push({
				...makeEnvelope(i % 2 === 0 ? "message_update" : "tool_execution_end", 64),
				truncated: true,
				originalBytes: 1024,
			}, { delta: `chunk-${i}-${"y".repeat(200)}` });
		}
	}

	for (const row of [
		{ name: "event filter", filters: { event: "message_update" }, expected: ["message_update", "message_update", "message_update"] },
		{ name: "since filter", filters: { since: "2026-05-21T00:00:00.003Z" }, expected: ["tool_execution_end", "message_update", "tool_execution_end"] },
	]) {
		test(`filters before limit: ${row.name}`, () => {
			const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
			pushSeries(history, 6);
			const result = history.buildResponse({ limit: 10, maxBytes: 1024 * 1024, ...row.filters });
			expect(result.events.map((entry) => entry.event)).toEqual(row.expected);
		});
	}

	test("trims compact envelopes by response budget before rehydration", () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
		pushSeries(history, 8);
		const compactSizes = history.snapshot().map((envelope) => Buffer.byteLength(JSON.stringify(envelope), "utf8"));
		const cap = compactSizes.slice(-3).reduce((sum, size) => sum + size, 0);
		const response = history.buildResponse({ limit: 50, maxBytes: cap });
		expect(response.events.length).toBeLessThan(8);
		expect(response.events.at(-1)?.timestamp).toBe(history.snapshot().at(-1)?.timestamp);
		expect(response.responseTruncated).toBe(true);
	});

	test("raw rehydration keeps compact form when rehydrated payload would exceed cap", () => {
		const limits: HistoryLimits = { ...defaultLimits, maxRawSpillBytes: 10 * 1024 * 1024 };
		const history = new BridgeHistory(spillPath, () => limits, () => undefined);
		pushSeries(history, 4);

		const snapshot = history.snapshot();
		const compactTotal = snapshot.reduce((sum, env) => sum + Buffer.byteLength(JSON.stringify(env), "utf8"), 0);
		// All 4 compact envelopes fit; leave headroom for ~2 rehydrations but not 4.
		const budget = compactTotal + 600;

		const response = history.buildResponse({ limit: 50, maxBytes: budget, raw: true });
		expect(response.events).toHaveLength(4);
		const hydrated = response.events.filter((e) => e.rawRestored === true);
		expect(hydrated.length).toBeGreaterThan(0);
		expect(hydrated.length).toBeLessThan(4);
		expect(response.responseTruncated).toBe(true);
		const compactStill = response.events.filter((e) => e.rawRestored !== true);
		for (const event of compactStill) {
			expect((event.data as Record<string, unknown>).filler).toBeDefined();
		}
	});

	test("rehydration failures surface as per-event rawError and aggregate rawErrors", () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
		const envelope = { ...makeEnvelope("message_update"), truncated: true, originalBytes: 200 };
		history.push(envelope, { delta: "y".repeat(200) });
		// Corrupt the sidecar so rehydration fails.
		writeFileSync(spillPath, "not-json\n", { mode: 0o600 });
		const response = history.buildResponse({ limit: 5, maxBytes: 1024 * 1024, raw: true });
		expect(response.events[0]?.rawRestored).not.toBe(true);
		expect(response.events[0]?.rawError?.split("\n")[0]).toBe("error_code=SyntaxError");
		expect(response.rawErrors?.length).toBeGreaterThan(0);
	});

	test("rawErrors only includes events that survived the compact budget cut", () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
		// Push two truncated events; corrupt the sidecar so any rehydration attempt fails.
		history.push({ ...makeEnvelope("message_update"), truncated: true, originalBytes: 200 }, { delta: "y".repeat(200) });
		history.push({ ...makeEnvelope("message_update"), truncated: true, originalBytes: 200 }, { delta: "y".repeat(200) });
		writeFileSync(spillPath, "not-json\n", { mode: 0o600 });

		// maxBytes=1 forces only the newest entry into the response. The older
		// event must NOT trigger a sidecar read or contribute to rawErrors.
		const response = history.buildResponse({ limit: 50, maxBytes: 1, raw: true });
		expect(response.events).toHaveLength(1);
		expect(response.responseTruncated).toBe(true);
		expect(response.events[0]?.event).toBe("message_update");
		expect(response.rawErrors?.length ?? 0).toBeLessThanOrEqual(1);
	});
});

