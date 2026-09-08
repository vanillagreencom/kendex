import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { HistoryResponse } from "../../extensions/event-history.ts";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
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

export async function sendCommand(socketPath: string, payload: Record<string, unknown>): Promise<{ success: boolean; data: HistoryResponse }> {
	const result = await runCli(["request", "--socket", socketPath, JSON.stringify(payload)]);
	assert.equal(result.code, 0, result.stderr);
	return JSON.parse(result.stdout);
}
