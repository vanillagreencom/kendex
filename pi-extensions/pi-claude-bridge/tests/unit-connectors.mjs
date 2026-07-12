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

test("connectorsEnabledFromEnv parses truthy/falsey", () => {
	for (const v of ["1", "true", "yes", "on", "TRUE", " On "]) assert.equal(withEnv(v, connectorsEnabledFromEnv), true, v);
	for (const v of [undefined, "", "0", "false", "no", "off", "nope"]) assert.equal(withEnv(v, connectorsEnabledFromEnv), false, String(v));
});

test("connectorsEnabledFor: env OR config.provider.enableConnectors", () => {
	assert.equal(withEnv(undefined, () => connectorsEnabledFor(undefined)), false);
	assert.equal(withEnv(undefined, () => connectorsEnabledFor({ provider: {} })), false);
	assert.equal(withEnv(undefined, () => connectorsEnabledFor({ provider: { enableConnectors: true } })), true);
	assert.equal(withEnv("0", () => connectorsEnabledFor({ provider: { enableConnectors: true } })), true);
	assert.equal(withEnv("1", () => connectorsEnabledFor({ provider: { enableConnectors: false } })), true);
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
