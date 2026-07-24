import { type HookCallback, type query } from "@anthropic-ai/claude-agent-sdk";
import { normalizeConnectorWriteMode, type Config, type ConnectorWriteMode } from "./config.js";
import { MCP_SERVER_NAME } from "./skills.js";

// Disable Claude Code built-ins in the provider path. Pi owns tool execution;
// Claude reaches Pi tools through the bridged MCP server instead.
//
// `allowedTools` is a permission auto-allow list in the Claude Agent SDK, not a
// visibility allowlist. Use `tools: []` to remove the built-in tool set, and keep
// this disallow list as a belt-and-suspenders guard for SDK/CLI built-ins that may
// otherwise leak into the model context (e.g. TodoWrite, CronList, SendMessage).
export const DISALLOWED_BUILTIN_TOOLS = [
	"Read", "Write", "Edit", "MultiEdit", "Glob", "Grep", "Bash", "Agent", "Task",
	"NotebookEdit", "EnterWorktree", "ExitWorktree",
	"CronList", "CronCreate", "CronDelete", "TeamCreate", "TeamDelete",
	"TaskOutput", "TaskStop", "SendMessage", "Skill",
	"TodoRead", "TodoWrite",
	"ListMcpResources", "ReadMcpResource",
	"WebFetch", "WebSearch",
	"AskUserQuestion", "EnterPlanMode", "ExitPlanMode",
	"ToolSearch", "ScheduleWakeup",
];

export const CLAUDE_BRIDGE_TOOL_ISOLATION = {
	tools: [] as string[],
	disallowedTools: DISALLOWED_BUILTIN_TOOLS,
	allowedTools: [`mcp__${MCP_SERVER_NAME}__*`],
} satisfies Pick<NonNullable<Parameters<typeof query>[0]["options"]>, "tools" | "allowedTools" | "disallowedTools">;

// --- Claude account cloud MCP connectors (Gmail / Calendar / Drive) ---
//
// By default the bridge suppresses claude.ai cloud MCP servers (see the
// ENABLE_CLAUDEAI_MCP_SERVERS="0" note near the query builder) so Pi owns tool
// execution and tokens stay lean. This opt-in flag lets the authenticated
// Claude account's authorized Google connectors flow through to the model,
// exposing Gmail/Calendar/Drive tools the account has connected. Gated so the
// default behavior is unchanged. See
// docs/plans/claude-bridge-google-connectors.md.
export function connectorsEnabledFromEnv(): boolean {
	const v = (process.env.CLAUDE_BRIDGE_ENABLE_CONNECTORS ?? "").trim().toLowerCase();
	return v === "1" || v === "true" || v === "yes" || v === "on";
}

// Connectors are enabled if EITHER the env var is truthy OR the resolved bridge
// config sets `provider.enableConnectors`. Env is the simplest per-process knob
// (one sidecar per Claude account sets it in its child env); config lets a host
// app enable it declaratively via its written settings.json.
export function connectorsEnabledFor(config?: Config): boolean {
	return connectorsEnabledFromEnv() || config?.provider?.enableConnectors === true;
}

// Cloud MCP connector tool namespaces auto-allowed when connectors are enabled.
// Names match Claude Code's claude.ai connector servers.
export const CLAUDE_AI_CONNECTOR_TOOL_PATTERNS = [
	"mcp__claude_ai_Gmail__*",
	"mcp__claude_ai_Google_Calendar__*",
	"mcp__claude_ai_Google_Drive__*",
];

// Claude Code registers a Claude account's cloud connectors as DEFERRED tools
// that the model must load via ToolSearch (and enumerate via the MCP-resource
// tools). The default bridge isolation disallows all three so Pi owns tool
// discovery — but that hides the connectors from the model entirely. When
// connectors are enabled we must let these through so Gmail/Calendar/Drive are
// discoverable. Verified: disallowing ToolSearch reliably yields NO_CONNECTORS.
export const CONNECTOR_DISCOVERY_TOOLS = ["ToolSearch", "ListMcpResources", "ReadMcpResource"];

