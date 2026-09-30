import { describe, expect, spyOn, test } from "bun:test";
import { Buffer } from "node:buffer";
import { existsSync, readFileSync, statSync } from "node:fs";
import * as fs from "node:fs";
import { dirname } from "node:path";
import { BridgeHistory, type HistoryEnvelope, type HistoryLimits } from "../event-history.js";
import { defaultLimits, makeEnvelope, spillPath, warnings, useHistoryFixture, pushRaw, settle } from "./lib/history-fixture.ts";

useHistoryFixture();

describe("BridgeHistory.push", async () => {
	test("retains envelopes in chronological order under count limit", async () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, (where, error) => warnings.push({ where, error }));
		for (let i = 0; i < 5; i++) {
			history.push({ ...makeEnvelope(`e${i}`, 16), data: { i } });
		}
		const snapshot = history.snapshot();
		expect(snapshot.map((e) => (e.data as { i: number }).i)).toEqual([0, 1, 2, 3, 4]);
		expect(history.count).toBe(5);
	});

	test("evicts oldest entries once the count limit is exceeded", async () => {
		const limits: HistoryLimits = { ...defaultLimits, historyLimit: 3, maxHistoryBytes: 1024 };
		const history = new BridgeHistory(spillPath, () => limits, () => undefined);
		for (let i = 0; i < 10; i++) history.push({ ...makeEnvelope(`e${i}`, 8), data: { i } });
		const events = history.snapshot();
		expect(events).toHaveLength(3);
		expect(events.map((e) => (e.data as { i: number }).i)).toEqual([7, 8, 9]);
	});

	test("spill writes a per-event sidecar line and stores ref/offset/length", async () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
		const envelope = {
			...makeEnvelope("message_end"),
			truncated: true,
			originalBytes: 80_000,
		} satisfies HistoryEnvelope;
		const rawPayload = { delta: "y".repeat(80_000) };
		const pushed = pushRaw(history, envelope, rawPayload);

		await settle(history);
		expect(pushed.rawEventPath).toBe(spillPath);
		expect(typeof pushed.rawEventRef).toBe("string");
		await settle(history);
		expect(existsSync(spillPath)).toBe(true);
		const fileContent = readFileSync(spillPath, "utf8");
		expect(fileContent.split("\n").filter(Boolean)).toHaveLength(1);

		const response = await history.buildResponse({ limit: 5, maxBytes: 1024 * 1024, raw: true });
		expect(response.events).toHaveLength(1);
		expect(response.events[0]?.rawRestored).toBe(true);
		expect((response.events[0]?.data as { delta: string }).delta).toBe(rawPayload.delta);
	});

	test("spill cap refuses overflow and surfaces rawError on the affected envelope", async () => {
		const limits: HistoryLimits = { ...defaultLimits, historyLimit: 4, maxHistoryBytes: 4 * 1024 * 1024, maxRawSpillBytes: 320 };
		const history = new BridgeHistory(spillPath, () => limits, (where, error) => warnings.push({ where, error }));
		const big = { delta: "z".repeat(120) };

		const first = pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true, originalBytes: 200 }, big);
		const second = pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true, originalBytes: 200 }, big);

		await settle(history);
		expect(first.rawEventRef).toBe("1");
		expect(first.rawError).toBeUndefined();
		await settle(history);
		expect(second.rawError?.split("\n")[0]).toBe("spill_max_bytes=320");
		expect(warnings.some((entry) => entry.where === "spill.budget")).toBe(true);
		expect(history.rawSpillBytes).toBeLessThanOrEqual(limits.maxRawSpillBytes);
	});

	test("a spill refused at budget leaves the sidecar unread and unwritten", async () => {
		const limits: HistoryLimits = { ...defaultLimits, historyLimit: 8, maxRawSpillBytes: 400 };
		const history = new BridgeHistory(spillPath, () => limits, (where, error) => warnings.push({ where, error }));
		const payload = { delta: "z".repeat(150) };

		const first = pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true, originalBytes: 200 }, payload);
		await settle(history);
		expect(first.rawEventRef).toBe("1");
		await settle(history);
		const before = statSync(spillPath);
		const beforeContent = readFileSync(spillPath, "utf8");

		// Both envelopes are live, so no orphaned bytes exist to reclaim and the
		// refusal must cost no file I/O at all.
		const second = pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true, originalBytes: 200 }, payload);

		await settle(history);
		expect(second.rawError?.split("\n")[0]).toBe("spill_max_bytes=400");
		await settle(history);
		expect(second.rawEventRef).toBeUndefined();
		const after = statSync(spillPath);
		expect(after.size).toBe(before.size);
		expect(after.mtimeMs).toBe(before.mtimeMs);
		expect(readFileSync(spillPath, "utf8")).toBe(beforeContent);
	});

	test("a first spill refused at budget creates no sidecar directory", async () => {
		const limits: HistoryLimits = { ...defaultLimits, maxRawSpillBytes: 16 };
		const history = new BridgeHistory(spillPath, () => limits, (where, error) => warnings.push({ where, error }));

		const pushed = pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true, originalBytes: 200 }, { delta: "z".repeat(150) });

		await settle(history);
		expect(pushed.rawError?.split("\n")[0]).toBe("spill_max_bytes=16");
		expect(pushed.rawEventRef).toBeUndefined();
		expect(existsSync(dirname(spillPath))).toBe(false);
	});

	test("the delta-only notes are charged against the response cap", async () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
		for (let i = 0; i < 300; i++) history.push({ ...makeEnvelope("message_update", 8), truncated: true, originalBytes: 6 });

		const size = (events: HistoryEnvelope[]): number => events.reduce((total, event) => total + Buffer.byteLength(JSON.stringify(event), "utf8"), 0);
		const compactBytes = size((await history.buildResponse({ limit: 500, maxBytes: 4 * 1024 * 1024 })).events);
		const annotated = (await history.buildResponse({ limit: 500, maxBytes: 4 * 1024 * 1024, raw: true })).events;
		expect(annotated.every((event) => event.rawError !== undefined)).toBe(true);
		const noteBytes = (size(annotated) - compactBytes) / annotated.length;
		expect(noteBytes).toBeGreaterThan(0);

		// Every envelope fits compactly; only the notes cross the cap, so the
		// cap holds solely because each note is added to the running total.
		const maxBytes = Math.floor(compactBytes + noteBytes * 2);
		const response = await history.buildResponse({ limit: 500, maxBytes, raw: true });

		expect(response.events).toHaveLength(300);
		expect(size(response.events)).toBeLessThanOrEqual(maxBytes);
		expect(response.responseTruncated).toBe(true);
		expect(response.events.filter((event) => event.rawError !== undefined)).toHaveLength(2);
	});

	test("a lone envelope keeps its delta-only note whatever the cap", async () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits, () => undefined);
		history.push({ ...makeEnvelope("message_update", 8), truncated: true, originalBytes: 6 });

		const response = await history.buildResponse({ limit: 500, maxBytes: 1, raw: true });

		expect(response.events).toHaveLength(1);
		expect(response.events[0]?.rawError?.split("\n")[0]).toBe("raw_retained=false");
	});

	test("a recorded spill failure outranks the delta-only note on a raw response", async () => {
		const limits: HistoryLimits = { ...defaultLimits, maxRawSpillBytes: 16 };
		const history = new BridgeHistory(spillPath, () => limits, (where, error) => warnings.push({ where, error }));

		const refused = pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true, originalBytes: 200 }, { delta: "z".repeat(150) });
		expect(refused.rawError?.split("\n")[0]).toBe("spill_max_bytes=16");

		const response = await history.buildResponse({ limit: 5, maxBytes: 1024 * 1024, raw: true });

		expect(response.events).toHaveLength(1);
		expect(response.events[0]?.rawError?.split("\n")[0]).toBe("spill_max_bytes=16");
	});

	test("sidecar file size never exceeds maxRawSpillBytes across count evictions", async () => {
		const limits: HistoryLimits = { ...defaultLimits, historyLimit: 1, maxRawSpillBytes: 500 };
		const history = new BridgeHistory(spillPath, () => limits, (where, error) => warnings.push({ where, error }));
		const big = { delta: "z".repeat(120) };
		for (let i = 0; i < 12; i++) {
			pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true, originalBytes: 200 }, big);
			await settle(history);
		expect(existsSync(spillPath)).toBe(true);
			expect(statSync(spillPath).size).toBeLessThanOrEqual(limits.maxRawSpillBytes);
		}
		if (existsSync(spillPath)) {
			expect(statSync(spillPath).size).toBeLessThanOrEqual(limits.maxRawSpillBytes);
		}
		expect(history.count).toBe(1);
	});

	test("asynchronous compaction preserves retained payloads and their new offsets", async () => {
		const limits = { ...defaultLimits, historyLimit: 2, maxRawSpillBytes: 600 };
		const history = new BridgeHistory(spillPath, () => limits);
		for (let i = 0; i < 8; i++) {
			pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true }, { i, text: "é".repeat(60) });
			await settle(history);
			expect(statSync(spillPath).size).toBeLessThanOrEqual(600);
		}
		const response = await history.buildResponse({ limit: 2, maxBytes: 4096, raw: true });
		expect(response.events.map((event) => event.data)).toEqual([6, 7].map((i) => ({ i, text: "é".repeat(60) })));
		expect(response.events.every((event) => event.rawRestored === true && event.rawError === undefined)).toBe(true);
	});

	test("after eviction the raw spill accounting drops so a later spill fits", async () => {
		const limits: HistoryLimits = { ...defaultLimits, historyLimit: 1, maxHistoryBytes: 4 * 1024 * 1024, maxRawSpillBytes: 400 };
		const history = new BridgeHistory(spillPath, () => limits, () => undefined);
		const big = { delta: "z".repeat(120) };
		pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true, originalBytes: 200 }, big);
		// #1 was evicted because historyLimit=1; rawBytes accounting must drop accordingly.
		const second = pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true, originalBytes: 200 }, big);

		expect(history.count).toBe(1);
		await settle(history);
		expect(second.rawEventRef).toBeDefined();
		expect(second.rawError).toBeUndefined();
		expect(history.rawSpillBytes).toBeLessThanOrEqual(limits.maxRawSpillBytes);
	});

	for (const row of [
		{ name: "byte", calls: 17, raw: "x".repeat(1_000_000), accepted: 16 },
		{ name: "count", calls: 65, raw: "x", accepted: 64 },
	]) {
		for (const stage of ["pending", "in-flight"]) {
			test(`queue ${row.name} bound includes ${stage} events with an unlimited disk budget`, async () => {
				const limits = { ...defaultLimits, maxRawSpillBytes: 0 };
				const history = new BridgeHistory(spillPath, () => limits);
				const append = fs.promises.appendFile.bind(fs.promises);
				let release!: () => void;
				let started!: () => void;
				const blocked = new Promise<void>((resolve) => { release = resolve; });
				const entered = new Promise<void>((resolve) => { started = resolve; });
				const spy = spyOn(fs.promises, "appendFile").mockImplementation(async (...args) => { started(); await blocked; return append(...args); });
				try {
					const push = () => pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true }, row.raw);
					push();
					if (stage === "in-flight") await entered;
					const pushed = Array.from({ length: row.calls - 1 }, push);
					expect(existsSync(spillPath)).toBe(false);
					expect(pushed.at(-1)?.rawError?.split("\n")[0]).toBe("spill_queue_full=true");
					release();
					await settle(history);
					const stored = readFileSync(spillPath, "utf8").trimEnd().split("\n").map((line) => JSON.parse(line) as { ref: string; data: string });
					expect(stored.map((line) => line.ref)).toEqual(Array.from({ length: row.accepted }, (_, i) => String(i + 1)));
					expect(stored.every((line) => line.data === row.raw)).toBe(true);
					await history.cleanup();
				} finally { release(); spy.mockRestore(); }
			});
		}
	}

	test("pending evictions cancel writes and release live retention bytes", async () => {
		const limits = { ...defaultLimits, historyLimit: 1, maxRawSpillBytes: 400 };
		const history = new BridgeHistory(spillPath, () => limits);
		for (let i = 0; i < 5; i++) pushRaw(history, { ...makeEnvelope("message_end", 8), truncated: true }, { i });
		await settle(history);
		const lines = readFileSync(spillPath, "utf8").trimEnd().split("\n");
		expect(lines).toHaveLength(1);
		expect(JSON.parse(lines[0]!)).toMatchObject({ ref: "5", data: { i: 4 } });
		expect(history.rawSpillBytes).toBe(statSync(spillPath).size);
	});

	test("cleanup waits for an in-flight append and cancels the remaining queue", async () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits);
		const append = fs.promises.appendFile.bind(fs.promises);
		let release!: () => void;
		let started!: () => void;
		let finished!: () => void;
		const blocked = new Promise<void>((resolve) => { release = resolve; });
		const entered = new Promise<void>((resolve) => { started = resolve; });
		const completed = new Promise<void>((resolve) => { finished = resolve; });
		let calls = 0;
		const spy = spyOn(fs.promises, "appendFile").mockImplementation(async (...args) => {
			calls++;
			started();
			await blocked;
			await append(...args);
			finished();
		});
		try {
			pushRaw(history, { ...makeEnvelope("message_end"), truncated: true }, { text: "first" });
			pushRaw(history, { ...makeEnvelope("message_end"), truncated: true }, { text: "second" });
			await entered;
			const cleanup = history.cleanup();
			release();
			await cleanup;
			await completed;
			expect(calls).toBe(1);
			expect(history.count).toBe(0);
			expect(history.rawSpillBytes).toBe(0);
			expect(existsSync(spillPath)).toBe(false);
		} finally { release(); spy.mockRestore(); }
	});

	test("history retains the producer's serialized data without a second serialization", async () => {
		const history = new BridgeHistory(spillPath, () => defaultLimits);
		const data = { toJSON() { throw new Error("The producer already serialized this payload"); } };
		const envelope = { ...makeEnvelope("bridge_pong"), data };
		const json = history.push(envelope, undefined, '{"text":"retained"}');
		expect(JSON.parse(json).data).toEqual({ text: "retained" });
		const response = await history.buildResponse({ limit: 1, maxBytes: 4096 });
		expect(response.events[0]?.data).toEqual({ text: "retained" });
		expect(history.sizeBytes).toBe(Buffer.byteLength(json));
	});

	test("spill disabled flags rawError and skips sidecar writes", async () => {
		const limits: HistoryLimits = { ...defaultLimits, spillEnabled: false };
		const history = new BridgeHistory(spillPath, () => limits, () => undefined);
		const pushed = pushRaw(history, { ...makeEnvelope("message_end"), truncated: true, originalBytes: 200 }, { delta: "x".repeat(200) });
		await settle(history);
		expect(pushed.rawEventPath).toBeUndefined();
		await settle(history);
		expect(pushed.rawError?.split("\n")[0]).toBe("spill_enabled=false");
		expect(existsSync(spillPath)).toBe(false);
	});
});
