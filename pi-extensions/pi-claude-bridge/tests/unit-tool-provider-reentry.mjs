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

if (process.argv.includes("--reentry-child")) {
	const { withBridge } = await import("./lib/queue-bridge.mjs");
	const { streamClaudeAgentSdk } = await import("../src/index.ts");
	const { piContext } = await import("./lib/transcript.mjs");
	const model = { id: "claude-haiku-4-5", api: "claude-bridge", provider: "pi-claude" };
	const collect = async (stream) => { const events = []; for await (const event of stream) events.push(event); return events; };
	await withBridge(["answer"], async (bridge) => {
		const { result } = await bridge.handler("answer");
		const query = bridge.query;
		const generation = query.callbackGeneration;
		const output = query.turnOutput;
		const parentStream = query.currentPiStream;
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
			assert.equal(query.deferredUserMessages.length, 0);
			return { id: "answer", text: nested[0].error.errorMessage, isError: true };
		};
		const toolResult = await executeTool();
		const resumed = collect(bridge.deliver([toolResult]));
		assert.equal((await result).isError, true);
		bridge.counts(0, 0);
		bridge.release();
		const events = await resumed;
		assert.equal(events.at(-1).type, "done");
		await bridge.finish();
	});
} else {
	it("a tool awaiting the active provider returns an error and ends the outer turn", () => {
		const home = mkdtempSync(join(tmpdir(), "bridge-reentry-"));
		try {
			const child = spawnSync(process.execPath, ["--import", "tsx", fileURLToPath(import.meta.url), "--reentry-child"], {
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
