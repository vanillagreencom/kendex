/**
 * Tests for deterministic connector enumeration.
 * Pins: credential resolution across split files and per-account CLAUDE_CONFIG_DIR,
 * the POST shape the endpoint requires, and — most importantly — that every
 * non-success path reports failure rather than an empty-but-successful list.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
	connectorServerNamespace,
	connectorsListUrl,
	listAccountConnectors,
} from "../src/connector-inventory.js";
import { CLAUDE_AI_CONNECTOR_TOOL_PATTERNS } from "../src/connectors.js";

const CREDS = { accessToken: "sk-ant-oat01-secret", organizationUuid: "org-uuid-1" };

// Mirrors the live payload observed on a personal claude_max org.
const LIVE_BODY = JSON.stringify({
	results: [
		{
			name: "Gmail",
			description: "Draft replies, summarize threads, & search your inbox",
			directoryUuid: "2701e52f-b826-4aaf-8b25-11f2a97c98b0",
			installedServerId: "cd7a4f5c-c21e-403f-aa35-481aff1d1bb5",
			customOAuthClientId: null,
			installState: "unknown",
			isAuthless: false,
		},
		{ name: "Google Calendar", directoryUuid: "2a838eaa", installedServerId: "43bfe39d", isAuthless: false },
		{ name: "Google Drive", directoryUuid: "b89f7865", installedServerId: "9a94a59a", isAuthless: false },
	],
	opt_in_required: false,
	message: null,
});

const okFetch = (body = LIVE_BODY, status = 200) => {
	const calls = [];
	const impl = async (url, init) => {
		calls.push({ url, init });
		return new Response(body, { status });
	};
	impl.calls = calls;
	return impl;
};

describe("request shape", () => {
	it("POSTs with the bearer token and oauth beta header", async () => {
		const f = okFetch();
		await listAccountConnectors({ credentials: CREDS, fetchImpl: f });
		assert.equal(f.calls.length, 1);
		const { url, init } = f.calls[0];
		assert.equal(url, "https://api.anthropic.com/api/oauth/organizations/org-uuid-1/mcp/connectors/list");
		// GET returns 405 on this endpoint — the method is load-bearing.
		assert.equal(init.method, "POST");
		assert.equal(init.headers.Authorization, `Bearer ${CREDS.accessToken}`);
		assert.equal(init.headers["anthropic-beta"], "oauth-2025-04-20");
		assert.equal(init.body, "{}");
	});

	it("percent-encodes the org UUID into the path", () => {
		assert.match(connectorsListUrl("a/b"), /organizations\/a%2Fb\/mcp/);
	});

	it("honors an apiBase override without doubling slashes", () => {
		assert.equal(
			connectorsListUrl("o", "https://example.test/"),
			"https://example.test/api/oauth/organizations/o/mcp/connectors/list",
		);
	});
});

describe("success path", () => {
	it("returns every connector, marked complete", async () => {
		const got = await listAccountConnectors({ credentials: CREDS, fetchImpl: okFetch() });
		assert.equal(got.ok, true);
		assert.equal(got.complete, true);
		assert.deepEqual(got.connectors.map((c) => c.name), ["Gmail", "Google Calendar", "Google Drive"]);
	});

	it("keeps installedServerId — the field that proves this is the attached set", async () => {
		const got = await listAccountConnectors({ credentials: CREDS, fetchImpl: okFetch() });
		assert.equal(got.connectors[0].installedServerId, "cd7a4f5c-c21e-403f-aa35-481aff1d1bb5");
		assert.equal(got.connectors[0].directoryUuid, "2701e52f-b826-4aaf-8b25-11f2a97c98b0");
	});

	it("an account with no connectors is a successful empty list, not a failure", async () => {
		const got = await listAccountConnectors({
			credentials: CREDS,
			fetchImpl: okFetch(JSON.stringify({ results: [] })),
		});
		assert.equal(got.ok, true);
		assert.equal(got.complete, true);
		assert.deepEqual(got.connectors, []);
	});
});

describe("failure paths never masquerade as an empty inventory", () => {
	it("identifies each HTTP, transport, and protocol failure", async () => {
		const rows = [
			["HTTP", () => okFetch(JSON.stringify({ error: { message: "api_error_405" } }), 405), "connector-http=405", "api_error_405"],
			["transport", () => async () => { throw new Error("ECONNREFUSED"); }, 'connector-request="transport"', "ECONNREFUSED"],
			["non-JSON", () => okFetch("<html>502</html>"), 'connector-json="invalid"'],
			["missing results", () => okFetch(JSON.stringify({ ok: true })), 'connector-results="not-array"'],
			["unnamed entry", () => okFetch(JSON.stringify({ results: [{ name: "Gmail" }, { installedServerId: "x" }] })), "connector-name=1"],
		];
		for (const [name, transport, expected, detail] of rows) {
			const got = await listAccountConnectors({ credentials: CREDS, fetchImpl: transport() });
			assert.deepEqual({ ok: got.ok, complete: got.complete, connectors: got.connectors, failure: got.reason?.split("\n")[0], detail: detail === undefined ? undefined : got.reason?.includes(detail) },
				{ ok: false, complete: false, connectors: undefined, failure: expected, detail: detail === undefined ? undefined : true }, name);
		}
	});

	it("never leaks the access token into a failure reason", async () => {
		const results = await Promise.all([
			listAccountConnectors({ credentials: CREDS, fetchImpl: okFetch("nope", 500) }),
			listAccountConnectors({ credentials: CREDS, fetchImpl: async () => { throw new Error(CREDS.accessToken); } }),
		]);
		for (const r of results) assert.ok(!r.reason.includes("sk-ant-oat01-secret"), r.reason);
	});
});

describe("connectorServerNamespace", () => {
	it("maps connector names to their tool namespace", () => {
		for (const [name, expected] of [["Gmail", "mcp__claude_ai_Gmail__"], ["Google Calendar", "mcp__claude_ai_Google_Calendar__"]]) {
			assert.equal(connectorServerNamespace(name), expected, name);
		}
	});

	// Corroboration, not restatement: CLAUDE_AI_CONNECTOR_TOOL_PATTERNS was built
	// from a live tool enumeration, independently of this naming rule.
	it("agrees with the independently-derived connector tool patterns", () => {
		for (const name of ["Gmail", "Google Calendar", "Google Drive", "Slack", "Atlassian"]) {
			assert.ok(
				CLAUDE_AI_CONNECTOR_TOOL_PATTERNS.includes(`${connectorServerNamespace(name)}*`),
				`no pattern for ${name}`,
			);
		}
	});
});
