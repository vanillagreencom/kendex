import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
	accountSessionScope,
	classifyClaudeFailure,
	rateLimitResetMs,
	rateLimitTypeFromInfo,
	RetryEventBuffer,
	subscriberProfileEnv,
} from "../src/account-router.ts";

function fakeStream() {
	const events = [];
	let ended = false;
	return {
		events,
		get ended() { return ended; },
		push(event) { events.push(event); },
		end() { ended = true; },
	};
}

describe("subscriberProfileEnv", () => {
	it("selects CLAUDE_CONFIG_DIR without inheriting API billing credentials", () => {
		const env = subscriberProfileEnv(
			{ configDir: "/profiles/max" },
			{
				PATH: "/bin",
				CLAUDE_CONFIG_DIR: "/profiles/old",
				ANTHROPIC_API_KEY: "secret",
				ANTHROPIC_AUTH_TOKEN: "secret",
				ANTHROPIC_OAUTH_TOKEN: "secret",
				CLAUDE_CODE_OAUTH_TOKEN: "secret",
				ANTHROPIC_BASE_URL: "https://gateway.invalid",
				ANTHROPIC_CUSTOM_HEADERS: "Authorization: secret",
				ANTHROPIC_AWS_API_KEY: "secret",
				ANTHROPIC_FOUNDRY_AUTH_TOKEN: "secret",
				AWS_BEARER_TOKEN_BEDROCK: "secret",
				CLAUDE_CODE_USE_BEDROCK: "1",
			},
		);
		assert.equal(env.PATH, "/bin");
		assert.equal(env.CLAUDE_CONFIG_DIR, "/profiles/max");
		assert.equal(env.ANTHROPIC_API_KEY, undefined);
		assert.equal(env.ANTHROPIC_AUTH_TOKEN, undefined);
		assert.equal(env.ANTHROPIC_OAUTH_TOKEN, undefined);
		assert.equal(env.CLAUDE_CODE_OAUTH_TOKEN, undefined);
		assert.equal(env.ANTHROPIC_BASE_URL, undefined);
		assert.equal(env.ANTHROPIC_CUSTOM_HEADERS, undefined);
		assert.equal(env.ANTHROPIC_AWS_API_KEY, undefined);
		assert.equal(env.ANTHROPIC_FOUNDRY_AUTH_TOKEN, undefined);
		assert.equal(env.AWS_BEARER_TOKEN_BEDROCK, undefined);
		assert.equal(env.CLAUDE_CODE_USE_BEDROCK, undefined);
	});

	it("uses the real default profile by unsetting CLAUDE_CONFIG_DIR", () => {
		const env = subscriberProfileEnv(
			{ configDir: undefined },
			{ HOME: "/home/test", CLAUDE_CONFIG_DIR: "/profiles/old" },
		);
		assert.equal(env.CLAUDE_CONFIG_DIR, undefined);
		assert.deepEqual(
			accountSessionScope({ profileId: "default", label: "default" }, env),
			{ accountProfileId: "default", claudeConfigDir: "/home/test/.claude" },
		);
	});
});

describe("RetryEventBuffer", () => {
	it("discards protocol setup events when an account fails before output", () => {
		const target = fakeStream();
		const buffer = new RetryEventBuffer(target);
		buffer.push({ type: "start", partial: {} });
		buffer.push({ type: "text_start", contentIndex: 0, partial: {} });
		buffer.discard();
		buffer.end();
		assert.deepEqual(target.events, []);
		assert.equal(target.ended, false);
	});

	it("flushes setup exactly once at the first visible delta", () => {
		const target = fakeStream();
		let commits = 0;
		const buffer = new RetryEventBuffer(target, () => { commits += 1; });
		buffer.push({ type: "start", partial: {} });
		buffer.push({ type: "text_start", contentIndex: 0, partial: {} });
		buffer.push({ type: "text_delta", contentIndex: 0, delta: "hello", partial: {} });
		buffer.push({ type: "text_end", contentIndex: 0, content: "hello", partial: {} });
		buffer.end();
		assert.deepEqual(target.events.map((event) => event.type), [
			"start", "text_start", "text_delta", "text_end",
		]);
		assert.equal(commits, 1);
		assert.equal(target.ended, true);
	});

	it("treats a complete tool call as committed output", () => {
		const target = fakeStream();
		const buffer = new RetryEventBuffer(target);
		buffer.push({ type: "start", partial: {} });
		buffer.push({ type: "toolcall_end", contentIndex: 0, toolCall: {}, partial: {} });
		assert.equal(buffer.hasCommittedOutput, true);
		assert.deepEqual(target.events.map((event) => event.type), ["start", "toolcall_end"]);
	});
});

describe("account routing helpers", () => {
	it("classifies retryable Claude failures", () => {
		assert.equal(classifyClaudeFailure("rate_limit"), "rate-limit");
		assert.equal(classifyClaudeFailure("You've hit your session limit · resets 7:10pm"), "rate-limit");
		assert.equal(classifyClaudeFailure("authentication_failed"), "auth");
		assert.equal(classifyClaudeFailure("401 authentication_error"), "auth");
		assert.equal(classifyClaudeFailure("OAuth token has expired; please run /login"), "auth");
		assert.equal(classifyClaudeFailure("Extra usage is disabled for this account"), "rate-limit");
		assert.equal(classifyClaudeFailure("Credit balance is too low"), "billing");
		assert.equal(classifyClaudeFailure({ status: 429, message: "request rejected" }), "rate-limit");
		assert.equal(classifyClaudeFailure("usage quota exceeded"), "rate-limit");
		assert.equal(classifyClaudeFailure("disk quota exceeded"), undefined);
		assert.equal(classifyClaudeFailure("API overloaded"), "overloaded");
		assert.equal(classifyClaudeFailure({ statusCode: 503, message: "temporarily unavailable" }), "server");
		assert.equal(classifyClaudeFailure("processed 500 files"), undefined);
		assert.equal(classifyClaudeFailure("socket timeout"), "network");
		assert.equal(classifyClaudeFailure("invalid request"), undefined);
	});

	it("normalizes camel/snake rate-limit payload variants", () => {
		const resetSeconds = Math.floor((Date.now() + 60_000) / 1000);
		assert.equal(rateLimitTypeFromInfo({ rate_limit_type: "seven_day_fable" }), "seven_day_fable");
		assert.equal(rateLimitResetMs({ resets_at: resetSeconds }), resetSeconds * 1000);
		assert.equal(rateLimitResetMs({ resetsAt: "2030-01-01T00:00:00Z" }), Date.parse("2030-01-01T00:00:00Z"));
	});

	it("keeps account-scoped session metadata explicit", () => {
		assert.deepEqual(
			accountSessionScope({ profileId: "2", label: "max", configDir: "/profiles/max" }),
			{ accountProfileId: "2", claudeConfigDir: "/profiles/max" },
		);
		assert.deepEqual(
			accountSessionScope(
				{ profileId: "1", label: "default" },
				{ HOME: "/home/test", CLAUDE_CONFIG_DIR: "/profiles/inherited" },
			),
			{ accountProfileId: "1", claudeConfigDir: "/home/test/.claude" },
		);
	});
});
