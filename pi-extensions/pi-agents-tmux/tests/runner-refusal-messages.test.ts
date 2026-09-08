import assert from "node:assert/strict";
import test from "node:test";

import { runSingleAgent } from "../extensions/subagent/runner.js";
import type { SingleResult, SubagentDetails } from "../extensions/subagent/types.js";

function makeDetails(results: SingleResult[]): SubagentDetails {
	return { agentScope: "project", mode: "single", projectAgentsDir: null, results };
}

test("runSingleAgent returns a stable unknown-agent refusal record", async () => {
	const result = await runSingleAgent(
		process.cwd(),
		process.cwd(),
		[],
		"missing-agent",
		"inspect the project",
		undefined,
		undefined,
		undefined,
		undefined,
		{} as Parameters<typeof runSingleAgent>[9],
		undefined,
		undefined,
		makeDetails,
	);

	assert.equal(result.stderr.split("\n", 1)[0], "unknown_agent=missing-agent");
	assert.equal(result.exitCode, 1);
	assert.equal(result.refused, true);
});
