import { expect, test } from "bun:test";

import { osc777NotificationSequence, terminalBellSequence } from "../extensions/qol/notifications.ts";

test("terminalBellSequence emits BEL unless bell sound is muted", () => {
	expect(terminalBellSequence(false)).toBe("\x07");
	expect(terminalBellSequence(true)).toBeUndefined();
});

test("osc777NotificationSequence preserves BEL terminator by default", () => {
	expect(osc777NotificationSequence("Title", "Body")).toBe("\x1b]777;notify;Title;Body\x07");
});

test("osc777NotificationSequence uses ST terminator when bell sound is muted", () => {
	const sequence = osc777NotificationSequence("Title", "Body", true);

	expect(sequence).toBe("\x1b]777;notify;Title;Body\x1b\\");
	expect(sequence).not.toContain("\x07");
});
