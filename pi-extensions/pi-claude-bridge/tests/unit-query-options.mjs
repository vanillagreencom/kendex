/**
 * The child runs under permissionMode "bypassPermissions", so every built-in
 * the query options leave enabled is a capability no permission check gates.
 * Tool authority comes only from the tools the host declared; an empty set and
 * an absent bridged server grant none of Claude Code's file, shell or web tools.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DISALLOWED_BUILTIN_TOOLS } from "../src/index.ts";
import { buildClaudeQueryOptions } from "../src/query-options.ts";
import { clearPackageConfigCache } from "../src/package-config.ts";
import { assertSourceControl } from "./lib/source-control.mjs";

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

// Claude Code's native file, shell and web tools, named here rather than read
// from the denylist under test.
const NATIVE_TOOLS = ["Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "Bash", "NotebookEdit", "WebFetch", "WebSearch"];

describe("bridge query options: tool authority comes only from the host's declared tools", () => {
	const connectors = { provider: { enableConnectors: true } };
	const rows = [
		{ why: "an ordinary request declares no tools", input: {}, bridged: false, connectors: false },
		{ why: "pi's tools reach the child on the bridged server", input: { mcpServers: bridgedServer }, bridged: true, connectors: false },
		{ why: "a connectors session resolves no pi tools", input: { bridgeConfig: connectors }, bridged: false, connectors: true },
		{ why: "a connectors session carries pi's tools", input: { bridgeConfig: connectors, mcpServers: bridgedServer }, bridged: true, connectors: true },
	];
	for (const row of rows) {
		it(`denies every native tool when ${row.why}`, () => {
			const built = build(row.input);
			const options = built.queryOptions;

			assert.equal(options.permissionMode, "bypassPermissions");
			assert.equal(built.bridgedToolsPresent, row.bridged);
			for (const name of NATIVE_TOOLS) assert.ok(options.disallowedTools.includes(name), name);
			assert.deepEqual(Object.keys(options.mcpServers ?? {}), row.bridged ? ["custom-tools"] : [], "nothing invents a server");
			if (row.connectors) {
				// An empty tools list would hide the account's connectors, so the
				// runtime allowlist hook holds that boundary instead.
				assert.equal("tools" in options, false);
				assert.ok(!options.disallowedTools.includes("ToolSearch"), "connector discovery stays reachable");
				assert.ok(options.hooks.PreToolUse[0].hooks.length > 0, "the runtime allowlist hook is wired");
			} else {
				assert.deepEqual(options.tools, [], "no built-in tool set is offered");
				assert.deepEqual(options.disallowedTools, DISALLOWED_BUILTIN_TOOLS);
				assert.deepEqual(options.allowedTools, ["mcp__custom-tools__*"], "only bridged tools are auto-allowed");
				assert.equal(options.hooks, undefined);
			}
		});
	}
});

describe("must-fail controls: connectors-off query enforcement", () => {
	const rows = [
		{
			why: "loaded settings cannot enable cloud connectors",
			before: '...(!enableCloudMcp ? { env: { ENABLE_CLAUDEAI_MCP_SERVERS: "0" } } : {}),',
			after: '...(!enableCloudMcp ? { env: { ENABLE_CLAUDEAI_MCP_SERVERS: "1" } } : {}),',
			failure: /command-line settings override user env without dropping fastMode/,
		},
		{
			why: "user-scope MCP cannot load undeclared servers",
			before: 'const strictMcpConfigEnabled = !enableCloudMcp || (!appendSystemPrompt && providerSettings.strictMcpConfig !== false);',
			after: 'const strictMcpConfigEnabled = enableCloudMcp || (!appendSystemPrompt && providerSettings.strictMcpConfig !== false);',
			failure: /only bridge-declared MCP servers load/,
		},
	];
	for (const row of rows) {
		it(row.why, () => assertSourceControl({
			source: "src/query-options.ts",
			...row,
			suite: "unit-query-options.mjs",
			pattern: "user sources load with connectors off",
		}));
	}
});

// One session outside any repository, with a marker in the Pi agent-dir
// AGENTS.md: loaded Claude user settings supply global instructions regardless
// of the connectors switch, so the append omits the file.
describe("bridge query options: the Pi agent-dir AGENTS.md is forwarded once without Claude user settings and not with them", () => {
	const rows = [
		{ why: "sources are unset with connectors off", provider: {}, settingSources: undefined, forwarded: 1 },
		{ why: "connectors on loads Claude user settings", provider: { enableConnectors: true }, settingSources: ["user"], forwarded: 0 },
		{ why: "user sources load with connectors off", provider: { settingSources: ["user"] }, settingSources: ["user"], forwarded: 0 },
		{ why: "user and project sources load with connectors off", provider: { settingSources: ["user", "project"] }, settingSources: ["user", "project"], forwarded: 0 },
		{ why: "strict MCP cannot opt out of connectors-off loaded sources", provider: { settingSources: ["user"], strictMcpConfig: false, fastMode: true }, settingSources: ["user"], forwarded: 0 },
		{ why: "project-only sources keep Pi global instructions", provider: { settingSources: ["project"] }, settingSources: ["project"], forwarded: 1 },
		{ why: "empty sources stay empty", provider: { settingSources: [] }, settingSources: [], forwarded: 1 },
	];
	for (const row of rows) {
		it(`forwards it ${row.forwarded} time(s) when ${row.why}`, () => {
			const dir = mkdtempSync(join(tmpdir(), "bridge-agents-md-"));
			const outsideRepo = join(dir, "outside");
			const agentDir = join(dir, "agent");
			mkdirSync(outsideRepo, { recursive: true });
			mkdirSync(agentDir, { recursive: true });
			writeFileSync(join(agentDir, "AGENTS.md"), "# global style marker\n");
			const saved = Object.fromEntries(["PI_CODING_AGENT_DIR", "CLAUDE_BRIDGE_ISOLATED", "CLAUDE_BRIDGE_ENABLE_CONNECTORS"].map((key) => [key, process.env[key]]));
			const oldCwd = process.cwd();
			try {
				process.env.PI_CODING_AGENT_DIR = agentDir;
				clearPackageConfigCache();
				delete process.env.CLAUDE_BRIDGE_ISOLATED;
				delete process.env.CLAUDE_BRIDGE_ENABLE_CONNECTORS;
				process.chdir(outsideRepo);
				const skills = "The following skills provide specialized instructions for specific tasks.\n<available_skills>skill marker</available_skills>";
				const built = build({ bridgeConfig: { provider: row.provider }, mcpServers: bridgedServer, systemPrompt: skills });

				assert.equal(built.appendSystemPrompt, true);
				assert.deepEqual(built.queryOptions.settingSources, row.settingSources);
				const append = built.queryOptions.systemPrompt.append ?? "";
				assert.equal(append.split("global style marker").length - 1, row.forwarded);
				assert.ok(append.includes("skill marker"), "Pi skills still append with loaded settings");
				if (!row.provider.enableConnectors) {
					assert.equal(built.queryOptions.env.ENABLE_CLAUDEAI_MCP_SERVERS, "0");
					assert.deepEqual(built.queryOptions.settings, {
						env: { ENABLE_CLAUDEAI_MCP_SERVERS: "0" },
						...(row.provider.fastMode ? { fastMode: true } : {}),
					}, "command-line settings override user env without dropping fastMode");
					assert.equal(built.queryOptions.strictMcpConfig, true, "only bridge-declared MCP servers load");
					assert.deepEqual(built.queryOptions.mcpServers, bridgedServer, "no connector servers are declared");
					assert.deepEqual(built.queryOptions.allowedTools, ["mcp__custom-tools__*"], "no connector allow patterns");
					assert.deepEqual(built.queryOptions.disallowedTools, DISALLOWED_BUILTIN_TOOLS);
					assert.deepEqual(built.queryOptions.tools, []);
					assert.equal(built.queryOptions.hooks, undefined, "uses non-connector isolation");
				}
			} finally {
				process.chdir(oldCwd);
				for (const [key, value] of Object.entries(saved)) {
					if (value === undefined) delete process.env[key];
					else process.env[key] = value;
				}
				clearPackageConfigCache();
				rmSync(dir, { recursive: true, force: true });
			}
		});
	}
});