// --- Connector WRITE tool control (read-inline / write-by-approval) ---
//
// Connector tools execute INSIDE claude via the bridge, so Memsira's Pi-level
// ConsentGate never sees them. To keep every connector WRITE explicit + gated,
// connector chat sessions run read-only (writes denied); the model performs a
// write only through a gated Pi custom-tool whose app-side dispatcher runs a
// ONE-SHOT write-enabled bridge query. This block is the bridge lever for that:
// deny connector write tools by default, allow them only for that executor.
//
// Cloud connector server namespaces (the `mcp__<server>__` prefix). Every
// claude.ai connector server lives under CONNECTOR_NS_PREFIX, so that prefix —
// not the named trio — is what marks a tool as connector-owned.
const CONNECTOR_NS_PREFIX = "mcp__claude_ai_";
const CONNECTOR_NS_GMAIL = `${CONNECTOR_NS_PREFIX}Gmail__`;
const CONNECTOR_NS_CALENDAR = `${CONNECTOR_NS_PREFIX}Google_Calendar__`;
const CONNECTOR_NS_DRIVE = `${CONNECTOR_NS_PREFIX}Google_Drive__`;

// Read-verb prefixes: a connector tool whose name (the segment after its
// namespace) starts with one of these is a non-mutating READ and always stays
// available. Everything else on a connector namespace is treated as a WRITE.
// Observed reads (POC): list_labels, search_threads, get_message, list_calendars,
// list_events, get_event — i.e. list_/search_/get_; the rest are common Google
// read verbs. Keep this list tight: mis-classifying a read as a write only
// blocks a read (safe, easily fixed), whereas mis-classifying a write as a read
// would open an ungated mutation.
const CONNECTOR_READ_PREFIXES = [
	"list_", "search_", "get_", "read_", "fetch_", "find_",
	"download_", "describe_", "query_", "count_", "view_",
];

// Explicit known write tool names (current claude.ai connectors). Passed to the
// SDK disallowedTools so today's writes are removed from the model's context by
// exact tool id (the CLI matcher only supports exact ids or a whole-server glob).
export const CONNECTOR_WRITE_TOOLS = [
	`${CONNECTOR_NS_GMAIL}create_draft`,
	`${CONNECTOR_NS_GMAIL}create_label`,
	`${CONNECTOR_NS_GMAIL}label_message`,
	`${CONNECTOR_NS_GMAIL}label_thread`,
	`${CONNECTOR_NS_GMAIL}unlabel_message`,
	`${CONNECTOR_NS_GMAIL}unlabel_thread`,
	`${CONNECTOR_NS_GMAIL}apply_sensitive_label`,
	`${CONNECTOR_NS_GMAIL}remove_sensitive_label`,
	`${CONNECTOR_NS_CALENDAR}create_event`,
	`${CONNECTOR_NS_CALENDAR}update_event`,
	`${CONNECTOR_NS_CALENDAR}delete_event`,
	`${CONNECTOR_NS_CALENDAR}respond_to_event`,
	`${CONNECTOR_NS_DRIVE}create_file`,
	`${CONNECTOR_NS_DRIVE}copy_file`,
];

