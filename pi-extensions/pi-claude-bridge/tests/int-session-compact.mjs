#!/usr/bin/env node
// syncSharedSession's REUSE check uses
// `priorMessages.slice(sharedSession.cursor)`. After /compact, pi shrinks
// its messages array — slice(N) on a shorter array returns []. Without an
// explicit signal, REUSE wins and CC keeps `--resume`ing the pre-compact
// session, which then thrashes its own autocompact. The bridge must subscribe
// to pi's `session_compact` event and set
// sharedSession.needsRebuild = true so the next syncSharedSession call
// takes the REBUILD path.

console.log("test=int-session-compact.mjs");

import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createRpcHarness } from "./lib/rpc-harness.mjs";

const TIMEOUT = 180_000;
const BRIDGE_MODEL = "pi-claude/claude-haiku-4-5";

// pi >=0.80 refuses to compact a session smaller than compaction.keepRecentTokens
// (default 20000) — far larger than this test's three tiny turns. Run against an
// isolated agent dir with a tiny keep-recent threshold so /compact always has
// something to cut. The machine's claude-bridge.json (e.g. a pinned Claude
// executable path) is carried over so the bridge still spawns correctly.
mkdirSync(join(process.cwd(), ".test-output"), { recursive: true });
const agentDir = mkdtempSync(join(process.cwd(), ".test-output/pi-compact-test-"));
writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ compaction: { keepRecentTokens: 100 } }));
const realBridgeConfig = join(homedir(), ".pi", "agent", "claude-bridge.json");
if (existsSync(realBridgeConfig)) copyFileSync(realBridgeConfig, join(agentDir, "claude-bridge.json"));

const harness = createRpcHarness({
	name: "session-compact",
	args: ["--model", BRIDGE_MODEL],
	env: { PI_CODING_AGENT_DIR: agentDir },
	defaultTimeout: TIMEOUT,
});

const { start, stop, send, promptAndWait, DEBUG_LOG, RPC_LOG } = harness;

function finish(code, msg) {
	if (code !== 0) throw new Error(msg);
	console.log(`test_exit=${code}\n${msg}`);
}

try {
	start();
	await new Promise((r) => setTimeout(r, 2000));
	// A few substantive turns so pi has something to compact.
	console.log("turn=1\nseed history...");
	await promptAndWait("Pick a number between 1 and 100 and remember it. Reply with just the number.");
	console.log("turn=2\nmore history...");
	await promptAndWait("Now pick a color. Reply with just the color.");
	console.log("turn=3\nmore history...");
	await promptAndWait("Now pick a fruit. Reply with just the fruit.");

	console.log("command=compact");
	await send({ type: "compact" });

	console.log("turn=4\nprompt after compact (should force REBUILD)...");
	await promptAndWait("Are you still there? Reply with just 'yes'.");

	// Split the log at the `session_compact:` marker. Reads BEFORE the
	// marker (including the summarization call pi made via our provider,
	// which legitimately uses the pre-compact session) don't matter — we
	// care about the first syncResult AFTER the event fires, which is
	// Turn 4's user prompt.
	const fullLog = readFileSync(DEBUG_LOG, "utf8");
	const compactIdx = fullLog.indexOf("session_compact:");
	if (compactIdx === -1) {
		throw new Error("no `session_compact:` debug marker — handler not subscribed?");
	}
	const postEventLog = fullLog.slice(compactIdx);

	// Capture both the path and the rebuild flavor (preserved | rotated-post-abort | first).
	const syncResults = [...postEventLog.matchAll(/syncResult: path=(reuse|rebuild|clean-start)(?: sessionId=\S+ priors=\d+ (\S+))?/g)]
		.map((m) => ({ path: m[1], flavor: m[2] }));
	console.log(`sync_results=${JSON.stringify(syncResults)}`);

	if (syncResults.length === 0) {
		throw new Error("no syncResult markers after session_compact event (Turn 4 didn't reach the provider?)");
	}

	const first = syncResults[0];

	// First syncResult after the event must NOT reuse — pi's history has
	// shrunk and CC's session JSONL is now stale.
	if (first.path === "reuse") {
		throw new Error(
			"bridge took REUSE path after session_compact — CC will resume the pre-compact session. " +
			"Expected REBUILD (or clean-start) so CC sees the post-compact history. " +
			"Symptom: triggers Claude Code's autocompact-thrashing (issue #8) on long sessions.");
	}

	// Compact has no concurrent CC writer, so the rebuild should preserve
	// the sessionId and wipe the JSONL in place (preserveId branch). If we
	// see "rotated-post-abort" here, the needsRebuild → preserveId logic
	// got re-conflated and we're leaking orphan JSONLs into ~/.claude/projects/
	// on every compact.
	if (first.path === "rebuild" && first.flavor !== "preserved") {
		throw new Error(
			`post-compact rebuild used flavor=${first.flavor}, expected "preserved". ` +
			`Compact has no concurrent CC writer — it should rebuild in place (deleteSession + ` +
			`createSession with the same UUID), not rotate. Rotating leaks orphan JSONL files.`);
	}

	finish(0, "PASS");
} catch (e) {
	console.error(`test_exit=1\n${e.stack ?? e.message}`);
	process.exitCode = 1;
} finally {
	await stop();
	rmSync(agentDir, { recursive: true, force: true });
}
