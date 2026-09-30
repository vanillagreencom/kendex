import { test } from "node:test";
import assert from "node:assert/strict";
import caveman from "../extensions/caveman.ts";
import { CONFIG_ID } from "../extensions/prompt.ts";
import { SETTINGS_CHANGED_EVENT } from "../extensions/package-config.ts";
import { settingsFixture } from "./lib/settings-fixture.ts";

/** A Pi whose `on` and `events.on` record their handlers, in the order Pi
 * would call them. */
function fakePi() {
	const handlers = new Map<string, Array<(event: unknown, ctx: unknown) => void>>();
	const listeners: Array<{ channel: string; handler: (data: unknown) => void }> = [];
	const pi = {
		on(event: string, handler: (event: unknown, ctx: unknown) => void) { handlers.set(event, [...(handlers.get(event) ?? []), handler]); },
		events: {
			on(channel: string, handler: (data: unknown) => void) {
				const listener = { channel, handler };
				listeners.push(listener);
				return () => { listeners.splice(listeners.indexOf(listener), 1); };
			},
		},
		registerCommand() {},
		appendEntry() {},
	};
	return {
		pi,
		fire(event: string, ctx: unknown) { for (const handler of handlers.get(event) ?? []) handler({}, ctx); },
		emit(channel: string, data: unknown) { for (const listener of [...listeners]) if (listener.channel === channel) listener.handler(data); },
	};
}

// The mode handler subscribes when the extension loads, before the shared
// cache refresh subscribes at session start, so it runs first and must drop
// the memo itself. The clock is held still, so only that drop lets it see the
// new mode inside the settings window.
test("a mode change announced inside the settings window applies the new mode", (t) => {
	const fixture = settingsFixture(t);
	t.mock.method(performance, "now", () => 0);
	const statuses: Array<string | undefined> = [];
	const ctx = {
		cwd: fixture.projectDir,
		hasUI: true,
		ui: { setStatus: (_key: string, value: string | undefined) => { statuses.push(value); }, notify() {} },
		sessionManager: { getSessionId: () => "settings-changed", getSessionFile: () => undefined, getBranch: () => [] },
	};
	const host = fakePi();
	caveman(host.pi as never);
	fixture.writeConfig(fixture.userPath, { [CONFIG_ID]: { mode: "lite" } });
	host.fire("session_start", ctx);
	assert.equal(statuses.at(-1), "CAVEMAN:LITE");

	fixture.writeConfig(fixture.userPath, { [CONFIG_ID]: { mode: "ultra" } });
	host.emit(SETTINGS_CHANGED_EVENT, { extensionId: CONFIG_ID, key: "mode" });
	const bridge = (globalThis as Record<PropertyKey, { getLastActiveMode(): string }>)[Symbol.for("kendex.pi.caveman")]!;
	assert.equal(bridge.getLastActiveMode(), "ultra");
	assert.equal(statuses.at(-1), "CAVEMAN:ULTRA");
});
