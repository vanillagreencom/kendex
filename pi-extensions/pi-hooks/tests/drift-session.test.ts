import { expect, spyOn, test } from "bun:test";
import { rmSync } from "node:fs";
import * as drift from "../extensions/drift-check.ts";
import { initRustRepo, installCarrier, trusted, useIsolatedGitEnv, writePiConfig } from "./harness.ts";
import { useSettledSessions } from "./session-fixture.ts";

useIsolatedGitEnv();
const settle = useSettledSessions();

for (const row of [
	{ reason: "startup", kind: "drift", checks: 1 },
	{ reason: "new", kind: "drift", checks: 1 },
	{ reason: "fork", kind: "drift", checks: 1 },
	{ reason: "reload", kind: "drift", checks: 0 },
	{ reason: "resume", kind: "drift", checks: 0 },
	{ reason: "startup", kind: "clean", checks: 1 },
] as const) {
	test(`native drift on ${row.reason}: ${row.kind}`, async () => {
		const root = initRustRepo("pi-hooks-session-");
		writePiConfig(root, { sessionDriftCheck: true });
		let complete!: (result: drift.DriftCheckResult) => void;
		const pending = new Promise<drift.DriftCheckResult>((resolve) => { complete = resolve; });
		const check = spyOn(drift, "runDriftCheck").mockReturnValue(pending);
		try {
			const carrier = installCarrier();
			const returned = carrier.handler("session_start")({ reason: row.reason }, trusted(root));
			expect(returned).toBeUndefined();
			expect(carrier.sent).toEqual([]);
			expect(check).toHaveBeenCalledTimes(row.checks);
			if (row.checks) expect(check.mock.calls[0]?.[0]).toBe(root);
			complete(row.kind === "clean" ? { kind: "clean" } : { kind: "drift", report: "outdated=orch" });
			await pending;
			await settle();
			expect(carrier.sent).toEqual(row.checks && row.kind === "drift" ? [{
				message: { customType: "kendex-drift", content: "outdated=orch", display: true },
				options: { triggerTurn: false },
			}] : []);
		} finally {
			complete({ kind: "clean" });
			await pending;
			await settle();
			check.mockRestore();
			rmSync(root, { recursive: true, force: true });
		}
	});
}
