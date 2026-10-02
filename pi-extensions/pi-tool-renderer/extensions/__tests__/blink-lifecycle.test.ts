import { afterEach, expect, jest, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

import { clearPackageConfigCache } from "../tool-renderer/package-config.js";
import { CONFIG_ID } from "../tool-renderer/settings.js";
import { registerBlinkEvents, renderPendingCall } from "../tool-renderer/text.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();
const theme = { fg: (_tone: string, text: string) => text, bold: (text: string) => text };

type Handler = (event: unknown, ctx: unknown) => void;

/** The subset of Pi's extension API the blink events register on. */
function fakePi() {
	const handlers = new Map<string, Handler[]>();
	return {
		on(name: string, handler: Handler) {
			handlers.set(name, [...(handlers.get(name) ?? []), handler]);
		},
		emit(name: string) {
			for (const handler of handlers.get(name) ?? []) handler({}, {});
		},
	};
}

afterEach(() => jest.useRealTimers());

// Pi drops a pending row with no final render at each of these events, so a
// row that never reached renderResult must stop blinking there.
for (const event of ["agent_end", "session_shutdown"]) {
	test(`${event} clears an animated pending row that got no final render`, () => {
		const { cwd } = world();
		writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: { pendingStatusAnimation: true } } } } }));
		clearPackageConfigCache();
		jest.useFakeTimers();
		const pi = fakePi();
		registerBlinkEvents(pi as any);
		let invalidations = 0;
		const context = { cwd, executionStarted: true, isPartial: true, toolCallId: `${event}-call`, invalidate: () => invalidations++ };

		renderPendingCall("Read file", theme, context, cwd);
		jest.advanceTimersByTime(450);
		expect([jest.getTimerCount(), invalidations]).toEqual([1, 1]);

		pi.emit(event);
		expect(jest.getTimerCount()).toBe(0);
		jest.advanceTimersByTime(4500);
		expect(invalidations).toBe(1);
	});
}
