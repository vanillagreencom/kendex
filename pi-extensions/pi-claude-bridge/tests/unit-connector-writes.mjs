import { test } from "node:test";
import assert from "node:assert/strict";
import {
	toolIsolationForQuery,
	connectorQueryOptions,
	connectorWriteDenyHook,
	CONNECTOR_WRITE_TOOLS,
	CLAUDE_AI_CONNECTOR_TOOL_PATTERNS,
} from "../bundle/index.js";

// Drive the hook the way the SDK does: PreToolUse input + tool name.
async function runHook(hook, toolName) {
	return hook({ hook_event_name: "PreToolUse", tool_name: toolName, tool_input: {}, tool_use_id: "t1" }, "t1", { signal: new AbortController().signal });
}
function isDeny(out) {
	return out?.hookSpecificOutput?.permissionDecision === "deny";
}

test("write hook denies mutations and preserves connector reads and other tools", async () => {
	const hook = connectorWriteDenyHook();
	const rows = [
		["mcp__claude_ai_Gmail__send_message", true],
		["mcp__claude_ai_Gmail__create_draft", true],
		["mcp__claude_ai_Google_Drive__delete_file", true],
		["mcp__claude_ai_Slack__send_message", true],
		["mcp__claude_ai_Atlassian__create_issue", true],
		["mcp__claude_ai_Gmail__search_threads", false],
		["mcp__claude_ai_Slack__search_messages", false],
		["ToolSearch", false], ["mcp__custom-tools__foo", false],
		["mcp__some_other_server__create_thing", false], [42, true],
	];
	for (const [name, denied] of rows) {
		const out = await runHook(hook, name);
		assert.deepEqual({ decision: out.hookSpecificOutput?.permissionDecision, reason: out.hookSpecificOutput?.permissionDecisionReason?.split("\n")[0], continue: out.continue },
			denied ? { decision: "deny", reason: `connector-write-denied=${JSON.stringify(typeof name === "string" ? name : "<unknown>")}`, continue: undefined }
				: { decision: undefined, reason: undefined, continue: true }, String(name));
	}
});

test("connectorQueryOptions(true) [deny] wires disallowedTools ids AND both PreToolUse hooks", async () => {
	const opts = connectorQueryOptions(true); // default deny
	for (const w of CONNECTOR_WRITE_TOOLS) assert.ok(opts.disallowedTools.includes(w), `deny id ${w}`);
	for (const p of CLAUDE_AI_CONNECTOR_TOOL_PATTERNS) assert.ok(opts.allowedTools.includes(p), `allow ${p}`);
	assert.ok(Array.isArray(opts.hooks?.PreToolUse), "PreToolUse hooks registered");
	assert.equal(opts.hooks.PreToolUse.length, 1);
	// Builtin allowlist + write deny, in that order (C13).
	assert.equal(opts.hooks.PreToolUse[0].hooks.length, 2);
	const [allowlist, writeDeny] = opts.hooks.PreToolUse[0].hooks;
	assert.ok(isDeny(await runHook(allowlist, "SlashCommand")), "allowlist denies non-permitted builtins");
	assert.ok(isDeny(await runHook(writeDeny, "mcp__claude_ai_Gmail__create_draft")), "write hook denies connector writes");
});

test("connectorQueryOptions(true, 'allow') exposes writes but KEEPS the builtin allowlist", async () => {
	const opts = connectorQueryOptions(true, "allow");
	for (const w of CONNECTOR_WRITE_TOOLS) assert.ok(!opts.disallowedTools.includes(w), `not denied ${w}`);
	for (const p of CLAUDE_AI_CONNECTOR_TOOL_PATTERNS) assert.ok(opts.allowedTools.includes(p), `allow ${p}`);
	// The one-shot write executor is still a connectors session ingesting
	// third-party content: no write-deny hook, but the allowlist stays (C13).
	assert.equal(opts.hooks.PreToolUse[0].hooks.length, 1);
	const [allowlist] = opts.hooks.PreToolUse[0].hooks;
	assert.equal((await runHook(allowlist, "mcp__claude_ai_Gmail__create_draft")).continue, true, "writes pass the allowlist in allow mode");
	assert.ok(isDeny(await runHook(allowlist, "SlashCommand")), "unknown builtins still denied in allow mode");
});

test("connectorQueryOptions(false) [connectors off] is default isolation, no hook, no write denies", () => {
	const deny = connectorQueryOptions(false, "deny");
	const allow = connectorQueryOptions(false, "allow");
	assert.deepEqual(deny, allow); // write mode ignored when connectors off
	assert.deepEqual(deny.tools, []);
	assert.equal(deny.hooks, undefined);
	for (const w of CONNECTOR_WRITE_TOOLS) assert.ok(!deny.disallowedTools.includes(w), `no connector write in default isolation ${w}`);
});

test("toolIsolationForQuery still denies writes fail-closed (any non-allow mode)", () => {
	for (const mode of ["deny", undefined, "read-only"]) {
		const iso = toolIsolationForQuery(true, mode);
		for (const w of CONNECTOR_WRITE_TOOLS) assert.ok(iso.disallowedTools.includes(w), `mode ${mode} denies ${w}`);
	}
	const allow = toolIsolationForQuery(true, "allow");
	for (const w of CONNECTOR_WRITE_TOOLS) assert.ok(!allow.disallowedTools.includes(w), `allow exposes ${w}`);
});
