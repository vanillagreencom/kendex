import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import * as net from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { clearPackageConfigCache } from "../extensions/package-config.ts";
import sessionBridge, { CLIENT_CLOSE_GRACE_MS } from "../extensions/session-bridge.ts";

import { fakeCtx, fakePi, writeBridgeSettings } from "./lib/bridge-fixture.ts";

let dir = "";
const saved = { cwd: "", piDir: undefined as string | undefined, bridgeDir: undefined as string | undefined };

beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "pi-session-bridge-shutdown-"));
	saved.cwd = process.cwd();
	saved.piDir = process.env.PI_CODING_AGENT_DIR;
	saved.bridgeDir = process.env.PI_BRIDGE_DIR;
	process.env.PI_CODING_AGENT_DIR = join(dir, "agent");
	clearPackageConfigCache();
	process.env.PI_BRIDGE_DIR = join(dir, "bridge");
});

afterEach(() => {
	process.chdir(saved.cwd);
	if (saved.piDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
	else process.env.PI_CODING_AGENT_DIR = saved.piDir;
	clearPackageConfigCache();
	if (saved.bridgeDir === undefined) delete process.env.PI_BRIDGE_DIR;
	else process.env.PI_BRIDGE_DIR = saved.bridgeDir;
	rmSync(dir, { recursive: true, force: true });
});

test("shutdown finishes within the close grace while a client never closes its connection", async () => {
	writeBridgeSettings(dir);
	process.chdir(dir);
	const { pi, handlers } = fakePi();
	sessionBridge(pi);
	await handlers.get("session_start")?.({ reason: "test" }, fakeCtx(dir));

	const socketPath = join(process.env.PI_BRIDGE_DIR!, `pi-${process.pid}.sock`);
	// allowHalfOpen keeps this end writable after the bridge's FIN, so the
	// client never closes its side: a peer that is stopped or wedged.
	const client = net.createConnection({ path: socketPath, allowHalfOpen: true });
	await new Promise<void>((resolve, reject) => { client.once("data", () => resolve()); client.once("error", reject); });
	client.on("error", () => {});
	client.on("data", () => {});
	try {
		const shutdown = Promise.resolve(handlers.get("session_shutdown")?.({ reason: "test" }, fakeCtx(dir))).then(() => "stopped");
		const deadline = new Promise((resolve) => setTimeout(() => resolve("hung"), CLIENT_CLOSE_GRACE_MS + 5_000));
		// The server's close callback fires only once every connection is gone, so
		// "stopped" proves the bridge destroyed the client's connection.
		expect(await Promise.race([shutdown, deadline])).toBe("stopped");
		expect(existsSync(socketPath)).toBe(false);
	} finally {
		client.destroy();
	}
}, 30_000);
