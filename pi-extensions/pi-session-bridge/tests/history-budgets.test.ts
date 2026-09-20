import { afterEach, beforeEach, describe, expect, setSystemTime, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import sessionBridge from "../extensions/session-bridge.ts";

import { fakePi, fakeCtx, sendCommand, shutdownBridge, writeBridgeSettings, type EventHandler } from "./lib/bridge-fixture.ts";

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

		await shutdownBridge(handlers, dir);
	});

	test("message_end spills the whole message and history --raw rehydrates it", async () => {
		writeBridgeSettings(dir);
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));

		const finalText = "x".repeat(50_000);
		await handlers.get("message_end")?.({ message: { role: "assistant", content: [{ type: "text", text: finalText }] } }, fakeCtx(dir));

		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
		expect(existsSync(socketPath)).toBe(true);

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

		await handlers.get("message_end")?.({ message: { role: "assistant", content: [{ type: "text", text: "z".repeat(50_000) }] } }, fakeCtx(dir));

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

		await handlers.get("message_end")?.({ message: { role: "assistant", content: [{ type: "text", text: "y".repeat(50_000) }] } }, fakeCtx(dir));

		const rawSpill = join(process.env.PI_BRIDGE_DIR!, "raw", `${process.pid}.jsonl`);
		expect(existsSync(rawSpill)).toBe(true);
		const lines = readFileSync(rawSpill, "utf8").split("\n").filter(Boolean);
		expect(lines.length).toBeGreaterThan(0);

		await shutdownBridge(handlers, dir);
		expect(existsSync(rawSpill)).toBe(false);
	});
});
