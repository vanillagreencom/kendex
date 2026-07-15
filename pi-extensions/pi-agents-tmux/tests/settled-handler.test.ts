import assert from "node:assert/strict";
import test from "node:test";
import { registerSettledHandler } from "../extensions/subagent/settled-handler.js";

test("settled handler registers only agent_settled and forwards context once", async () => {
	const handlers = new Map<string, (event: unknown, ctx: any) => void | Promise<void>>();
	const calls: any[] = [];
	registerSettledHandler({ on(name, handler) { handlers.set(name, handler); } }, async (ctx) => {
		calls.push(ctx);
	});

	assert.deepEqual([...handlers.keys()], ["agent_settled"]);
	await handlers.get("agent_settled")?.({}, { settled: true });
	assert.deepEqual(calls, [{ settled: true }]);
});