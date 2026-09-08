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
	test("publish compacts noisy events and history --raw rehydrates from sidecar", async () => {
		writeBridgeSettings(dir);
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));

		const update = handlers.get("message_update");
		expect(typeof update).toBe("function");
		const hugeDelta = "x".repeat(50_000);
		await update?.({ role: "assistant", contentIndex: 0, type: "text", delta: hugeDelta }, fakeCtx(dir));

		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
		expect(existsSync(socketPath)).toBe(true);

		const compactResp = await sendCommand(socketPath, { id: "h1", type: "history", limit: 5 });
		expect(compactResp.success).toBe(true);
		const compactEvents = compactResp.data.events as Array<Record<string, unknown>>;
		const compactUpdate = compactEvents.find((entry) => entry.event === "message_update");
		expect(compactUpdate).toBeTruthy();
		expect(compactUpdate?.truncated).toBe(true);
		expect(typeof compactUpdate?.originalBytes).toBe("number");
		expect(typeof compactUpdate?.rawEventPath).toBe("string");
		expect(typeof compactUpdate?.rawEventRef).toBe("string");
		const compactData = compactUpdate?.data as Record<string, unknown>;
		expect(compactData.deltaLength).toBe(50_000);
		expect("delta" in compactData).toBe(false);
		expect(typeof compactData.deltaPreview).toBe("string");
		expect((compactData.deltaPreview as string).length).toBeLessThan(hugeDelta.length);
		expect(existsSync(compactUpdate?.rawEventPath as string)).toBe(true);

		const rawResp = await sendCommand(socketPath, { id: "h2", type: "history", limit: 5, raw: true });
		expect(rawResp.success).toBe(true);
		const rawEvents = rawResp.data.events as Array<Record<string, unknown>>;
		const rawUpdate = rawEvents.find((entry) => entry.event === "message_update");
		expect(rawUpdate?.rawRestored).toBe(true);
		const rawData = rawUpdate?.data as Record<string, unknown>;
		expect(rawData.delta).toBe(hugeDelta);

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

		const rawTight = await sendCommand(socketPath, { id: "rt3", type: "history", limit: 50, raw: true, maxBytes: 800 });
		expect(rawTight.success).toBe(true);
		const restored = (rawTight.data.events as Array<Record<string, unknown>>).filter((entry) => entry.rawRestored === true);
		expect(restored.length).toBeGreaterThan(0);
		expect(rawTight.data.responseTruncated).toBe(true);
		const rawNewest = (rawTight.data.events as Array<{ event: string; data: Record<string, unknown> }>)
			.filter((entry) => entry.event === "message_update").at(-1);
		expect(rawNewest?.data.contentIndex).toBe(11);

		await shutdownBridge(handlers, dir);
	});

	test("rehydration surfaces rawError when sidecar entry is corrupted", async () => {
		writeBridgeSettings(dir);
		process.chdir(dir);
		const { pi, handlers } = fakePi();
		activeHandlers = handlers;
		sessionBridge(pi);
		await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));

		await handlers.get("message_update")?.({ role: "assistant", contentIndex: 0, delta: "z".repeat(5_000) }, fakeCtx(dir));

		const rawSpill = join(process.env.PI_BRIDGE_DIR!, "raw", `${process.pid}.jsonl`);
		expect(existsSync(rawSpill)).toBe(true);
		writeFileSync(rawSpill, "not-json\n", { mode: 0o600 });

		const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
		const resp = await sendCommand(socketPath, { id: "rr1", type: "history", limit: 5, raw: true });
		expect(resp.success).toBe(true);
		const updateEvent = (resp.data.events as Array<Record<string, unknown>>).find((entry) => entry.event === "message_update");
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

		await handlers.get("message_update")?.({ role: "assistant", contentIndex: 0, delta: "y".repeat(10_000) }, fakeCtx(dir));

		const rawSpill = join(process.env.PI_BRIDGE_DIR!, "raw", `${process.pid}.jsonl`);
		expect(existsSync(rawSpill)).toBe(true);
		const lines = readFileSync(rawSpill, "utf8").split("\n").filter(Boolean);
		expect(lines.length).toBeGreaterThan(0);

		await shutdownBridge(handlers, dir);
		expect(existsSync(rawSpill)).toBe(false);
	});
});
