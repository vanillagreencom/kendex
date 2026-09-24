/**
 * Pi 0.86 moved the system prompt and the tool declarations out of
 * `Context.systemPrompt` / `Context.tools` and into `system` entries of
 * `context.messages`. Both halves have to be read from there, and this is the
 * surface where a miss is invisible: the provider still runs, the child still
 * answers, and the turn merely arrives with no pi tools and no pi prompt
 * (kendex#2749).
 */
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { __testSetBridgeIntegrityState, __testSetSdkQueryFactory, streamClaudeAgentSdk } from "../src/index.ts";
import { resetStack } from "../src/query-state.ts";
import { piContext } from "./lib/transcript.mjs";

const model = { id: "claude-haiku-4-5", api: "claude-bridge", provider: "pi-claude", cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const tool = { name: "read", description: "Read a file", parameters: { type: "object", properties: { path: { type: "string" } }, required: ["path"] } };
const SKILLS_BLOCK = [
	"The following skills provide specialized instructions for specific tasks.",
	"Use the read tool to load a skill's file when the task matches its description.",
	"",
	"<available_skills>",
	"  <skill><name>br</name><description>Browser automation.</description></skill>",
	"</available_skills>",
].join("\n");

const collect = async (stream) => { const events = []; for await (const event of stream) events.push(event); return events; };

/** Run one turn against an offline SDK transport and return the options it received. */
async function optionsFor(context) {
	const root = mkdtempSync(join(tmpdir(), "bridge-transcript-"));
	const env = { CLAUDE_CONFIG_DIR: root, PI_CODING_AGENT_DIR: root, CLAUDE_CODE_OAUTH_TOKEN: "offline-test", CLAUDE_BRIDGE_STREAM_IDLE_TIMEOUT: "0" };
	const previous = Object.fromEntries(Object.keys(env).map((key) => [key, process.env[key]]));
	Object.assign(process.env, env);
	resetStack();
	__testSetBridgeIntegrityState({ sharedSession: null, ui: { notify() {} } });
	const calls = [];
	__testSetSdkQueryFactory(({ options }) => {
		calls.push(options);
		return {
			async *[Symbol.asyncIterator]() {
				yield { type: "system", subtype: "init", session_id: "offline-transcript" };
				yield { type: "result", subtype: "success", result: "done" };
			},
			close() {},
			async interrupt() {},
		};
	});
	try {
		await collect(streamClaudeAgentSdk(model, context, { cwd: root }));
		assert.equal(calls.length, 1, "the turn opened exactly one query");
		return calls[0];
	} finally {
		__testSetSdkQueryFactory();
		__testSetBridgeIntegrityState({ sharedSession: null, ui: null });
		resetStack();
		for (const [key, value] of Object.entries(previous)) { if (value === undefined) delete process.env[key]; else process.env[key] = value; }
		rmSync(root, { recursive: true, force: true });
	}
}

describe("the provider reads Pi's 0.86 transcript", () => {
	it("bridges the tools a system entry declares and appends the prompt it carries", async () => {
		const options = await optionsFor(piContext({
			messages: [{ role: "user", content: "read the file" }],
			tools: [tool],
			systemPrompt: `You are a coding assistant.\n\n${SKILLS_BLOCK}`,
		}));

		assert.deepEqual(Object.keys(options.mcpServers ?? {}), ["custom-tools"], "pi's tools reach the child on the bridged server");
		assert.ok(
			options.systemPrompt.append.includes("Use the read tool (mcp__custom-tools__read) to load a skill's file"),
			"and pi's skills block is appended, rewritten for the bridged tool name",
		);
	});

	it("leaves Claude Code's own tools in place when the transcript declares none", async () => {
		const options = await optionsFor(piContext({ messages: [{ role: "user", content: "just answer" }] }));

		assert.equal(options.mcpServers, undefined, "there is no bridged server to route tool calls to");
		assert.equal("tools" in options, false, "so the fail-soft leaves the child its own tools");
	});
});
