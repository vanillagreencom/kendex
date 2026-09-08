import { describe, expect, test } from "bun:test";
import { defaultReadProcessIdentity, identityMatches } from "../extensions/snapshot.js";
import { identityChild } from "./fixtures/identity-child.js";

describe.skipIf(process.platform !== "linux")("Linux process identity across exec and exit", () => {
	test("observes each owned process transition", async () => {
		const rows = [
			{ name: "exec changes the executable but retains the process identity", release: "exec", matches: true },
			{ name: "reaped process no longer matches its recorded identity", release: "exit", matches: false },
		] as const;
		expect.assertions(rows.length + 1);
		expect(rows.length, "process identity table must contain cases").toBeGreaterThan(0);
		for (const row of rows) {
			const owned = identityChild();
			try {
				await owned.ready("bash-ready");
				const pid = owned.child.pid;
				if (pid === undefined) throw new Error(`${row.name}: Bash has no process ID`);
				const initial = defaultReadProcessIdentity(pid);
				if (initial === null) throw new Error(`${row.name}: initial live identity is null`);
				owned.child.stdin.write(`${row.release}\n`);
				if (row.release === "exec") await owned.ready("exec-ready");
				else await owned.exited();
				const current = defaultReadProcessIdentity(pid);
				if (row.release === "exec" && current === null) {
					throw new Error(`${row.name}: post-exec live identity is null`);
				}
				expect({ initial, current, matches: identityMatches(initial, current) }, row.name).toStrictEqual({
					initial: { pid, startToken: expect.stringMatching(/^\d+$/), comm: "bash" },
					current: row.release === "exec"
						? { pid, startToken: initial.startToken, comm: "sh" }
						: current === null ? null : expect.not.objectContaining({ startToken: initial.startToken }),
					matches: row.matches,
				});
				if (row.release === "exec") {
					owned.child.stdin.write("exit\n");
					await owned.exited();
				}
			} finally {
				await owned.dispose();
			}
		}
	}, 15_000);
});
