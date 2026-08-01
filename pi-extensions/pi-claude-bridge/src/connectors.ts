import { type HookCallback, type query } from "@anthropic-ai/claude-agent-sdk";
import { normalizeConnectorWriteMode, type Config, type ConnectorWriteMode } from "./config.js";
import { MCP_SERVER_NAME } from "./skills.js";
import { connectorProxyUrl, connectorServerName, type ConnectorInventory } from "./connector-inventory.js";

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
// Whole-server globs (the only glob shape the CLI matcher honors). Deny rules
// take precedence, so listing a server here never exposes its writes — the
// write ids above and the PreToolUse hook still remove them.
export const CLAUDE_AI_CONNECTOR_TOOL_PATTERNS = [
	"mcp__claude_ai_Gmail__*",
	"mcp__claude_ai_Google_Calendar__*",
	"mcp__claude_ai_Google_Drive__*",
	"mcp__claude_ai_Slack__*",
	"mcp__claude_ai_Atlassian__*",
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
const CONNECTOR_NS_SLACK = `${CONNECTOR_NS_PREFIX}Slack__`;
const CONNECTOR_NS_ATLASSIAN = `${CONNECTOR_NS_PREFIX}Atlassian__`;

// Read verbs: a connector tool whose tool segment BEGINS with one of these
// words is a non-mutating READ and stays available. Everything else on a
// connector namespace is treated as a WRITE. Matching is on WORDS, not on a
// literal `verb_` prefix, because connector servers do not share a naming
// convention — verified live against a Claude account with Slack + Atlassian
// attached:
//
//   Gmail      search_threads, get_message          (snake_case)
//   Slack      slack_read_channel, slack_search_public
//                                                   (snake_case, server-prefixed)
//   Atlassian  getJiraIssue, searchJiraIssuesUsingJql, getConfluencePage
//                                                   (camelCase)
//
// A literal-prefix test only matched the Gmail shape, so EVERY Slack and
// Atlassian tool — reads included — classified as a write and was denied at
// runtime, making those connectors unusable in a read-only session.
const CONNECTOR_READ_VERBS = new Set([
	"list", "search", "get", "read", "fetch", "find",
	"download", "describe", "query", "count", "view", "lookup", "whoami",
]);

// Mutating words. Two jobs, both on the deny side:
//
//  1. A name that begins with a read verb but also names a mutation
//     (`fetchAndLock`, `get_incident_and_acknowledge`) is a WRITE — deny wins
//     over the read exemption, so a compound name cannot earn read treatment.
//  2. A leading word that repeats the server name is NOT skipped when it is a
//     mutation word, so a connector whose SERVER is verb-shaped
//     (`Delete__delete_get_thing`) keeps its real verb.
//
// This list is deliberately broad and errs toward over-denial: a read wrongly
// called a write only blocks a read, whereas the reverse runs an ungated
// mutation. It is a backstop, not the primary protection — that is the leading
// verb, which real connector tools put first (`createJiraIssue`,
// `slack_send_message`, `delete_file`). Nouns that collide with real read names
// are deliberately excluded (`comment`/`tag`/`flag`/`run`, since
// `getComment`, `searchByTag`, `getFeatureFlag`, `getWorkflowRun` are reads).
const CONNECTOR_MUTATION_WORDS = new Set([
	"create", "update", "delete", "remove", "add", "edit", "send", "post",
	"write", "upload", "publish", "schedule", "transition", "archive", "move",
	"copy", "revoke", "assign", "invite", "share", "rename", "replace", "set",
	"merge", "resolve", "lock", "unlock", "acknowledge", "ack", "book",
	"start", "stop", "terminate", "restart", "join", "leave", "star", "unstar",
	"forward", "sync", "approve", "reject", "close", "reopen", "cancel",
	"enable", "disable", "grant", "trigger", "execute", "apply", "submit",
	"pin", "unpin", "mute", "unmute", "subscribe", "unsubscribe", "follow",
	"unfollow", "clear", "purge", "reset", "rotate", "deploy", "install",
	"uninstall", "save", "store", "put", "patch", "insert", "append",
	"prepend", "duplicate", "restore", "revert", "import", "export", "upsert",
	"sign", "complete", "claim", "release", "promote", "demote", "escalate",
	"resend", "retry", "react", "vote",
]);

// Splits a tool (or server) segment into lowercase words, handling snake_case,
// camelCase, PascalCase, and acronym runs (`getHTTPResponse` → get, http,
// response). Punctuation-only input yields an empty list, which callers treat
// as unparseable → write.
function connectorNameWords(segment: string): string[] {
	return segment
		.replace(/([a-z0-9])([A-Z])/g, "$1 $2")
		.replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
		.split(/[^A-Za-z0-9]+/)
		.filter(Boolean)
		.map((word) => word.toLowerCase());
}

// Explicit known write tool names (current claude.ai connectors). Passed to the
// SDK disallowedTools so today's writes are removed from the model's context by
// exact tool id (the CLI matcher only supports exact ids or a whole-server glob).
//
// PUBLIC CONTRACT — this list and `isConnectorWriteTool` have downstream
// dependents that gate real user-facing approvals on them (vstack#892):
//
//   memsira  routes connector writes through its own gated approval flow
//   drovr    keeps its chat sidecar permanently write-`deny` and runs an
//            approved write as a separate one-shot `claude -p` scoped by
//            `--allowedTools` to exactly one connector tool (drovr#288)
//
// Both pin the actions they expose against this classification, because "the
// sidecar structurally cannot do this itself" is THIS module's claim, not
// theirs. RECLASSIFYING AN ENTRY HERE AS A READ WOULD MAKE A CONSUMER'S
// CONFIRMATION CARD BYPASSABLE. Additions are safe and expected; removals and
// read-verb reclassifications are breaking — coordinate first, see
// docs/cross-repo.md. `unit-connectors.mjs` pins the set so a change has to be
// deliberate.
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
	// Slack + Atlassian writes, taken from a live enumeration of an account with
	// both connectors attached. The PreToolUse hook already denies these by verb;
	// listing them by id also removes them from the model's context in a
	// read-only session (the CLI matcher needs exact ids). Additive only — an id
	// missing here is still denied at call time.
	`${CONNECTOR_NS_SLACK}slack_send_message`,
	`${CONNECTOR_NS_SLACK}slack_send_message_draft`,
	`${CONNECTOR_NS_SLACK}slack_schedule_message`,
	`${CONNECTOR_NS_SLACK}slack_create_canvas`,
	`${CONNECTOR_NS_SLACK}slack_update_canvas`,
	`${CONNECTOR_NS_ATLASSIAN}createJiraIssue`,
	`${CONNECTOR_NS_ATLASSIAN}editJiraIssue`,
	`${CONNECTOR_NS_ATLASSIAN}transitionJiraIssue`,
	`${CONNECTOR_NS_ATLASSIAN}addCommentToJiraIssue`,
	`${CONNECTOR_NS_ATLASSIAN}addWorklogToJiraIssue`,
	`${CONNECTOR_NS_ATLASSIAN}createIssueLink`,
	`${CONNECTOR_NS_ATLASSIAN}createConfluencePage`,
	`${CONNECTOR_NS_ATLASSIAN}updateConfluencePage`,
	`${CONNECTOR_NS_ATLASSIAN}createConfluenceFooterComment`,
	`${CONNECTOR_NS_ATLASSIAN}createConfluenceInlineComment`,
	`${CONNECTOR_NS_ATLASSIAN}createCompassComponent`,
	`${CONNECTOR_NS_ATLASSIAN}createCompassComponentRelationship`,
	`${CONNECTOR_NS_ATLASSIAN}createCompassCustomFieldDefinition`,
];

