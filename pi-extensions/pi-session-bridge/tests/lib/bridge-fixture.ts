import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { HistoryEnvelope, HistoryResponse } from "../../extensions/event-history.ts";
import assert from "node:assert/strict";
import { createConnection, type Socket } from "node:net";
import { mkdirSync, writeFileSync } from "node:fs";
import { clearPackageConfigCache } from "../../extensions/package-config.ts";
import { runCli } from "./cli-fixture.ts";
import { dirname, join } from "node:path";

export type EventHandler = (event: unknown, ctx?: unknown) => unknown | Promise<unknown>;

interface FakePi {
	handlers: Map<string, EventHandler>;
	pi: ExtensionAPI;
}

export function fakePi(): FakePi {
	const handlers = new Map<string, EventHandler>();
	return {
		handlers,
		pi: {
			events: { emit: () => undefined, on: () => () => undefined },
			exec: async () => ({ code: 0, stdout: "" }),
			getCommands: () => [],
			getSessionName: () => undefined,
			getThinkingLevel: () => undefined,
			on: (eventName: string, handler: EventHandler) => {
				const previous = handlers.get(eventName);
				handlers.set(eventName, previous ? async (event, ctx) => {
					await previous(event, ctx);
					return handler(event, ctx);
				} : handler);
			},
			registerCommand: () => undefined,
			sendUserMessage: () => undefined,
		} as unknown as ExtensionAPI,
	};
}

export function writeBridgeSettings(root: string, extras: Record<string, unknown> = {}): void {
	const settingsPath = join(root, ".pi/settings.json");
	mkdirSync(dirname(settingsPath), { recursive: true });
	writeFileSync(settingsPath, JSON.stringify({
		kendex: {
			extensionManager: {
				config: {
					"@vanillagreen/pi-session-bridge": { enabled: true, ...extras },
				},
			},
		},
	}));
	// What pi-extension-manager's settings-changed event does after a write.
	clearPackageConfigCache();
}

export function fakeCtx(dir: string): ExtensionContext {
	return {
		cwd: dir,
		hasUI: false,
		isProjectTrusted: () => true,
		sessionManager: { getSessionId: () => "session-test" },
	} as unknown as ExtensionContext;
}

export async function shutdownBridge(handlers: Map<string, EventHandler>, dir: string): Promise<void> {
	const shutdown = handlers.get("session_shutdown");
	if (!shutdown) return;
	handlers.delete("session_shutdown");
	await shutdown({ reason: "test" }, fakeCtx(dir));
}

/** Keep a real event subscriber attached while the test produces terminal events. */
export async function attachSubscriber(socketPath: string): Promise<Socket> {
	const socket = createConnection(socketPath);
	await new Promise<void>((resolve, reject) => {
		socket.once("error", reject);
		socket.once("data", () => { socket.off("error", reject); resolve(); });
	});
	socket.on("data", () => undefined);
	return socket;
}

/** Read one complete event line from an attached bridge subscriber. */
export function readEvent(socket: Socket, eventName: string): Promise<HistoryEnvelope> {
	return new Promise((resolve, reject) => {
		let buffer = "";
		const cleanup = () => {
			socket.off("data", onData);
			socket.off("error", onError);
			socket.off("close", onClose);
		};
		const onError = (error: Error) => { cleanup(); reject(error); };
		const onClose = () => onError(new Error(`Bridge closed before ${eventName}`));
		const onData = (chunk: Buffer) => {
			buffer += chunk.toString("utf8");
			let newline: number;
			while ((newline = buffer.indexOf("\n")) >= 0) {
				const line = buffer.slice(0, newline);
				buffer = buffer.slice(newline + 1);
				try {
					const event = JSON.parse(line) as HistoryEnvelope;
					if (event.type === "event" && event.event === eventName) {
						cleanup();
						resolve(event);
						return;
					}
				} catch (error) { cleanup(); reject(error); return; }
			}
		};
		socket.on("data", onData);
		socket.once("error", onError);
		socket.once("close", onClose);
	});
}

export async function sendCommand(socketPath: string, payload: Record<string, unknown>): Promise<{ success: boolean; data: HistoryResponse }> {
	const result = await runCli(["request", "--socket", socketPath, JSON.stringify(payload)]);
	assert.equal(result.code, 0, result.stderr);
	return JSON.parse(result.stdout);
}
