import { expect, test } from "bun:test";
import { isBgTasksBoundedManifest } from "../extensions/persistence.js";

test("bounded manifest recognition distinguishes snapshot envelopes", () => {
	expect.hasAssertions();
	for (const { name, value, expected } of [
		{
			name: "bounded manifest envelope",
			value: { version: 2, fullSnapshot: false, reason: "payload-too-large", byteSize: 999_999, fingerprint: "abc", counts: { tasks: 70 }, updatedAt: 0 },
			expected: true,
		},
		{ name: "full snapshot envelope", value: { version: 1, tasks: [], updatedAt: 0 }, expected: false },
		{ name: "other version is a barrier but not a recognized manifest", value: { version: 3, fullSnapshot: false, reason: "some-new-reason" }, expected: false },
	] as const) {
		expect(isBgTasksBoundedManifest(value), name).toBe(expected);
	}
});
