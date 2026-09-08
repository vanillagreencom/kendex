import { test } from "node:test";
import assert from "node:assert/strict";
import {
	connectorsEnabledFromEnv,
	connectorsEnabledFor,
	toolIsolationForQuery,
	CLAUDE_AI_CONNECTOR_TOOL_PATTERNS,
	CONNECTOR_DISCOVERY_TOOLS,
	CLAUDE_BRIDGE_TOOL_ISOLATION,
	DISALLOWED_BUILTIN_TOOLS,
	CONNECTOR_WRITE_TOOLS,
	isConnectorTool,
	isConnectorWriteTool,
	connectorQueryOptions,
	connectorServerNamespace,
} from "../bundle/index.js";

function withEnv(value, fn) {
	const prev = process.env.CLAUDE_BRIDGE_ENABLE_CONNECTORS;
	if (value === undefined) delete process.env.CLAUDE_BRIDGE_ENABLE_CONNECTORS;
	else process.env.CLAUDE_BRIDGE_ENABLE_CONNECTORS = value;
	try { return fn(); } finally {
		if (prev === undefined) delete process.env.CLAUDE_BRIDGE_ENABLE_CONNECTORS;
		else process.env.CLAUDE_BRIDGE_ENABLE_CONNECTORS = prev;
	}
}

test("connector enablement parses environment values", () => {
	const rows = [["1", true], ["true", true], ["yes", true], ["on", true], ["TRUE", true], [" On ", true],
		[undefined, false], ["", false], ["0", false], ["false", false], ["no", false], ["off", false], ["nope", false]];
	for (const [value, expected] of rows) assert.equal(withEnv(value, connectorsEnabledFromEnv), expected, String(value));
});

test("connector enablement accepts environment or provider opt-in", () => {
	const rows = [
		[undefined, undefined, false], [undefined, { provider: {} }, false],
		[undefined, { provider: { enableConnectors: true } }, true],
		["0", { provider: { enableConnectors: true } }, true],
		["1", { provider: { enableConnectors: false } }, true],
	];
	for (const [value, config, expected] of rows) {
		assert.equal(withEnv(value, () => connectorsEnabledFor(config)), expected, JSON.stringify([value, config]));
	}
});

test("toolIsolationForQuery(false) is the default isolation (connectors suppressed)", () => {
	const iso = toolIsolationForQuery(false);
	assert.deepEqual(iso, CLAUDE_BRIDGE_TOOL_ISOLATION);
	assert.deepEqual(iso.tools, []); // empty --tools; connectors intentionally hidden
});

test("toolIsolationForQuery(true) exposes connectors: drops empty tools, allows patterns, un-blocks ToolSearch", () => {
	const iso = toolIsolationForQuery(true);
	// `tools: []` must be omitted (an empty --tools allowlist strips cloud connectors).
	assert.equal("tools" in iso, false);
	// Connector namespaces are auto-allowed.
	for (const p of CLAUDE_AI_CONNECTOR_TOOL_PATTERNS) assert.ok(iso.allowedTools.includes(p), `allow ${p}`);
	// Discovery tools (ToolSearch etc.) must NOT be disallowed — connectors are deferred behind them.
	for (const d of CONNECTOR_DISCOVERY_TOOLS) assert.ok(!iso.disallowedTools.includes(d), `un-block ${d}`);
	// File/shell built-ins stay blocked so Pi keeps tool ownership.
	for (const b of ["Read", "Write", "Bash", "WebFetch"]) assert.ok(iso.disallowedTools.includes(b), `still block ${b}`);
});

test("discovery tools are a subset of the default disallow list", () => {
	for (const d of CONNECTOR_DISCOVERY_TOOLS) assert.ok(DISALLOWED_BUILTIN_TOOLS.includes(d), `${d} is disallowed by default`);
});

test("CONTRACT: connectors.ts and connector-inventory.ts agree on the connector namespace prefix", () => {
	// CONNECTOR_NS_PREFIX is deliberately duplicated between the two modules
	// (connector-inventory also builds standalone). This makes drift loud: the
	// namespace connector-inventory derives for a server MUST classify as a
	// connector tool, and the literal prefix is pinned so a change has to be
	// made knowingly in both places.
	const namespace = connectorServerNamespace("Probe Server");
	assert.equal(namespace, "mcp__claude_ai_Probe_Server__");
	assert.equal(isConnectorTool(`${namespace}get_thing`), true);
	assert.ok(namespace.startsWith("mcp__claude_ai_"), "shared literal prefix");
	assert.equal(isConnectorTool("mcp__claude_ai_X__anything"), true);
});

