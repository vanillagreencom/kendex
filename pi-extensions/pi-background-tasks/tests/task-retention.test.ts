import { expect, test } from "bun:test";
import { MAX_FINISHED_TASKS } from "../extensions/constants.js";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

test("task logs follow the lane retention rule, and finished tasks are bounded and released", () => {
	const result = runSpawnFixture("retention-extension.ts", {}) as Record<string, unknown>;
	expect(result).toStrictEqual({
		// session_start removed the lane whose worktree is gone and the log past five days.
		pruned: { goneLane: false, oldLane: [".lane-cwd", "bg-2-2.log"] },
		spawned: MAX_FINISHED_TASKS + 5,
		listed: MAX_FINISHED_TASKS,
		logInLane: true,
		laneCwd: true,
		logsBeforeClear: MAX_FINISHED_TASKS,
		newestLog: "(empty)",
		logsAfterClear: 0,
	});
}, SPAWN_FIXTURE_TIMEOUT_MS);
