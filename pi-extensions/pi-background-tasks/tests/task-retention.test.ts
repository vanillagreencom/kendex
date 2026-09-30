import { expect, test } from "bun:test";
import { MAX_FINISHED_TASKS } from "../extensions/constants.js";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

test("task logs follow the lane retention rule, and finished tasks are bounded and released", () => {
	const result = runSpawnFixture("retention-extension.ts", {}) as Record<string, unknown>;
	expect(result).toStrictEqual({
		// session_start removed the lane whose worktree is gone and the log past five days.
		// Folders the package did not make keep their old files.
		pruned: { goneLane: false, oldLane: [".lane-cwd", "bg-2-2.log"], foreign: [".lane-cwd", "old.txt"], unmarked: ["old.log"], victim: [".lane-cwd", "old.txt"] },
		spawned: MAX_FINISHED_TASKS + 5,
		listed: MAX_FINISHED_TASKS,
		logInLane: true,
		laneCwd: true,
		logsBeforeClear: MAX_FINISHED_TASKS,
		newestLog: "(empty)",
		logsAfterClear: 0,
		longLog: { tail: true, head: false },
		unloggedLog: "late-output",
		// session_shutdown releases the task map.
		listedAfterShutdown: "No background tasks.",
		// A forked session forgets the tasks it restored from this session's
		// branch, past the bound and on clear, and keeps their logs.
		fork: { taskSession: "retention-session", listed: MAX_FINISHED_TASKS, logsKept: MAX_FINISHED_TASKS + 1, listedAfterClear: "No background tasks." },
	});
}, SPAWN_FIXTURE_TIMEOUT_MS);
