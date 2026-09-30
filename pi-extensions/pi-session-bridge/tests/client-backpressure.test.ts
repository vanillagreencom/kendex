import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import * as net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { clearPackageConfigCache } from "../extensions/package-config.ts";
import sessionBridge, { CLIENT_QUEUE_MAX_BYTES, CLIENT_STALLED_KEY } from "../extensions/session-bridge.ts";

import { fakeCtx, fakePi, sendCommand, shutdownBridge, writeBridgeSettings, type EventHandler } from "./lib/bridge-fixture.ts";

let dir = "";
let activeHandlers: Map<string, EventHandler> | undefined;
const saved = { cwd: "", piDir: undefined as string | undefined, bridgeDir: undefined as string | undefined };

beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "pi-session-bridge-backpressure-"));
	saved.cwd = process.cwd();
	saved.piDir = process.env.PI_CODING_AGENT_DIR;
	saved.bridgeDir = process.env.PI_BRIDGE_DIR;
	process.env.PI_CODING_AGENT_DIR = join(dir, "agent");
	clearPackageConfigCache();
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
		clearPackageConfigCache();
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
	// A session with a UI, so the user is told the stalled client was dropped.
	const notices: Array<{ text: string; level: string }> = [];
	const uiCtx = { ...fakeCtx(dir), hasUI: true, ui: { notify: (text: string, level: string) => { notices.push({ text, level }); }, setStatus: () => {} } } as unknown as ExtensionContext;
	await handlers.get("session_start")?.({ reason: "test" }, uiCtx);

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
		await turnEnd({ type: "turn_end", turnIndex: index, note }, uiCtx);
		sentBytes += note.length;
	}

	let received = 0;
	client.on("data", (chunk) => { received += chunk.length; });
	client.resume();
	const deadline = Date.now() + 10_000;
	while ((!closed || notices.length === 0) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 10));
	expect(closed).toBe(true);
	expect(received).toBeLessThan(sentBytes);
	const warnings = notices.filter((notice) => notice.level === "warning");
	expect(warnings).toHaveLength(1);
	expect(warnings[0]!.text).toStartWith(`Session bridge: ${CLIENT_STALLED_KEY}=`);
}, 30_000);

test("one response larger than the bound reaches a client that reads it", async () => {
	writeBridgeSettings(dir);
	process.chdir(dir);
	const { pi, handlers } = fakePi();
	activeHandlers = handlers;
	sessionBridge(pi);
	await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));
	// message_end spills the whole message, and history --raw restores it into one response line.
	const finalText = "x".repeat(CLIENT_QUEUE_MAX_BYTES + 1024 * 1024);
	await handlers.get("message_end")?.({ message: { role: "assistant", content: [{ type: "text", text: finalText }] } }, fakeCtx(dir));
	const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
	const response = await sendCommand(socketPath, { id: "big", type: "history", limit: 1, raw: true });
	const restored = (response.data.events[0]?.data as { message: { content: Array<{ text: string }> } } | undefined)?.message.content[0]?.text;
	expect(restored?.length).toBe(finalText.length);
}, 30_000);

test("pi-bridge stream stops reading while its stdout is full, delivers every line once drained, and exits non-zero when the bridge closes", async () => {
	const socketPath = join(dir, "fake.sock");
	const line = `${JSON.stringify({ type: "event", data: "y".repeat(1000) })}\n`;
	const lines = 16 * 1024;
	let server: net.Socket | undefined;
	const listener = net.createServer((socket) => {
		server = socket;
		// A reader that exits early resets the socket; the assertions report it.
		socket.on("error", () => {});
		socket.once("data", () => {
			for (let index = 0; index < lines; index++) socket.write(line);
		});
	});
	await new Promise<void>((resolveListen) => listener.listen(socketPath, resolveListen));
	const cli = resolve(dirname(fileURLToPath(import.meta.url)), "../bin/pi-bridge.js");
	// Bun 1.3 drains a spawned child's stdout pipe before any listener attaches,
	// so pi-bridge's stdout goes to a cat that starts only once a line arrives on
	// fd 3; until then pi-bridge's stdout fills on every runtime. The shell exits
	// with pi-bridge's status.
	const script = 'exec 3<&0; node "$1" stream --socket "$2" </dev/null | { read -r _ <&3; exec cat; }; exit "${PIPESTATUS[0]}"';
	const child = spawn("bash", ["-c", script, "pi-bridge-gate", cli, socketPath], { stdio: ["pipe", "pipe", "pipe"], env: { PATH: process.env.PATH, HOME: dir } });
	try {
		let stderr = "";
		child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
		const exited = new Promise<number | null>((resolveExit) => child.once("close", resolveExit));
		// stdout is not read yet. A reader that kept reading would take the whole
		// 16 MiB off the socket; a paused one leaves most of it queued at the bridge.
		const deadline = Date.now() + 10_000;
		while ((server?.bytesWritten ?? 0) < line.length * lines / 2 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 10));
		// A wait long enough for a reader that did not pause to drain the socket.
		await new Promise((r) => setTimeout(r, 1000));
		const unreadAtBridge = server!.writableLength;
		let received = 0;
		child.stdout.on("data", (chunk: Buffer) => { received += chunk.length; });
		child.stdin.end("\n");
		while (received < line.length * lines && Date.now() < deadline + 10_000) await new Promise((r) => setTimeout(r, 10));
		server!.end();
		expect({ unreadAtBridge: unreadAtBridge > CLIENT_QUEUE_MAX_BYTES, received, code: await exited, stderr: stderr.split("\n")[0] })
			.toEqual({ unreadAtBridge: true, received: line.length * lines, code: 1, stderr: "bridge-stream-closed" });
	} finally {
		// Killing bash leaves pi-bridge running; closing its socket ends it.
		child.kill("SIGKILL");
		server?.destroy();
		await new Promise<void>((resolveClose) => listener.close(() => resolveClose()));
	}
}, 30_000);