/**
 * True for a claude.ai connector tool — the CHILD's own cloud MCP servers,
 * attached to the authenticated account and reachable only from inside that
 * process (`mcp__claude_ai_<Server>__<tool>`).
 *
 * The test is the NAMESPACE, deliberately, not "does this name resolve to a Pi
 * tool". Every claude.ai connector server lives under `mcp__claude_ai_`, and
 * that is the only tool class the bridge knowingly delegates. A broader
 * "unresolvable ⇒ delegated" rule would also swallow a genuine tool-name
 * mismatch between Pi and the child, which SHOULD still surface as a loud
 * dispatcher error.
 *
 * This is the CONNECTOR test: it gates connector-only concerns (the
 * connector-call audit, write classification). For the broader "the child runs
 * this itself, never mirror it" question, use `isChildExecutedTool`.
 */
export function isConnectorTool(name: string | undefined): boolean {
	return typeof name === "string" && name.startsWith(CONNECTOR_NS_PREFIX);
}

// Claude Code built-in meta-tools the child resolves ENTIRELY in-process:
// deferred-tool discovery and MCP-resource enumeration. They surface in a
// bridge stream when connectors are enabled (CONNECTOR_DISCOVERY_TOOLS
// un-blocks the first three so deferred connector tools are discoverable), but
// they are not connector calls and Pi cannot run them. Matched EXACTLY, never
// by prefix or substring: a Pi tool that merely resembles one of these names
// is a Pi tool, and a mismatch on it must still surface as a dispatcher error.
const CHILD_INTERNAL_TOOLS = new Set(["ToolSearch", "ListMcpResources", "ReadMcpResource", "ScheduleWakeup"]);

