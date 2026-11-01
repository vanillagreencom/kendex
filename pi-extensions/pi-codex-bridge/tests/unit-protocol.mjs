import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import test from "node:test";
import { CodexProtocolClient } from "../src/json-rpc.ts";
import { classifyRequestFailure, decodeMcpServerNames } from "../src/protocol.ts";

const SENTINEL = "SENTINEL-mcp-env-value-1658";

/** A child whose stdout the test writes and whose stdin it reads. */
function fakeChild() {
	const child = new EventEmitter();
	child.stdin = new PassThrough();
	child.stdout = new PassThrough();
	child.stderr = new PassThrough();
	child.exitCode = null;
	child.signalCode = null;
	child.kill = () => true;
	const sent = [];
	child.stdin.on("data", (chunk) => sent.push(...chunk.toString().split("\n").filter(Boolean).map((line) => JSON.parse(line))));
	return { child, sent };
}

const configReply = (id) => ({
	id,
	result: {
		config: {
			model: "gpt-x",
			mcp_servers: {
				user_marker: { command: `/bin/${SENTINEL}`, args: ["--token", SENTINEL], env: { FAKE_TOKEN: SENTINEL } },
				project_marker: { url: `https://${SENTINEL}.invalid/mcp`, bearer_token_env_var: SENTINEL },
			},
			model_providers: { corp: { experimental_bearer_token: SENTINEL } },
		},
		origins: { "mcp_servers.user_marker.env.FAKE_TOKEN": { name: { type: "user" } } },
		layers: null,
	},
});

test("config/read reaches the bridge as server names only", async () => {
	const { child, sent } = fakeChild();
	const client = new CodexProtocolClient(child, false);
	const reply = client.requestDecoded("config/read", { cwd: "/workspace" }, decodeMcpServerNames);
	await new Promise((resolve) => setImmediate(resolve));
	const [request] = sent;
	child.stdout.write(`${JSON.stringify(configReply(request.id))}\n`);
	const names = await reply;
	assert.deepEqual(names, ["project_marker", "user_marker"]);
	assert.equal(JSON.stringify(names).includes(SENTINEL), false);
});

test("a failed config/read names its code, never the configuration text", async () => {
	const { child, sent } = fakeChild();
	const client = new CodexProtocolClient(child, false);
	const reply = client.requestDecoded("config/read", {}, decodeMcpServerNames);
	await new Promise((resolve) => setImmediate(resolve));
	child.stdout.write(`${JSON.stringify({ id: sent[0].id, error: { code: -32600, message: `invalid value ${SENTINEL}` } })}\n`);
	await assert.rejects(reply, (error) => error.message === "codex-request-failed method=config/read code=-32600");
});

for (const [name, result] of [
	["no config", {}],
	["a config that is not an object", { config: [] }],
	["an mcp_servers table that is not an object", { config: { mcp_servers: "fixture" } }],
]) {
	test(`a malformed config/read is refused: ${name}`, () => {
		assert.throws(() => decodeMcpServerNames(result), (error) => error.message.startsWith("codex-protocol-invalid method=config/read"));
	});
}

// Real Codex 0.163.0 replies, captured from the app-server, beside replies the
// table must not match.
for (const [method, code, message, kind] of [
	["thread/resume", -32600, "no rollout found for thread id 01a15600-0000-7000-8000-000000000000", "thread-not-found"],
	["turn/interrupt", -32600, "no active turn to interrupt", "no-active-turn"],
	["thread/resume", -32603, "no rollout found for thread id 01a15600-0000-7000-8000-000000000000", null],
	["thread/start", -32600, "no rollout found for thread id x", null],
	["thread/resume", -32600, "failed to load configuration: invalid transport\nin `mcp_servers.nope`\n", null],
]) {
	test(`a ${method} ${code} reply is classified ${kind}`, () => {
		assert.equal(classifyRequestFailure(method, code, message), kind);
	});
}
