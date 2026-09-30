import { describe, expect, test } from "bun:test";
import { PROBE_CONCURRENCY } from "../extensions/probes.js";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";
import { fixturePid } from "./fixtures/spawn-native.js";

// Windows the extension coalesces per-chunk work into.
const OUTPUT_SETTLE_MS = 1_500;
const LOG_FLUSH_MS = 250;
const UI_REFRESH_MS = 200;
const PERSIST_MS = 1_000;

// The spawn-time identity read; the fixture answers /proc/<pid>/stat on Linux and ps elsewhere.
const spawnIdentity = process.platform === "linux"
	? { pid: fixturePid, startToken: "12345", comm: "fixture-child" }
	: { pid: fixturePid, startToken: "Mon Jan 1 00:00:00 2024", comm: "fixture-child" };

test("streamed output chunks defer log, widget and state writes to their windows", () => {
	const rows = [
		{ name: "fifty chunks with output wakes on", chunks: 50 },
		{ name: "one chunk arms each window once", chunks: 1 },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "chunk write table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const result = runSpawnFixture("write-path-extension.ts", { mode: "chunks", chunks: row.chunks }) as { chunkBytes: number };
		// The spawn-time identity read arms the persist window before any chunk,
		// and every chunk's persist request joins it.
		const persistWindows = 1;
		expect(result, row.name).toStrictEqual({
			duringChunks: {
				entries: 0, logBytes: 0,
				timerSets: {
					"interval:30000": 1, [`timeout:${OUTPUT_SETTLE_MS}`]: row.chunks, [`timeout:${LOG_FLUSH_MS}`]: 1,
					[`timeout:${UI_REFRESH_MS}`]: 1, [`timeout:${PERSIST_MS}`]: persistWindows,
				},
			},
			afterPersistWindow: persistWindows,
			procIdent: spawnIdentity,
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
			// Restore probes the final task set; the orphan watcher's first pass waits one poll interval.
			expect(result, row.name).toStrictEqual({
				probes: ["systemctl --user show-environment", "/proc/4242/stat", `systemctl --user is-active --quiet ${unit}`].sort(),
				states: [{ id: "bg-1", status: "running" }, { id: "bg-2", status: "running" }, { id: "bg-3", status: "completed" }],
				unexpected: [],
			});
		}
	}, SPAWN_FIXTURE_TIMEOUT_MS * 3);
});

// The fixture holds only /proc reads, so the deferred rows need the Linux identity path.
describe.skipIf(process.platform !== "linux")("deferred identity reads", () => {
	test("a task cleared before its spawn-time identity read resolves keeps no identity", () => {
		const result = runSpawnFixture("write-path-extension.ts", { mode: "identity-cleared" });
		expect(result).toStrictEqual({ heldReads: 1, liveProcIdent: null, persistArmed: false, unexpected: [] });
	}, SPAWN_FIXTURE_TIMEOUT_MS);

	test("restore runs at most PROBE_CONCURRENCY identity reads at once", () => {
		const running = PROBE_CONCURRENCY + 2;
		const result = runSpawnFixture("write-path-extension.ts", { mode: "restore-concurrency", running });
		expect(result).toStrictEqual({ maxInFlight: PROBE_CONCURRENCY, probes: running, unexpected: [] });
	}, SPAWN_FIXTURE_TIMEOUT_MS);
});
