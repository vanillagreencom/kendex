import { expect, spyOn, test } from "bun:test";
import { rmSync } from "node:fs";
import * as drift from "../extensions/drift-check.ts";
import { initRustRepo, installCarrier, trusted, useIsolatedGitEnv, writePiConfig } from "./harness.ts";
import { useSettledSessions } from "./session-fixture.ts";

useIsolatedGitEnv();
const settle = useSettledSessions();

// pi-agents-tmux starts both background and pane children with the agent name.
for (const row of [
	{ reason: "startup", kind: "drift", agent: undefined, hasUI: false, checks: 1 },
	{ reason: "new", kind: "drift", agent: undefined, hasUI: false, checks: 1 },
	{ reason: "fork", kind: "drift", agent: undefined, hasUI: false, checks: 1 },
	{ reason: "reload", kind: "drift", agent: undefined, hasUI: false, checks: 0 },
	{ reason: "resume", kind: "drift", agent: undefined, hasUI: false, checks: 0 },
	{ reason: "startup", kind: "clean", agent: undefined, hasUI: false, checks: 1 },
	{ reason: "startup", kind: "drift", agent: "", hasUI: true, checks: 1 },
	{ reason: "startup", kind: "drift", agent: "engineer", hasUI: false, checks: 0 },
	{ reason: "new", kind: "drift", agent: "engineer", hasUI: false, checks: 0 },
	{ reason: "fork", kind: "drift", agent: "engineer", hasUI: false, checks: 0 },
	{ reason: "startup", kind: "drift", agent: "engineer", hasUI: true, checks: 0 },
] as const) {
	test(`native drift on ${row.reason}: ${row.kind}, agent=${JSON.stringify(row.agent)}, hasUI=${row.hasUI}`, async () => {
		const root = initRustRepo("pi-hooks-session-");
		writePiConfig(root, { sessionDriftCheck: true });
		const previousAgent = process.env.PI_SUBAGENT_CHILD_AGENT;
		if (row.agent === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
		else process.env.PI_SUBAGENT_CHILD_AGENT = row.agent;
		let complete!: (result: drift.DriftCheckResult) => void;
		const pending = new Promise<drift.DriftCheckResult>((resolve) => { complete = resolve; });
		const check = spyOn(drift, "runDriftCheck").mockReturnValue(pending);
		try {
			const carrier = installCarrier();
			const returned = carrier.handler("session_start")({ reason: row.reason }, trusted(root, { hasUI: row.hasUI }));
			expect(returned).toBeUndefined();
			expect(carrier.sent).toEqual([]);
			complete(row.kind === "clean" ? { kind: "clean" } : { kind: "drift", report: "outdated=orch" });
			await pending;
			await settle();
			expect(carrier.sent).toEqual(row.checks && row.kind === "drift" ? [{
				message: { customType: "kendex-drift", content: "outdated=orch", display: true },
				options: { triggerTurn: false },
			}] : []);
			expect(check).toHaveBeenCalledTimes(row.checks);
			if (row.checks) expect(check.mock.calls[0]?.[0]).toBe(root);
		} finally {
			complete({ kind: "clean" });
			await pending;
			await settle();
			check.mockRestore();
			if (previousAgent === undefined) delete process.env.PI_SUBAGENT_CHILD_AGENT;
			else process.env.PI_SUBAGENT_CHILD_AGENT = previousAgent;
			rmSync(root, { recursive: true, force: true });
		}
	});
}
