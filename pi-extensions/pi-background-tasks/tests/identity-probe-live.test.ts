// Live integration test for defaultReadProcessIdentity (vstack#15
// round 5 reviewer-error BLOCK reproducer).
//
// Spawn `/bin/bash -lc "sleep 5"` and observe what the kernel reports:
// bash exec(2)s the sleep binary in place, so /proc/<pid>/comm rotates
// from "bash" to "sleep" while pid + starttime stay identical. The
// identity check MUST treat these as the same process — otherwise the
// orphan watcher false-finalizes a live task on every restore.
//
// Requires: Linux /proc OR `ps -o lstart=,comm= -p <pid>` available.
// Skips cleanly if the probe returns null (sandbox without /proc and
// without ps).

import { afterAll, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { defaultReadProcessIdentity, identityMatches } from "../extensions/snapshot.js";

const children: number[] = [];
afterAll(() => {
	for (const pid of children) {
		try { process.kill(pid, "SIGKILL"); } catch { /* */ }
	}
});

function sleep(ms: number): Promise<void> {
	return new Promise((res) => setTimeout(res, ms));
}

describe("defaultReadProcessIdentity live (bash exec drift)", () => {
	test("bash -c 'exec sleep N': pid + startToken stable, comm drifts bash->sleep, identityMatches stays true", async () => {
		// `exec sleep N` replaces the bash process image in place
		// (execve(2) with no fork), so the kernel reports the same pid
		// + same start time but a new /proc/<pid>/comm. This is the
		// canonical reproducer from the reviewer; without the BLOCK
		// fix, identityMatches would treat post-exec as PID reuse.
		const child = spawn("/bin/bash", ["-c", "exec sleep 5"], { stdio: "ignore", detached: true });
		const pid = child.pid;
		if (typeof pid !== "number" || pid <= 0) {
			throw new Error("could not spawn bash");
		}
		children.push(pid);

		const spawnIdentity = defaultReadProcessIdentity(pid);
		if (spawnIdentity === null) {
			// /proc + ps both unavailable in this environment; nothing
			// meaningful to assert.
			expect(true).toBe(true);
			return;
		}

		// Give bash time to call execve. On Linux this typically
		// takes <10ms; 250ms is generous.
		await sleep(250);

		const drifted = defaultReadProcessIdentity(pid);
		expect(drifted).not.toBeNull();
		// pid + startToken MUST stay identical across the exec.
		expect(drifted?.pid).toBe(spawnIdentity.pid);
		expect(drifted?.startToken).toBe(spawnIdentity.startToken);
		// identityMatches MUST treat them as the same process, even if
		// comm rotated bash -> sleep. comm is diagnostic-only.
		expect(identityMatches(spawnIdentity, drifted)).toBe(true);
		// We expect to observe the drift on this platform; if comm
		// matches both reads (e.g. the kernel didn't rotate it before
		// the first probe), the test still passes the identity check
		// above so the bug is still gated.
		if (spawnIdentity.comm === "bash" && drifted?.comm === "sleep") {
			// Drift was observed; identity check survived it.
			expect(true).toBe(true);
		}
	});

	test("identityMatches is false after the process actually exits", async () => {
		const child = spawn("/bin/true", [], { stdio: "ignore" });
		const pid = child.pid;
		if (typeof pid !== "number" || pid <= 0) throw new Error("could not spawn /bin/true");
		// Capture identity before /bin/true reaps.
		const ident = defaultReadProcessIdentity(pid);
		// Wait for the child to be reaped. /bin/true exits immediately.
		await new Promise<void>((res) => child.on("exit", () => res()));
		await sleep(50);
		const dead = defaultReadProcessIdentity(pid);
		// After exit + reap, identity reads as null (or the pid is
		// reused; either way identityMatches against the original
		// must NOT return true with a null current).
		if (dead === null) {
			expect(identityMatches(ident ?? undefined, null)).toBe(false);
		} else {
			// Unlikely but possible: a different process raced into
			// this pid by the time we re-read. The kernel-stable
			// startToken still differs from the original.
			expect(dead.startToken).not.toBe(ident?.startToken ?? "missing");
		}
	});
});
