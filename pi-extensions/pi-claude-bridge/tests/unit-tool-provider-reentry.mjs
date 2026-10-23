/** Surface: a Pi tool's same-provider completion must not consume its parent's
 * result-delivery stream. Inputs: provider entry, MCP bridge, query state and
 * queue-bridge transport. The parent process bounds a genuinely stuck call. */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { it } from "node:test";

const orderings = [
	{ name: "handler before nested request", handlerFirst: true, deliverFirst: false },
	{ name: "nested request before handler registration", handlerFirst: false, deliverFirst: false },
	{ name: "nested request and result before handler registration", handlerFirst: false, deliverFirst: true },
];
const childRow = orderings.find((row) => process.argv.includes(`--reentry-child=${row.name}`));
if (childRow) {
	const { withBridge } = await import("./lib/queue-bridge.mjs");
	const { streamClaudeAgentSdk } = await import("../src/index.ts");
	const { piContext } = await import("./lib/transcript.mjs");
	const model = { id: "claude-haiku-4-5", api: "claude-bridge", provider: "pi-claude" };
	const collect = async (stream) => { const events = []; for await (const event of stream) events.push(event); return events; };
	await withBridge(["answer"], async (bridge) => {
		let result;
		if (childRow.handlerFirst) ({ result } = await bridge.handler("answer"));
		const query = bridge.query;
		const generation = query.callbackGeneration;
		const output = query.turnOutput;
		const parentStream = query.currentPiStream;
		const activeQuery = query.activeQuery;
		const cursor = query.latestCursor;
		// pi-web-access answer mode awaits a separate completion using the
		// active model before Pi can append this tool's result to its context.
		const executeTool = async () => {
			process.stdout.write(`tool-provider-reentry=waiting handlers=${query.pendingToolCalls.size}\n`);
			const nested = await collect(streamClaudeAgentSdk(model, piContext({ messages: [
				{ role: "user", content: "Answer this page question" },
			] })));
			assert.equal(nested.length, 1);
			assert.equal(nested[0].type, "error");
			assert.equal(nested[0].reason, "error");
			assert.equal(nested[0].error.stopReason, "error");
			assert.equal(query.callbackGeneration, generation);
			assert.equal(query.turnOutput, output);
			assert.equal(query.currentPiStream, parentStream);
			assert.equal(query.activeQuery, activeQuery);
			assert.equal(query.latestCursor, cursor);
			assert.equal(query.deferredUserMessages.length, 0);
			return { id: "answer", text: nested[0].error.errorMessage, isError: true };
		};
		const toolResult = await executeTool();
		if (!childRow.handlerFirst && !childRow.deliverFirst) ({ result } = await bridge.handler("answer"));
		const resumed = collect(bridge.deliver([toolResult]));
		if (childRow.deliverFirst) ({ result } = await bridge.handler("answer"));
		assert.equal((await result).isError, true);
		bridge.counts(0, 0);
		bridge.release();
		const events = await resumed;
		assert.equal(events.at(-1).type, "done");
		await bridge.finish();
	});
} else {
	it("Pi result obligations follow forwarding, delivery and terminal cleanup across handler orderings", async () => {
		const { QueryContext, drainPendingToolCalls } = await import("../src/query-state.ts");
		const rows = [
			{ name: "not forwarded", steps: [], awaiting: false },
			{ name: "forwarded before handler", steps: ["forward"], awaiting: true },
			{ name: "forwarded with handler", steps: ["forward", "handler"], awaiting: true },
			{ name: "message boundary before result", steps: ["forward", "boundary"], awaiting: true },
			{ name: "result queued before handler", steps: ["forward", "deliver"], awaiting: false },
			{ name: "result parked past boundary", steps: ["forward", "deliver", "park", "boundary"], awaiting: false },
			{ name: "result resolved by handler", steps: ["forward", "handler", "deliver", "resolve"], awaiting: false },
			{ name: "duplicate forward after delivery", steps: ["forward", "deliver", "boundary", "forward"], awaiting: false },
			{ name: "split batch still owes sibling", steps: ["forward", "sibling", "deliver"], awaiting: true },
			{ name: "terminal cleanup before handler", steps: ["forward", "drain"], awaiting: false },
			{ name: "terminal cleanup with handler", steps: ["forward", "handler", "drain"], awaiting: false },
		];
		for (const row of rows) {
			const query = new QueryContext();
			for (const step of row.steps) {
				switch (step) {
					case "forward": query.markToolCallForwarded("answer"); break;
					case "sibling": query.markToolCallForwarded("sibling"); break;
					case "handler": query.pendingToolCalls.set("answer", { toolName: "echo", args: {}, generation: 0, resolve() {} }); break;
					case "boundary": query.resetToolTracking(); break;
					case "deliver": query.markToolResultDelivered("answer"); query.pendingResults.set("answer", { content: [] }); break;
					case "park": query.takeStaleQueuedResults(); break;
					case "resolve": query.markToolResultResolved("answer"); break;
					case "drain": drainPendingToolCalls(query, "query-end"); break;
					default: assert.fail(`unknown step ${step}`);
				}
			}
			assert.equal(query.awaitingPiToolResults, row.awaiting, row.name);
		}
	});
	for (const row of orderings) it(`a tool awaiting the active provider returns an error and ends the outer turn: ${row.name}`, () => {
		const home = mkdtempSync(join(tmpdir(), "bridge-reentry-"));
		try {
			const child = spawnSync(process.execPath, ["--import", "tsx", fileURLToPath(import.meta.url), `--reentry-child=${row.name}`], {
				cwd: fileURLToPath(new URL("../", import.meta.url)),
				env: { PATH: process.env.PATH, HOME: home, PI_CODING_AGENT_DIR: home, CLAUDE_CONFIG_DIR: home },
				encoding: "utf8",
				timeout: 15_000,
				killSignal: "SIGKILL",
			});
			assert.equal(child.error, undefined, `${child.error}\n${child.stdout}\n${child.stderr}`);
			assert.equal(child.status, 0, `${child.stdout}\n${child.stderr}`);
		} finally { rmSync(home, { recursive: true, force: true }); }
	});
}
