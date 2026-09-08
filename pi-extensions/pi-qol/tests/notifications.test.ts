import { expect, test } from "bun:test";

import { osc777NotificationSequence, terminalBellSequence } from "../extensions/qol/notifications.ts";

const bellRows = [
	{ name: "audible terminal bell", muted: false, expected: "\x07" },
	{ name: "muted terminal bell", muted: true, expected: undefined },
];

if (bellRows.length === 0) throw new Error("Terminal bell table is empty");

for (const row of bellRows) {
	test(row.name, () => {
		expect.hasAssertions();
		expect(terminalBellSequence(row.muted)).toBe(row.expected);
	});
}

const oscRows = [
	{ name: "default OSC BEL terminator", muted: undefined, expected: { sequence: "\x1b]777;notify;Title;Body\x07", containsBell: true } },
	{ name: "muted OSC ST terminator", muted: true, expected: { sequence: "\x1b]777;notify;Title;Body\x1b\\", containsBell: false } },
];

if (oscRows.length === 0) throw new Error("OSC notification table is empty");

for (const row of oscRows) {
	test(row.name, () => {
		expect.hasAssertions();
		const sequence = osc777NotificationSequence("Title", "Body", row.muted);
		expect({ sequence, containsBell: sequence.includes("\x07") }).toEqual(row.expected);
	});
}
