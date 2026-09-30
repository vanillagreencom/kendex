import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync, rmSync, utimesSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { LANE_FILE_MAX_AGE_MS, pruneLanes } from "../scripts/lane-retention.js";
import { RUNTIME_LANE_FOLDERS, RUNTIME_LANE_REFRESH_MS, setRuntimeLaneCwd } from "../extensions/subagent/paths.js";
import { runSingleAgent, setSingleAgentSpawnForTests, writeFullOutputArtifact } from "../extensions/subagent/runner.js";
import { createHarness, fakeCtx, type Harness, installExtension, teardown, withoutRealIntervals } from "./extension-fixture.js";
import { bridgeStdout, installMockSpawn, makeDetails, mockPiEvents, testAgent } from "./single-agent-fixture.js";

let harness: Harness | undefined;

afterEach(() => {
	if (harness) teardown(harness);
	harness = undefined;
	// No case runs session_shutdown, which clears the owner's record cwd.
	setRuntimeLaneCwd(undefined);
});

function sessionRuntimeRoot(h: Harness, sessionId: string): string {
	return join(h.piUserDir, "kendex", "sessions", sessionId, "pi-agents-tmux");
}

/** Run session_start for an owning session with id `sessionId`; return the
 *  intervals it started. */
async function startOwnerSession(h: Harness, sessionId: string): Promise<Array<{ callback: () => void; ms: number }>> {
	const onSessionStart = await installExtension(h);
	const ctx = fakeCtx(h);
	ctx.sessionManager.getSessionId = () => sessionId;
	const started: Array<{ callback: () => void; ms: number }> = [];
	await withoutRealIntervals(async () => {
		await onSessionStart({}, ctx);
	}, started);
	return started;
}

/** Run one one-shot agent that writes its transcript under `runtimeRoot`;
 *  return the transcript path. */
async function runOneShot(h: Harness, runtimeRoot: string): Promise<string> {
	const agent = testAgent();
	installMockSpawn([{ code: 0, stdout: bridgeStdout([]) }]);
	try {
		const result = await runSingleAgent(h.cwd, runtimeRoot, [agent], agent.name, "retention task", undefined, undefined, undefined, undefined, mockPiEvents([]), undefined, undefined, makeDetails);
		expect(typeof result.transcriptPath).toBe("string");
		return result.transcriptPath!;
	} finally {
		setSingleAgentSpawnForTests();
	}
}

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

for (const row of [
	{ folder: "transcripts", write: (h: Harness, root: string) => runOneShot(h, root) },
	{ folder: "outputs", write: async (_h: Harness, root: string) => (await writeFullOutputArtifact(root, "scout", "label", "full text")).path },
]) {
	test(`the owning session records its ${row.folder} lane at session_start, and again on a write after the lane was pruned`, async () => {
		harness = createHarness({});
		const root = sessionRuntimeRoot(harness, "owner");
		const record = () => readFileSync(join(root, row.folder, ".lane-cwd"), "utf8");
		await startOwnerSession(harness, "owner");
		const atStart = record();
		// The prune removes a lane that was idle past five days.
		rmSync(join(root, row.folder), { recursive: true, force: true });
		const written = await row.write(harness, root);
		expect({
			atStart,
			writtenInLane: typeof written === "string" && dirname(dirname(written)) === join(root, row.folder),
			afterWrite: record(),
		}).toEqual({ atStart: harness.cwd, writtenInLane: true, afterWrite: harness.cwd });
	});
}

test("a transcript only a child agent wrote into its parent's root is pruned by a later session after five days", async () => {
	harness = createHarness({});
	const parentRoot = sessionRuntimeRoot(harness, "parent");
	await startOwnerSession(harness, "parent");
	// The child agent is a separate process, and it never sets a record cwd.
	setRuntimeLaneCwd(undefined);
	const transcript = await runOneShot(harness, parentRoot);
	const written = existsSync(transcript);
	const past = (Date.now() - LANE_FILE_MAX_AGE_MS - 60_000) / 1000;
	utimesSync(transcript, past, past);
	await startOwnerSession(harness, "later");
	expect({ written, kept: existsSync(transcript) }).toEqual({ written: true, kept: false });
});

test("a live owner's lane refresh keeps each lane through a prune once its first record is past five days", async () => {
	harness = createHarness({});
	const root = sessionRuntimeRoot(harness, "owner");
	const refreshes = (await startOwnerSession(harness, "owner")).filter((interval) => interval.ms === RUNTIME_LANE_REFRESH_MS);
	expect(refreshes).toHaveLength(1);
	const past = (Date.now() - LANE_FILE_MAX_AGE_MS - 60_000) / 1000;
	for (const folder of RUNTIME_LANE_FOLDERS) utimesSync(join(root, folder, ".lane-cwd"), past, past);
	refreshes[0]!.callback();
	const sessions = join(harness.piUserDir, "kendex", "sessions");
	const removed = RUNTIME_LANE_FOLDERS.flatMap((folder) => pruneLanes(sessions, ["pi-agents-tmux", folder]).removed);
	expect({
		removed,
		records: RUNTIME_LANE_FOLDERS.map((folder) => readFileSync(join(root, folder, ".lane-cwd"), "utf8")),
	}).toEqual({ removed: [], records: RUNTIME_LANE_FOLDERS.map(() => harness!.cwd) });
});
