import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { credentialCandidatePaths, resolveClaudeOAuth } from "../src/connector-inventory.ts";

describe("credential resolution", () => {
	it("reads token and org UUID from separate files", () => {
		const files = {
			"/h/.claude/.credentials.json": JSON.stringify({ claudeAiOauth: { accessToken: "tok" } }),
			"/h/.claude.json": JSON.stringify({ oauthAccount: { organizationUuid: "org" } }),
		};
		const got = resolveClaudeOAuth((p) => files[p], { HOME: "/h" });
		assert.deepEqual(got, { accessToken: "tok", organizationUuid: "org" });
	});

	it("prefers CLAUDE_CONFIG_DIR over HOME so per-account sidecars stay isolated", () => {
		const files = {
			"/acct-b/.credentials.json": JSON.stringify({ claudeAiOauth: { accessToken: "b-tok" } }),
			"/acct-b/.claude.json": JSON.stringify({ oauthAccount: { organizationUuid: "b-org" } }),
			"/h/.claude/.credentials.json": JSON.stringify({ claudeAiOauth: { accessToken: "a-tok" } }),
			"/h/.claude.json": JSON.stringify({ oauthAccount: { organizationUuid: "a-org" } }),
		};
		const got = resolveClaudeOAuth((p) => files[p], { HOME: "/h", CLAUDE_CONFIG_DIR: "/acct-b" });
		assert.deepEqual(got, { accessToken: "b-tok", organizationUuid: "b-org" });
	});

	it("skips a corrupt file instead of letting it mask a later good one", () => {
		const files = {
			"/h/.claude/.credentials.json": "{ not json",
			"/h/.claude.json": JSON.stringify({
				claudeAiOauth: { accessToken: "tok" },
				oauthAccount: { organizationUuid: "org" },
			}),
		};
		const got = resolveClaudeOAuth((p) => files[p], { HOME: "/h" });
		assert.deepEqual(got, { accessToken: "tok", organizationUuid: "org" });
	});

	it("returns undefined when either half is missing", () => {
		for (const [name, files] of [
			["token only", { "/h/.claude/.credentials.json": JSON.stringify({ claudeAiOauth: { accessToken: "tok" } }) }],
			["organization only", { "/h/.claude.json": JSON.stringify({ oauthAccount: { organizationUuid: "org" } }) }],
			["empty", {}],
		]) {
			assert.equal(resolveClaudeOAuth((p) => files[p], { HOME: "/h" }), undefined, name);
		}
	});

	it("probes ONLY the CLAUDE_CONFIG_DIR root when it is set (no HOME fallback)", () => {
		// A managed profile with a missing .credentials.json must NOT silently
		// borrow the default account's token — that is a confident, well-formed
		// answer for the wrong account.
		const paths = credentialCandidatePaths({ HOME: "/h", CLAUDE_CONFIG_DIR: "/cfg" });
		assert.deepEqual(paths, ["/cfg/.credentials.json", "/cfg/.claude.json"]);
	});

	it("keeps the HOME candidates when no config dir is selected", () => {
		const paths = credentialCandidatePaths({ HOME: "/h" });
		assert.deepEqual(paths, [
			"/h/.claude/.credentials.json",
			"/h/.claude/.claude.json",
			"/h/.credentials.json",
			"/h/.claude.json",
		]);
	});

	it("a managed profile missing its credentials resolves nothing rather than the default account", () => {
		const files = {
			// Default account fully present under HOME…
			"/h/.claude/.credentials.json": JSON.stringify({ claudeAiOauth: { accessToken: "default-tok" } }),
			"/h/.claude.json": JSON.stringify({ oauthAccount: { organizationUuid: "default-org" } }),
		};
		// …but the selected profile dir is empty: no borrowing.
		const got = resolveClaudeOAuth((p) => files[p], { HOME: "/h", CLAUDE_CONFIG_DIR: "/profiles/b" });
		assert.equal(got, undefined);
	});
});

