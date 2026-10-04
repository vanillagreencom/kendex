/**
 * Pi answers an abort once its own loop has stopped, which does not wait for
 * the bridge: the aborted query's teardown runs on that query's promise chain.
 * A prompt that arrives before the teardown finds the dying query still active.
 * Queued on it as a steer, the prompt is dropped by the abort completion and
 * its turn ends aborted with no answer; it has to wait for the teardown and
 * open a fresh query.
 */
import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { answerSdkQuery } from "./lib/fake-sdk-query.mjs";
import { assertSourceControl } from "./lib/source-control.mjs";
import { withBridge } from "./lib/queue-bridge.mjs";
import { waitFor } from "./lib/wait-for.mjs";

it("a prompt sent before the aborted query's teardown waits for it and gets its own answer", { timeout: 5000 }, async () => {
	const prompts = [];
	await withBridge(["t0"], async (bridge) => {
		bridge.abort();
		// Same tick as the abort: the teardown has not run yet.
		const stream = bridge.deliver([{ id: "t0", text: "Operation aborted", isError: true }], { steer: "the next request" });
		assert.notEqual(bridge.query.activeQuery, null, "the call arrived while the aborted query was still active");
		const events = [];
		const collecting = (async () => { for await (const event of stream) events.push(event); })();

		const ended = await waitFor(() => events.some((event) => event.type === "done" || event.type === "error"), 2000);
		assert.equal(ended, true, "the prompt's stream ends");
		await collecting;
		assert.deepEqual(prompts, ["the next request"], "on a fresh query prompted with the new request");
		assert.deepEqual(events.filter((event) => event.type === "done" || event.type === "error").map((event) => [event.type, event.reason]), [["done", "stop"]]);
		assert.deepEqual(events.filter((event) => event.type === "text_delta").map((event) => event.delta), ["answered"], "carrying that query's answer");
		assert.equal(bridge.query.deferredUserMessages.length, 0, "nothing was left queued on the aborted query");
	}, {
		continuationQuery: ({ prompt }) => {
			prompts.push(prompt);
			return answerSdkQuery("answered", "offline-successor");
		},
	});
});

describe("source control: the abort successor", () => {
	it("a call during the teardown is queued on the aborted query", { timeout: 60_000 }, () => assertSourceControl({
		source: "src/index.ts",
		before: "const abortedTeardown = queryCtx.abortedQueryTeardown;",
		after: "const abortedTeardown = null;",
		suite: "unit-abort-successor.mjs",
		pattern: "waits for it and gets its own answer",
		failure: /on a fresh query prompted with the new request/,
	}));
});
