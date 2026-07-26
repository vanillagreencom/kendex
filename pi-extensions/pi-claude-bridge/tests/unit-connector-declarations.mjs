import { test } from "node:test";
import assert from "node:assert/strict";
import { connectorMcpServers, connectorServerName, connectorProxyUrl } from "../bundle/index.js";

const ok = (connectors) => ({ ok: true, complete: true, connectors });

test("declares only connectors the account reports as connected", () => {
	// installState mirrors what the account returns: `connected` is exactly the
	// set the CLI itself attempts. Declaring the rest would ask alwaysLoad to
	// block startup on servers that never connect.
	const servers = connectorMcpServers(ok([
		{ name: "Slack", installedServerId: "id-slack", installState: "connected" },
		{ name: "Asana", installedServerId: "id-asana", installState: "unknown" },
		{ name: "Box", installedServerId: "id-box" },
	]));
	assert.deepEqual(Object.keys(servers), ["claude.ai Slack"]);
});

test("keys each server by the CLI's own name, because the key IS the namespace", () => {
	// Keyed as anything else the connector appears twice under two namespaces,
	// which breaks consumers that pin fully-qualified tool names.
	const servers = connectorMcpServers(ok([
		{ name: "Google Calendar", installedServerId: "id-cal", installState: "connected" },
	]));
	assert.deepEqual(Object.keys(servers), ["claude.ai Google Calendar"]);
	assert.equal(connectorServerName("Google Calendar"), "claude.ai Google Calendar");
});

test("emits the claudeai-proxy shape with alwaysLoad set", () => {
	const servers = connectorMcpServers(ok([
		{ name: "Slack", installedServerId: "id-slack", installState: "connected" },
	]));
	assert.deepEqual(servers["claude.ai Slack"], {
		type: "claudeai-proxy",
		url: connectorProxyUrl("id-slack"),
		id: "id-slack",
		// The whole mechanism: blocks startup until connected, so the tools are
		// present when the turn-1 prompt is built.
		alwaysLoad: true,
	});
});

test("proxy url targets the claude.ai mcp proxy and escapes the id", () => {
	assert.equal(connectorProxyUrl("id-slack"), "https://mcp-proxy.anthropic.com/v1/mcp/id-slack");
	assert.equal(connectorProxyUrl("a/b"), "https://mcp-proxy.anthropic.com/v1/mcp/a%2Fb");
	assert.equal(connectorProxyUrl("x", "https://example.test/mcp///"), "https://example.test/mcp/x");
});

test("a connected connector with no installed server id is skipped, not emitted broken", () => {
	const servers = connectorMcpServers(ok([
		{ name: "Slack", installState: "connected" },
	]));
	assert.deepEqual(servers, {});
});

test("a failed inventory declares nothing rather than throwing", () => {
	// Fail open: a network blip must not break the turn, it just means the
	// connectors race again for that session.
	assert.deepEqual(connectorMcpServers({ ok: false, complete: false, reason: "boom" }), {});
});

test("CLAUDE_BRIDGE_CONNECTOR_DECLARE=off disables declarations without disabling connectors", () => {
	// The alwaysLoad barrier's worst-case bound is not established (5s per the
	// SDK doc comment vs 30000ms in the CLI's own log), so an account with slow
	// connectors needs a way out that does not cost them connectors entirely.
	const inv = { ok: true, complete: true, connectors: [
		{ name: "Slack", installedServerId: "id-slack", installState: "connected" },
	] };
	const prev = process.env.CLAUDE_BRIDGE_CONNECTOR_DECLARE;
	try {
		for (const off of ["off", "0", "false", "no", "OFF"]) {
			process.env.CLAUDE_BRIDGE_CONNECTOR_DECLARE = off;
			assert.deepEqual(connectorMcpServers(inv), {}, `expected ${off} to disable`);
		}
		for (const on of ["", "on", "1", "true"]) {
			process.env.CLAUDE_BRIDGE_CONNECTOR_DECLARE = on;
			assert.deepEqual(Object.keys(connectorMcpServers(inv)), ["claude.ai Slack"], `expected ${on || "<empty>"} to keep declarations`);
		}
	} finally {
		if (prev === undefined) delete process.env.CLAUDE_BRIDGE_CONNECTOR_DECLARE;
		else process.env.CLAUDE_BRIDGE_CONNECTOR_DECLARE = prev;
	}
});
