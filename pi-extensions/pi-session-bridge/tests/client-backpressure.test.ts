import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import * as net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

import sessionBridge, { CLIENT_QUEUE_MAX_BYTES } from "../extensions/session-bridge.ts";

import { fakeCtx, fakePi, shutdownBridge, writeBridgeSettings, type EventHandler } from "./lib/bridge-fixture.ts";

let dir = "";
let activeHandlers: Map<string, EventHandler> | undefined;
const saved = { cwd: "", piDir: undefined as string | undefined, bridgeDir: undefined as string | undefined };

beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "pi-session-bridge-backpressure-"));
	saved.cwd = process.cwd();
	saved.piDir = process.env.PI_CODING_AGENT_DIR;
	saved.bridgeDir = process.env.PI_BRIDGE_DIR;
	process.env.PI_CODING_AGENT_DIR = join(dir, "agent");
	process.env.PI_BRIDGE_DIR = join(dir, "bridge");
});

afterEach(async () => {
	try {
		if (activeHandlers) await shutdownBridge(activeHandlers, dir);
	} finally {
		activeHandlers = undefined;
		process.chdir(saved.cwd);
		if (saved.piDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = saved.piDir;
		if (saved.bridgeDir === undefined) delete process.env.PI_BRIDGE_DIR;
		else process.env.PI_BRIDGE_DIR = saved.bridgeDir;
		rmSync(dir, { recursive: true, force: true });
	}
});

test("a subscriber that stops reading is disconnected once its unsent bytes pass the bound", async () => {
	writeBridgeSettings(dir);
	process.chdir(dir);
	const { pi, handlers } = fakePi();
	activeHandlers = handlers;
	sessionBridge(pi);
	await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));

	const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
	const client = net.createConnection(socketPath);
	await new Promise<void>((resolve, reject) => { client.once("connect", resolve); client.once("error", reject); });
	client.pause();
	let closed = false;
	client.on("close", () => { closed = true; });
	client.on("error", () => {});

	// About three times the bound, in envelopes under the 8 KiB event cap.
	// turn_end has no compactor, so each envelope carries this 7 KiB field whole.
	const turnEnd = handlers.get("turn_end")!;
	const note = "x".repeat(7 * 1024);
	let sentBytes = 0;
	for (let index = 0; sentBytes < CLIENT_QUEUE_MAX_BYTES * 3; index++) {
		await turnEnd({ type: "turn_end", turnIndex: index, note }, fakeCtx(dir));
		sentBytes += note.length;
	}

	let received = 0;
	client.on("data", (chunk) => { received += chunk.length; });
	client.resume();
	const deadline = Date.now() + 10_000;
	while (!closed && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
	expect(closed).toBe(true);
	expect(received).toBeLessThan(sentBytes);
}, 30_000);
