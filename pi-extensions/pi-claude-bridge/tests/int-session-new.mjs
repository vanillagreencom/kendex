#!/usr/bin/env node
// The bridge must clear sharedSession when Pi starts a replacement session.

console.log("test=int-session-new.mjs");

import { readFileSync } from "node:fs";
import { createRpcHarness } from "./lib/rpc-harness.mjs";

const TIMEOUT = 180_000;
const BRIDGE_MODEL = "pi-claude/claude-haiku-4-5";

const harness = createRpcHarness({
	name: "session-new",
	args: ["--model", BRIDGE_MODEL],
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
	console.log("turn=1\nseed history...");
	await promptAndWait("Pick a number between 1 and 100 and remember it. Reply with just the number.");
	console.log("turn=2\nmore history...");
	await promptAndWait("Now pick a color. Reply with just the color.");

	const NEW_MARKER_LOG = readFileSync(DEBUG_LOG, "utf8").length;

	console.log("command=new_session");
	await send({ type: "new_session" });

	console.log("turn=3\nprompt after /new (should be a clean start)...");
	await promptAndWait("Hello fresh session. Reply with just 'hi'.");

	const fullLog = readFileSync(DEBUG_LOG, "utf8");
	const postNewLog = fullLog.slice(NEW_MARKER_LOG);

	// The bridge must log that it observed the session-start event.
	if (!/session_start:new: clearing session/.test(postNewLog)) {
		finish(1, "FAIL: no `session_start:new: clearing session` marker — bridge didn't observe /new");
	}

	// The first syncResult must be a clean start (sharedSession=null,
	// no prior messages on the fresh agent state).
	const syncResults = [...postNewLog.matchAll(/syncResult: path=(reuse|rebuild|clean-start)/g)].map((m) => m[1]);
	console.log(`sync_results=${JSON.stringify(syncResults)}`);
	if (syncResults.length === 0) {
		finish(1, "FAIL: no syncResult markers after /new (Turn 3 didn't reach the provider?)");
	}
	if (syncResults[0] !== "clean-start") {
		finish(1,
			`FAIL: bridge took ${syncResults[0]} path after /new — expected clean-start.\n` +
			`       sharedSession should be cleared by the session_start:new handler.`);
	}

	finish(0, "PASS");
} catch (e) {
	console.error(`test_exit=1\n${e.stack ?? e.message}`);
	process.exitCode = 1;
} finally {
	await stop();
}
