import { expect, test } from "bun:test";
import { createOrphanWatcher } from "../extensions/orphan-watcher.js";
import type { ProbeResult } from "../extensions/probes.js";
import { defaultReadProcessIdentity, restoredTaskFromSnapshot, type IdentityProbe } from "../extensions/snapshot.js";
import { fakeSnapshot, recordingHooks } from "./fixtures/lifecycle.js";
import { orphanTask } from "./fixtures/orphan-watcher.js";

const pid = 4242;
const startToken = "Mon Jan 1 00:00:00 2024";

const unknown = { reading: "unknown", restored: "running", finalized: 0, watched: "running" };
const alive = { reading: "identity", restored: "running", finalized: 0, watched: "running" };
const gone = { reading: "gone", restored: "stopped", finalized: 1, watched: "failed" };
const enoent = Object.assign(new Error("no such file"), { code: "ENOENT" });

// ps and the signal-0 check answer only in rows that set them; any other call fails the row.
test("an identity read decides restore and the orphan watcher through one liveness verdict", async () => {
	const rows: {
		name: string; platform?: NodeJS.Platform; stat?: Error; ps?: ProbeResult; pidExists?: boolean;
		expected: { reading: string; restored: string; finalized: number; watched: string };
	}[] = [
		{ name: "a timed-out ps is unknown and keeps the task running", ps: { kind: "unsettled", cause: "timed-out" }, expected: unknown },
		{ name: "a signalled ps is unknown and keeps the task running", ps: { kind: "unsettled", cause: "signalled", signal: "SIGKILL" }, expected: unknown },
		{ name: "a ps that cannot start is unknown and keeps the task running", ps: { kind: "unsettled", cause: "spawn-failed", code: "EAGAIN" }, expected: unknown },
		{ name: "ps output with too few fields is unknown and keeps the task running", ps: { kind: "exited", status: 0, stdout: "garbage\n" }, expected: unknown },
		{ name: "a ps that matched no process is gone", ps: { kind: "exited", status: 1, stdout: "" }, expected: gone },
		{ name: "a ps that printed nothing is gone", ps: { kind: "exited", status: 0, stdout: "\n" }, expected: gone },
		{ name: "a ps naming the recorded start is alive", ps: { kind: "exited", status: 0, stdout: `${startToken} sleep\n` }, expected: alive },
		{ name: "a ps naming another start is a reused pid", ps: { kind: "exited", status: 0, stdout: "Tue Jan 2 00:00:00 2024 sleep\n" }, expected: { ...gone, reading: "identity" } },
		{ name: "a missing ps and a dead pid are gone", ps: { kind: "missing" }, pidExists: false, expected: gone },
		{ name: "a missing ps and a live pid are alive without an identity", ps: { kind: "missing" }, pidExists: true, expected: { ...alive, reading: "alive" } },
		{ name: "a Linux pid with no /proc entry is gone without ps", platform: "linux", stat: enoent, expected: gone },
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "identity reading table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const identityProbe: IdentityProbe = (probed) => defaultReadProcessIdentity(probed, {
			platform: row.platform ?? "darwin",
			async readStat(path) {
				if (!row.stat || path !== `/proc/${pid}/stat`) throw new Error(`identity_reading_test.unexpected_read=${path}`);
				throw row.stat;
			},
			async run(file, args) {
				if (!row.ps || file !== "ps" || args.at(-1) !== String(pid)) throw new Error(`identity_reading_test.unexpected_call=${file} ${args.join(" ")}`);
				return row.ps;
			},
			processAlive(probed) {
				if (row.pidExists === undefined || probed !== pid) throw new Error(`identity_reading_test.unexpected_signal_check=${probed}`);
				return row.pidExists;
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
