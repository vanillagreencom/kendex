import { afterEach, beforeEach, describe, expect, setSystemTime, spyOn, test } from "bun:test";
import { Buffer } from "node:buffer";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Socket } from "node:net";

import { clearPackageConfigCache } from "../extensions/package-config.ts";
import sessionBridge from "../extensions/session-bridge.ts";

import { fakePi, fakeCtx, attachSubscriber, readEvent, sendCommand, shutdownBridge, writeBridgeSettings, type EventHandler } from "./lib/bridge-fixture.ts";

let dir = "";
let activeHandlers: Map<string, EventHandler> | undefined;
let oldPiDir: string | undefined;
let oldBridgeDir: string | undefined;
let oldCwd = "";

beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "pi-session-bridge-history-"));
	oldBridgeDir = process.env.PI_BRIDGE_DIR;
	oldPiDir = process.env.PI_CODING_AGENT_DIR;
	process.env.PI_CODING_AGENT_DIR = join(dir, "agent");
	clearPackageConfigCache();
	oldCwd = process.cwd();
	process.env.PI_BRIDGE_DIR = join(dir, "bridge");
});

afterEach(async () => {
	try {
		if (activeHandlers) await shutdownBridge(activeHandlers, dir);
	} finally {
		activeHandlers = undefined;
		setSystemTime();
		if (oldPiDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = oldPiDir;
		clearPackageConfigCache();
	if (oldBridgeDir === undefined) delete process.env.PI_BRIDGE_DIR;
	else process.env.PI_BRIDGE_DIR = oldBridgeDir;
	process.chdir(oldCwd);
	if (dir) rmSync(dir, { recursive: true, force: true });
	}
});

describe("history byte budgets", () => {
	test("a streaming turn publishes delta-only envelopes and writes nothing to the sidecar", async () => {
		writeBridgeSettings(dir);
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));

		const update = handlers.get("message_update");
		expect(typeof update).toBe("function");
		const rawSpill = join(process.env.PI_BRIDGE_DIR!, "raw", `${process.pid}.jsonl`);
		// One turn: the cumulative message grows while each event carries one token.
		let cumulative = "";
		for (let i = 0; i < 200; i++) {
			cumulative += "token ".repeat(200);
			await update?.({
				message: { role: "assistant", content: [{ type: "text", text: cumulative }] },
				assistantMessageEvent: { type: "text_delta", contentIndex: 0, delta: "token ", partial: { role: "assistant", content: [{ type: "text", text: cumulative }] } },
			}, fakeCtx(dir));
		}
		expect(cumulative.length).toBeGreaterThan(200_000);
		expect(existsSync(rawSpill)).toBe(false);

		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
		// The stored envelope carries no explanation, so a streaming turn adds
		// no per-event bytes to history or to the broadcast.
		const compact = await sendCommand(socketPath, { id: "s0", type: "history", limit: 500 });
		expect(compact.success).toBe(true);
		const compactUpdates = (compact.data.events as Array<Record<string, unknown>>).filter((entry) => entry.event === "message_update");
		expect(compactUpdates.length).toBe(200);
		expect(compactUpdates.every((entry) => entry.rawError === undefined)).toBe(true);

		const resp = await sendCommand(socketPath, { id: "s1", type: "history", limit: 500, raw: true });
		expect(resp.success).toBe(true);
		const updates = (resp.data.events as Array<Record<string, unknown>>).filter((entry) => entry.event === "message_update");
		expect(updates.length).toBe(200);
		for (const entry of updates) {
			expect(entry.rawEventPath).toBeUndefined();
			expect(entry.rawEventRef).toBeUndefined();
			expect(entry.rawRestored).toBeUndefined();
			expect(entry.originalBytes).toBe(6);
			// A --raw request says why nothing was restored, so a delta-only
			// envelope never reads as a spill that failed.
			expect((entry.rawError as string).split("\n")[0]).toBe("raw_retained=false");
			const data = entry.data as Record<string, unknown>;
			expect(data).toEqual({ role: "assistant", type: "text_delta", contentIndex: 0, deltaLength: 6, deltaBytes: 6, deltaPreview: "token " });
		}

		// The delta-only note is optional detail, so it is charged against the
		// response cap like a rehydrated payload rather than added on top.
		const capped = await sendCommand(socketPath, { id: "s2", type: "history", limit: 500, raw: true, maxBytes: 4_096 });
		expect(capped.success).toBe(true);
		const cappedEvents = capped.data.events as Array<Record<string, unknown>>;
		const cappedBytes = cappedEvents.reduce((total, entry) => total + Buffer.byteLength(JSON.stringify(entry), "utf8"), 0);
		expect(cappedBytes).toBeLessThanOrEqual(4_096);
		expect(capped.data.responseTruncated).toBe(true);

		await shutdownBridge(handlers, dir);
	});

	test("terminal events without an attached subscriber keep only compact history", async () => {
		writeBridgeSettings(dir);
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));
		let serializations = 0;
		await handlers.get("tool_execution_end")?.({ toolName: "probe", result: { toJSON() { serializations++; return { text: "x".repeat(1_000_000) }; } } }, fakeCtx(dir));
		expect(serializations).toBe(1);
		const rawSpill = join(process.env.PI_BRIDGE_DIR!, "raw", `${process.pid}.jsonl`);
		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
		const response = await sendCommand(socketPath, { type: "history", event: "tool_execution_end", raw: true });
		expect(response.data.events).toHaveLength(1);
		expect(response.data.events[0]?.rawError?.split("\n")[0]).toBe("spill_subscriber=false");
		expect(response.data.events[0]?.rawRestored).toBeUndefined();
		expect(existsSync(rawSpill)).toBe(false);
	});

	test("terminal event publication serializes compact JSON once regardless of subscriber count", async () => {
		// Pi produces tool_execution_end; bridge subscribers receive its compact envelope.
		// Disable spill so worker metadata updates cannot enter the publication count.
		writeBridgeSettings(dir, { spillRawEvents: false, eventPreviewBytes: 16 });
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")!({ reason: "test" }, fakeCtx(dir));
		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
		const subscribers: Socket[] = [];
		const payload = { toolName: "probe", toolUseId: "call-1", isError: false, result: "x".repeat(1024) };
		const originalBytes = Buffer.byteLength(JSON.stringify(payload), "utf8");
		const stringify = JSON.stringify;
		try {
			for (const count of [1, 3]) {
				while (subscribers.length < count) subscribers.push(await attachSubscriber(socketPath));
				const received = subscribers.map((socket) => readEvent(socket, "tool_execution_end"));
				const calls = { original: 0, compact: 0, envelope: 0 };
				const spy = spyOn(JSON, "stringify").mockImplementation((...args) => {
					const value = args[0] as Record<string, unknown> | undefined;
					if (value?.toolName === "probe") {
						if (value.result !== undefined) calls.original++;
						else if (value.resultPreview !== undefined) calls.compact++;
					}
					if (value?.event === "tool_execution_end") calls.envelope++;
					return stringify(...args);
				});
				try { await handlers.get("tool_execution_end")!(payload, fakeCtx(dir)); }
				finally { spy.mockRestore(); }
				const events = await Promise.all(received);
				expect(calls).toEqual({ original: 1, compact: 1, envelope: 1 });
				expect(events).toHaveLength(count);
				for (const event of events) {
					expect(event).toMatchObject({
						type: "event", event: "tool_execution_end",
						truncated: true, originalBytes,
						data: { toolName: "probe", toolUseId: "call-1", isError: false, resultBytes: 1024, resultPreview: "x".repeat(16) },
					});
					expect(typeof event.timestamp).toBe("string");
					expect(event.rawError?.split("\n")[0]).toBe("spill_enabled=false");
					expect(event).toEqual(events[0]);
				}
			}
		} finally {
			try {
				await shutdownBridge(handlers, dir);
			} finally {
				for (const socket of subscribers) socket.destroy();
			}
		}
	});

	test("message_end spills the whole message and history --raw rehydrates it", async () => {
		writeBridgeSettings(dir);
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));
		await attachSubscriber(join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`));

		const finalText = "x".repeat(50_000);
		await handlers.get("message_end")?.({ message: { role: "assistant", content: [{ type: "text", text: finalText }] } }, fakeCtx(dir));

		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
		expect(existsSync(socketPath)).toBe(true);

		await sendCommand(socketPath, { type: "history", raw: true });
		const compactResp = await sendCommand(socketPath, { id: "h1", type: "history", limit: 5 });
		expect(compactResp.success).toBe(true);
		const compactEnd = (compactResp.data.events as Array<Record<string, unknown>>).find((entry) => entry.event === "message_end");
		expect(compactEnd?.truncated).toBe(true);
		expect(compactEnd?.originalBytes).toBeGreaterThan(50_000);
		expect(typeof compactEnd?.rawEventPath).toBe("string");
		expect(typeof compactEnd?.rawEventRef).toBe("string");
		expect(existsSync(compactEnd?.rawEventPath as string)).toBe(true);

		const rawResp = await sendCommand(socketPath, { id: "h2", type: "history", limit: 5, raw: true });
		expect(rawResp.success).toBe(true);
		const rawEnd = (rawResp.data.events as Array<Record<string, unknown>>).find((entry) => entry.event === "message_end");
		expect(rawEnd?.rawRestored).toBe(true);
		const restored = (rawEnd?.data as { message: { content: Array<{ text: string }> } }).message;
		expect(restored.content[0]?.text).toBe(finalText);

		await shutdownBridge(handlers, dir);
	});

	test("history honors event and since filters", async () => {
		setSystemTime(new Date("2026-05-20T00:00:00.000Z"));
		writeBridgeSettings(dir);
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));

		setSystemTime(new Date("2026-05-21T00:00:00.000Z"));
		await handlers.get("message_update")?.({ role: "assistant", contentIndex: 0, delta: "first" }, fakeCtx(dir));
		const turnStart = new Date("2026-05-21T00:00:01.000Z");
		setSystemTime(turnStart);
		await handlers.get("tool_execution_end")?.({ toolName: "Read", toolUseId: "t1", status: "success", result: "result body" }, fakeCtx(dir));
		await handlers.get("message_update")?.({ role: "assistant", contentIndex: 1, delta: "second" }, fakeCtx(dir));

		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);

		const filtered = await sendCommand(socketPath, { id: "f1", type: "history", limit: 50, event: "message_update" });
		expect(filtered.success).toBe(true);
		const filteredEvents = filtered.data.events as Array<{ event: string }>;
		expect(filteredEvents.every((entry) => entry.event === "message_update")).toBe(true);
		expect(filteredEvents).toHaveLength(2);

		const sinceResp = await sendCommand(socketPath, { id: "f2", type: "history", limit: 50, since: turnStart.toISOString() });
		expect(sinceResp.success).toBe(true);
		const sinceEvents = sinceResp.data.events as Array<{ event: string }>;
		expect(sinceEvents.map((entry) => entry.event)).toEqual(["tool_execution_end", "message_update"]);

		await shutdownBridge(handlers, dir);
	});

	test("history evicts oldest envelopes once total byte budget is exceeded", async () => {
		writeBridgeSettings(dir, { maxHistoryBytes: 1_500, maxEventBytes: 65_536, eventPreviewBytes: 32 });
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));

		const update = handlers.get("message_update");
		for (let i = 0; i < 30; i++) {
			await update?.({ role: "assistant", contentIndex: i, delta: `chunk-${i}-${"a".repeat(40)}` }, fakeCtx(dir));
		}

		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
		const resp = await sendCommand(socketPath, { id: "b1", type: "history", limit: 500 });
		expect(resp.success).toBe(true);
		const events = resp.data.events as Array<Record<string, unknown>>;
		const messageEvents = events.filter((entry) => entry.event === "message_update");
		expect(messageEvents.length).toBeLessThan(30);
		expect(messageEvents.length).toBeGreaterThan(0);
		const lastIndex = (messageEvents.at(-1)?.data as Record<string, unknown>).contentIndex;
		expect(lastIndex).toBe(29);

		await shutdownBridge(handlers, dir);
	});

	test("history response cap evicts oldest envelopes and reports responseTruncated", async () => {
		writeBridgeSettings(dir, { maxEventBytes: 65_536, eventPreviewBytes: 16 });
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));

		const update = handlers.get("message_update");
		for (let i = 0; i < 12; i++) {
			await update?.({ role: "assistant", contentIndex: i, delta: `delta-${i}` }, fakeCtx(dir));
		}

		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
		const tight = await sendCommand(socketPath, { id: "rt1", type: "history", limit: 50, maxBytes: 600 });
		expect(tight.success).toBe(true);
		expect(tight.data.responseTruncated).toBe(true);
		expect(typeof tight.data.totalEvents).toBe("number");
		const tightEvents = tight.data.events as Array<{ event: string; data: Record<string, unknown> }>;
		expect(tightEvents.length).toBeLessThan(tight.data.totalEvents);
		expect(tightEvents.length).toBeGreaterThan(0);
		const newestCompact = tightEvents.filter((entry) => entry.event === "message_update").at(-1);
		expect(newestCompact?.data.contentIndex).toBe(11);

		const generous = await sendCommand(socketPath, { id: "rt2", type: "history", limit: 50, maxBytes: 1024 * 1024 });
		expect(generous.success).toBe(true);
		expect(generous.data.responseTruncated).toBe(false);

		await shutdownBridge(handlers, dir);
	});

	test("the response cap also trims rehydrated envelopes", async () => {
		writeBridgeSettings(dir, { maxEventBytes: 120, eventPreviewBytes: 16 });
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));
		await attachSubscriber(join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`));

		// Above maxEventBytes, so each terminal message spills a small raw line.
		const end = handlers.get("message_end");
		for (let i = 0; i < 4; i++) {
			await end?.({ message: { role: "assistant", content: [{ type: "text", text: `final-${i}-${"m".repeat(200)}` }] } }, fakeCtx(dir));
		}

		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
		const rawTight = await sendCommand(socketPath, { id: "rt3", type: "history", limit: 50, raw: true, maxBytes: 1_300 });
		expect(rawTight.success).toBe(true);
		const restored = (rawTight.data.events as Array<Record<string, unknown>>).filter((entry) => entry.rawRestored === true);
		expect(restored.length).toBeGreaterThan(0);
		expect(rawTight.data.responseTruncated).toBe(true);
		const newestRestored = restored.at(-1)?.data as { message: { content: Array<{ text: string }> } };
		expect(newestRestored.message.content[0]?.text.startsWith("final-3-")).toBe(true);

		await shutdownBridge(handlers, dir);
	});

	test("rehydration surfaces rawError when sidecar entry is corrupted", async () => {
		writeBridgeSettings(dir);
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));
		await attachSubscriber(join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`));

		await handlers.get("message_end")?.({ message: { role: "assistant", content: [{ type: "text", text: "z".repeat(50_000) }] } }, fakeCtx(dir));

		await sendCommand(join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`), { type: "history", raw: true });
		const rawSpill = join(process.env.PI_BRIDGE_DIR!, "raw", `${process.pid}.jsonl`);
		expect(existsSync(rawSpill)).toBe(true);
		writeFileSync(rawSpill, "not-json\n", { mode: 0o600 });

		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
		const resp = await sendCommand(socketPath, { id: "rr1", type: "history", limit: 5, raw: true });
		expect(resp.success).toBe(true);
		const updateEvent = (resp.data.events as Array<Record<string, unknown>>).find((entry) => entry.event === "message_end");
		expect(updateEvent?.rawRestored).not.toBe(true);
		expect((updateEvent?.rawError as string).split("\n")[0]).toBe("error_code=SyntaxError");
		expect(Array.isArray(resp.data.rawErrors)).toBe(true);

		await shutdownBridge(handlers, dir);
	});

	test("session_shutdown cleans up the raw spill sidecar", async () => {
		writeBridgeSettings(dir);
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));
		await attachSubscriber(join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`));

		await handlers.get("message_end")?.({ message: { role: "assistant", content: [{ type: "text", text: "y".repeat(50_000) }] } }, fakeCtx(dir));

		await sendCommand(join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`), { type: "history", raw: true });
		const rawSpill = join(process.env.PI_BRIDGE_DIR!, "raw", `${process.pid}.jsonl`);
		expect(existsSync(rawSpill)).toBe(true);
		const lines = readFileSync(rawSpill, "utf8").split("\n").filter(Boolean);
		expect(lines.length).toBeGreaterThan(0);

		await shutdownBridge(handlers, dir);
		expect(existsSync(rawSpill)).toBe(false);
	});
});
