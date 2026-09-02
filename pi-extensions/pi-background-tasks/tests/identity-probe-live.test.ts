// Live integration test for defaultReadProcessIdentity (kendex#15
// round 5 reviewer-error BLOCK reproducer).
//
// Spawn `/bin/bash -c "exec sleep 5"`: bash execve(2)s the sleep binary
// in place with no fork, so pid + starttime stay identical across the
// exec while the process image changes underneath them. The identity
// check MUST treat before and after as the same process — otherwise the
// orphan watcher false-finalizes a live task on every restore.
//
// Enforced on Linux only. There, a null from the probe against a pid
// still present in /proc is a defect in the reader this suite gates, and
// the case throws. Elsewhere a null logs a skip line and returns: the
// portable `ps -o lstart=,comm= -p <pid>` path returns null for reader
// defects too, and nothing here separates those from a host that cannot
// probe at all, so this suite makes no promise off Linux.

import { afterAll, describe, expect, test } from "bun:test";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
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
	test("bash -c 'exec sleep N': pid + startToken stable across the exec, identityMatches stays true whether or not comm rotated", async () => {
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
			// A null is "the probe failed", not "this host cannot probe":
			// defaultReadProcessIdentity also returns null on a malformed
			// /proc/<pid>/stat, an absent starttime field, or a non-zero `ps`
			// exit — regressions in the reader this case exists to gate. On
			// Linux with the process still in /proc, the probe path is there,
			// so a null is that defect and must fail rather than pass quietly.
			if (process.platform === "linux" && existsSync(`/proc/${pid}`)) {
				throw new Error(
					`defaultReadProcessIdentity returned null for live pid ${pid} with /proc/${pid} present — the probe is broken, not the host`,
				);
			}
			// No /proc and no working `ps`: nothing to observe. Say so, so a
			// suite that has stopped exercising the reproducer is visible in
			// the log instead of reading like a run that proved the fix.
			console.log(`skip: no process-identity probe on ${process.platform} — the exec-drift reproducer did not run`);
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
		// comm may or may not have rotated by the time of the second
		// read — the kernel does not promise when. Either way the
		// identity check above is what gates the bug, so nothing here
		// depends on observing the rotation.
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
