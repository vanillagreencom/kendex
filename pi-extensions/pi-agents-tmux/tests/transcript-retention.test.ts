import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, utimesSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { LANE_FILE_MAX_AGE_MS } from "../scripts/lane-retention.js";
import { writeFullOutputArtifact } from "../extensions/subagent/runner.js";
import { createHarness, fakeCtx, type Harness, installExtension, teardown, withoutRealIntervals } from "./extension-fixture.js";

let harness: Harness | undefined;

afterEach(() => {
	if (harness) teardown(harness);
	harness = undefined;
});

/** Lanes a previous run left under each retained folder: one whose worktree is
 *  gone, and a live one whose record and one file are past five days. */
function seedLanes(h: Harness) {
	const sessions = join(h.piUserDir, "kendex", "sessions");
	const lane = (session: string, folder: string) => join(sessions, session, "pi-agents-tmux", folder);
	const past = (Date.now() - LANE_FILE_MAX_AGE_MS - 60_000) / 1000;
	for (const folder of ["transcripts", "outputs"]) {
		mkdirSync(lane("merged", folder), { recursive: true });
		writeFileSync(join(lane("merged", folder), ".lane-cwd"), join(h.cwd, "removed-worktree"));
		writeFileSync(join(lane("merged", folder), "a.jsonl"), "{}\n");
		mkdirSync(lane("live", folder), { recursive: true });
		writeFileSync(join(lane("live", folder), ".lane-cwd"), h.cwd);
		writeFileSync(join(lane("live", folder), "old.jsonl"), "{}\n");
		writeFileSync(join(lane("live", folder), "new.jsonl"), "{}\n");
		utimesSync(join(lane("live", folder), "old.jsonl"), past, past);
		utimesSync(join(lane("live", folder), ".lane-cwd"), past, past);
	}
	const state = () => Object.fromEntries(["transcripts", "outputs"].map((folder) => [folder, {
		merged: existsSync(lane("merged", folder)),
		old: existsSync(join(lane("live", folder), "old.jsonl")),
		new: existsSync(join(lane("live", folder), "new.jsonl")),
		record: existsSync(join(lane("live", folder), ".lane-cwd")) && readFileSync(join(lane("live", folder), ".lane-cwd"), "utf8"),
	}]));
	return { lane, state };
}

for (const row of [
	{
		name: "the owning session prunes transcripts and saved outputs, and keeps a live lane's record",
		childAgent: undefined,
		expected: (cwd: string) => ({ merged: false, old: false, new: true, record: cwd }),
	},
	{
		name: "a child agent sharing the root prunes nothing and leaves the record",
		childAgent: "scout",
		expected: (cwd: string) => ({ merged: true, old: true, new: true, record: cwd }),
	},
]) {
	test(`session_start lane retention: ${row.name}`, async () => {
		harness = createHarness({ childAgent: row.childAgent });
		const { state } = seedLanes(harness);
		const onSessionStart = await installExtension(harness);
		await withoutRealIntervals(async () => {
			await onSessionStart({}, fakeCtx(harness!));
		});
		const lanes = row.expected(harness.cwd);
		expect(state()).toEqual({ transcripts: lanes, outputs: lanes });
	});
}

test("a saved full output records the owning session's lane before it is written", async () => {
	harness = createHarness({});
	const onSessionStart = await installExtension(harness);
	await withoutRealIntervals(async () => {
		await onSessionStart({}, fakeCtx(harness!));
	});
	const runtimeRoot = join(harness.piUserDir, "kendex", "sessions", "test-session-id", "pi-agents-tmux");
	const saved = await writeFullOutputArtifact(runtimeRoot, "scout", "label", "full text");
	expect({
		saved: typeof saved.path === "string" && dirname(dirname(saved.path)) === join(runtimeRoot, "outputs"),
		record: readFileSync(join(runtimeRoot, "outputs", ".lane-cwd"), "utf8"),
	}).toEqual({ saved: true, record: harness.cwd });
});