/**
 * True for a Claude Code built-in meta-tool the child resolves in-process.
 *
 * Mirroring one into the Pi stream (vstack#980) made Pi's agent loop dispatch a
 * tool it does not have and deliver an error result for an id no MCP handler
 * ever claimed. The result queued in `pendingResults` until the reaper dropped
 * it — one "dropped 1 tool result(s) whose handler never matched (ToolSearch)"
 * warning and one phantom failed tool call per discovery, plus a spurious
 * pi-turn boundary. These calls also never enter the connector-call audit:
 * that trail records account-data access, and tool discovery is not that.
 */
export function isChildInternalTool(name: string | undefined): boolean {
	return typeof name === "string" && CHILD_INTERNAL_TOOLS.has(name);
}

/**
 * True for a tool that the `claude` CHILD executes itself, so Pi must never be
 * asked to dispatch it.
 *
 * WHY THIS EXISTS. Every other tool the model calls in a bridge turn is a PI
 * tool: Pi hands its tool set to the bridge, the bridge re-offers it to the
 * child through the in-process MCP server, and a `tool_use` coming back is the
 * child asking PI to run something. The bridge is built around that direction —
 * it mirrors the call into the Pi stream, ends the Pi turn with `toolUse`, and
 * the MCP handler blocks until Pi delivers the result.
 *
 * Two tool classes run the other way, and both must stay un-mirrored:
 *
 * 1. claude.ai connectors (`isConnectorTool`). Pi has never heard of them.
 *    Mirroring one made Pi's agent loop look the name up in `context.tools`,
 *    miss, and write a synthetic `Tool <name> not found` error result into the
 *    transcript — while the child went on and executed the real call. The Pi
 *    transcript then RECORDED A FAILURE FOR A CALL THAT SUCCEEDED, next to an
 *    answer built from the real payload, so the model's correct answer read as
 *    a fabrication (drovr#311, memsira#320). The false result is also projected
 *    back into the child's session on a rebuild (`syncSharedSession`), which is
 *    how a lie in a mirror becomes a lie in the conversation of record.
 *
 * 2. Claude Code's own in-process meta-tools (`isChildInternalTool`), which the
 *    child resolves without any dispatcher at all (vstack#980).
 *
 * Takes the RAW SDK tool name, before `mapToolName` — child-executed names have
 * no Pi-side counterpart, so mapping them is meaningless. Accepts a missing
 * name rather than asserting one: this decides whether Pi is allowed to
 * dispatch a block, and a nameless block is neither a connector nor a child
 * built-in, so it answers `false`.
 */
export function isChildExecutedTool(name: string | undefined): boolean {
	return isConnectorTool(name) || isChildInternalTool(name);
}

