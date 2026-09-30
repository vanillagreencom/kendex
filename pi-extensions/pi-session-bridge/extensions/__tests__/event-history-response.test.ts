import { describe, expect, spyOn, test } from "bun:test";
import * as fs from "node:fs";
import { writeFileSync } from "node:fs";
import { setImmediate as nextTurn } from "node:timers/promises";
import { BridgeHistory, type HistoryLimits } from "../event-history.js";
import { defaultLimits, makeEnvelope, spillPath, useHistoryFixture, pushRaw, settle } from "./lib/history-fixture.ts";

useHistoryFixture();

describe("BridgeHistory.buildResponse", async () => {
	function pushSeries(history: BridgeHistory, count: number): void {
		for (let i = 0; i < count; i++) {
			pushRaw(history, {
				...makeEnvelope(i % 2 === 0 ? "message_update" : "tool_execution_end", 64),
				truncated: true,
				originalBytes: 1024,
			}, { delta: `chunk-${i}-${"y".repeat(200)}` });
		}
	}

	for (const row of [
		{ name: "event filter before limit", filters: { event: "message_update" }, limit: 2, expected: ["message_update", "message_update"], indexes: [2, 4] },
		{ name: "since filter", filters: { since: "2026-05-21T00:00:00.003Z" }, limit: 10, expected: ["tool_execution_end", "message_update", "tool_execution_end"], indexes: [3, 4, 5] },
	]) {
		test(`history response: ${row.name}`, async () => {
			const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
			pushSeries(history, 6);
			const result = await history.buildResponse({ limit: row.limit, maxBytes: 1024 * 1024, ...row.filters });
			expect(result.events.map((entry) => entry.event)).toEqual(row.expected);
			expect(result.events.map((entry) => (entry.data as { idx: number }).idx)).toEqual(row.indexes);
		});
	}

	test("compact history bypasses an in-flight spill while raw history waits for restoration", async () => {
		// A subscribed Pi tool_execution_end queues raw data while clients request history.
		const history = new BridgeHistory(spillPath, () => defaultLimits);
		const envelope = { ...makeEnvelope("tool_execution_end"), truncated: true, originalBytes: 1024 };
		const payload = { toolName: "probe", result: "y".repeat(1024) };
		const blocked = Promise.withResolvers<void>();
		const entered = Promise.withResolvers<void>();
		const append = fs.promises.appendFile.bind(fs.promises);
		const spy = spyOn(fs.promises, "appendFile").mockImplementation(async (...args) => {
			entered.resolve();
			await blocked.promise;
			return append(...args);
		});
		try {
			pushRaw(history, envelope, payload);
			await entered.promise;
			const order: string[] = [];
			const compact = history.buildResponse({ limit: 5, maxBytes: 4096 }).then((response) => { order.push("compact"); return response; });
			const raw = history.buildResponse({ limit: 5, maxBytes: 4096, raw: true }).then((response) => { order.push("raw"); return response; });
			// One event-loop turn lets response continuations run, but cannot release the staged append.
			await nextTurn();
			expect(order).toEqual(["compact"]);
			const compactResponse = await compact;
			expect(compactResponse.events).toHaveLength(1);
			expect(compactResponse.events[0]?.data).toEqual({ filler: "x".repeat(32), idx: 0 });
			expect(compactResponse.events[0]?.rawError?.split("\n")[0]).toBe("spill_pending=true");
			expect(compactResponse.events[0]?.rawRestored).toBeUndefined();
			order.push("release");
			blocked.resolve();
			const rawResponse = await raw;
			expect(order).toEqual(["compact", "release", "raw"]);
			expect(rawResponse.events).toHaveLength(1);
			expect(rawResponse.events[0]?.data).toEqual(payload);
			expect(rawResponse.events[0]?.rawRestored).toBe(true);
			expect(rawResponse.events[0]?.rawError).toBeUndefined();
			expect(compactResponse.events[0]?.rawError?.split("\n")[0]).toBe("spill_pending=true");
		} finally {
			blocked.resolve();
			await history.cleanup();
			spy.mockRestore();
		}
	});

	test("trims compact envelopes by response budget before rehydration", async () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
		pushSeries(history, 8);
		const compactSizes = history.snapshot().map((envelope) => Buffer.byteLength(JSON.stringify(envelope), "utf8"));
		const cap = compactSizes.slice(-3).reduce((sum, size) => sum + size, 0);
		const response = await history.buildResponse({ limit: 50, maxBytes: cap });
		expect(response.events.length).toBeLessThan(8);
		expect(response.events.at(-1)?.timestamp).toBe(history.snapshot().at(-1)?.timestamp);
		expect(response.responseTruncated).toBe(true);
	});

	test("raw rehydration keeps compact form when rehydrated payload would exceed cap", async () => {
		const limits: HistoryLimits = { ...defaultLimits, maxRawSpillBytes: 10 * 1024 * 1024 };
		const history = new BridgeHistory(spillPath, () => limits, () => undefined);
		pushSeries(history, 4);

		await settle(history);
		const snapshot = history.snapshot();
		const compactTotal = snapshot.reduce((sum, env) => sum + Buffer.byteLength(JSON.stringify(env), "utf8"), 0);
		// All 4 compact envelopes fit; leave headroom for ~2 rehydrations but not 4.
		const budget = compactTotal + 600;

		const response = await history.buildResponse({ limit: 50, maxBytes: budget, raw: true });
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

	test("rehydration failures surface as per-event rawError and aggregate rawErrors", async () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
		const envelope = { ...makeEnvelope("message_update"), truncated: true, originalBytes: 200 };
		pushRaw(history, envelope, { delta: "y".repeat(200) });
		// Corrupt the sidecar so rehydration fails.
		await settle(history);
		writeFileSync(spillPath, "not-json\n", { mode: 0o600 });
		const response = await history.buildResponse({ limit: 5, maxBytes: 1024 * 1024, raw: true });
		expect(response.events[0]?.rawRestored).not.toBe(true);
		expect(response.events[0]?.rawError?.split("\n")[0]).toBe("error_code=SyntaxError");
		expect(response.rawErrors?.length).toBeGreaterThan(0);
	});

	test("rawErrors only includes events that survived the compact budget cut", async () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
		// Push two truncated events; corrupt the sidecar so any rehydration attempt fails.
		pushRaw(history, { ...makeEnvelope("message_update"), truncated: true, originalBytes: 200 }, { delta: "y".repeat(200) });
		pushRaw(history, { ...makeEnvelope("message_update"), truncated: true, originalBytes: 200 }, { delta: "y".repeat(200) });
		await settle(history);
		writeFileSync(spillPath, "not-json\n", { mode: 0o600 });

		// maxBytes=1 forces only the newest entry into the response. The older
		// event must NOT trigger a sidecar read or contribute to rawErrors.
		const response = await history.buildResponse({ limit: 50, maxBytes: 1, raw: true });
		expect(response.events).toHaveLength(1);
		expect(response.responseTruncated).toBe(true);
		expect(response.events[0]?.event).toBe("message_update");
		expect(response.rawErrors?.length ?? 0).toBeLessThanOrEqual(1);
	});
});

