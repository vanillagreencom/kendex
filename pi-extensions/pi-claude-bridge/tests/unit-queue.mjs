/** Exercise production MCP handlers and provider result delivery with an offline SDK transport. */
import assert from "node:assert/strict";
import { it } from "node:test";

// The bridge modules read the debug flag at load: scrub it before importing them.
delete process.env.CLAUDE_BRIDGE_DEBUG;
const { withBridge } = await import("./lib/queue-bridge.mjs");
const { DEBUG } = await import("../src/debug.ts");

const orderings = [
	{ name: "results before handlers", ids: ["t0", "t1", "t2"], steps: [["deliver", "t2", "t0", "t1"], ["handler", "t0", "t1", "t2"]] },
	{ name: "handlers before results", ids: ["t0", "t1", "t2"], steps: [["handler", "t0", "t1", "t2"], ["deliver", "t2", "t0", "t1"]] },
	{ name: "interleaved", ids: ["t0", "t1"], steps: [["handler", "t0"], ["deliver", "t0"], ["deliver", "t1"], ["handler", "t1"]] },
	{ name: "ID matching across mixed arrival order", ids: ["t0", "t1", "t2", "t3", "t4", "t5", "t6"], steps: [["handler", "t0", "t1", "t2"], ["deliver", "t4", "t3", "t2", "t1", "t0"], ["handler", "t3", "t4", "t5", "t6"], ["deliver", "t6", "t5"]] },
];
for (const row of orderings) it(row.name, { timeout: 5000 }, async () => {
	await withBridge(row.ids, async (bridge) => {
		const handlers = new Map();
		const delivered = new Set();
		for (const [action, ...ids] of row.steps) {
			if (action === "deliver") { bridge.deliver(ids.map((id) => ({ id, text: `result-${id}`, isError: id === "t0" }))); for (const id of ids) delivered.add(id); }
			else for (const id of ids) handlers.set(id, (await bridge.handler(id)).result);
			bridge.counts([...handlers.keys()].filter((id) => !delivered.has(id)).length, [...delivered].filter((id) => !handlers.has(id)).length);
		}
		for (const id of row.ids) assert.deepEqual(await handlers.get(id), { content: [{ type: "text", text: `result-${id}` }], isError: id === "t0", toolCallId: id });
		bridge.counts(0, 0);
	});
});

it("abort resolves waiting handlers and clears queued results before a fresh query", { timeout: 5000 }, async () => {
	await withBridge(["t0", "t1", "t2", "t3", "queued", "queued-again"], async (bridge) => {
		const handlers = [];
		for (const id of ["t0", "t1", "t2", "t3"]) handlers.push((await bridge.handler(id)).result);
		bridge.deliver([{ id: "t0", text: "resolved" }, { id: "queued", text: "stale" }]);
		bridge.counts(3, 1);
		bridge.deliver([{ id: "queued-again", text: "also stale" }]);
		bridge.counts(3, 2);
		bridge.abort();
		const results = await Promise.all(handlers);
		assert.equal(results[0].content[0].text, "resolved");
		for (const result of results.slice(1)) assert.deepEqual([result.isError, result.content[0].text.split("\n")[0]], [true, "tool-call-drain=abort"]);
		bridge.counts(0, 0);
	});
	await withBridge(["queued"], async (bridge) => {
		const fresh = (await bridge.handler("queued")).result;
		bridge.counts(1, 0);
		bridge.deliver([{ id: "queued", text: "fresh" }]);
		assert.equal((await fresh).content[0].text, "fresh");
		bridge.counts(0, 0);
	});
});

it("delivery serializes no result content for a debug preview while debugging is off", { timeout: 5000 }, async () => {
	assert.equal(DEBUG, false, "precondition: this test process must run with CLAUDE_BRIDGE_DEBUG unset");
	await withBridge(["t0"], async (bridge) => {
		const waiting = (await bridge.handler("t0")).result;
		const marker = "result-content-marker";
		const stringify = JSON.stringify;
		const serialized = [];
		JSON.stringify = (value, ...rest) => {
			const out = stringify(value, ...rest);
			if (typeof out === "string" && out.includes(marker)) serialized.push(out);
			return out;
		};
		try {
			bridge.deliver([{ id: "t0", text: marker }]);
		} finally {
			JSON.stringify = stringify;
		}
		assert.deepEqual(serialized, []);
		assert.equal((await waiting).content[0].text, marker);
	});
});
