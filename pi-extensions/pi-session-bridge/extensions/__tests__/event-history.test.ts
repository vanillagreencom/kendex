import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { BridgeHistory, cleanupStaleSpills, type HistoryEnvelope, type HistoryLimits } from "../event-history.js";

const defaultLimits: HistoryLimits = {
	historyLimit: 500,
	maxHistoryBytes: 4 * 1024 * 1024,
	maxRawSpillBytes: 16 * 1024 * 1024,
	spillEnabled: true,
};

let monotonicCounter = 0;

function makeEnvelope(event: string, dataBytes = 32): HistoryEnvelope {
	const filler = "x".repeat(dataBytes);
	const idx = monotonicCounter++;
	const ms = String(idx % 1000).padStart(3, "0");
	const seconds = String(Math.floor(idx / 1000) % 60).padStart(2, "0");
	return {
		type: "event",
		event,
		timestamp: `2026-05-21T00:00:${seconds}.${ms}Z`,
		data: { filler, idx },
	};
}

let dir = "";
let spillPath = "";
let warnings: Array<{ where: string; error: unknown }> = [];

beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "bridge-history-"));
	spillPath = join(dir, "raw", `${process.pid}.jsonl`);
	warnings = [];
	monotonicCounter = 0;
});

afterEach(() => {
	rmSync(dir, { recursive: true, force: true });
});

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

	test("evicts oldest entries once count or byte limits are exceeded", () => {
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
		expect(second.rawError).toBeDefined();
		expect(warnings.some((entry) => entry.where === "spill.budget")).toBe(true);
		expect(history.rawSpillBytes).toBeLessThanOrEqual(limits.maxRawSpillBytes);
	});

	test("sidecar file size never exceeds maxRawSpillBytes across count evictions", () => {
		const limits: HistoryLimits = { ...defaultLimits, historyLimit: 1, maxRawSpillBytes: 500 };
		const history = new BridgeHistory(spillPath, () => limits, (where, error) => warnings.push({ where, error }));
		const big = { delta: "z".repeat(120) };
		for (let i = 0; i < 12; i++) {
			history.push({ ...makeEnvelope("message_update", 8), truncated: true, originalBytes: 200 }, big);
			if (existsSync(spillPath)) {
				expect(statSync(spillPath).size).toBeLessThanOrEqual(limits.maxRawSpillBytes);
			}
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
		expect(pushed.rawError).toBe("raw spill disabled");
		expect(existsSync(spillPath)).toBe(false);
	});
});

describe("BridgeHistory.buildResponse", () => {
	function pushSeries(history: BridgeHistory, count: number): void {
		for (let i = 0; i < count; i++) {
			history.push({
				...makeEnvelope(i % 2 === 0 ? "message_update" : "tool_execution_end", 64, String(i).padStart(3, "0")),
				truncated: true,
				originalBytes: 1024,
			}, { delta: `chunk-${i}-${"y".repeat(200)}` });
		}
	}

	test("applies event and since filters before slicing to the requested limit", () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
		pushSeries(history, 6);
		const filtered = history.buildResponse({ limit: 10, maxBytes: 1024 * 1024, event: "message_update" });
		expect(filtered.events.every((e) => e.event === "message_update")).toBe(true);
		expect(filtered.events).toHaveLength(3);

		const since = history.snapshot()[3]!.timestamp;
		const sinceResponse = history.buildResponse({ limit: 10, maxBytes: 1024 * 1024, since });
		expect(sinceResponse.events.map((e) => e.event)).toEqual(history.snapshot().slice(3).map((e) => e.event));
	});

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
		expect(typeof response.events[0]?.rawError).toBe("string");
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

describe("cleanupStaleSpills", () => {
	test("removes spill files for dead pids and keeps live and self pids", () => {
		const liveDir = join(dir, "raw");
		const selfPath = join(liveDir, `${process.pid}.jsonl`);
		const livePid = process.pid + 12_345;
		const deadPath = join(liveDir, "9999999.jsonl");
		const livePath = join(liveDir, `${livePid}.jsonl`);
		const notJsonl = join(liveDir, "ignored.txt");
		const fs = require("node:fs") as typeof import("node:fs");
		fs.mkdirSync(liveDir, { recursive: true });
		fs.writeFileSync(selfPath, "ours\n");
		fs.writeFileSync(deadPath, "stale\n");
		fs.writeFileSync(livePath, "live\n");
		fs.writeFileSync(notJsonl, "skip\n");

		cleanupStaleSpills(liveDir, (pid) => pid === livePid);
		expect(existsSync(selfPath)).toBe(true);
		expect(existsSync(deadPath)).toBe(false);
		expect(existsSync(livePath)).toBe(true);
		expect(existsSync(notJsonl)).toBe(true);
	});
});