// Classify a connector tool name as a WRITE (mutating) tool. FAIL CLOSED, twice:
//
//  1. Namespace: the whole `mcp__claude_ai_<Server>__` space counts, not just the
//     known Gmail/Calendar/Drive trio. Connectors attach account-wide, so ANY
//     other connector on the account (Slack, Atlassian, Figma, org-custom) shows
//     up in a bridge session — and the connector path deliberately omits
//     `tools: []` (see toolIsolationForQuery), so those tools are discoverable
//     and callable. Keying on the trio meant e.g. a Slack send_message ran
//     ungated inside claude, invisible to Pi's ConsentGate.
//  2. Verb: a tool on that space is a write UNLESS its tool segment BEGINS with a
//     known read verb, so not-yet-known write tools (e.g. Gmail send_message,
//     Drive delete_file, Calendar add_attendee) are blocked in a read-only
//     session. A name under the connector prefix with no parseable `__<tool>`
//     segment is also a write: it is a connector by construction, so deny wins.
//     The verb is matched as a WORD across snake_case and camelCase, and a
//     leading word that merely repeats the server name is skipped first
//     (`Slack__slack_read_channel` reads as `read channel`), because connector
//     servers name their tools differently from one another.
//
// Non-connector tools (Pi custom-tools, ToolSearch, MCP-resource tools, other MCP
// servers) are never connector writes → false. Used by connectorWriteDenyHook and
// by callers (e.g. the one-shot write executor) that enumerate live connector tools.
export function isConnectorWriteTool(name: string): boolean {
	if (!isConnectorTool(name)) return false;
	// First `__` after the prefix ends the server segment. First (not last) so a
	// server name containing `__` leaves the extra segment in `tool`, which then
	// fails the read-prefix test — ambiguity resolves to write.
	const sep = name.indexOf("__", CONNECTOR_NS_PREFIX.length);
	// No separator (sep < 0) OR an EMPTY server segment (sep at the prefix, e.g.
	// `mcp__claude_ai___search_messages`) means the name doesn't parse as
	// <server>__<tool> — it never earns the read-prefix exemption.
	if (sep <= CONNECTOR_NS_PREFIX.length) return true;
	const server = name.slice(CONNECTOR_NS_PREFIX.length, sep);
	const words = connectorNameWords(name.slice(sep + "__".length));
	// Skip a leading run of words that just repeats the server name, so a
	// server-prefixed tool (`Slack__slack_read_channel`) is judged on its real
	// verb. Only an exact leading match is skipped — an unrelated first word
	// (`Weird__Server__list_things`) stays and fails the read test. A mutation
	// word is never skipped, so a verb-shaped server name
	// (`Delete__delete_get_thing`, `Sync__sync_get_status`) cannot launder its
	// own tool's verb away.
	const serverWords = connectorNameWords(server);
	let skipped = 0;
	while (
		skipped < serverWords.length
		&& words[skipped] === serverWords[skipped]
		&& !CONNECTOR_MUTATION_WORDS.has(words[skipped])
	) skipped++;
	const rest = words.slice(skipped);
	// Nothing parseable left (empty/punctuation-only tool segment, or a tool
	// named exactly after its server) → write.
	if (rest.length === 0) return true;
	if (!CONNECTOR_READ_VERBS.has(rest[0])) return true;
	// Begins as a read but also names a mutation → deny wins.
	return rest.some((word) => CONNECTOR_MUTATION_WORDS.has(word));
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
			// A non-string tool name cannot be classified, and this hook fails
			// CLOSED: deny it rather than let an unclassifiable call proceed.
			// (Before isConnectorTool tolerated non-strings, `startsWith` threw
			// here and the catch denied — this keeps that contract explicit.)
			if (typeof input.tool_name !== "string") return connectorWriteDenyOutput("<unknown>");
			if (!isConnectorWriteTool(input.tool_name)) return { continue: true };
			return connectorWriteDenyOutput(input.tool_name);
		} catch {
			const toolName = typeof (input as { tool_name?: unknown })?.tool_name === "string"
				? (input as { tool_name: string }).tool_name
				: "<unknown>";
			return connectorWriteDenyOutput(toolName);
		}
	};
}