// Classify a connector tool name as a WRITE (mutating) tool. FAIL CLOSED, twice:
//
//  1. Namespace: the whole `mcp__claude_ai_<Server>__` space counts, not just the
//     known Gmail/Calendar/Drive trio. Connectors attach account-wide, so ANY
//     other connector on the account (Slack, Atlassian, Figma, org-custom) shows
//     up in a bridge session — and the connector path deliberately omits
//     `tools: []` (see toolIsolationForQuery), so those tools are discoverable
//     and callable. Keying on the trio meant e.g. a Slack send_message ran
//     ungated inside claude, invisible to Pi's ConsentGate.
//  2. Verb: a tool on that space is a write UNLESS its tool segment starts with a
//     known read prefix, so not-yet-known write tools (e.g. Gmail send_message,
//     Drive delete_file, Calendar add_attendee) are blocked in a read-only
//     session. A name under the connector prefix with no parseable `__<tool>`
//     segment is also a write: it is a connector by construction, so deny wins.
//
// Non-connector tools (Pi custom-tools, ToolSearch, MCP-resource tools, other MCP
// servers) are never connector writes → false. Used by connectorWriteDenyHook and
// by callers (e.g. the one-shot write executor) that enumerate live connector tools.
export function isConnectorWriteTool(name: string): boolean {
	if (!name.startsWith(CONNECTOR_NS_PREFIX)) return false;
	// First `__` after the prefix ends the server segment. First (not last) so a
	// server name containing `__` leaves the extra segment in `tool`, which then
	// fails the read-prefix test — ambiguity resolves to write.
	const sep = name.indexOf("__", CONNECTOR_NS_PREFIX.length);
	// No separator (sep < 0) OR an EMPTY server segment (sep at the prefix, e.g.
	// `mcp__claude_ai___search_messages`) means the name doesn't parse as
	// <server>__<tool> — it never earns the read-prefix exemption.
	if (sep <= CONNECTOR_NS_PREFIX.length) return true;
	const tool = name.slice(sep + "__".length);
	return !CONNECTOR_READ_PREFIXES.some((prefix) => tool.startsWith(prefix));
}

// Connector write mode from the env override. `allow` exposes connector write
// tools; `deny` hides them. Returns undefined when unset so config can decide.
export function connectorWriteModeFromEnv(): ConnectorWriteMode | undefined {
	const v = (process.env.CLAUDE_BRIDGE_CONNECTOR_WRITE ?? "").trim().toLowerCase();
	if (v === "allow") return "allow";
	if (v === "deny") return "deny";
	return undefined;
}

// Resolve the connector write mode: env wins over config, default `deny`
// (mirrors connectorsEnabledFor's env-first precedence). Only meaningful when
// connectors are enabled; connector chat sessions keep the default deny and the
// one-shot approved-write executor sets allow (env or config).
//
// FAIL CLOSED: writes are enabled ONLY by an explicit, validated `allow`. The
// config value is re-normalized here (defense in depth over normalizeProviderConfig)
// so a raw legacy-config value like "Deny"/"read-only"/true can never be treated
// as a truthy non-deny and silently open writes — anything but exact allow → deny.
export function connectorWriteModeFor(config?: Config): ConnectorWriteMode {
	const resolved = connectorWriteModeFromEnv() ?? normalizeConnectorWriteMode(config?.provider?.connectorWriteMode);
	return resolved === "allow" ? "allow" : "deny";
}

// PreToolUse hook that hard-blocks connector WRITE tools at call time. Hooks run
// regardless of permissionMode (we use bypassPermissions), so this — not the
// static deny lists — is the real prefix-based runtime enforcement of
// isConnectorWriteTool. disallowedTools removes today's KNOWN writes from model
// context, but it lists exact ids on the known trio only, so a future write tool
// (e.g. mcp__claude_ai_Gmail__send_message, ..._Drive__delete_file) or any tool
// on another connector the account has attached (mcp__claude_ai_Slack__send_message)
// would otherwise be callable in a read-only session; this hook denies it by prefix.
export function connectorWriteDenyHook(): HookCallback {
	return async (input) => {
		// The CLI treats a hook error/timeout as an EMPTY hook output and lets
		// the tool call proceed (fail OPEN) — so any exception in this body
		// must convert to a deny, never an allow. Today's body is pure string
		// checks on schema-validated input; the catch pins that invariant for
		// whatever gets added here later.
		try {
			if (input.hook_event_name !== "PreToolUse") return { continue: true };
			if (!isConnectorWriteTool(input.tool_name)) return { continue: true };
			return connectorWriteDenyOutput(String(input.tool_name));
		} catch {
			const toolName = typeof (input as { tool_name?: unknown })?.tool_name === "string"
				? (input as { tool_name: string }).tool_name
				: "<unknown>";
			return connectorWriteDenyOutput(toolName);
		}
	};
}

