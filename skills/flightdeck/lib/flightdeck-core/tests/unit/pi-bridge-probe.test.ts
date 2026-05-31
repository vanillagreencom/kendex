// Unit tests for pi-bridge subprocess probes. These tests may spawn
// fake bridge commands and local Unix sockets; keep them out of paths.test.ts.

import { describe, expect, test } from "bun:test";
import { createServer, type Server } from "node:net";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { piBridgeStateProbe } from "../../src/paths/pi.ts";

function listenUnixSocket(path: string): Promise<Server> {
	const server = createServer();
	return new Promise((resolve, reject) => {
		server.once("error", reject);
		server.listen(path, () => {
			server.off("error", reject);
			resolve(server);
		});
	});
}

function closeServer(server: Server): Promise<void> {
	return new Promise((resolve) => server.close(() => resolve()));
}

describe("pi bridge probe", () => {
	test("piBridgeStateProbe SIGKILL-timeouts an unresponsive bridge child", async () => {
		const root = mkdtempSync(join(tmpdir(), "flightdeck-pi-timeout-"));
		const sock = join(root, "bridge.sock");
		const bin = join(root, "pi-bridge");
		writeFileSync(bin, "#!/usr/bin/env bash\nexec sleep 5\n");
		chmodSync(bin, 0o755);
		const server = await listenUnixSocket(sock);
		const oldBin = process.env.PI_BRIDGE_BIN;
		try {
			process.env.PI_BRIDGE_BIN = bin;
			const started = Date.now();
			const result = piBridgeStateProbe(process.pid, sock, 100);
			const elapsed = Date.now() - started;
			expect(result.ok).toBe(false);
			if (!result.ok) expect(result.reason).toBe("bridge-timeout");
			expect(elapsed).toBeLessThan(1000);
		} finally {
			if (oldBin === undefined) delete process.env.PI_BRIDGE_BIN;
			else process.env.PI_BRIDGE_BIN = oldBin;
			await closeServer(server);
			rmSync(root, { force: true, recursive: true });
		}
	});
});