// The deny reason is handed verbatim to the `claude` child's model, so it must
// stay PRODUCT-NEUTRAL: this is shared source and every consuming app shows it.
// Naming one host told a different app's model to use a product it has never
// heard of, which is confusing at exactly the moment someone is debugging a
// refused write (vstack#892). Each host describes its own approval flow in its
// own prompt; this string only has to say that one exists.
function connectorWriteDenyOutput(toolName: string) {
	return {
		hookSpecificOutput: {
			hookEventName: "PreToolUse" as const,
			permissionDecision: "deny" as const,
			permissionDecisionReason:
				`Connector write tool "${toolName}" is blocked in read-only connector mode. ` +
				`Connector writes must go through the host application's gated approval flow.`,
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

/**
 * Explicit `mcpServers` declarations for the account's CONNECTED connectors.
 *
 * Why this exists (vstack#832): claude.ai connectors load async and non-blocking,
 * and the turn-1 tool manifest is built at +410-665ms — roughly 300ms BEFORE the
 * CLI has even fetched the connector list. The model therefore composes its first
 * answer against a manifest containing no connectors and says it has no access,
 * while the connector attaches ~1s later and is never asked. Measured end to end
 * on 40 cold sidecars (memsira, 2026-07-26): a connector tool call happened in
 * 7/20 baseline runs versus 20/20 with the declaration, and "I don't have access"
 * went 13/20 → 0/20, one-sided Fisher exact p = 6.4e-6. Confirmed at seven
 * declarations over a further 30 runs: 5/10 → 10/10 calls, 5/10 → 0/10 denials.
 *
 * It is also FASTER, which is the opposite of what the startup barrier suggests.
 * The barrier is real but small and sub-linear — manifest build 490ms none /
 * 1996ms one / 2574ms seven, so seven costs +578ms over one, not 7x. Meanwhile
 * first token drops from a 9840ms median (worst 35.7s) to 6887ms (worst 7.8s),
 * because declaring removes the model's speculative ToolSearch and dead ends.
 * The barrier buys back more than it spends.
 *
 * `alwaysLoad` is the mechanism: it blocks startup until the server is connected
 * (5s cap) precisely "since the tools must be present when the turn-1 prompt is
 * built". It is a field on the server config, so the connector has to be a server
 * WE declare — the CLI's own loader never applies it.
 *
 * Two things here are load-bearing and were established by measurement, not
 * inference:
 *
 * 1. The key MUST be the CLI's own server name (`connectorServerName`). The key
 *    is the tool namespace, so any other key yields the connector twice under two
 *    namespaces. Consumers that pin fully-qualified tool names rather than
 *    globbing a namespace then break.
 * 2. Only `installState === "connected"` connectors are declared. The rest are
 *    never attempted by the CLI either, and declaring them would mean asking
 *    `alwaysLoad` to block startup on servers that cannot connect.
 *
 * Deliberately NOT typed against the SDK's `McpServerConfig`: that exported union
 * omits the `claudeai-proxy` variant entirely, and its `McpClaudeAIProxyServerConfig`
 * has no `alwaysLoad` field — while the runtime zod schema in the shipped CLI does.
 * Typings and runtime disagree; the runtime honours `alwaysLoad` (verified live),
 * so this builds the object the runtime accepts and casts once, here, with the
 * reason recorded rather than spread across call sites.
 */
export function connectorMcpServers(inventory: ConnectorInventory): Record<string, unknown> {
	if (!inventory.ok) return {};
	// Escape hatch. `alwaysLoad` holds startup until each declared server
	// connects, and the bound on that wait is NOT established: the SDK doc
	// comment says a 5s cap while the CLI logs `timeout of 30000ms`, and four
	// attempts to force a genuine mid-handshake hang each failed fast for a
	// different reason, so the worst case was never observed. An account with
	// slow or numerous connectors therefore has an unquantified turn-1 delay,
	// and this switch turns declarations off without giving up connectors.
	if (connectorDeclarationsDisabled()) return {};
	const servers: Record<string, unknown> = {};
	for (const entry of inventory.connectors) {
		if (entry.installState !== "connected") continue;
		if (!entry.installedServerId) continue;
		servers[connectorServerName(entry.name)] = {
			type: "claudeai-proxy",
			url: connectorProxyUrl(entry.installedServerId),
			id: entry.installedServerId,
			alwaysLoad: true,
		};
	}
	return servers;
}


/**
 * `CLAUDE_BRIDGE_CONNECTOR_DECLARE=off` (or `0`/`false`/`no`) disables explicit
 * connector declarations while leaving connectors themselves enabled. Falls back
 * to the pre-#832 behaviour: connectors still load, they just race the turn-1
 * manifest again.
 */
export function connectorDeclarationsDisabled(env: NodeJS.ProcessEnv = process.env): boolean {
	const v = (env.CLAUDE_BRIDGE_CONNECTOR_DECLARE ?? "").trim().toLowerCase();
	return v === "off" || v === "0" || v === "false" || v === "no";
}
