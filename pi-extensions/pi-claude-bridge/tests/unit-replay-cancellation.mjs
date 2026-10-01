import assert from "node:assert/strict";
import { it } from "node:test";
import { heldSdkQuery } from "./lib/fake-sdk-query.mjs";
import { withBridge } from "./lib/queue-bridge.mjs";
import { waitFor } from "./lib/wait-for.mjs";
import { __testGetBridgeIntegrityState } from "../src/index.ts";
import { activeStreamIdleWatchdogs } from "../src/stream-idle-watchdog.ts";

// Pi drains a steer beside a tool result. The original SDK child completes,
// then the bridge replays the steer in a new child whose transport stays silent.
for (const { name, messages } of [
	{ name: "silent continuation", messages: [] },
	{ name: "continuation after output", messages: [{ type: "assistant", message: { content: [{ type: "text", text: "replayed output" }] } }] },
]) {
	it(`abort ends ${name} without another SDK message`, { timeout: 5000 }, async (t) => {
		const child = heldSdkQuery(messages);
		try {
			await withBridge(["t0"], async (bridge) => {
				const events = [];
				const stream = bridge.deliver([{ id: "t0" }], { steer: "queued steer" });
				const collecting = (async () => { for await (const event of stream) events.push(event); })();
				assert.deepEqual(bridge.query.deferredUserMessages.map((message) => message.text), ["queued steer"]);
				bridge.release();
				await child.record.entered;
				assert.equal(bridge.query.activeQuery, child.query, "the continuation owns the active child");
				const started = performance.now();
				bridge.abort();
				// Real time is required to prove the issue's one-second cancellation bound.
				const settled = await waitFor(() => bridge.query.activeQuery === null && events.some((event) => event.type === "error"), 1000);
				const elapsed = performance.now() - started;
				t.diagnostic(`abort-to-ended-stream-and-released-query-ms=${elapsed.toFixed(3)}`);
				assert.equal(child.record.interruptions, 1, "abort must target the continuation");
				assert.equal(child.record.closed, true, "abort closes the continuation transport");
				assert.equal(settled, true, "Pi and query teardown must finish within one second without a child message");
				assert.ok(elapsed < 1000, "cancellation met the measured bound");
				await collecting;
				assert.deepEqual(events.filter((event) => event.type === "error" || event.type === "done").map((event) => [event.type, event.reason]), [["error", "aborted"]]);
				assert.equal(events.at(-1).error.stopReason, "aborted");
				assert.equal(activeStreamIdleWatchdogs.has(bridge.query), false, "teardown released the watchdog");
				assert.equal(__testGetBridgeIntegrityState().sharedSession?.needsRebuild, true, "the interrupted replay must rebuild from Pi history");
				child.release([{ type: "result", subtype: "success", result: "late output" }]);
				await new Promise((resolve) => setImmediate(resolve));
				assert.equal(events.at(-1).error.stopReason, "aborted", "late SDK messages cannot replace the aborted outcome");
			}, { continuationQuery: () => child.query });
		} finally { child.release(); }
	});
}

it("idle watchdog stops a silent continuation after the original child emitted output", { timeout: 5000 }, async (t) => {
	const child = heldSdkQuery();
	try {
		await withBridge(["t0"], async (bridge) => {
			// The watchdog uses Date and setTimeout. Advance that clock rather than
			// waiting for the production idle deadline in real time.
			t.mock.timers.enable({ apis: ["Date", "setTimeout"], now: Date.now() });
			const events = [];
			const stream = bridge.deliver([{ id: "t0" }], { steer: "queued steer" });
			const collecting = (async () => { for await (const event of stream) events.push(event); })();
			bridge.release();
			await child.record.entered;
			assert.equal(bridge.query.turnStarted, false, "the replay has not emitted output");
			t.mock.timers.tick(999);
			// Teardown and stream forwarding use microtasks, not the mocked clock.
			for (let turn = 0; turn < 100; turn++) await Promise.resolve();
			assert.equal(bridge.query.activeQuery, child.query, "the continuation stays active before its deadline");
			assert.equal(child.record.interruptions, 0, "the watchdog cannot interrupt before its deadline");
			assert.equal(child.record.closed, false, "the watchdog cannot close the transport before its deadline");
			assert.deepEqual(events.filter((event) => event.type === "error" || event.type === "done"), [], "the stream has no terminal event before its deadline");
			t.mock.timers.tick(1);
			for (let turn = 0; turn < 100; turn++) await Promise.resolve();
			assert.equal(child.record.interruptions, 1, "the watchdog targets the continuation");
			assert.equal(child.record.closed, true);
			assert.equal(bridge.query.activeQuery, null, "the timeout releases the query even with a blocked iterator");
			await collecting;
			assert.deepEqual(events.filter((event) => event.type === "error" || event.type === "done").map((event) => [event.type, event.reason]), [["error", "error"]]);
			assert.equal(events.at(-1).error.rateLimitType, "stream_idle");
			assert.equal(activeStreamIdleWatchdogs.has(bridge.query), false);
			assert.equal(__testGetBridgeIntegrityState().sharedSession?.needsRebuild, true);
			t.mock.timers.reset();
		}, {
			continuationQuery: () => child.query,
			idleTimeout: "1s",
			completionMessages: [
				{ type: "assistant", message: { content: [{ type: "text", text: "original output" }] } },
				{ type: "result", subtype: "success", result: "original output" },
			],
		});
	} finally {
		child.release();
		t.mock.timers.reset();
	}
});

it("a completed replay keeps its successful outcome when Escape arrives later", { timeout: 5000 }, async () => {
	await withBridge(["t0"], async (bridge) => {
		const events = [];
		const stream = bridge.deliver([{ id: "t0" }], { steer: "queued steer" });
		const collecting = (async () => { for await (const event of stream) events.push(event); })();
		await bridge.finish();
		await collecting;
		bridge.abort();
		assert.deepEqual(events.filter((event) => event.type === "error" || event.type === "done").map((event) => [event.type, event.reason]), [["done", "stop"]]);
		assert.equal(events.at(-1).message.stopReason, "stop");
	});
});
