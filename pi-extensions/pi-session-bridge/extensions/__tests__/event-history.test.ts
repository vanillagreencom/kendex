import { describe, expect, test } from "bun:test";
import { existsSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BridgeHistory, cleanupStaleSpills, type HistoryEnvelope, type HistoryLimits } from "../event-history.js";
import { defaultLimits, dir, makeEnvelope, spillPath, warnings, useHistoryFixture } from "./lib/history-fixture.ts";

useHistoryFixture();

describe("BridgeHistory.push", () => {
	test("retains envelopes in chronological order under count limit", () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, (where, error) => warnings.push({ where, error }));
		for (let i = 0; i < 5; i++) {
			history.push({ ...makeEnvelope(`e${i}`, 16), data: { i } });
		}
		const snapshot = history.snapshot();
		expect(snapshot.map((e) => (e.data as { i: number }).i)).toEqual([0, 1, 2, 3, 4]);
		expect(history.count).toBe(5);
	});

	test("evicts oldest entries once the count limit is exceeded", () => {
		const limits: HistoryLimits = { ...defaultLimits, historyLimit: 3, maxHistoryBytes: 1024 };
		const history = new BridgeHistory(spillPath, () => limits, () => undefined);
		for (let i = 0; i < 10; i++) history.push({ ...makeEnvelope(`e${i}`, 8), data: { i } });
		const events = history.snapshot();
		expect(events).toHaveLength(3);
		expect(events.map((e) => (e.data as { i: number }).i)).toEqual([7, 8, 9]);
	});

	test("spill writes a per-event sidecar line and stores ref/offset/length", () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
		const envelope = {
			...makeEnvelope("message_update"),
			truncated: true,
			originalBytes: 80_000,
		} satisfies HistoryEnvelope;
		const rawPayload = { delta: "y".repeat(80_000) };
		const pushed = history.push(envelope, rawPayload);

		expect(pushed.rawEventPath).toBe(spillPath);
		expect(typeof pushed.rawEventRef).toBe("string");
		expect(existsSync(spillPath)).toBe(true);
		const fileContent = readFileSync(spillPath, "utf8");
		expect(fileContent.split("\n").filter(Boolean)).toHaveLength(1);

		const response = history.buildResponse({ limit: 5, maxBytes: 1024 * 1024, raw: true });
		expect(response.events).toHaveLength(1);
		expect(response.events[0]?.rawRestored).toBe(true);
		expect((response.events[0]?.data as { delta: string }).delta).toBe(rawPayload.delta);
	});

	test("spill cap refuses overflow and surfaces rawError on the affected envelope", () => {
		const limits: HistoryLimits = { ...defaultLimits, historyLimit: 4, maxHistoryBytes: 4 * 1024 * 1024, maxRawSpillBytes: 320 };
		const history = new BridgeHistory(spillPath, () => limits, (where, error) => warnings.push({ where, error }));
		const big = { delta: "z".repeat(120) };

		const first = history.push({ ...makeEnvelope("message_update", 8), truncated: true, originalBytes: 200 }, big);
		const second = history.push({ ...makeEnvelope("message_update", 8), truncated: true, originalBytes: 200 }, big);

		expect(first.rawEventRef).toBe("1");
		expect(first.rawError).toBeUndefined();
		expect(second.rawError?.split("\n")[0]).toBe("spill_max_bytes=320");
		expect(warnings.some((entry) => entry.where === "spill.budget")).toBe(true);
		expect(history.rawSpillBytes).toBeLessThanOrEqual(limits.maxRawSpillBytes);
	});

	test("sidecar file size never exceeds maxRawSpillBytes across count evictions", () => {
		const limits: HistoryLimits = { ...defaultLimits, historyLimit: 1, maxRawSpillBytes: 500 };
		const history = new BridgeHistory(spillPath, () => limits, (where, error) => warnings.push({ where, error }));
		const big = { delta: "z".repeat(120) };
		for (let i = 0; i < 12; i++) {
			history.push({ ...makeEnvelope("message_update", 8), truncated: true, originalBytes: 200 }, big);
			expect(existsSync(spillPath)).toBe(true);
			expect(statSync(spillPath).size).toBeLessThanOrEqual(limits.maxRawSpillBytes);
		}
		if (existsSync(spillPath)) {
			expect(statSync(spillPath).size).toBeLessThanOrEqual(limits.maxRawSpillBytes);
		}
		expect(history.count).toBe(1);
	});

	test("after eviction the raw spill accounting drops so a later spill fits", () => {
		const limits: HistoryLimits = { ...defaultLimits, historyLimit: 1, maxHistoryBytes: 4 * 1024 * 1024, maxRawSpillBytes: 400 };
		const history = new BridgeHistory(spillPath, () => limits, () => undefined);
		const big = { delta: "z".repeat(120) };
		history.push({ ...makeEnvelope("message_update", 8), truncated: true, originalBytes: 200 }, big);
		// #1 was evicted because historyLimit=1; rawBytes accounting must drop accordingly.
		const second = history.push({ ...makeEnvelope("message_update", 8), truncated: true, originalBytes: 200 }, big);

		expect(history.count).toBe(1);
		expect(second.rawEventRef).toBeDefined();
		expect(second.rawError).toBeUndefined();
		expect(history.rawSpillBytes).toBeLessThanOrEqual(limits.maxRawSpillBytes);
	});

	test("spill disabled flags rawError and skips sidecar writes", () => {
		const limits: HistoryLimits = { ...defaultLimits, spillEnabled: false };
		const history = new BridgeHistory(spillPath, () => limits, () => undefined);
		const pushed = history.push({ ...makeEnvelope("message_update"), truncated: true, originalBytes: 200 }, { delta: "x".repeat(200) });
		expect(pushed.rawEventPath).toBeUndefined();
		expect(pushed.rawError?.split("\n")[0]).toBe("spill_enabled=false");
		expect(existsSync(spillPath)).toBe(false);
	});
});
