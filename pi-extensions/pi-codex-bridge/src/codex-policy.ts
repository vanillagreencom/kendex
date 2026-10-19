// What the bridge asks of Codex CLI 0.163.0, and what it accepts back. Each
// list here was read from that exact release (`codex features list`, the
// app-server protocol and the fixture suites); a different release is refused
// before any of it applies, so no list carries a compatibility branch.

import type { JsonObject } from "./protocol.js";

export const SUPPORTED_CODEX_VERSION = "0.163.0";

/**
 * Default-on 0.163.0 features that run something outside Pi: native shell,
 * exec and patch tools, browsers, computer use, image tools, MCP and plugin
 * server sources, hooks, turns Pi did not ask for (goals, the guardian
 * reviewer, sub-agents), and UI-only surfaces that have no place in a bridge.
 */
export const DISABLED_FEATURES = [
	"shell_tool",
	"apps",
	"plugins",
	"remote_plugin",
	"multi_agent",
	"browser_use",
	"computer_use",
	"image_generation",
	"view_image",
	"sleep_tool",
	"hooks",
	"unified_exec",
	"unified_exec_tty",
	"write_stdin_approval",
	"shell_snapshot",
	"code_mode_host",
	"code_mode_interrupt",
	"workspace_dependencies",
	"worktrees",
	"in_app_local_automation",
	"browser_use_external",
	"browser_use_full_cdp_access",
	"in_app_browser",
	"browser_annotation_api",
	"skill_mcp_dependency_install",
	"tool_call_mcp_elicitation",
	"auth_elicitation",
	"tool_suggest",
	"skill_search",
	"goals",
	"guardian_approval",
	"daemon_auto_start",
	"in_app_chat",
	"in_app_dictation",
	"in_app_voice",
	"in_app_updates",
	"realtime_conversation",
] as const;

/**
 * Features 0.163.0 still reports enabled for a thread after the launch list
 * above, each reviewed as running nothing outside Pi. Any other enabled
 * feature refuses the thread before its first turn.
 */
export const REVIEWED_ENABLED_FEATURES: ReadonlyMap<string, string> = new Map([
	// `--disable unified_exec`, `-c features.unified_exec=false` and
	// `experimental_use_unified_exec_tool=false` all leave it reported on in
	// 0.163.0. Its exec_command and write_stdin tools are not offered while
	// shell_tool is off and the thread has no environment; the fixture suite
	// reads the tools Codex offers the model to hold that.
	["unified_exec", "tools not offered: shell_tool off, environments []"],
	["api_key_cyber_access_programs", "API-key access programs; no tool"],
	["api_key_model_discovery", "API-key model listing; no tool"],
	["cli_daybreak", "access-program selection; no tool"],
	["compaction_image_budget", "compaction image budget; no tool"],
	["content_item_kinds", "content item kinds; no tool"],
	["enable_request_compression", "request compression; no tool"],
	["fast_mode", "service tier; no tool"],
	["ultrafast_mode", "service tier; no tool"],
	["guardian_reuse_parent_compaction", "guardian setting; guardian_approval is off"],
	["instant_interrupt", "interrupt latency; no tool"],
	["mentions_v2", "input mention parsing; no tool"],
	["plugin_sharing", "plugin sharing; plugins are off"],
	["system_proxy_fallback", "proxy transport; no tool"],
	["unbounded_connection_retries", "transport retries; no tool"],
	["collaboration_modes", "stage removed in 0.163.0"],
	["item_ids", "stage removed in 0.163.0"],
	["resize_all_images", "stage removed in 0.163.0"],
	["sqlite", "stage removed in 0.163.0"],
	["steer", "stage removed in 0.163.0"],
	["terminal_resize_reflow", "stage removed in 0.163.0"],
	["tool_search_always_defer_mcp_tools", "stage removed in 0.163.0"],
	["tui_app_server", "stage removed in 0.163.0"],
]);

/** Thread item types a bridged turn may start. Any other is a native tool or a
 * turn outside Pi, and interrupts the turn. */
export const ALLOWED_ITEM_TYPES: ReadonlySet<string> = new Set([
	"userMessage",
	"agentMessage",
	"reasoning",
	"plan",
	"contextCompaction",
	"dynamicToolCall",
]);

/** A native tool that survives the lists above asks before it runs, and the
 * bridge declines every such request. */
export const APPROVAL_POLICY = "untrusted";

/**
 * Launch settings beside the feature list. Web search is off, and Codex does
 * not offer the model `request_user_input`, because no user answers Codex
 * here. None of them enables a feature, so the feature audit's list is the
 * same with them as without.
 */
export const LAUNCH_CONFIG = [
	'web_search="disabled"',
	"tools.experimental_request_user_input={enabled=false}",
	// A thread tree may hold one thread: the root. Codex then refuses a
	// sub-agent spawn before the sub-agent's thread exists, so it sends no model
	// request. A setting under the multi_agent_v2 table that enables no
	// feature; the catalog's multi-agent runtime reads it even while the
	// multi_agent feature is off.
	"features.multi_agent_v2.max_concurrent_threads_per_session=1",
] as const;

export function appServerArgs(configOverrides: readonly string[]): string[] {
	return [
		"app-server",
		"--stdio",
		...DISABLED_FEATURES.flatMap((feature) => ["--disable", feature]),
		...LAUNCH_CONFIG.flatMap((setting) => ["-c", setting]),
		...configOverrides.flatMap((override) => ["-c", override]),
	];
}

/** Per-thread config that keeps every configured MCP server named in
 * `config/read` from starting. */
export function threadConfig(mcpServerNames: readonly string[]): JsonObject {
	return {
		mcp_servers: Object.fromEntries(mcpServerNames.map((name) => [name, { enabled: false }])),
	};
}

/** The first enabled feature no review covers, if any. */
export function unreviewedFeature(enabled: readonly string[]): string | undefined {
	return [...enabled].sort().find((name) => !REVIEWED_ENABLED_FEATURES.has(name));
}
