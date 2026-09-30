import { describe, expect, test } from "bun:test";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

// Windows the extension coalesces per-chunk work into.
const OUTPUT_SETTLE_MS = 1_500;
const LOG_FLUSH_MS = 250;
const UI_REFRESH_MS = 200;
const PERSIST_MS = 1_000;

test("streamed output chunks defer log, widget and state writes to their windows", () => {
	const rows = [
		{ name: "fifty chunks with output wakes on", chunks: 50 },
		{ name: "one chunk arms each window once", chunks: 1 },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "chunk write table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const result = runSpawnFixture("write-path-extension.ts", { mode: "chunks", chunks: row.chunks }) as { chunkBytes: number };
		// A rescheduled output wake is dropped once per chunk after the first.
		const persistWindows = row.chunks > 1 ? 1 : 0;
		expect(result, row.name).toStrictEqual({
			duringChunks: {
				entries: 0, logBytes: 0,
				timerSets: {
					"interval:30000": 1, [`timeout:${OUTPUT_SETTLE_MS}`]: row.chunks, [`timeout:${LOG_FLUSH_MS}`]: 1,
					[`timeout:${UI_REFRESH_MS}`]: 1, ...(persistWindows ? { [`timeout:${PERSIST_MS}`]: 1 } : {}),
				},
			},
			afterPersistWindow: persistWindows,
			logBytesAfterFlush: row.chunks * result.chunkBytes,
			chunkBytes: result.chunkBytes,
			unexpected: [],
		});
	}
}, SPAWN_FIXTURE_TIMEOUT_MS * 3);

describe.skipIf(process.platform !== "linux")("restore probes", () => {
	test("a long snapshot history probes each restored running task once", () => {
		const rows = [
			{ name: "one hundred entries of the same tasks", entries: 100 },
			{ name: "a single entry", entries: 1 },
		];
		expect.assertions(rows.length + 1);
		expect(rows.length, "restore probe table must contain cases").toBeGreaterThan(0);
		const unit = "kendex-pi-bg-bg-2-1700000000000.service";
		for (const row of rows) {
			const result = runSpawnFixture("write-path-extension.ts", { mode: "restore", entries: row.entries });
			// Restore probes the final task set, then session_start runs one orphan pass.
			const onePass = ["/proc/4242/stat", `systemctl --user is-active --quiet ${unit}`];
			expect(result, row.name).toStrictEqual({
				probes: ["systemctl --user show-environment", ...onePass, ...onePass].sort(),
				states: [{ id: "bg-1", status: "running" }, { id: "bg-2", status: "running" }, { id: "bg-3", status: "completed" }],
				unexpected: [],
			});
		}
	}, SPAWN_FIXTURE_TIMEOUT_MS * 3);
});
