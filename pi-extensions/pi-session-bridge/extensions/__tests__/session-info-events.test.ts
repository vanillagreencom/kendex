import { expect, spyOn, test } from "bun:test";
import * as fs from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import sessionBridge, { BRIDGE_STREAM_EVENT_NAMES, REGISTRY_REFRESH_EVENT_NAMES } from "../session-bridge.js";
import { fakePi, fakeCtx, sendCommand, shutdownBridge, writeBridgeSettings } from "../../tests/lib/bridge-fixture.ts";

for (const eventName of new Set(["session_info_changed", ...BRIDGE_STREAM_EVENT_NAMES, ...REGISTRY_REFRESH_EVENT_NAMES])) {
	test(`${eventName} publishes once and updates registry when required`, async () => {
		const root = fs.mkdtempSync(join(tmpdir(), "bridge-events-"));
		const oldBridge = process.env.PI_BRIDGE_DIR;
		const oldAgent = process.env.PI_CODING_AGENT_DIR;
		const oldCwd = process.cwd();
		const fixture = fakePi();
		let writeSpy: ReturnType<typeof spyOn> | undefined;
		let deadline: ReturnType<typeof setTimeout> | undefined;
		try {
			writeBridgeSettings(root);
			process.chdir(root);
			const bridgeDir = join(root, "bridge");
			process.env.PI_BRIDGE_DIR = bridgeDir;
			process.env.PI_CODING_AGENT_DIR = join(root, "agent");
			let name = "before";
			fixture.pi.getSessionName = () => name;
			sessionBridge(fixture.pi);
			const ctx = fakeCtx(root);
			await fixture.handlers.get("session_start")!({ reason: "test" }, ctx);
			const registryPath = join(bridgeDir, "instances", `${process.pid}.json`);
			const writes: string[] = [];
			const writeFile = fs.promises.writeFile.bind(fs.promises);
			let resolveWrite: () => void = () => {};
			const written = new Promise<void>((resolve) => { resolveWrite = resolve; });
			writeSpy = spyOn(fs.promises, "writeFile").mockImplementation(async (...args) => {
				await writeFile(...args);
				if (args[0] === registryPath) { writes.push(String(args[1])); resolveWrite(); }
			});
			name = `after-${eventName}`;
			const handler = fixture.handlers.get(eventName);
			expect(typeof handler).toBe("function");
			await handler!({ name }, ctx);
			const refresh = eventName === "session_info_changed" || REGISTRY_REFRESH_EVENT_NAMES.has(eventName);
			if (refresh) {
				await Promise.race([written, new Promise<never>((_resolve, reject) => {
					deadline = setTimeout(() => reject(new Error("registry write deadline exceeded")), 2500);
				})]);
				clearTimeout(deadline);
				expect(writes).toHaveLength(1);
				expect(JSON.parse(fs.readFileSync(registryPath, "utf8"))).toMatchObject({ sessionName: name, lastReason: eventName });
			}
			const response = await sendCommand(join(bridgeDir, `pi-${process.pid}.sock`), { id: "events", type: "history", event: eventName, limit: 50 });
			expect(response.success).toBe(true);
			expect(response.data.events).toHaveLength(1);
			expect(response.data.events[0].event).toBe(eventName);
		} finally {
			clearTimeout(deadline);
			writeSpy?.mockRestore();
			try { await shutdownBridge(fixture.handlers, root); } finally {
				process.chdir(oldCwd);
				if (oldBridge === undefined) delete process.env.PI_BRIDGE_DIR; else process.env.PI_BRIDGE_DIR = oldBridge;
				if (oldAgent === undefined) delete process.env.PI_CODING_AGENT_DIR; else process.env.PI_CODING_AGENT_DIR = oldAgent;
				fs.rmSync(root, { recursive: true, force: true });
			}
		}
	});
}
