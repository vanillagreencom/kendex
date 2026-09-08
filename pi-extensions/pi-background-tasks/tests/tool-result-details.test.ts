import { expect, test } from "bun:test";
import { bgToolResultTasks, isBgToolResultBoundedTasks } from "../extensions/tool-result-details.js";
import { fakeSnapshot } from "./fixtures/lifecycle.js";

const rows = [
	{ name: "small list retains full serialized snapshots", count: 2, firstId: 1, huge: false, reason: undefined, sample: 0, omitted: 0 },
	{ name: "empty list retains the empty array", count: 0, huge: false, reason: undefined, sample: 0, omitted: 0 },
	{ name: "exact count threshold retains full snapshots", count: 50, huge: false, reason: undefined, sample: 0, omitted: 0 },
	{ name: "count overflow uses the sampled manifest", count: 100, huge: false, reason: "task-count-threshold", sample: 20, omitted: 80 },
	{ name: "byte overflow below count threshold uses the manifest", count: 1, huge: true, reason: "payload-too-large", sample: 1, omitted: 0 },
];

test("bounded tool-result list rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "tool-result list table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const tasks = Array.from({ length: row.count }, (_, index) => fakeSnapshot({ id: `bg-${index + (row.firstId ?? 0)}`, pid: 10_000 + index, command: row.huge ? "x".repeat(80 * 1024) : "printf ready" }));
		const result = bgToolResultTasks(tasks);
		const manifest = Array.isArray(result) ? undefined : result;
		// Tool results cross the JSON transcript boundary. Optional undefined fields may be absent.
		expect({
			isArray: Array.isArray(result), recognized: isBgToolResultBoundedTasks(result),
			fullSnapshots: Array.isArray(result) ? JSON.parse(JSON.stringify(result)) : undefined,
			manifest: manifest ? { fullSnapshot: manifest.fullSnapshot, reason: manifest.reason, counts: manifest.counts, taskIds: manifest.taskIds, omitted: manifest.omitted } : undefined,
			bounded: manifest ? Buffer.byteLength(JSON.stringify(result), "utf8") <= 4 * 1024 : true,
			wrappedBounded: manifest ? Buffer.byteLength(JSON.stringify({ action: "list", tasks: result }), "utf8") <= 4 * 1024 : true,
		}, row.name).toStrictEqual({
			isArray: row.reason === undefined, recognized: row.reason !== undefined,
			fullSnapshots: row.reason === undefined ? JSON.parse(JSON.stringify(tasks)) : undefined,
			manifest: row.reason === undefined ? undefined : { fullSnapshot: false, reason: row.reason, counts: { tasks: row.count }, taskIds: Array.from({ length: row.sample }, (_, index) => `bg-${index}`), omitted: { tasks: row.omitted } },
			bounded: true, wrappedBounded: true,
		});
	}
});
