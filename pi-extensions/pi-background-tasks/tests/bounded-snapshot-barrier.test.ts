import { expect, test } from "bun:test";
import { applyCustomEntryWithBarrier } from "../extensions/persistence.js";
import type { BackgroundTaskSnapshot } from "../extensions/types.js";
import { boundedSnapshot } from "./fixtures/bounded-snapshot.js";

test("custom entries restore the sidecar at bounded snapshot barriers", () => {
	expect.hasAssertions();
	for (const { name, initialIds, sidecarIds, entries, expected } of [
		{
			name: "older full snapshot is replaced by the later sidecar barrier",
			initialIds: ["bg-new"],
			sidecarIds: ["bg-new"],
			entries: [
				{ tasks: [boundedSnapshot({ id: "bg-old" })], updatedAt: 1 },
				{ version: 2, fullSnapshot: false, reason: "payload-too-large", byteSize: 999_999, fingerprint: "abc", counts: { tasks: 1 }, updatedAt: 2 },
			],
			expected: [["bg-old"], ["bg-new"]],
		},
		{
			name: "barrier without a loaded sidecar preserves current tasks",
			initialIds: ["bg-pre"],
			sidecarIds: undefined,
			entries: [{ version: 2, fullSnapshot: false, reason: "payload-too-large", byteSize: 1, fingerprint: "x", counts: { tasks: 0 }, updatedAt: 0 }],
			expected: [["bg-pre"]],
		},
		{
			name: "barrier marker is independent of envelope version",
			initialIds: ["bg-old"],
			sidecarIds: ["bg-sidecar"],
			entries: [{ version: 3, fullSnapshot: false, reason: "some-new-reason" }],
			expected: [["bg-sidecar"]],
		},
	] as const) {
		let current: BackgroundTaskSnapshot[] = initialIds.map((id) => boundedSnapshot({ id }));
		const sidecarTasks = sidecarIds?.map((id) => boundedSnapshot({ id }));
		const states = entries.map((data) => {
			applyCustomEntryWithBarrier({
				data,
				sidecarLoaded: sidecarTasks !== undefined,
				sidecarTasks,
				clear: () => { current = []; },
				apply: (snapshot) => { current.push(snapshot); },
			});
			return current.map((task) => task.id);
		});
		expect(states, name).toEqual(expected);
	}
});
