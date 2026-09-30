import { describe, expect, test } from "bun:test";
import { mapWithConcurrency, runProbe, runProbeSync, type ProbeResult } from "../extensions/probes.js";

describe.skipIf(process.platform === "win32")("probe subprocess results", () => {
	test("each way a probe ends maps to one tagged result from either runner", async () => {
		const rows: { name: string; file: string; args: string[]; expected: ProbeResult }[] = [
			{ name: "zero exit keeps stdout", file: "/bin/sh", args: ["-c", "printf ok"], expected: { kind: "exited", status: 0, stdout: "ok" } },
			{ name: "non-zero exit keeps its status", file: "/bin/sh", args: ["-c", "exit 3"], expected: { kind: "exited", status: 3, stdout: "" } },
			{ name: "a signal the probe did not send", file: "/bin/sh", args: ["-c", "kill -TERM $$"], expected: { kind: "unsettled", cause: "signalled", signal: "SIGTERM" } },
			{ name: "a missing command", file: "/nonexistent/kendex-probe", args: [], expected: { kind: "missing" } },
			{ name: "a command that exists but cannot start", file: import.meta.path, args: [], expected: { kind: "unsettled", cause: "spawn-failed", code: "EACCES" } },
			// The one real wait: a child that outlives the probe timeout.
			{ name: "a child past the timeout", file: "/bin/sh", args: ["-c", "sleep 5"], expected: { kind: "unsettled", cause: "timed-out" } },
		];
		expect.assertions(rows.length + 1);
		expect(rows.length, "probe result table must contain cases").toBeGreaterThan(0);
		for (const row of rows) {
			const results = { async: await runProbe(row.file, row.args), sync: runProbeSync(row.file, row.args) };
			expect(results, row.name).toStrictEqual({ async: row.expected, sync: row.expected });
		}
	}, 10_000);
});

test("mapWithConcurrency bounds calls in flight and keeps input order", async () => {
	const rows = [
		{ name: "more items than the limit", items: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], limit: 4, maxInFlight: 4 },
		{ name: "fewer items than the limit", items: [1, 2], limit: 4, maxInFlight: 2 },
		{ name: "no items", items: [], limit: 4, maxInFlight: 0 },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "concurrency table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		let inFlight = 0;
		let maxInFlight = 0;
		const waiting: (() => void)[] = [];
		const mapped = mapWithConcurrency(row.items, row.limit, async (item) => {
			inFlight++;
			maxInFlight = Math.max(maxInFlight, inFlight);
			await new Promise<void>((resolve) => waiting.push(resolve));
			inFlight--;
			return item * 10;
		});
		let settled = false;
		void mapped.then(() => { settled = true; });
		// Release the calls newest first so completion order differs from input
		// order; setImmediate lets every resolved call start its successor.
		while (!settled) {
			waiting.pop()?.();
			await new Promise<void>((resolve) => setImmediate(resolve));
		}
		expect({ results: await mapped, maxInFlight }, row.name).toStrictEqual({ results: row.items.map((item) => item * 10), maxInFlight: row.maxInFlight });
	}
});
