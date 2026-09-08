import { expect, test } from "bun:test";
import { applyBgToolResultTasksWithBarrier, bgToolResultTasks } from "../extensions/tool-result-details.js";
import { fakeSnapshot } from "./fixtures/lifecycle.js";

const rows = [
	{ name: "manifest restores the sidecar after an older full list", sidecarLoaded: true, emptySidecar: false, expectedIds: ["bg-sidecar"], expectedClears: 1 },
	{ name: "manifest without a sidecar keeps the accumulated full list", sidecarLoaded: false, emptySidecar: false, expectedIds: ["bg-sidecar", "bg-old"], expectedClears: 0 },
	{ name: "loaded empty sidecar clears accumulated older tasks", sidecarLoaded: true, emptySidecar: true, expectedIds: [], expectedClears: 1 },
];

test("tool-result restore barrier rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "tool-result barrier table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const sidecar = fakeSnapshot({ id: "bg-sidecar", updatedAt: 2_000 });
		const older = fakeSnapshot({ id: "bg-old", updatedAt: 1_000 });
		let current = [sidecar];
		let clears = 0;
		const sidecarTasks = row.emptySidecar ? [] : [sidecar];
		const apply = (task: typeof sidecar) => { current.push(task); };
		const clear = () => { clears++; current = []; };
		applyBgToolResultTasksWithBarrier({ apply, clear, detailsTasks: [older], sidecarLoaded: row.sidecarLoaded, sidecarTasks });
		const afterFull = { tasks: [...current], clears };
		const manifest = bgToolResultTasks(Array.from({ length: 100 }, (_, index) => fakeSnapshot({ id: `bg-${index}` })));
		applyBgToolResultTasksWithBarrier({ apply, clear, detailsTasks: manifest, sidecarLoaded: row.sidecarLoaded, sidecarTasks });
		expect({ afterFull, afterManifest: { ids: current.map((task) => task.id), tasks: current, clears } }, row.name).toStrictEqual({
			afterFull: { tasks: [sidecar, older], clears: 0 },
			afterManifest: { ids: row.expectedIds, tasks: row.expectedIds.map((id) => id === "bg-sidecar" ? sidecar : older), clears: row.expectedClears },
		});
	}
});
