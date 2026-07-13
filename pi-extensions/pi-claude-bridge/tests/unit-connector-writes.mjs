import { test } from "node:test";
import assert from "node:assert/strict";
import {
	connectorWriteModeFromEnv,
	connectorWriteModeFor,
	toolIsolationForQuery,
	connectorQueryOptions,
	connectorWriteDenyHook,
	isConnectorWriteTool,
	CONNECTOR_WRITE_TOOLS,
	CLAUDE_AI_CONNECTOR_TOOL_PATTERNS,
} from "../bundle/index.js";

function withEnv(value, fn) {
	const prev = process.env.CLAUDE_BRIDGE_CONNECTOR_WRITE;
	if (value === undefined) delete process.env.CLAUDE_BRIDGE_CONNECTOR_WRITE;
	else process.env.CLAUDE_BRIDGE_CONNECTOR_WRITE = value;
	try { return fn(); } finally {
		if (prev === undefined) delete process.env.CLAUDE_BRIDGE_CONNECTOR_WRITE;
		else process.env.CLAUDE_BRIDGE_CONNECTOR_WRITE = prev;
	}
}

// Drive the hook the way the SDK does: PreToolUse input + tool name.
async function runHook(hook, toolName) {
	return hook({ hook_event_name: "PreToolUse", tool_name: toolName, tool_input: {}, tool_use_id: "t1" }, "t1", { signal: new AbortController().signal });
}
function isDeny(out) {
	return out?.hookSpecificOutput?.permissionDecision === "deny";
}

test("connectorWriteModeFromEnv parses deny/allow (case-insensitive), else undefined", () => {
	assert.equal(withEnv("allow", connectorWriteModeFromEnv), "allow");
	assert.equal(withEnv(" ALLOW ", connectorWriteModeFromEnv), "allow");
	assert.equal(withEnv("deny", connectorWriteModeFromEnv), "deny");
	assert.equal(withEnv("DENY", connectorWriteModeFromEnv), "deny");
	for (const v of [undefined, "", "1", "true", "read-only", "nope"]) {
		assert.equal(withEnv(v, connectorWriteModeFromEnv), undefined, String(v));
	}
});

test("connectorWriteModeFor defaults to deny (no env, no config)", () => {
	assert.equal(withEnv(undefined, () => connectorWriteModeFor(undefined)), "deny");
	assert.equal(withEnv(undefined, () => connectorWriteModeFor({ provider: {} })), "deny");
});

test("connectorWriteModeFor: env allow enables writes", () => {
	assert.equal(withEnv("allow", () => connectorWriteModeFor(undefined)), "allow");
});

test("connectorWriteModeFor: config allow enables writes", () => {
	assert.equal(withEnv(undefined, () => connectorWriteModeFor({ provider: { connectorWriteMode: "allow" } })), "allow");
});

test("connectorWriteModeFor: env beats config both directions", () => {
	assert.equal(withEnv("deny", () => connectorWriteModeFor({ provider: { connectorWriteMode: "allow" } })), "deny");
	assert.equal(withEnv("allow", () => connectorWriteModeFor({ provider: { connectorWriteMode: "deny" } })), "allow");
});

test("connectorWriteModeFor FAILS CLOSED on unvalidated config values", () => {
	// Legacy config files are merged raw; a truthy non-"allow" value must NOT
	// silently open writes. Anything that isn't a valid "allow" resolves to
	// "deny" (validated strings are trimmed + lowercased first).
	for (const bad of ["Deny", "read-only", "on", "1", "allowed", true, 1, {}, null]) {
		assert.equal(
			withEnv(undefined, () => connectorWriteModeFor({ provider: { connectorWriteMode: bad } })),
			"deny",
			`config value ${JSON.stringify(bad)} must resolve to deny`,
		);
	}
});

test("isConnectorWriteTool classifies known + future write tools as writes (fail closed)", () => {
	const writes = [
		...CONNECTOR_WRITE_TOOLS,
		// not-yet-known future writes must still classify as writes
		"mcp__claude_ai_Gmail__send_message",
		"mcp__claude_ai_Gmail__update_draft",
		"mcp__claude_ai_Gmail__create_filter",
		"mcp__claude_ai_Google_Drive__update_file",
		"mcp__claude_ai_Google_Drive__delete_file",
		"mcp__claude_ai_Google_Drive__move_file",
		"mcp__claude_ai_Google_Calendar__add_attendee",
	];
	for (const name of writes) assert.equal(isConnectorWriteTool(name), true, name);
});

test("isConnectorWriteTool leaves connector reads + non-connector tools available", () => {
	const reads = [
		"mcp__claude_ai_Gmail__search_threads",
		"mcp__claude_ai_Gmail__get_message",
		"mcp__claude_ai_Gmail__list_labels",
		"mcp__claude_ai_Google_Calendar__list_events",
		"mcp__claude_ai_Google_Calendar__get_event",
		"mcp__claude_ai_Google_Drive__search_files",
		"mcp__claude_ai_Google_Drive__fetch_file",
		"mcp__claude_ai_Google_Drive__download_file",
		// discovery + Pi custom tools are never connector writes
		"ToolSearch",
		"ListMcpResources",
		"mcp__custom-tools__anything",
	];
	for (const name of reads) assert.equal(isConnectorWriteTool(name), false, name);
});

test("PreToolUse hook denies connector writes (known + future) and allows reads", async () => {
	const hook = connectorWriteDenyHook();
	// future write: not a known read verb → deny
	assert.ok(isDeny(await runHook(hook, "mcp__claude_ai_Gmail__send_message")), "send_message denied");
	assert.ok(isDeny(await runHook(hook, "mcp__claude_ai_Gmail__create_draft")), "create_draft denied");
	assert.ok(isDeny(await runHook(hook, "mcp__claude_ai_Google_Drive__delete_file")), "delete_file denied");
	// reads pass through untouched
	assert.equal(isDeny(await runHook(hook, "mcp__claude_ai_Gmail__search_threads")), false, "search_threads allowed");
	assert.equal((await runHook(hook, "mcp__claude_ai_Gmail__search_threads")).continue, true, "search_threads continues");
	// non-connector tools pass through
	assert.equal((await runHook(hook, "ToolSearch")).continue, true, "ToolSearch continues");
	assert.equal((await runHook(hook, "mcp__custom-tools__foo")).continue, true, "custom tool continues");
});

test("connectorQueryOptions(true) [deny] wires BOTH disallowedTools ids AND the PreToolUse hook", () => {
	const opts = connectorQueryOptions(true); // default deny
	for (const w of CONNECTOR_WRITE_TOOLS) assert.ok(opts.disallowedTools.includes(w), `deny id ${w}`);
	for (const p of CLAUDE_AI_CONNECTOR_TOOL_PATTERNS) assert.ok(opts.allowedTools.includes(p), `allow ${p}`);
	assert.ok(Array.isArray(opts.hooks?.PreToolUse), "PreToolUse hook registered");
	assert.equal(opts.hooks.PreToolUse.length, 1);
	assert.equal(typeof opts.hooks.PreToolUse[0].hooks[0], "function");
});

test("connectorQueryOptions(true, 'allow') exposes writes and registers NO hook", () => {
	const opts = connectorQueryOptions(true, "allow");
	for (const w of CONNECTOR_WRITE_TOOLS) assert.ok(!opts.disallowedTools.includes(w), `not denied ${w}`);
	assert.equal(opts.hooks, undefined, "no write hook when writes allowed");
	for (const p of CLAUDE_AI_CONNECTOR_TOOL_PATTERNS) assert.ok(opts.allowedTools.includes(p), `allow ${p}`);
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