test("CONTRACT: the request-side option surface still carries request-side spellings only (kendex#1011)", () => {
	// The SDK's rule parser alias-normalizes option strings, so the request-side
	// spellings are correct THERE and must not be "fixed" to the canonical ones.
	// Pinned with literal names for the same reason as the hook test above.
	assert.deepEqual(CONNECTOR_DISCOVERY_TOOLS, ["ToolSearch", "ListMcpResources", "ReadMcpResource"]);
	const expected = DISALLOWED_BUILTIN_TOOLS.filter((t) => !["ToolSearch", "ListMcpResources", "ReadMcpResource"].includes(t));
	assert.deepEqual(toolIsolationForQuery(true, "allow").disallowedTools, expected);
	assert.deepEqual(toolIsolationForQuery(true, "deny").disallowedTools, [...expected, ...CONNECTOR_WRITE_TOOLS]);
	for (const iso of [toolIsolationForQuery(true, "allow"), toolIsolationForQuery(true, "deny")]) {
		for (const name of ["ListMcpResourcesTool", "ReadMcpResourceTool"]) {
			assert.ok(!iso.disallowedTools.includes(name), `${name} must not leak into SDK options`);
			assert.ok(!iso.allowedTools.includes(name), `${name} must not leak into SDK options`);
		}
	}
});

test("connectorQueryOptions wires the allowlist hook in BOTH write modes", async () => {
	for (const mode of ["deny", "allow"]) {
		const opts = connectorQueryOptions(true, mode);
		const hooks = opts.hooks?.PreToolUse?.[0]?.hooks ?? [];
		assert.ok(hooks.length >= 1, `mode ${mode} registers hooks`);
		// The FIRST hook is the allowlist: it must deny an unknown builtin.
		const out = await hooks[0]({ hook_event_name: "PreToolUse", tool_name: "SlashCommand", tool_input: {} }, "t1", { signal: new AbortController().signal });
		assert.equal(out.hookSpecificOutput?.permissionDecision, "deny", `mode ${mode} denies unknown builtins`);
	}
	// Write-deny mode additionally carries the write-deny hook.
	assert.equal(connectorQueryOptions(true, "deny").hooks.PreToolUse[0].hooks.length, 2);
	assert.equal(connectorQueryOptions(true, "allow").hooks.PreToolUse[0].hooks.length, 1);
});

// --- CONNECTOR_WRITE_TOOLS is a public contract, not an internal detail ---

// memsira routes connector writes through its own gated approval flow; drovr
// keeps its chat sidecar permanently write-`deny` and runs an approved write as
// a one-shot `claude -p` scoped to exactly one tool. Both pin the
// actions they expose against this classification, because "the sidecar
// structurally cannot do this itself" is THIS module's claim, not theirs.
//
// Reclassifying an entry here as a READ would make a consumer's confirmation
// card bypassable, and nothing downstream would notice. Additions are safe and
// expected — this asserts every listed id still classifies as a write, so a
// removal or a read-verb rename has to be deliberate.
test("CONTRACT: every CONNECTOR_WRITE_TOOLS entry still classifies as a write", () => {
	assert.ok(CONNECTOR_WRITE_TOOLS.length > 0, "the write list must not be emptied");
	for (const name of CONNECTOR_WRITE_TOOLS) {
		assert.equal(isConnectorWriteTool(name), true, `${name} must stay a write`);
	}
});

test("CONTRACT: the connectors consumers gate on are all represented", () => {
	// A whole connector family vanishing from the list is the shape that would
	// silently un-gate a consumer, so pin the families rather than exact ids.
	// Server segments as they actually appear in the tool id — Google connectors
	// are `Google_Calendar` / `Google_Drive`, not `Calendar` / `Drive`.
	for (const ns of ["Gmail", "Google_Calendar", "Google_Drive", "Slack", "Atlassian"]) {
		assert.ok(
			CONNECTOR_WRITE_TOOLS.some((t) => t.includes(`claude_ai_${ns}__`)),
			`${ns} writes must stay enumerated`,
		);
	}
});
