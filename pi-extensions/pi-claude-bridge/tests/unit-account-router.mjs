import assert from "node:assert/strict";
import { homedir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";

import {
	accountSessionScope,
	claudeDirForProfile,
	classifyClaudeFailure,
	rateLimitResetMs,
	rateLimitTypeFromInfo,
	subscriberProfileEnv,
} from "../src/account-router.ts";


describe("subscriberProfileEnv", () => {
	it("selects the profile and removes each billing credential", () => {
		const rows = [
			["PATH", "/bin", "/bin"],
			["CLAUDE_CONFIG_DIR", "/profiles/old", "/profiles/max"],
			["ANTHROPIC_API_KEY", "secret", undefined],
			["ANTHROPIC_AUTH_TOKEN", "secret", undefined],
			["ANTHROPIC_OAUTH_TOKEN", "secret", undefined],
			["CLAUDE_CODE_OAUTH_TOKEN", "secret", undefined],
			["ANTHROPIC_BASE_URL", "https://gateway.invalid", undefined],
			["ANTHROPIC_CUSTOM_HEADERS", "Authorization: secret", undefined],
			["ANTHROPIC_AWS_API_KEY", "secret", undefined],
			["ANTHROPIC_FOUNDRY_AUTH_TOKEN", "secret", undefined],
			["AWS_BEARER_TOKEN_BEDROCK", "secret", undefined],
			["CLAUDE_CODE_USE_BEDROCK", "1", undefined],
		];
		for (const [key, value, expected] of rows) {
			assert.equal(subscriberProfileEnv({ configDir: "/profiles/max" }, { [key]: value })[key], expected, key);
		}
	});

	it("uses the real default profile by unsetting CLAUDE_CONFIG_DIR", () => {
		const env = subscriberProfileEnv(
			{ configDir: undefined },
			{ CLAUDE_CONFIG_DIR: "/profiles/old" },
		);
		assert.equal(env.CLAUDE_CONFIG_DIR, undefined);
	});
});

describe("claudeDirForProfile", () => {
	it("resolves explicit, blank, and absent profile directories", () => {
		const rows = [
			[{ configDir: "/profiles/max" }, "/profiles/max"],
			[{ configDir: "  " }, join(homedir(), ".claude")],
			[{}, join(homedir(), ".claude")],
		];
		for (const [profile, expected] of rows) assert.equal(claudeDirForProfile(profile), expected, JSON.stringify(profile));
	});
});

describe("classifyClaudeFailure", () => {
	// Copy → classification table. Keep every observed error shape here so a
	// regex change shows its blast radius.
	const TABLE = [
		["rate_limit", "rate-limit"],
		["You've hit your session limit · resets 7:10pm", "rate-limit"],
		["You've hit your weekly limit · resets Thursday 4am", "rate-limit"],
		["Too many requests", "rate-limit"],
		["Extra usage is disabled for this account", "rate-limit"],
		["overage not provisioned", "rate-limit"],
		["You have exceeded your usage quota", "rate-limit"],
		["API quota exceeded for requests", "rate-limit"],
		["status 429 Too Many Requests", "rate-limit"],
		["authentication_failed", "auth"],
		["401 authentication_error", "auth"],
		["OAuth token has expired; please run /login", "auth"],
		["Unauthorized", "auth"],
		// 403/permission_error: another profile may be allowed where this org
		// restriction blocks — rotation posture matches 401.
		["permission_error", "auth"],
		["HTTP 403 permission_error", "auth"],
		["OAuth org not allowed: oauth_org_not_allowed", "auth"],
		// Bare "permission denied" is just as likely a filesystem EACCES, which
		// no other account can fix.
		["EACCES: permission denied, open '/etc/hosts'", undefined],
		["Credit balance is too low", "billing"],
		["billing error: payment required", "billing"],
		["API overloaded", "overloaded"],
		["API Error: 529 overloaded_error", "overloaded"],
		["internal server error", "server"],
		["HTTP 500", "server"],
		["status 503 service unavailable capacity", "overloaded"],
		["socket timeout", "network"],
		["fetch failed", "network"],
		["ECONNRESET while streaming", "network"],
		// Tightened cases (S5): bare numbers and non-usage quota must not match.
		["disk quota exceeded", undefined],
		["the request took 500ms", undefined],
		["processed 429 rows", undefined],
		["line 502 of the file", undefined],
		["invalid request", undefined],
	];

	it("classifies error copy per the table", () => {
		for (const [copy, expected] of TABLE) {
			assert.equal(classifyClaudeFailure(copy), expected, `copy: ${copy}`);
		}
	});

	it("classifies structured status fields before prose", () => {
		const rows = [
			[{ status: 429, message: "request rejected" }, "rate-limit"],
			[{ statusCode: 401, message: "nope" }, "auth"],
			[{ status: 529 }, "overloaded"],
			[{ status: 500, message: "boom" }, "server"],
			[{ status: 402 }, "billing"],
			[{ status: 403, type: "permission_error", message: "Permission denied" }, "auth"],
			[{ type: "permission_error", message: "Your organization does not allow this model" }, "auth"],
		];
		for (const [input, expected] of rows) assert.equal(classifyClaudeFailure(input), expected, JSON.stringify(input));
	});
});

describe("account routing helpers", () => {
	it("normalizes rate-limit type", () => {
		assert.equal(rateLimitTypeFromInfo({ rate_limit_type: "seven_day_fable" }), "seven_day_fable");
	});

	it("normalizes numeric and string reset timestamps", () => {
		const resetSeconds = Math.floor((Date.now() + 60_000) / 1000);
		const rows = [
			[{ resets_at: resetSeconds }, resetSeconds * 1000],
			[{ resetsAt: "2030-01-01T00:00:00Z" }, Date.parse("2030-01-01T00:00:00Z")],
		];
		for (const [input, expected] of rows) assert.equal(rateLimitResetMs(input), expected, JSON.stringify(input));
	});

	it("resolves the session scope's claude dir like the child env", () => {
		const rows = [
			[{ profileId: "2", label: "max", configDir: "/profiles/max" }, { accountProfileId: "2", claudeConfigDir: "/profiles/max" }],
			[{ profileId: "1", label: "default" }, { accountProfileId: "1", claudeConfigDir: join(homedir(), ".claude") }],
			[undefined, {}],
		];
		for (const [profile, expected] of rows) assert.deepEqual(accountSessionScope(profile), expected, JSON.stringify(profile));
	});
});
