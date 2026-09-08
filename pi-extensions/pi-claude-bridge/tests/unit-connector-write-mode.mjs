import { test } from "node:test";
import assert from "node:assert/strict";
import { connectorWriteModeFromEnv, connectorWriteModeFor } from "../bundle/index.js";

function withEnv(value, fn) {
	const prev = process.env.CLAUDE_BRIDGE_CONNECTOR_WRITE;
	if (value === undefined) delete process.env.CLAUDE_BRIDGE_CONNECTOR_WRITE;
	else process.env.CLAUDE_BRIDGE_CONNECTOR_WRITE = value;
	try { return fn(); } finally {
		if (prev === undefined) delete process.env.CLAUDE_BRIDGE_CONNECTOR_WRITE;
		else process.env.CLAUDE_BRIDGE_CONNECTOR_WRITE = prev;
	}
}

test("connector write mode parses the environment", () => {
	const rows = [["allow", "allow"], [" ALLOW ", "allow"], ["deny", "deny"], ["DENY", "deny"],
		[undefined, undefined], ["", undefined], ["1", undefined], ["true", undefined], ["read-only", undefined], ["nope", undefined]];
	for (const [value, expected] of rows) assert.equal(withEnv(value, connectorWriteModeFromEnv), expected, String(value));
});

test("connector write mode uses environment precedence and defaults to deny", () => {
	const rows = [
		[undefined, undefined, "deny"], [undefined, { provider: {} }, "deny"],
		["allow", undefined, "allow"],
		[undefined, { provider: { connectorWriteMode: "allow" } }, "allow"],
		["deny", { provider: { connectorWriteMode: "allow" } }, "deny"],
		["allow", { provider: { connectorWriteMode: "deny" } }, "allow"],
		...["Deny", "read-only", "on", "1", "allowed", true, 1, {}, null].map((value) => [undefined, { provider: { connectorWriteMode: value } }, "deny"]),
	];
	for (const [value, config, expected] of rows) {
		assert.equal(withEnv(value, () => connectorWriteModeFor(config)), expected, JSON.stringify([value, config]));
	}
});

