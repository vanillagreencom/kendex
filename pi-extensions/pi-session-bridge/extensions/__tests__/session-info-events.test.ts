import { expect, test } from "bun:test";

import { BRIDGE_STREAM_EVENT_NAMES, REGISTRY_REFRESH_EVENT_NAMES } from "../session-bridge.js";

test("session_info_changed is streamed to clients and refreshes registry metadata", () => {
	expect(BRIDGE_STREAM_EVENT_NAMES).toContain("session_info_changed");
	expect(REGISTRY_REFRESH_EVENT_NAMES.has("session_info_changed")).toBe(true);
});

test("every registry-refresh event is also streamed", () => {
	const streamed = new Set<string>(BRIDGE_STREAM_EVENT_NAMES);
	for (const eventName of REGISTRY_REFRESH_EVENT_NAMES) {
		expect(streamed.has(eventName)).toBe(true);
	}
});

test("streamed event names are unique", () => {
	expect(new Set<string>(BRIDGE_STREAM_EVENT_NAMES).size).toBe(BRIDGE_STREAM_EVENT_NAMES.length);
});