function connectorWriteDenyOutput(toolName: string) {
	return {
		hookSpecificOutput: {
			hookEventName: "PreToolUse" as const,
			permissionDecision: "deny" as const,
			permissionDecisionReason:
				`Connector write tool "${toolName}" is blocked in read-only connector mode. ` +
				`Connector writes must go through Memsira's gated approval flow.`,
		},
	};
}

// Connector query-option fragment: tool isolation (allow/deny lists) plus, when
// connectors are enabled and writes are denied, the runtime PreToolUse write
// hook. Spread into the SDK query options; continuation queries inherit it via
// `{ ...queryOptions }`. Exported so the wiring is unit-testable end to end.
export function connectorQueryOptions(connectorsEnabled: boolean, writeMode: ConnectorWriteMode = "deny"): Partial<Pick<NonNullable<Parameters<typeof query>[0]["options"]>, "tools" | "allowedTools" | "disallowedTools" | "hooks">> {
	const isolation = toolIsolationForQuery(connectorsEnabled, writeMode);
	// Only enforce (and only meaningful) when connectors are on and writes denied.
	if (!connectorsEnabled || writeMode === "allow") return isolation;
	return { ...isolation, hooks: { PreToolUse: [{ hooks: [connectorWriteDenyHook()] }] } };
}

// Tool isolation for a query. When connectors are enabled we still remove
// Claude Code's filesystem/shell built-ins (via disallowedTools; Pi owns those)
// and auto-allow the cloud connector tool namespaces so the model can call
// Gmail/Calendar/Drive.
//
// Critically, we must OMIT `tools: []` in the connector path: an empty --tools
// allowlist strips the claude.ai cloud MCP connector tools from the model's
// view (verified — Pi's SDK-injected custom-tools survive it, but connectors do
// not). Dropping `tools` leaves the connectors visible; disallowedTools still
// hard-denies the built-ins so Pi keeps ownership of file/shell/web tools.
export function toolIsolationForQuery(connectorsEnabled: boolean, writeMode: ConnectorWriteMode = "deny"): Partial<Pick<NonNullable<Parameters<typeof query>[0]["options"]>, "tools" | "allowedTools" | "disallowedTools">> {
	if (!connectorsEnabled) return CLAUDE_BRIDGE_TOOL_ISOLATION;
	// Keep ToolSearch + MCP-resource tools available so the model can discover the
	// deferred cloud connector tools; still block file/shell/web built-ins.
	const disallowedTools = DISALLOWED_BUILTIN_TOOLS.filter((t) => !CONNECTOR_DISCOVERY_TOOLS.includes(t));
	// Deny connector WRITE tools unless writes are explicitly allowed (fail
	// closed: any mode but exact "allow" is treated as read-only). This removes
	// today's KNOWN writes from the model's context by exact id; deny rules take
	// precedence over the CLAUDE_AI_CONNECTOR_TOOL_PATTERNS allow rules below, so
	// reads stay available. Runtime enforcement covering future write tools and
	// connector namespaces we don't enumerate here (Slack, Atlassian, org-custom)
	// is done by connectorWriteDenyHook — see connectorQueryOptions.
	if (writeMode !== "allow") disallowedTools.push(...CONNECTOR_WRITE_TOOLS);
	return {
		disallowedTools,
		allowedTools: [...CLAUDE_BRIDGE_TOOL_ISOLATION.allowedTools, ...CLAUDE_AI_CONNECTOR_TOOL_PATTERNS],
	};
}
