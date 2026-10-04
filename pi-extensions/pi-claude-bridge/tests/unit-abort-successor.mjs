/**
 * Pi answers an abort once its own loop has stopped, which does not wait for
 * the bridge: the aborted query's teardown runs on that query's promise chain.
 * A prompt that arrives before the teardown finds the dying query still active.
 * Queued on it as a steer, the prompt is dropped by the abort completion and
 * its turn ends aborted with no answer; it has to wait for the teardown and
 * open a fresh query. That query owns the context from then on, so what the
 * dying query's chain still does after its teardown must not write to it.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { onPiHistoryReplaced } from "../src/index.ts";
import { answerSdkQuery } from "./lib/fake-sdk-query.mjs";
import { assertSourceControl } from "./lib/source-control.mjs";
import { withBridge } from "./lib/queue-bridge.mjs";
import { waitFor } from "./lib/wait-for.mjs";

const endings = (events) => events.filter((event) => event.type === "done" || event.type === "error");

describe("a prompt sent before the aborted query's teardown waits for it and gets its own answer", () => {
	// A restart pending at the abort ends its own callback's stream after the
	// teardown, which is when the prompt's fresh query already runs.
	for (const { when, restartPending } of [
		{ when: "after a plain abort", restartPending: false },
		{ when: "with a history restart pending at the abort", restartPending: true },
	]) {
		it(when, { timeout: 5000 }, async () => {
			const prompts = [];
			await withBridge(["t0"], async (bridge) => {
				const restartEvents = [];
				let restartCollecting;
				if (restartPending) {
					onPiHistoryReplaced("session_compact");
					const restartStream = bridge.deliver([{ id: "t0" }]);
					restartCollecting = (async () => { for await (const event of restartStream) restartEvents.push(event); })();
				}
				bridge.abort();
				// Same tick as the abort: the teardown has not run yet.
				const stream = bridge.deliver([{ id: "t0", text: "Operation aborted", isError: true }], { steer: "the next request" });
				assert.notEqual(bridge.query.activeQuery, null, "the call arrived while the aborted query was still active");
				const events = [];
				const collecting = (async () => { for await (const event of stream) events.push(event); })();

				const ended = await waitFor(() => endings(events).length > 0, 2000);
				assert.equal(ended, true, "the prompt's stream ends");
				await collecting;
				assert.deepEqual(prompts, ["the next request"], "on a fresh query prompted with the new request");
				assert.deepEqual(endings(events).map((event) => [event.type, event.reason, event.message?.stopReason, event.message?.errorMessage]), [["done", "stop", "stop", undefined]], "ending as its own answer, not as the abort");
				assert.deepEqual(events.filter((event) => event.type === "text_delta").map((event) => event.delta), ["answered"], "carrying that query's answer");
				assert.equal(bridge.query.deferredUserMessages.length, 0, "nothing was left queued on the aborted query");
				if (restartPending) {
					await restartCollecting;
					assert.deepEqual(endings(restartEvents).map((event) => [event.type, event.reason]), [["error", "aborted"]], "the restart's callback ends aborted");
					assert.notEqual(endings(restartEvents)[0].error, endings(events)[0].message, "on a message of its own");
				}
			}, {
				continuationQuery: ({ prompt }) => {
					prompts.push(prompt);
					return answerSdkQuery("answered", "offline-successor");
				},
			});
		});
	}
});

describe("source control: the abort successor", () => {
	const rows = [
		{
			why: "a call during the teardown is queued on the aborted query",
			before: "const abortedTeardown = queryCtx.abortedQueryTeardown;",
			after: "const abortedTeardown = null;",
			pattern: "after a plain abort",
			failure: /on a fresh query prompted with the new request/,
		},
		{
			why: "the aborted restart writes its outcome onto the context the prompt's query owns",
			before: "reentryStream.push({ type: \"error\", reason: \"aborted\", error: failedTurnOutput(restart.model, \"aborted\", \"Operation aborted\") });",
			after: "abortCtx.resetTurnState(restart.model); reentryStream.push({ type: \"error\", reason: \"aborted\", error: Object.assign(abortCtx.turnOutput!, { stopReason: \"aborted\", errorMessage: \"Operation aborted\" }) });",
			pattern: "with a history restart pending at the abort",
			failure: /ending as its own answer, not as the abort/,
		},
	];
	for (const { why, ...row } of rows) {
		it(why, { timeout: 60_000 }, () => assertSourceControl({ ...row, source: "src/index.ts", suite: "unit-abort-successor.mjs" }));
	}
});
