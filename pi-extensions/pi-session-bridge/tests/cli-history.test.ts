import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync, unlinkSync } from "node:fs";
import * as net from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const BRIDGE_BIN = resolve(__dirname, "..", "bin", "pi-bridge.js");

interface CapturedCommand {
	raw: string;
	parsed: Record<string, unknown>;
}

interface FakeBridge {
	socketPath: string;
	captured: CapturedCommand[];
	close: () => Promise<void>;
}

async function startFakeBridge(dir: string, responder?: (cmd: Record<string, unknown>) => Record<string, unknown>): Promise<FakeBridge> {
	const socketPath = join(dir, "fake.sock");
	const captured: CapturedCommand[] = [];
	const server = net.createServer((socket) => {
		let buffer = "";
		socket.setEncoding("utf8");
		socket.write(`${JSON.stringify({ type: "bridge_hello", protocol: "pi-session-bridge.v1" })}\n`);
		socket.on("data", (chunk) => {
			buffer += chunk;
			while (true) {
				const nl = buffer.indexOf("\n");
				if (nl === -1) break;
				const line = buffer.slice(0, nl).replace(/\r$/, "");
				buffer = buffer.slice(nl + 1);
				if (!line) continue;
				let parsed: Record<string, unknown>;
				try {
					parsed = JSON.parse(line) as Record<string, unknown>;
				} catch {
					continue;
				}
				captured.push({ raw: line, parsed });
				const id = parsed.id ?? "fake";
				const reply = responder ? responder(parsed) : { events: [], totalEvents: 0, responseTruncated: false };
				socket.write(`${JSON.stringify({ type: "response", id, command: parsed.type, success: true, data: reply })}\n`);
			}
		});
	});
	await new Promise<void>((resolveServer, reject) => {
		server.once("error", reject);
		server.listen(socketPath, () => {
			server.off("error", reject);
			resolveServer();
		});
	});
	return {
		socketPath,
		captured,
		close: () =>
			new Promise<void>((resolveClose) => {
				server.close(() => {
					try { unlinkSync(socketPath); } catch { /* ignore */ }
					resolveClose();
				});
			}),
	};
}

async function runCli(args: string[]): Promise<{ stdout: string; stderr: string; code: number }> {
	return new Promise((resolveProcess, rejectProcess) => {
		const child = spawn("node", [BRIDGE_BIN, ...args], { stdio: ["ignore", "pipe", "pipe"] });
		let stdout = "";
		let stderr = "";
		child.stdout.on("data", (chunk) => { stdout += chunk.toString("utf8"); });
		child.stderr.on("data", (chunk) => { stderr += chunk.toString("utf8"); });
		child.on("error", rejectProcess);
		child.on("close", (code) => resolveProcess({ stdout, stderr, code: code ?? -1 }));
	});
}

let dir = "";
let bridge: FakeBridge | undefined;

beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "pi-bridge-cli-"));
});

afterEach(async () => {
	if (bridge) {
		await bridge.close();
		bridge = undefined;
	}
	if (dir) rmSync(dir, { recursive: true, force: true });
});

describe("pi-bridge history CLI", () => {
	test("forwards --raw, --event, --since, --max-bytes, and limit positional", async () => {
		bridge = await startFakeBridge(dir);
		const since = "2026-05-21T00:00:00.000Z";
		const result = await runCli([
			"history",
			"--socket",
			bridge.socketPath,
			"30",
			"--raw",
			"--event",
			"message_update",
			"--since",
			since,
			"--max-bytes",
			"4096",
		]);
		expect(result.code).toBe(0);
		expect(bridge.captured).toHaveLength(1);
		const cmd = bridge.captured[0]!.parsed;
		expect(cmd.type).toBe("history");
		expect(cmd.limit).toBe(30);
		expect(cmd.raw).toBe(true);
		expect(cmd.event).toBe("message_update");
		expect(cmd.since).toBe(since);
		expect(cmd.maxBytes).toBe(4096);
		expect(typeof cmd.id).toBe("string");
	});

	test("treats --verbose as an alias for --raw", async () => {
		bridge = await startFakeBridge(dir);
		const result = await runCli([
			"history",
			"--socket",
			bridge.socketPath,
			"--verbose",
		]);
		expect(result.code).toBe(0);
		expect(bridge.captured).toHaveLength(1);
		expect(bridge.captured[0]!.parsed.raw).toBe(true);
		expect("limit" in bridge.captured[0]!.parsed).toBe(false);
	});

	test("default history call omits raw/event/since fields", async () => {
		bridge = await startFakeBridge(dir);
		const result = await runCli([
			"history",
			"--socket",
			bridge.socketPath,
			"10",
		]);
		expect(result.code).toBe(0);
		const cmd = bridge.captured[0]!.parsed;
		expect(cmd.type).toBe("history");
		expect(cmd.limit).toBe(10);
		expect("raw" in cmd).toBe(false);
		expect("event" in cmd).toBe(false);
		expect("since" in cmd).toBe(false);
		expect("maxBytes" in cmd).toBe(false);
	});

	test("ignores non-numeric --max-bytes and falls back to bridge default", async () => {
		bridge = await startFakeBridge(dir);
		const result = await runCli([
			"history",
			"--socket",
			bridge.socketPath,
			"--max-bytes",
			"not-a-number",
		]);
		expect(result.code).toBe(0);
		expect("maxBytes" in bridge.captured[0]!.parsed).toBe(false);
	});
});
