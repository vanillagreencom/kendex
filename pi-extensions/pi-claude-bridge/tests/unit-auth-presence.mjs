/**
 * Tests for claude-bridge credential presence detection and the pure
 * registration decision that gates provider availability (W8-2 availability
 * honesty). These exercise auth-presence.ts directly — no live pi instance.
 */
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { resolveClaudeConfigDir, hasClaudeCredentials } from "../src/auth-presence.ts";

function withTempHome(fn) {
	const root = mkdtempSync(join(tmpdir(), "claude-bridge-auth-"));
	try {
		return fn(root);
	} finally {
		rmSync(root, { recursive: true, force: true });
	}
}

// Pin the platform to linux in credential tests so the darwin Keychain default
// never masks a real false/true; darwin behavior is tested explicitly.
const LINUX = "linux";

describe("resolveClaudeConfigDir", () => {
	it("resolves explicit, trimmed and absent config paths", () => {
		for (const [env, expected] of [
			[{ CLAUDE_CONFIG_DIR: "/custom/dir" }, "/custom/dir"],
			[{ CLAUDE_CONFIG_DIR: "  /custom/dir  " }, "/custom/dir"],
			[{ CLAUDE_CONFIG_DIR: "   " }, join(homedir(), ".claude")],
			[{}, join(homedir(), ".claude")],
		]) {
			assert.equal(resolveClaudeConfigDir(env), expected, JSON.stringify(env));
		}
	});
});

describe("hasClaudeCredentials", () => {
	it("is false when no signal and no .credentials.json exists (linux)", () => withTempHome((dir) => {
		assert.equal(hasClaudeCredentials({ CLAUDE_CONFIG_DIR: dir }, LINUX), false);
	}));

	it("is true when .credentials.json exists in the resolved config dir", () => withTempHome((dir) => {
		writeFileSync(join(dir, ".credentials.json"), "{}");
		assert.equal(hasClaudeCredentials({ CLAUDE_CONFIG_DIR: dir }, LINUX), true);
	}));

	it("honors CLAUDE_CONFIG_DIR override for the credentials file location", () => withTempHome((dir) => {
		const nested = join(dir, "alt");
		mkdirSync(nested, { recursive: true });
		writeFileSync(join(nested, ".credentials.json"), "{}");
		assert.equal(hasClaudeCredentials({ CLAUDE_CONFIG_DIR: nested }, LINUX), true);
		assert.equal(hasClaudeCredentials({ CLAUDE_CONFIG_DIR: dir }, LINUX), false);
	}));

	it("detects each environment credential source independently", () => withTempHome((dir) => {
		// Claude Code emits token variables and provider-routing flags.
		for (const [key, value, expected] of [
			["CLAUDE_CODE_OAUTH_TOKEN", "tok", true],
			["ANTHROPIC_API_KEY", "sk-ant-x", true],
			["ANTHROPIC_AUTH_TOKEN", "at-x", true],
			["CLAUDE_CODE_USE_BEDROCK", "1", true],
			["CLAUDE_CODE_USE_BEDROCK", "true", true],
			["CLAUDE_CODE_USE_BEDROCK", "0", false],
			["CLAUDE_CODE_USE_BEDROCK", "yes", false],
			["CLAUDE_CODE_USE_VERTEX", "1", true],
			["CLAUDE_CODE_USE_VERTEX", "false", false],
			["CLAUDE_CODE_USE_FOUNDRY", "1", true],
			["CLAUDE_CODE_USE_FOUNDRY", "true", true],
			["CLAUDE_CODE_USE_FOUNDRY", "0", false],
			["CLAUDE_CODE_USE_ANTHROPIC_AWS", "1", true],
			["CLAUDE_CODE_USE_ANTHROPIC_AWS", "true", true],
			["CLAUDE_CODE_USE_ANTHROPIC_AWS", "0", false],
			["CLAUDE_CODE_USE_MANTLE", "1", true],
			["CLAUDE_CODE_USE_MANTLE", "true", true],
			["CLAUDE_CODE_USE_MANTLE", "0", false],
			["CLAUDE_CODE_OAUTH_TOKEN", "", false],
			["ANTHROPIC_API_KEY", "   ", false],
			["ANTHROPIC_AUTH_TOKEN", "", false],
		]) {
			assert.equal(hasClaudeCredentials({ CLAUDE_CONFIG_DIR: dir, [key]: value }, LINUX), expected, `${key}=${value}`);
		}
	}));

	// settings.json apiKeyHelper ---------------------------------------------
	it("is true when settings.json has a non-empty apiKeyHelper string", () => withTempHome((dir) => {
		writeFileSync(join(dir, "settings.json"), JSON.stringify({ apiKeyHelper: "/usr/local/bin/get-key.sh" }));
		assert.equal(hasClaudeCredentials({ CLAUDE_CONFIG_DIR: dir }, LINUX), true);
	}));

	it("is false when settings.json lacks apiKeyHelper or it is empty", () => withTempHome((dir) => {
		writeFileSync(join(dir, "settings.json"), JSON.stringify({ apiKeyHelper: "", other: 1 }));
		assert.equal(hasClaudeCredentials({ CLAUDE_CONFIG_DIR: dir }, LINUX), false);
	}));

	it("tolerates malformed settings.json as apiKeyHelper-absent", () => withTempHome((dir) => {
		writeFileSync(join(dir, "settings.json"), "{ not valid json");
		assert.equal(hasClaudeCredentials({ CLAUDE_CONFIG_DIR: dir }, LINUX), false);
	}));

	it("uses the platform credential fallback only on darwin", () => withTempHome((dir) => {
		for (const [platform, expected] of [["darwin", true], ["linux", false], ["win32", false]]) {
			assert.equal(hasClaudeCredentials({ CLAUDE_CONFIG_DIR: dir }, platform), expected, platform);
		}
	}));
});
