import { expect, test } from "bun:test";
import { createOrphanWatcher } from "../extensions/orphan-watcher.js";
import type { ProbeResult } from "../extensions/probes.js";
import { defaultReadProcessIdentity, restoredTaskFromSnapshot, type IdentityProbe } from "../extensions/snapshot.js";
import { fakeSnapshot, recordingHooks } from "./fixtures/lifecycle.js";
import { orphanTask } from "./fixtures/orphan-watcher.js";

const pid = 4242;
const startToken = "Mon Jan 1 00:00:00 2024";

test("a ps answer decides restore and the orphan watcher through one liveness verdict", async () => {
	const rows: { name: string; ps: ProbeResult; expected: { reading: string; restored: string; finalized: number; watched: string } }[] = [
		{ name: "a timed-out ps is unknown and keeps the task running", ps: { kind: "timed-out" }, expected: { reading: "unknown", restored: "running", finalized: 0, watched: "running" } },
		{ name: "a signalled ps is unknown and keeps the task running", ps: { kind: "signalled", signal: "SIGKILL" }, expected: { reading: "unknown", restored: "running", finalized: 0, watched: "running" } },
		{ name: "a ps that cannot start is unknown and keeps the task running", ps: { kind: "spawn-failed", code: "EAGAIN" }, expected: { reading: "unknown", restored: "running", finalized: 0, watched: "running" } },
		{ name: "a ps that matched no process is gone", ps: { kind: "exited", status: 1, stdout: "" }, expected: { reading: "gone", restored: "stopped", finalized: 1, watched: "failed" } },
		{ name: "a ps that printed nothing is gone", ps: { kind: "exited", status: 0, stdout: "\n" }, expected: { reading: "gone", restored: "stopped", finalized: 1, watched: "failed" } },
		{ name: "a ps naming the recorded start is alive", ps: { kind: "exited", status: 0, stdout: `${startToken} sleep\n` }, expected: { reading: "identity", restored: "running", finalized: 0, watched: "running" } },
		{ name: "a ps naming another start is a reused pid", ps: { kind: "exited", status: 0, stdout: "Tue Jan 2 00:00:00 2024 sleep\n" }, expected: { reading: "identity", restored: "stopped", finalized: 1, watched: "failed" } },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "identity reading table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const identityProbe: IdentityProbe = (probed) => defaultReadProcessIdentity(probed, {
			platform: "darwin",
			async run(file, args) {
				if (file !== "ps" || args.at(-1) !== String(pid)) throw new Error(`identity_reading_test.unexpected_call=${file} ${args.join(" ")}`);
				return row.ps;
			},
		});
		const procIdent = { pid, startToken, comm: "bash" };
		const reading = await identityProbe(pid);
		const restored = await restoredTaskFromSnapshot(fakeSnapshot({ status: "running", pid, procIdent, sessionId: "sess-1" }), { identityProbe, sessionId: "sess-1", now: 1_700_000_100_000 });
		const task = orphanTask({ pid, procIdent });
		const watcher = createOrphanWatcher({
			getTasks: () => [task], hooks: recordingHooks().hooks, identityProbe,
			async unitActiveProbe() { throw new Error("identity_reading_test.unexpected_unit_probe"); },
		});
		const { finalized } = await watcher.checkOnce();
		expect({ reading: reading.kind, restored: restored.status, finalized, watched: task.status }, row.name).toStrictEqual(row.expected);
	}
});
