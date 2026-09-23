/**
 * The built-in isolation is a TRADE, and this is where the two halves have to
 * agree: Claude Code's own file, shell and web tools are removed only because
 * pi's arrive on the bridged `custom-tools` MCP server instead. A query that
 * carries the denylist and an empty `tools` allowlist WITHOUT that server
 * reaches the model with no tools at all, silently — the state a pi-ai contract
 * change put every session into (kendex#2749).
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DISALLOWED_BUILTIN_TOOLS } from "../src/index.ts";
import { buildClaudeQueryOptions } from "../src/query-options.ts";

const model = { id: "claude-haiku-4-5", api: "claude-bridge", provider: "pi-claude", cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const bridgedServer = { "custom-tools": { name: "custom-tools", instance: {} } };

// A throwaway CLAUDE_CONFIG_DIR keeps the connector snapshot read off the
// developer's real account directory.
const build = (input) => {
	const claudeDir = mkdtempSync(join(tmpdir(), "bridge-query-options-"));
	const previous = process.env.CLAUDE_CONFIG_DIR;
	process.env.CLAUDE_CONFIG_DIR = claudeDir;
	try {
		return buildClaudeQueryOptions({
			cwd: claudeDir,
			requestedModel: model,
			queryModel: model,
			bridgeConfig: {},
			resumeSessionId: null,
			...input,
		});
	} finally {
		if (previous === undefined) delete process.env.CLAUDE_CONFIG_DIR;
		else process.env.CLAUDE_CONFIG_DIR = previous;
		rmSync(claudeDir, { recursive: true, force: true });
	}
};

describe("bridge query options: the built-in isolation follows the bridged tool server", () => {
	const rows = [
		{
			why: "pi's tools reached the child",
			input: { mcpServers: bridgedServer },
			isolated: true,
		},
		{
			why: "a pi-driven one-shot (compaction, branch summary) carries no tools by design",
			input: { ephemeralOneShot: true },
			isolated: true,
		},
		{
			why: "nothing replaced the built-ins this turn",
			input: {},
			isolated: false,
		},
	];
	for (const row of rows) {
		it(`${row.isolated ? "isolates" : "keeps"} the built-ins when ${row.why}`, () => {
			const built = build(row.input);

			assert.equal(built.bridgedToolsPresent, row.isolated);
			assert.equal(built.queryOptions.tools !== undefined, row.isolated, "an empty tools allowlist also strips Claude Code's own tools");
			assert.equal(built.queryOptions.disallowedTools !== undefined, row.isolated, "and the denylist removes what the bridge was going to replace");
			if (!row.isolated) return;
			assert.deepEqual(built.queryOptions.tools, []);
			assert.deepEqual(built.queryOptions.disallowedTools, DISALLOWED_BUILTIN_TOOLS);
			assert.deepEqual(built.queryOptions.allowedTools, ["mcp__custom-tools__*"]);
		});
	}

	it("keeps the connector session's built-in restriction, which is a boundary rather than a trade", () => {
		// A connectors session ingests untrusted third-party content, and
		// connectorBuiltinAllowlistHook denies everything outside three name classes
		// at runtime. Relaxing the request-side lists there would weaken that
		// boundary and reach nothing the model could call anyway.
		const built = build({ bridgeConfig: { provider: { enableConnectors: true } } });

		assert.equal(built.bridgedToolsPresent, false, "the same turn that fails soft without connectors");
		assert.ok(built.queryOptions.disallowedTools.includes("Bash"), "still denies the file and shell built-ins");
		assert.ok(built.queryOptions.hooks.PreToolUse.length > 0, "and keeps the runtime allowlist hook wired");
	});
});
