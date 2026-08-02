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
	isConnectorWriteTool,
	connectorWriteDenyHook,
	settingSourcesForQuery,
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

// --- vstack#990: connectors mode must not load repo-controlled settings ---

test("CONTRACT: connectors mode loads USER setting sources only", () => {
	// Settings files carry `env` and `apiKeyHelper`; "project"/"local" would let
	// a hostile checkout's .claude/settings.json reinject the provider-override
	// env the bridge scrubs (e.g. ANTHROPIC_BASE_URL). Connector state is
	// user-scope, so ["user"] is sufficient for connectors to surface.
	assert.deepEqual(settingSourcesForQuery(true, true), ["user"]);
	assert.deepEqual(settingSourcesForQuery(true, false), ["user"]);
	for (const scope of ["project", "local"]) {
		assert.ok(!settingSourcesForQuery(true, true).includes(scope), `must not include ${scope}`);
	}
});

test("explicit provider.settingSources still wins verbatim in connectors mode", () => {
	assert.deepEqual(settingSourcesForQuery(true, true, ["user", "project"]), ["user", "project"]);
	assert.deepEqual(settingSourcesForQuery(true, true, []), []);
});

test("non-connectors setting sources are unchanged", () => {
	// appendSystemPrompt=true → isolation; configured sources deliberately ignored.
	assert.equal(settingSourcesForQuery(false, true), undefined);
	assert.equal(settingSourcesForQuery(false, true, ["user"]), undefined);
	// appendSystemPrompt=false → historical default, explicit override honored.
	assert.deepEqual(settingSourcesForQuery(false, false), ["user", "project"]);
	assert.deepEqual(settingSourcesForQuery(false, false, ["user", "local"]), ["user", "local"]);
});

test("discovery tools are a subset of the default disallow list", () => {
	for (const d of CONNECTOR_DISCOVERY_TOOLS) assert.ok(DISALLOWED_BUILTIN_TOOLS.includes(d), `${d} is disallowed by default`);
});

// --- vstack#892: the deny reason is shared source shown verbatim to a model ---

test("CONTRACT: the connector write-deny reason names no host product", async () => {
	const hook = connectorWriteDenyHook();
	const out = await hook({
		hook_event_name: "PreToolUse",
		tool_name: "mcp__claude_ai_Gmail__create_draft",
	});
	const reason = out.hookSpecificOutput.permissionDecisionReason;

	// The string goes straight to the `claude` child's model in EVERY consuming
	// app, so naming one host tells another app's model to use a product it has
	// never heard of. Each host describes its own approval flow in its own
	// prompt; this only has to say that one exists.
	for (const product of ["Memsira", "memsira", "drovr", "Drovr", "hyprtrade"]) {
		assert.ok(!reason.includes(product), `deny reason must not name "${product}": ${reason}`);
	}
	assert.ok(reason.includes("mcp__claude_ai_Gmail__create_draft"), "names the refused tool");
	assert.ok(/host application/i.test(reason), "points at the host's approval flow generically");

	// The malformed-input path returns the same message, so it cannot drift.
	const fallback = await hook({ hook_event_name: "PreToolUse", tool_name: 42 });
	assert.equal(fallback.hookSpecificOutput.permissionDecision, "deny");
	for (const product of ["Memsira", "memsira", "drovr"]) {
		assert.ok(!fallback.hookSpecificOutput.permissionDecisionReason.includes(product));
	}
});

// --- vstack#892: CONNECTOR_WRITE_TOOLS is a public contract, not an internal ---

// memsira routes connector writes through its own gated approval flow; drovr
// keeps its chat sidecar permanently write-`deny` and runs an approved write as
// a one-shot `claude -p` scoped to exactly one tool (drovr#288). Both pin the
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
