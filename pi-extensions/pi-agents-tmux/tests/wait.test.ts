import assert from "node:assert/strict";
import test, { after } from "node:test";
import { waitForIdleTransition } from "../extensions/subagent/wait.js";
import { cleanupTempRuntimes, importRuntimeCopy } from "./browser-fixture.js";

after(cleanupTempRuntimes);

async function boundedRead(wait: typeof waitForIdleTransition): Promise<void> {
	let signal: AbortSignal | undefined;
	let fallback: ReturnType<typeof setTimeout> | undefined;
	try {
		// Real time exercises cancellation of an asynchronous dependency that never replies.
		const result = await wait((currentSignal) => {
			signal = currentSignal;
			return new Promise((_, reject) => { fallback = setTimeout(() => reject(new Error("stalled-read-fallback")), 100); });
		}, 5);
		assert.equal(result.timedOut, true);
		assert.equal(signal?.aborted, true);
	} finally {
		if (fallback) clearTimeout(fallback);
	}
}

test("a stalled readState cannot outlive the idle wait deadline", async () => {
	await boundedRead(waitForIdleTransition);
	const mutant = await importRuntimeCopy("wait.ts", "}, Math.max(0, deadline - Date.now()));", "}, 200);") as typeof import("../extensions/subagent/wait.js");
	await assert.rejects(boundedRead(mutant.waitForIdleTransition), /stalled-read-fallback/);
});
