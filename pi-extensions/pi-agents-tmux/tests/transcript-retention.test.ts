import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { LANE_FILE_MAX_AGE_MS } from "../scripts/lane-retention.js";
import { createHarness, fakeCtx, type Harness, installExtension, teardown, withoutRealIntervals } from "./extension-fixture.js";

let harness: Harness | undefined;

afterEach(() => {
	if (harness) teardown(harness);
	harness = undefined;
});

test("session_start applies the lane retention rule to transcripts and records its own lane", async () => {
	harness = createHarness({});
	const sessions = join(harness.piUserDir, "kendex", "sessions");
	const transcripts = (session: string) => join(sessions, session, "pi-agents-tmux", "transcripts");
	// A lane whose worktree is gone, and a live lane with one transcript past five days.
	mkdirSync(transcripts("merged"), { recursive: true });
	writeFileSync(join(transcripts("merged"), ".lane-cwd"), join(harness.cwd, "removed-worktree"));
	writeFileSync(join(transcripts("merged"), "a.jsonl"), "{}\n");
	mkdirSync(transcripts("live"), { recursive: true });
	writeFileSync(join(transcripts("live"), ".lane-cwd"), harness.cwd);
	writeFileSync(join(transcripts("live"), "old.jsonl"), "{}\n");
	writeFileSync(join(transcripts("live"), "new.jsonl"), "{}\n");
	const past = (Date.now() - LANE_FILE_MAX_AGE_MS - 60_000) / 1000;
	utimesSync(join(transcripts("live"), "old.jsonl"), past, past);

	const onSessionStart = await installExtension(harness);
	await withoutRealIntervals(async () => {
		await onSessionStart({}, fakeCtx(harness!));
	});

	expect({
		merged: existsSync(transcripts("merged")),
		old: existsSync(join(transcripts("live"), "old.jsonl")),
		new: existsSync(join(transcripts("live"), "new.jsonl")),
		ownLane: readFileSync(join(transcripts("test-session-id"), ".lane-cwd"), "utf8"),
	}).toEqual({ merged: false, old: false, new: true, ownLane: harness.cwd });
});
