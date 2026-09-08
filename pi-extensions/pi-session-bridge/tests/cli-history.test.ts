import { afterEach, beforeEach, expect, test } from "bun:test";
import { runCli } from "./lib/cli-fixture.ts";
import { mkdtempSync, rmSync, unlinkSync } from "node:fs";
import * as net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";


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
	const sockets = new Set<net.Socket>();
	const server = net.createServer((socket) => {
		sockets.add(socket);
		socket.once("close", () => sockets.delete(socket));
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
				for (const socket of sockets) socket.destroy();
				server.close(() => {
					try { unlinkSync(socketPath); } catch { /* ignore */ }
					resolveClose();
				});
			}),
	};
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

for (const row of [
	{ name: "raw and filters", args: ["30", "--raw", "--event", "message_update", "--since", "2026-05-21T00:00:00.000Z", "--max-bytes", "4096"], expected: { type: "history", limit: 30, raw: true, event: "message_update", since: "2026-05-21T00:00:00.000Z", maxBytes: 4096 } },
	{ name: "verbose alias omits limit", args: ["--verbose"], expected: { type: "history", raw: true } },
	{ name: "default omits optional filters", args: ["10"], expected: { type: "history", limit: 10 } },
	{ name: "non-numeric budget falls back", args: ["--max-bytes", "not-a-number"], expected: { type: "history" } },
]) {
	test(`history CLI ${row.name}`, async () => {
		bridge = await startFakeBridge(dir);
		const result = await runCli(["history", "--socket", bridge.socketPath, ...row.args]);
		expect(result.code).toBe(0);
		expect(bridge.captured).toHaveLength(1);
		const { id, ...command } = bridge.captured[0]!.parsed;
		expect(typeof id).toBe("string");
		expect(command).toEqual(row.expected);
	});
}
