/**
 * Part of the built-in denylist is a TRADE, and this is where the two halves
 * have to agree: Claude Code's own file, shell and web tools are removed only
 * because pi's arrive on the bridged `custom-tools` MCP server instead. A query
 * that carries that half WITHOUT the server reaches the model with no tools at
 * all, silently — the state a pi-ai contract change put every session into
 * (kendex#2749). The rest of the denylist was never traded and never comes back.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ALWAYS_DENIED_BUILTIN_TOOLS, DISALLOWED_BUILTIN_TOOLS, SUBSTITUTED_BUILTIN_TOOLS } from "../src/index.ts";
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

describe("bridge query options: the substituted built-ins follow the bridged tool server", () => {
	const rows = [
		{
			why: "pi's tools reached the child",
			input: { mcpServers: bridgedServer },
			bridgedToolsPresent: true,
			isolated: true,
		},
		{
			why: "a pi-driven one-shot (compaction, branch summary) carries no tools by design",
			input: { piOneShot: true },
			bridgedToolsPresent: false,
			isolated: true,
		},
		{
			why: "a connectors session restricts the child as a security boundary",
			input: { bridgeConfig: { provider: { enableConnectors: true } } },
			bridgedToolsPresent: false,
			isolated: true,
		},
		{
			why: "nothing replaced them this turn",
			input: {},
			bridgedToolsPresent: false,
			isolated: false,
		},
	];
	for (const row of rows) {
		it(`${row.isolated ? "denies" : "restores"} them when ${row.why}`, () => {
			const built = build(row.input);

			assert.equal(built.bridgedToolsPresent, row.bridgedToolsPresent, "reports whether pi's tools reached the child");
			assert.equal(built.builtinIsolationApplied, row.isolated, "and reports what it did about the substituted built-ins, not what it inferred");
			for (const name of SUBSTITUTED_BUILTIN_TOOLS) {
				assert.equal(built.queryOptions.disallowedTools?.includes(name) ?? false, row.isolated, name);
			}
		});
	}

	it("keeps every never-traded built-in denied even when the substituted ones come back", () => {
		// The denylist is not only the file, shell and web set. The child runs
		// under permissionMode "bypassPermissions", so handing it subagents,
		// skills, todos, teams, worktrees or scheduling is not a degraded session,
		// it is a different one.
		const built = build({});

		assert.equal(built.builtinIsolationApplied, false);
		assert.deepEqual(built.queryOptions.disallowedTools, ALWAYS_DENIED_BUILTIN_TOOLS);
		assert.equal("tools" in built.queryOptions, false, "an empty tools allowlist would strip Claude Code's own tools too");
		assert.equal("mcpServers" in built.queryOptions, false, "nothing invented a server to stand in for pi's tools");
	});

	it("isolates with the whole denylist and the bridged allowlist when pi's tools are there", () => {
		const built = build({ mcpServers: bridgedServer });

		assert.deepEqual(built.queryOptions.tools, []);
		assert.deepEqual(built.queryOptions.disallowedTools, DISALLOWED_BUILTIN_TOOLS);
		assert.deepEqual(built.queryOptions.allowedTools, ["mcp__custom-tools__*"]);
	});

	it("leaves the connectors boundary alone when that session resolves no pi tools", () => {
		// connectorBuiltinAllowlistHook denies everything outside three name
		// classes at runtime, so relaxing the request-side lists here would weaken
		// the boundary and reach nothing the model could call anyway.
		const built = build({ bridgeConfig: { provider: { enableConnectors: true } } });

		assert.equal(built.enableCloudMcp, true);
		assert.ok(built.queryOptions.disallowedTools.includes("Bash"), "the file and shell built-ins stay denied");
		assert.ok(built.queryOptions.hooks.PreToolUse.length > 0, "and the runtime allowlist hook stays wired");
	});
});
