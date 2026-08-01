import { type AssistantMessage, type AssistantMessageEventStream, type Context, type Model, type SimpleStreamOptions, type Tool } from "@earendil-works/pi-ai";
import * as piAi from "@earendil-works/pi-ai";
import { type ExtensionAPI, type ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { createSdkMcpServer, query, type EffortLevel, type SDKMessage, type SDKUserMessage, type SettingSource } from "@anthropic-ai/claude-agent-sdk";
import type { Base64ImageSource, ContentBlockParam, MessageParam } from "@anthropic-ai/sdk/resources";
import { PROVIDER_ID, messageContentToText } from "./convert.js";
import { buildModels, fallbackModelForPrimaryModel, modelDisplayName } from "./models.js";
import { MCP_SERVER_NAME, MCP_TOOL_PREFIX, extractSkillsBlock } from "./skills.js";
import { extractAllToolResults as _extractAllToolResults, type McpResult } from "./extract-tool-results.js";
import { QueryContext, ctx, drainPendingToolCalls, stackDepth, pushContext, toolCallDrainCause } from "./query-state.js";
import { teardownQuery } from "./query-teardown.js";
import { loadConfig, normalizeEffortLevel, recordProjectTrust, registerExternalConfigResolver, type Config } from "./config.js";
import { hasClaudeCredentials } from "./auth-presence.js";
import { NATIVE_PROVIDER_UNSUPPORTED_MESSAGE, buildNativeProvider, supportsNativeProvider } from "./native-provider.js";
import { extractAgentsAppend } from "./agents-md.js";
import { buildPromptContextAppend } from "./prompt-context.js";
import { jsonSchemaToZodShape } from "./typebox-to-zod.js";
import { readFileSync as nodeReadFileSync } from "node:fs";
import { resolveGetModels } from "./pi-ai-compat.js";
import { listAccountConnectors, resolveClaudeOAuth } from "./connector-inventory.js";
// Re-exported from the extension entry point ON PURPOSE. Consuming apps
// regenerate their vendored package.json with a CLOSED exports map
// ({".": "./bundle/index.js"}), which makes Node reject BOTH a subpath import
// and a deep path into the package (ERR_PACKAGE_PATH_NOT_EXPORTED) — verified.
// So the ./connector-inventory entry point alone does not reach them. Naming
// these here puts them in bundle/index.js's own export list, which is the one
// path their existing manifest already allows, and incidentally keeps esbuild
// from tree-shaking helpers index.ts never calls itself.
export {
	connectorProxyUrl,
	connectorServerName,
	connectorServerNamespace,
	connectorsListUrl,
	credentialCandidatePaths,
	listAccountConnectors,
	resolveClaudeOAuth,
	type ClaudeOAuthCredentials,
	type ConnectorEntry,
	type ConnectorInventory,
} from "./connector-inventory.js";
export { connectorCachePath, connectorCacheScopeKey, readCachedConnectors, writeCachedConnectors } from "./connector-cache.js";
import { debug, diagDump, makeCliDebugOptions, moduleInstanceId } from "./debug.js";
import { preflightClaudeExecutable, resolveClaudeExecutable, spawnClaudeCodeWithDiagnostics } from "./claude-executable.js";
import { appendIntegrityEntry, argKeys, extensionApi, piUI, reportToolResultMismatch, safeNotify, safeToolCallSummary, setExtensionApi, setPiUI, setSharedSession, sharedSession } from "./bridge-state.js";
import { connectorMcpServers, connectorQueryOptions, connectorWriteModeFor, connectorsEnabledFor, isChildExecutedTool } from "./connectors.js";
import { readCachedConnectors, writeCachedConnectors } from "./connector-cache.js";
import { restoreSharedSessionFromPi, schedulePersistSharedSession, syncSharedSession } from "./session-persistence.js";
import { STREAM_IDLE_BACKOFF_HINT_MS, activeStreamIdleWatchdogs, buildStreamIdleTimeoutErrorMessage, createStreamIdleWatchdog, formatDurationShort, streamIdleTimeoutMsFromEnv } from "./stream-idle-watchdog.js";
import { RATE_LIMIT_AUTO_RESUME_EVENT, RATE_LIMIT_TOKEN, formatAllowedRateLimitWarning, formatResetTimestamp, isExtraUsageRequiredMessage, isUsageLimitMessage, resetTimestampMs, uniqueNonEmptyLines } from "./rate-limit.js";
import { mapToolArgs } from "./tool-mapping.js";
import { ensureTurnStarted, finalizeCurrentStream, finalizeToolUseTurnFromMcpInvocation, noteChildExecutedToolResults, processAssistantMessage, processStreamEvent, scheduleToolUseTurnEnd, updateTurnOutputModel } from "./assistant-stream.js";

// Re-exports: the module decomposition must not change the bundle entry's
// public surface — unit tests and downstream consumers import these from
// bundle/index.js.
export { classifyClaudeExecutableBytes, preflightClaudeExecutable, resolveClaudeExecutable, spawnClaudeCodeWithDiagnostics, wrapClaudeSpawnErrorForSdk, type ClaudeExecutableFileType, type ClaudeExecutablePreflightResult } from "./claude-executable.js";
export { __testGetBridgeIntegrityState, __testSetBridgeIntegrityState, INTEGRITY_CUSTOM_TYPE, appendIntegrityEntry, reportToolResultMismatch } from "./bridge-state.js";
export { CONNECTOR_CALL_CUSTOM_TYPE, connectorResultByteSize, flushConnectorCallAudit, recordConnectorCallResult, setConnectorCallAuditSink, type ConnectorCallAuditData, type ConnectorCallAuditSink, type ConnectorCallOutcome } from "./connector-audit.js";
export { CLAUDE_AI_CONNECTOR_TOOL_PATTERNS, connectorMcpServers, connectorDeclarationsDisabled, CLAUDE_BRIDGE_TOOL_ISOLATION, CONNECTOR_DISCOVERY_TOOLS, CONNECTOR_WRITE_TOOLS, DISALLOWED_BUILTIN_TOOLS, connectorQueryOptions, connectorWriteDenyHook, connectorWriteModeFor, connectorWriteModeFromEnv, connectorsEnabledFor, connectorsEnabledFromEnv, isChildExecutedTool, isChildInternalTool, isConnectorTool, isConnectorWriteTool, toolIsolationForQuery } from "./connectors.js";
export { restoreSharedSessionFromPi, shouldRestorePersistedBridgeEntry } from "./session-persistence.js";
export { NATIVE_PROVIDER_UNSUPPORTED_MESSAGE, buildNativeProvider, claudeAuthSourceLabel, supportsNativeProvider } from "./native-provider.js";
export { DEFAULT_STREAM_IDLE_TIMEOUT_MS, STREAM_IDLE_BACKOFF_HINT_MS, STREAM_IDLE_TIMEOUT_ENV, buildStreamIdleTimeoutErrorMessage, createStreamIdleWatchdog, streamIdleTimeoutMsFromEnv, type StreamIdleTimeoutInfo, type StreamIdleWatchdog, type StreamIdleWatchdogState } from "./stream-idle-watchdog.js";
export { ALLOWED_RATE_LIMIT_WARNING_UTILIZATION_THRESHOLD, formatAllowedRateLimitWarning, formatResetTimestamp, isExtraUsageRequiredMessage, isUsageLimitMessage, normalizeRateLimitUtilization, resetTimestampMs, uniqueNonEmptyLines } from "./rate-limit.js";
export { mapToolName } from "./tool-mapping.js";
export { cancelScheduledToolUseEnd, endToolUseTurn, finalizeToolUseTurnFromMcpInvocation, noteChildExecutedToolResults, processAssistantMessage, processStreamEvent, reapStaleQueuedResults, scheduleToolUseTurnEnd } from "./assistant-stream.js";

// Compat (#2): use factory if available (pi-ai ≥0.66), else fall back to constructor (gsd-pi etc.)
const _piAi = piAi as any;
const getModels = await resolveGetModels(_piAi) as (provider: string) => Array<Model<any>>;
const newAssistantMessageEventStream: () => AssistantMessageEventStream =
	typeof _piAi.createAssistantMessageEventStream === "function"
		? _piAi.createAssistantMessageEventStream
		: () => new _piAi.AssistantMessageEventStream();

// --- Constants ---

// Two process-global tokens govern provider registration across module reloads.
// Extensions like pi-subagents spawn a subagent that loads THIS module again as
// a fresh (non-primary) instance. Two failure modes must be prevented:
//   (1) a subagent's registerProvider() overwriting the parent's `streamSimple`
//       in the shared ModelRegistry — the parent would then deliver tool results
//       through the subagent's empty-state streamSimple and break tool pairing;
//   (2) a subagent STEALING registration ownership: if the parent loaded
//       uncredentialed and the user logged in mid-session, a later subagent load
//       would see credentialed + no-owner and claim ownership + register ITS
//       streamSimple, split-braining the shared session/ctx.
//
// PRIMARY_INSTANCE_KEY — claimed UNCONDITIONALLY (regardless of credentials) by
// the first-loaded module instance. ONLY the primary instance may ever
// register, unregister, or claim the stream guard. Non-primary instances
// (subagents) always no-op. This is the authority token; it closes (2).
//
// ACTIVE_STREAM_SIMPLE_KEY — holds the registered instance's `streamSimple`.
// Only the primary claims it, and only while a registration is live. It doubles
// as the "already registered" flag (guard === our streamSimple) and the routing
// target for reentrant subagent calls; it closes (1).
//
// Both are released on session_shutdown (incl. /reload) by releaseProviderTokens
// so the next module load starts clean. See applyProviderRegistration for the
// native (pi >=0.81) upsert flow.
const PRIMARY_INSTANCE_KEY = Symbol.for("claude-bridge:primaryInstance");
const ACTIVE_STREAM_SIMPLE_KEY = Symbol.for("claude-bridge:activeStreamSimple");
const COMMANDS_REGISTERED_KEY = Symbol.for("claude-bridge:commandsRegistered");

// MODELS is buildModels(getModels("anthropic")) — projection kept in models.js.
const MODELS = buildModels(getModels("anthropic"));

let extraUsageHelperInFlight: Promise<string> | null = null;

function emitRateLimitEvent(payload: Record<string, unknown>): void {
	try {
		extensionApi?.events?.emit?.(RATE_LIMIT_AUTO_RESUME_EVENT, payload);
	} catch {
		// Cross-extension broker is best-effort only.
	}
}

function extraUsageAllowed(config: Config): boolean {
	return config.provider?.allowExtraUsage === true;
}

// The fastMode setting silently no-ops when Claude Code declines fast mode.
// Surface the typed fast_mode_disabled_reason (SDK 0.3.219+) once per distinct
// reason so an enabled-but-inert setting explains itself instead of looking
// broken. Module-level dedup: the same reason repeats on every init message.
let lastFastModeDisabledNoticeReason: string | null = null;

const FAST_MODE_DISABLED_REASON_TEXT: Record<string, string> = {
	disabled_by_env: "disabled by an environment variable",
	extra_usage_disabled: "extra usage is disabled for this account",
	free: "not available on the free plan",
	model_not_allowed: "not available for this model",
	network_error: "the eligibility check hit a network error",
	not_first_party: "not available for this account type",
	preference: "disabled by a Claude Code preference",
	sdk_opt_in_required: "the SDK opt-in is missing",
	unknown: "unavailable for an unknown reason",
};

function noteFastModeDisabledReason(message: unknown, bridgeConfig: Config): void {
	if (bridgeConfig.provider?.fastMode !== true) return;
	const reason = (message as { fast_mode_disabled_reason?: unknown }).fast_mode_disabled_reason;
	// "pending" means the CLI is still deciding — not a verdict worth announcing.
	if (typeof reason !== "string" || reason === "pending") return;
	if (reason === lastFastModeDisabledNoticeReason) return;
	lastFastModeDisabledNoticeReason = reason;
	const text = FAST_MODE_DISABLED_REASON_TEXT[reason] ?? `unavailable (${reason})`;
	safeNotify(`Claude bridge: fast mode is enabled in settings but Claude Code declined it — ${text}.`, "warning");
}

function sdkTextFromMessage(message: SDKMessage): string | undefined {
	if (message.type === "result") return (message as any).result;
	if (message.type === "assistant") {
		const content = (message as any).message?.content;
		if (!Array.isArray(content)) return undefined;
		return content
			.map((block) => block?.type === "text" && typeof block.text === "string" ? block.text : "")
			.filter(Boolean)
			.join("\n");
	}
	return undefined;
}

async function runExtraUsageHelper(cwd: string, config = loadConfig(cwd)): Promise<string> {
	const providerSettings = config.provider ?? {};
	const claudeExecutable = resolveClaudeExecutable(providerSettings.pathToClaudeCodeExecutable);
	if (claudeExecutable) preflightClaudeExecutable(claudeExecutable, cwd);

	const helperQuery = query({
		prompt: "/extra-usage",
		options: {
			cwd,
			env: { ...process.env, ENABLE_CLAUDEAI_MCP_SERVERS: "0", DISABLE_AUTO_COMPACT: "1" },
			maxTurns: 1,
			...(claudeExecutable ? { pathToClaudeCodeExecutable: claudeExecutable } : {}),
			spawnClaudeCodeProcess: spawnClaudeCodeWithDiagnostics,
			...makeCliDebugOptions("extra-usage"),
		},
	});
	const outputs: string[] = [];
	try {
		for await (const message of helperQuery) {
			const text = sdkTextFromMessage(message)?.trim();
			if (text && outputs[outputs.length - 1] !== text) outputs.push(text);
		}
	} finally {
		helperQuery.close();
	}
	return outputs.join("\n").trim() || "Claude Code /extra-usage completed.";
}

function launchExtraUsageHelperIfAllowed(cwd: string, config: Config, reason: string): boolean {
	if (!extraUsageAllowed(config)) return false;
	if (extraUsageHelperInFlight) return true;
	extraUsageHelperInFlight = runExtraUsageHelper(cwd, config)
		.then((message) => {
			piUI?.notify(`Claude extra usage helper: ${message}`, "info");
			return message;
		})
		.catch((error) => {
			const message = error instanceof Error ? error.message : String(error);
			piUI?.notify(`Claude extra usage helper failed after ${reason}: ${message}`, "error");
			throw error;
		})
		.finally(() => { extraUsageHelperInFlight = null; });
	void extraUsageHelperInFlight.catch(() => {});
	return true;
}

// Pi doesn't pass tool results directly — it appends them to the context and calls
// the provider again. Thin wrapper over extract-tool-results.js that adds per-turn
// debug logging at the extraction boundary.
function extractAllToolResults(context: Context): McpResult[] {
	const { results, stopIdx } = _extractAllToolResults(context.messages as unknown as Array<{ role: string; [key: string]: unknown }>);
	debug(`extractAllToolResults: ${results.length} results from ${context.messages.length} msgs, stopped at index ${stopIdx}`);
	debug(`extractAllToolResults: all msg roles:`, context.messages.map((m, i) => `[${i}]${m.role}`).join(" "));
	for (let r = 0; r < results.length; r++) {
		debug(`extractAllToolResults: result[${r}] id=${results[r].toolCallId}${results[r].isError ? " ERROR" : ""} preview:`, JSON.stringify(results[r].content).slice(0, 150));
	}
	return results;
}

/** Extract the last user message from context as a prompt string. Returns null if last message is not a user message. */
function extractUserPrompt(messages: Context["messages"]): string | null {
	const last = messages[messages.length - 1];
	if (!last || last.role !== "user") return null;
	if (typeof last.content === "string") return last.content;
	return messageContentToText(last.content) || "";
}

/** Extract the last user message as ContentBlockParam[] (preserving images).
 *  Returns null if no images — caller should fall back to string prompt. */
function extractUserPromptBlocks(messages: Context["messages"]): ContentBlockParam[] | null {
	const last = messages[messages.length - 1];
	if (!last || last.role !== "user") return null;
	if (typeof last.content === "string") {
		debug(`extractUserPromptBlocks: content is string (length=${last.content.length})`);
		return null;
	}
	if (!Array.isArray(last.content)) {
		debug(`extractUserPromptBlocks: content is ${typeof last.content}`);
		return null;
	}
	debug(`extractUserPromptBlocks: ${last.content.length} blocks, types=${last.content.map((b: any) => b.type).join(",")}`);
	let hasImage = false;
	const blocks: ContentBlockParam[] = [];
	for (const block of last.content) {
		if (block.type === "text" && block.text) {
			blocks.push({ type: "text", text: block.text });
		} else if (block.type === "image") {
			debug(`image block: mimeType=${(block as any).mimeType}, data length=${((block as any).data ?? "").length}, keys=${Object.keys(block).join(",")}`);
			if (!(block as any).data || !(block as any).mimeType) {
				debug(`image block missing data or mimeType, skipping`);
				continue;
			}
			hasImage = true;
			blocks.push({
				type: "image",
				source: { type: "base64", media_type: block.mimeType as Base64ImageSource["media_type"], data: block.data },
			});
		}
	}
	return hasImage ? blocks : null;
}

async function* wrapPromptStream(blocks: ContentBlockParam[]): AsyncIterable<SDKUserMessage> {
	yield {
		type: "user",
		message: { role: "user", content: blocks } as MessageParam,
		parent_tool_use_id: null,
	};
}

// --- Provider helpers: tool resolution ---

// --- Provider helpers: tool bridge ---

// --- Query state ---
// QueryContext + context stack live in query-state.js so tests can import
// them without activating the extension. `ctx()`, `pushContext()`, `popContext()`
// are imported at the top of this file.

export function resolveMcpTools(context: Context, excludeToolName?: string): {
	mcpTools: Tool[];
	customToolNameToSdk: Map<string, string>;
	customToolNameToPi: Map<string, string>;
} {
	const mcpTools: Tool[] = [];
	const customToolNameToSdk = new Map<string, string>();
	const customToolNameToPi = new Map<string, string>();

	if (!context.tools) return { mcpTools, customToolNameToSdk, customToolNameToPi };

	for (const tool of context.tools) {
		if (tool.name === excludeToolName) continue;
		// Never re-offer a tool the child owns natively. The claude.ai connector
		// namespace belongs to the child's own MCP servers, so a Pi tool sitting
		// on it would be advertised a SECOND time under our prefix — two names
		// for one capability, and the model picking the wrong one gets a real
		// `Tool ... not found` from the dispatcher (memsira#320). It would also
		// be uncallable in any case: a `tool_use` under that namespace is treated
		// as child-executed and never handed to Pi (isChildExecutedTool), so
		// filtering here is what makes the two halves agree end to end.
		if (isChildExecutedTool(tool.name)) {
			debug(`resolveMcpTools: not re-offering child-native tool ${tool.name}`);
			continue;
		}
		const sdkName = `${MCP_TOOL_PREFIX}${tool.name}`;
		mcpTools.push(tool);
		// Case-insensitive aliases mean two tools differing only by case would
		// silently overwrite each other's mapping — surface it if it ever happens.
		const lowerName = tool.name.toLowerCase();
		const collision = customToolNameToSdk.get(lowerName);
		if (collision !== undefined && collision !== sdkName) {
			debug(`WARNING: resolveMcpTools lowercase alias collision: ${tool.name} overwrites mapping previously held by ${collision}`);
		}
		customToolNameToSdk.set(tool.name, sdkName);
		customToolNameToSdk.set(lowerName, sdkName);
		customToolNameToPi.set(sdkName, tool.name);
		customToolNameToPi.set(sdkName.toLowerCase(), tool.name);
	}

	return { mcpTools, customToolNameToSdk, customToolNameToPi };
}

// finalizeToolUseTurnFromMcpInvocation moved to assistant-stream.ts: it is now
// the grace-timer ACTION armed by scheduleToolUseTurnEnd rather than an
// immediate end. The CLI invokes MCP handlers before message_delta arrives on
// every tool-use turn, and message_delta is what carries the real output-token
// count — ending the pi stream at handler invocation is what froze pi's
// per-turn output figures at the message_start placeholders (1–7 tokens).

// Creates an MCP server that bridges pi tools to the SDK. Each tool handler
// blocks on a Promise until pi delivers the tool result via streamSimple.
// Handlers claim their tool_call id by matching the actual MCP call
// (tool name + arguments) against the recorded tool_use blocks, then results
// are matched by ID. Handlers close over the captured `queryCtx`, ensuring they
// operate on the correct query's state even across pushContext/popContext calls.
function buildMcpServers(tools: Tool[], queryCtx: QueryContext): Record<string, ReturnType<typeof createSdkMcpServer>> | undefined {
	if (!tools.length) return undefined;
	const mcpTools = tools.map((tool) => ({
		name: tool.name,
		description: tool.description,
		inputSchema: jsonSchemaToZodShape(tool.parameters),
		handler: async (args?: Record<string, unknown>) => {
			const mappedArgs = mapToolArgs(tool.name, args);
			const claim = queryCtx.claimToolCall(tool.name, mappedArgs);
			const toolCallId = claim.toolCallId;
			if (!toolCallId) {
				debug(`WARNING: mcp handler ${tool.name} has no toolCallId (available=${claim.available})`);
				diagDump("tool_handler_unmatched", {
					toolName: tool.name,
					argKeys: argKeys(mappedArgs),
					available: claim.available,
					turnToolCallIds: queryCtx.turnToolCallIds,
					turnToolCalls: safeToolCallSummary(queryCtx.turnToolCalls),
				});
				appendIntegrityEntry("tool_handler_unmatched", {
					toolName: tool.name,
					argKeys: argKeys(mappedArgs),
					available: claim.available,
					turnToolCallIds: queryCtx.turnToolCallIds,
				});
				return { content: [{ type: "text", text: `Claude bridge internal error: no matching tool_call id for ${tool.name}` }], isError: true } satisfies McpResult;
			}
			if (claim.argsMismatch) {
				// Claimed anyway (sole same-name candidate) — record the divergence so
				// a schema/validator drift stays visible without stranding the call.
				debug(`mcp handler: ${tool.name} [${toolCallId}] claimed sole same-name call despite args mismatch`);
				diagDump("tool_claim_args_mismatch", {
					toolName: tool.name,
					toolCallId,
					handlerArgKeys: argKeys(mappedArgs),
					recordedArgKeys: argKeys(queryCtx.turnToolCalls.find((call) => call.id === toolCallId)?.arguments),
				});
			} else if (claim.match !== "tool-args" || claim.ambiguous) {
				debug(`mcp handler: ${tool.name} [${toolCallId}] claimed by ${claim.match}${claim.ambiguous ? " (ambiguous)" : ""}`);
			}
			if (toolCallId && queryCtx.pendingResults.has(toolCallId)) {
				const result = queryCtx.pendingResults.get(toolCallId)!;
				queryCtx.pendingResults.delete(toolCallId);
				queryCtx.markToolResultResolved(toolCallId);
				debug(`mcp handler: ${tool.name} [${toolCallId}] → resolved from queue (${queryCtx.pendingResults.size} remaining)`);
				return result;
			}
			debug(`mcp handler: ${tool.name} [${toolCallId}] → waiting`);
			// Don't end the pi turn here — message_delta (real output tokens) and
			// message_stop are normally milliseconds behind this invocation. Arm the
			// grace timer instead; it force-finalizes only if they never arrive.
			scheduleToolUseTurnEnd(
				queryCtx,
				() => finalizeToolUseTurnFromMcpInvocation(queryCtx, toolCallId, tool.name, mappedArgs),
				`mcp-invocation:${tool.name}`,
			);
			return new Promise<McpResult>((resolve) => {
				queryCtx.pendingToolCalls.set(toolCallId, {
					toolName: tool.name,
					resolve: (result) => {
						queryCtx.markToolResultResolved(toolCallId);
						resolve(result);
					},
				});
			});
		},
	}));
	const server = createSdkMcpServer({ name: MCP_SERVER_NAME, version: "1.0.0", tools: mcpTools });
	return { [MCP_SERVER_NAME]: server };
}

// --- Effort level mapping ---
// Pi reasoning levels → CC SDK effort levels

const REASONING_TO_EFFORT: Record<string, EffortLevel> = {
	minimal: "low", low: "low", medium: "medium", high: "high", xhigh: "max", max: "max",
};

function normalizeEffortOverrideModelKey(value: string): string {
	const key = value.trim().toLowerCase();
	return key.startsWith(`${PROVIDER_ID}/`) ? key.slice(PROVIDER_ID.length + 1) : key;
}

export function resolveConfiguredEffort(
	modelId: string,
	reasoningEffort: EffortLevel | undefined,
	providerConfig?: Config["provider"],
): EffortLevel | undefined {
	const target = normalizeEffortOverrideModelKey(modelId);
	for (const [key, rawEffort] of Object.entries(providerConfig?.modelEffortOverrides ?? {})) {
		const normalizedKey = normalizeEffortOverrideModelKey(key);
		if (normalizedKey !== "*" && normalizedKey !== target) continue;
		const effort = normalizeEffortLevel(rawEffort) as EffortLevel | undefined;
		if (effort) return effort;
	}
	return (normalizeEffortLevel(providerConfig?.forceEffort) as EffortLevel | undefined) ?? reasoningEffort;
}

// --- Provider: streaming function ---
//
// Push-based streaming with MCP tool bridge:
// 1. streamSimple starts a query() and kicks off consumeQuery() in background
// 2. consumeQuery() iterates the SDK generator, pushing events to currentPiStream
// 3. On tool_use: ends the current pi stream, nulls it out. The MCP handler
//    blocks the generator naturally — no events arrive until resolved.
// 4. Pi executes the tool, calls streamSimple again. We swap in the new stream,
//    resolve the MCP handler, and the generator unblocks — events flow to new stream.
//
// Note: resetTurnState clears turnSawStreamEvent while the generator may still
// have queued messages from the previous turn. This is safe because step 3 nulls
// currentPiStream, so any leftover messages hit the `!ctx().currentPiStream` guard
// in consumeQuery and are skipped before resetTurnState runs.

/** Background consumer: iterates the SDK generator, pushing events to currentPiStream.
 *  Runs until the query ends. Per turn, the SDK yields stream_events (deltas), then
 *  an assistant message (completed blocks). On tool_use, the stream is ended by
 *  whichever path handles it first (processStreamEvent or processAssistantMessage),
 *  and the MCP handler blocks the generator until pi delivers the tool result. */
async function consumeQuery(
	sdkQuery: ReturnType<typeof query>,
	customToolNameToPi: Map<string, string>,
	model: Model<any>,
	cwd: string,
	bridgeConfig: Config,
	wasAborted: () => boolean,
): Promise<{ capturedSessionId?: string }> {
	let capturedSessionId: string | undefined;

	for await (const message of sdkQuery) {
		if (wasAborted()) break;
		const queryCtx = ctx();
		activeStreamIdleWatchdogs.get(queryCtx)?.noteChunk();
		if (!queryCtx.turnOutput) continue;
		if (!queryCtx.currentPiStream && !(message.type === "assistant" && queryCtx.turnSawToolCall)) continue;

		switch (message.type) {
			case "stream_event":
				processStreamEvent(message, customToolNameToPi, model);
				break;
			case "assistant":
				processAssistantMessage(message, model, customToolNameToPi);
				break;
			case "result":
				if (!ctx().turnSawStreamEvent && message.subtype === "success") {
					const text = message.result || "";
					// The no-stream-events assistant fallback may have already rendered
					// this exact text (it does not set turnSawStreamEvent) — re-pushing
					// it here is the other half of the duplicated-output bug.
					if (ctx().turnBlocks.some((b: any) => b.type === "text" && b.text === text)) {
						debug("consumeQuery: result text already rendered by assistant fallback; skipping duplicate");
						break;
					}
					ensureTurnStarted();
					ctx().turnBlocks.push({ type: "text", text });
					const idx = ctx().turnBlocks.length - 1;
					ctx().currentPiStream?.push({ type: "text_start", contentIndex: idx, partial: ctx().turnOutput });
					ctx().currentPiStream?.push({ type: "text_delta", contentIndex: idx, delta: text, partial: ctx().turnOutput });
					ctx().currentPiStream?.push({ type: "text_end", contentIndex: idx, content: text, partial: ctx().turnOutput });
				} else if (message.subtype !== "success" && (isExtraUsageRequiredMessage(message) || isUsageLimitMessage(message))) {
					// isUsageLimitMessage matches the CLI's own usage-limit copy (SDK
					// USAGE_LIMIT_ERROR_PREFIXES) — e.g. a plain "You've hit your weekly
					// limit" that the extra-usage regex never matched, so those turns
					// used to end as a silent empty success. The /extra-usage helper and
					// its hints stay gated on the narrow extra-usage test.
					const errorLines = Array.isArray((message as any).errors) ? uniqueNonEmptyLines((message as any).errors) : [];
					const errors = errorLines.length > 0 ? errorLines.join("\n") : String(message.subtype ?? "Claude Code rate limit");
					const extraUsage = isExtraUsageRequiredMessage(message);
					const openedExtraUsage = extraUsage && launchExtraUsageHelperIfAllowed(cwd, bridgeConfig, "result error");
					ctx().handledTerminalError = true;
					ctx().turnOutput.stopReason = "error";
					const extraUsageHint = openedExtraUsage
						? "\n\nOpened Claude Code /extra-usage helper. Complete billing/admin flow in the browser, then retry the prompt."
						: extraUsage
							? "\n\nRun /claude-bridge:extra, or enable Allow extra usage helper in settings."
							: "";
					ctx().turnOutput.errorMessage = `${errors}${extraUsageHint}`;
					ctx().currentPiStream?.push({ type: "error", reason: "error", error: ctx().turnOutput });
					ctx().currentPiStream?.end();
					ctx().currentPiStream = null;
				}
				break;
			case "system":
				if ((message as any).subtype === "init" && (message as any).session_id) {
					capturedSessionId = (message as any).session_id;
					// Also on this message's query context, so the connector-call audit
					// trail can name the child session that executed a call — including
					// from the teardown flush, which runs outside this function's scope.
					queryCtx.childSessionId = capturedSessionId;
					noteFastModeDisabledReason(message, bridgeConfig);
				} else if ((message as any).subtype === "model_refusal_fallback") {
					const originalModel = (message as any).original_model;
					const fallbackModel = (message as any).fallback_model;
					updateTurnOutputModel(fallbackModel);
					debug("consumeQuery: model_refusal_fallback", JSON.stringify({ originalModel, fallbackModel }));
					// Notify only for reroutes we configured, so an unexpected pairing from
					// Claude Code is still logged above but not announced as one of ours.
					if (typeof fallbackModel === "string" && typeof originalModel === "string" && fallbackModelForPrimaryModel(originalModel) === fallbackModel) {
						safeNotify(
							`Claude bridge switched ${modelDisplayName(originalModel)} to ${modelDisplayName(fallbackModel)} after Claude Code safety fallback.`,
							"info",
						);
					}
				}
				break;
			case "user":
				// Mostly the SDK echoing the prompt back — nothing to render. The one
				// thing worth reading is a child-executed tool's real result, which
				// arrives here and nowhere else.
				noteChildExecutedToolResults(message);
				break;
			case "rate_limit_event": {
				const info = (message as any).rate_limit_info;
				debug("consumeQuery: rate_limit_event", JSON.stringify(info).slice(0, 300));
				if (info?.status === "rejected") {
					const resetsAt = formatResetTimestamp(info.resetsAt);
					const resetAtMs = resetTimestampMs(info.resetsAt);
					const reason = `${info.rateLimitType ?? "unknown"} rate limit`;
					const launchedExtraUsage = isExtraUsageRequiredMessage(info) && launchExtraUsageHelperIfAllowed(cwd, bridgeConfig, reason);
					emitRateLimitEvent({
						model: model.id,
						provider: PROVIDER_ID,
						rateLimitType: info.rateLimitType,
						reason,
						resetAt: info.resetsAt,
						...(Number.isFinite(resetAtMs) ? { resetAtMs } : {}),
						source: "claude-bridge",
						status: "rejected",
					});
					piUI?.notify(`${RATE_LIMIT_TOKEN} Claude ${reason} hit — resets ${resetsAt}${launchedExtraUsage ? "; opened /extra-usage helper" : ""}`, "warning");
				} else if (info?.status === "allowed_warning") {
					const warning = formatAllowedRateLimitWarning(info);
					if (warning) piUI?.notify(warning, "warning");
					else debug("consumeQuery: suppressed low/ambiguous allowed_warning rate_limit_event", JSON.stringify(info).slice(0, 300));
				}
				break;
			}
			default:
				debug("consumeQuery: unhandled SDK message type", message.type);
				break;
		}
	}

	// DEBUG: trace when consumeQuery exits
	debug(`consumeQuery: for-await loop exited, wasAborted=${wasAborted()}, capturedSessionId=${capturedSessionId?.slice(0, 8) ?? "none"}`);

	return { capturedSessionId };
}

// Claim the primary-instance token for this module instance if unclaimed, and
// report whether this instance is the primary. First-loaded instance wins,
// UNCONDITIONALLY (before any credential check), so a later subagent load can
// never become primary and steal registration ownership.
function claimPrimaryInstance(): boolean {
	const g = globalThis as Record<symbol, any>;
	if (!g[PRIMARY_INSTANCE_KEY]) g[PRIMARY_INSTANCE_KEY] = streamClaudeAgentSdk;
	return g[PRIMARY_INSTANCE_KEY] === streamClaudeAgentSdk;
}

// Release both process-global tokens this instance owns. Called on
// session_shutdown (incl. /reload) so the freshly loaded instance starts clean.
// NOTE: this does NOT unregister the provider — pi's provider registry is
// process-lifetime state that survives module reload; the next loaded instance
// simply upserts its own provider object over ours (registerNativeProvider is
// replace-by-id), and logout-hiding is the provider's own auth check.
function releaseProviderTokens(event: string): void {
	const g = globalThis as Record<symbol, any>;
	if (g[ACTIVE_STREAM_SIMPLE_KEY] === streamClaudeAgentSdk) {
		debug(`${event}: clearing ACTIVE_STREAM_SIMPLE_KEY`);
		g[ACTIVE_STREAM_SIMPLE_KEY] = undefined;
	}
	if (g[PRIMARY_INSTANCE_KEY] === streamClaudeAgentSdk) {
		debug(`${event}: clearing PRIMARY_INSTANCE_KEY`);
		g[PRIMARY_INSTANCE_KEY] = undefined;
	}
}

// Native (pi >=0.81) provider registration. Run at extension load, on every
// session_start, and at pre-spawn.
//
// 2.x registers UNCONDITIONALLY (once primary): credential-driven availability
// is the provider's own auth.check/resolve reporting configured-ness, so pi
// hides/shows claude-bridge models itself — the 1.x register/unregister state
// machine (decideRegistration) is gone. What each trigger does now:
//   - load: build + register the provider (queued by the loader until bindCore).
//   - session_start: re-upsert the SAME provider object. registerNativeProvider
//     is upsert-by-id and kicks pi's model-snapshot/availability refresh, so a
//     `claude login`/logout since the last session boundary is reflected
//     deterministically — the same guarantee the 1.x re-check gave — without
//     depending on pi's own refresh cadence.
//   - pre-spawn: same re-upsert, from the fail-fast path, so a mid-session
//     logout also flips availability at first use.
// Non-primary instances (subagents) never touch registration: pi's native
// registry REPLACES by id, so an unguarded subagent re-register would swap in
// its own streamSimple — the exact split-brain the tokens exist to prevent.
// On a pre-0.81 host the extension declines loudly (once) instead of
// registering wrongly through the legacy overload.
let nativeProviderInstance: unknown;
let notifiedNativeUnsupported = false;

function applyProviderRegistration(trigger: string): void {
	const pi = extensionApi;
	if (!pi) { debug(`${trigger}: applyProviderRegistration skipped — no extensionApi`); return; }
	const g = globalThis as Record<symbol, any>;
	const isPrimary = claimPrimaryInstance();
	if (!isPrimary) {
		debug(`${trigger}: registration noop — non-primary instance (module=${moduleInstanceId})`);
		return;
	}
	if (!supportsNativeProvider(_piAi)) {
		debug(`${trigger}: host pi-ai lacks createProvider; refusing to register (module=${moduleInstanceId})`);
		if (!notifiedNativeUnsupported) {
			notifiedNativeUnsupported = true;
			safeNotify(NATIVE_PROVIDER_UNSUPPORTED_MESSAGE, "error");
		}
		return;
	}
	const credentialed = hasClaudeCredentials();
	debug(`${trigger}: native registration upsert, credentialed=${credentialed} (module=${moduleInstanceId})`);
	// Start the connector inventory now, not on the first turn: the query path
	// can only read a synchronous snapshot, so priming here is what gets the
	// declarations in place before turn 1 (vstack#832). Fire and forget —
	// registration must not wait on the network. Only worth it when a Claude
	// account is actually connected.
	if (credentialed && connectorsEnabledFor(loadConfig(process.cwd()))) primeConnectorServers();
	// Claim ordering: stream guard BEFORE registerProvider so a concurrent
	// subagent can never observe a registered provider without an owner.
	g[ACTIVE_STREAM_SIMPLE_KEY] = streamClaudeAgentSdk;
	try {
		nativeProviderInstance ??= buildNativeProvider(_piAi, MODELS, streamClaudeAgentSdk as (...args: unknown[]) => unknown);
		(pi.registerProvider as (provider: unknown) => void)(nativeProviderInstance);
	} catch (err) {
		// Self-heal: release ONLY the stream guard we just claimed so a later
		// re-check retries cleanly. Keep PRIMARY_INSTANCE_KEY: releasing it would
		// reopen the subagent ownership-steal window.
		if (g[ACTIVE_STREAM_SIMPLE_KEY] === streamClaudeAgentSdk) g[ACTIVE_STREAM_SIMPLE_KEY] = undefined;
		debug(`${trigger}: registerProvider threw; released stream guard for retry (kept primary):`, err);
	}
}

/** Provider entry point. Pi calls this for each new prompt and each tool result.
 *  Two cases: tool result delivery (active query) or fresh query. */
function streamClaudeAgentSdk(model: Model<any>, context: Context, options?: SimpleStreamOptions): AssistantMessageEventStream {
	const stream = newAssistantMessageEventStream();

	// DEBUG: trace followUp message triggering
	const lastMsgRole = context.messages[context.messages.length - 1]?.role;
	const cwd = (options as { cwd?: string } | undefined)?.cwd ?? process.cwd();
	debug(`provider: streamClaudeAgentSdk called, activeQuery=${!!ctx().activeQuery}, lastMsgRole=${lastMsgRole}, isReentrant=${ctx().activeQuery !== null}`);

	// --- Tool result delivery ---
	// Pi appends tool results to context and calls back. Extract this turn's results
	// (everything after the last assistant message) and match against waiting MCP
	// handlers. Results that arrive before their handler get queued in pendingResults.
	if (ctx().activeQuery) {
		const queryCtx = ctx();
		queryCtx.currentPiStream = stream;
		queryCtx.resetTurnState(model);
		activeStreamIdleWatchdogs.get(queryCtx)?.refresh();
		const allResults = extractAllToolResults(context);
		debug(`provider: tool results, ${allResults.length} results, ${queryCtx.pendingToolCalls.size} waiting handlers, ctx.msgs=${context.messages.length}`);
		const unmatchedResultIds: string[] = [];
		for (const result of allResults) {
			const id = result.toolCallId;
			if (id && !queryCtx.hasRecordedToolCall(id)) {
				queryCtx.markToolResultUnmatched(id);
				unmatchedResultIds.push(id);
				debug(`ERROR: tool result [${id}] has no registered tool_call id; refusing to queue or deliver`);
				continue;
			}
			queryCtx.markToolResultDelivered(id);
			if (id && queryCtx.pendingToolCalls.has(id)) {
				const pending = queryCtx.pendingToolCalls.get(id)!;
				queryCtx.pendingToolCalls.delete(id);
				debug(`provider: resolving ${pending.toolName} [${id}]${result.isError ? " (error)" : ""}`, JSON.stringify(result.content).slice(0, 200));
				pending.resolve(result);
			} else if (id) {
				queryCtx.pendingResults.set(id, result);
				debug(`provider: queued result [${id}] (${queryCtx.pendingResults.size} pending)`);
			} else {
				debug(`WARNING: tool result without toolCallId, cannot match`);
			}
			if (queryCtx.pendingToolCalls.size > 0 && queryCtx.pendingResults.size > 0) {
				debug(`BUG: both maps non-empty! handlers=${queryCtx.pendingToolCalls.size} results=${queryCtx.pendingResults.size}`);
			}
		}
		if (unmatchedResultIds.length > 0) {
			const errorResult: McpResult = {
				content: [{ type: "text", text: `Claude bridge internal error: ${unmatchedResultIds.length} tool result(s) did not match any registered tool_call id. The turn was stopped to avoid delivering tool output to the wrong call. Unmatched ids: ${unmatchedResultIds.slice(0, 8).join(", ")}${unmatchedResultIds.length > 8 ? ", ..." : ""}` }],
				isError: true,
			};
			for (const pending of queryCtx.pendingToolCalls.values()) pending.resolve(errorResult);
			queryCtx.pendingToolCalls.clear();
			reportToolResultMismatch(queryCtx, "unmatched tool result", cwd);
		}
		if (queryCtx.pendingToolCalls.size > 0) {
			debug(`WARNING: ${queryCtx.pendingToolCalls.size} MCP handlers still waiting after delivering ${allResults.length} results`);
			piUI?.notify(`Claude bridge: ${queryCtx.pendingToolCalls.size} tool handler(s) still waiting — provider may be stuck`, "warning");
		}

		// Detect user messages (steer/followUp) that pi injected into context
		// during the active query. This happens when:
		//   - User sends a steer while a tool is executing; pi drains the steer
		//     queue at the turn boundary and appends it to context alongside the
		//     tool result, then calls the provider again.
		//   - A followUp is delivered between tool-result turns.
		// The bridge can't forward these mid-query (the SDK query is in progress),
		// so we save them for replay as continuation queries after consumeQuery ends.
		if (lastMsgRole === "user") {
			const userPrompt = extractUserPrompt(context.messages);
			if (userPrompt) {
				ctx().deferredUserMessages.push(userPrompt);
				debug(`provider: deferred user message for replay after query: ${userPrompt.slice(0, 60)}`);
			}
		}

		if (sharedSession) sharedSession.cursor = context.messages.length;
		queryCtx.latestCursor = Math.max(queryCtx.latestCursor, context.messages.length);
		return stream;
	}

	// --- Orphaned tool result (e.g. user aborted a tool call) ---
	// The query is gone but pi still delivered the result. Nothing to do — just
	// emit end_turn so pi waits for the next real user message.
	const lastMsg = context.messages[context.messages.length - 1];
	if (lastMsg?.role === "toolResult") {
		debug(`provider: orphaned tool result after abort, emitting end_turn`);
		if (sharedSession) sharedSession.cursor = context.messages.length;
		const c = ctx();  // capture current context for the microtask
		queueMicrotask(() => {
			c.resetTurnState(model);
			stream.push({ type: "done", reason: "stop", message: c.turnOutput });
			stream.end();
		});
		return stream;
	}

	// --- Fresh query ---

	// Fail-fast credential re-check (only for a fresh query — NEVER for
	// tool-result delivery of an in-flight query, handled above, where creds were
	// valid at start and failing mid-turn would break tool pairing). This bounds
	// the logout-visibility window from "next session boundary" to "first use":
	// if credentials vanished since the last session_start, (a) re-upsert the
	// provider (primary-only) so pi's availability recompute hides the models,
	// and (b) fail this request with a clear, actionable message instead of
	// letting the SDK spawn die with a generic error. The check is cheap
	// (existsSync + env reads only, no credential contents).
	if (!hasClaudeCredentials()) {
		try { applyProviderRegistration("pre-spawn"); } catch { /* best effort */ }
		const message = "Claude account not connected — connect an account (or run `claude login`) and retry.";
		debug(`provider: pre-spawn credential check failed; failing fast: ${message}`);
		const errorOutput: AssistantMessage = {
			role: "assistant", content: [],
			api: model.api, provider: model.provider, model: model.id,
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
			stopReason: "error", timestamp: Date.now(),
			errorMessage: message,
		};
		queueMicrotask(() => {
			stream.push({ type: "error", reason: "error", error: errorOutput });
			stream.end();
		});
		return stream;
	}

	// 1. Determine reentrancy and push parent context if needed.
	const isReentrant = ctx().activeQuery !== null;
	if (isReentrant) pushContext();
	debug(`provider: fresh query setup, isReentrant=${isReentrant}, stackDepth=${stackDepth()}`);

	// 2. Fresh child context — constructor already gave us clean Maps and empty
	//    arrays. For a reused top-level context, clear explicitly.
	ctx().currentPiStream = stream;
	ctx().pendingToolCalls.clear();
	ctx().pendingResults.clear();
	ctx().deferredUserMessages = [];
	ctx().resetTurnState(model);
	ctx().resetToolTracking();
	ctx().latestCursor = 0;

	const { mcpTools, customToolNameToSdk, customToolNameToPi } = resolveMcpTools(context);
	const promptBlocks = extractUserPromptBlocks(context.messages);
	let promptText = extractUserPrompt(context.messages) ?? "";

	// Guard: empty prompt means the last context message isn't a user message.
	// This should never happen with the state stack fix — dump diagnostics if it does.
	if (!promptText && !promptBlocks) {
		diagDump("empty_prompt", {
			contextLength: context.messages.length,
			lastMsgRole: lastMsg?.role,
			isReentrant,
			stackDepth: stackDepth(),
			activeQueryExists: ctx().activeQuery !== null,
			sharedSession: sharedSession ? { sessionId: sharedSession.sessionId.slice(0, 8), cursor: sharedSession.cursor } : null,
			messageRoles: context.messages.map((m, i) => `[${i}]${m.role}`).join(" "),
		});
		// Recover: use a continuation prompt so the SDK doesn't send an empty text block
		promptText = "[continue]";
	}

	const prompt: string | AsyncIterable<SDKUserMessage> = promptBlocks
		? wrapPromptStream(promptBlocks)
		: promptText;
	const mcpServers = buildMcpServers(mcpTools, ctx());
	const bridgeConfig = loadConfig(cwd);
	const providerSettings = bridgeConfig.provider ?? {};
	// Whether to expose the Claude account's claude.ai cloud MCP connectors
	// (Gmail/Calendar/Drive). Enabled via env or config; drives setting-sources,
	// tool isolation, and the ENABLE_CLAUDEAI_MCP_SERVERS child-env gate below.
	const enableCloudMcp = connectorsEnabledFor(bridgeConfig);
	// Connector WRITE control: read-only by default (writes denied); the one-shot
	// approved-write executor sets CLAUDE_BRIDGE_CONNECTOR_WRITE=allow / config.
	const connectorWriteMode = connectorWriteModeFor(bridgeConfig);
	// Declare the account's connected connectors explicitly so `alwaysLoad` can
	// hold startup until they attach — otherwise the turn-1 manifest is built
	// before the CLI has fetched them (vstack#832).
	const connectorServers = enableCloudMcp ? connectorServersSnapshot() : {};
	const appendSystemPrompt = providerSettings.appendSystemPrompt !== false;
	const agentsAppend = appendSystemPrompt ? extractAgentsAppend() : undefined;
	const skillsAppend = appendSystemPrompt ? extractSkillsBlock(context.systemPrompt) : undefined;
	const promptContextAppend = buildPromptContextAppend(context.systemPrompt, cwd, bridgeConfig.promptContext ?? {});
	const appendParts = [agentsAppend, skillsAppend, promptContextAppend.text].filter((part): part is string => Boolean(part));
	const systemPromptAppend = appendParts.length > 0 ? appendParts.join("\n\n") : undefined;

	// MCP auto-loading suppression: with appendSystemPrompt=true (default), the
	// SDK uses isolation mode and avoids filesystem settings. If users turn that
	// off, load user/project settings but pass --strict-mcp-config so Claude Code
	// ignores auto-discovered filesystem MCP servers while Pi owns tool execution.
	// claude.ai cloud MCP connectors only load when Claude Code resolves its
	// filesystem setting sources. The SDK treats settingSources=undefined as
	// isolation (no sources), which drops the connectors even with
	// ENABLE_CLAUDEAI_MCP_SERVERS=1. When connectors are enabled we force the CLI
	// default source set so Gmail/Calendar/Drive surface.
	const settingSources: SettingSource[] | undefined = enableCloudMcp
		? (providerSettings.settingSources ?? ["user", "project", "local"])
		: appendSystemPrompt
			? undefined
			: providerSettings.settingSources ?? ["user", "project"];
	const strictMcpConfigEnabled = !appendSystemPrompt && providerSettings.strictMcpConfig !== false;
	const claudeExecutable = resolveClaudeExecutable(providerSettings.pathToClaudeCodeExecutable);
	const claudeExecutablePreflight = claudeExecutable ? preflightClaudeExecutable(claudeExecutable, cwd) : undefined;
	const { sessionId: resumeSessionId } = syncSharedSession(context.messages, cwd, customToolNameToSdk, model.id);

	// Prefer the model's own thinkingLevelMap when present (pi-ai 0.72+ ships
	// per-model overrides — e.g. opus-4-7 wants xhigh→xhigh, not xhigh→max).
	// Fall back to our generic table for older pi-ai or unmapped levels.
	const requestedEffort = options?.reasoning
		? ((model as any).thinkingLevelMap?.[options.reasoning] as EffortLevel | undefined)
			?? REASONING_TO_EFFORT[options.reasoning]
		: undefined;
	const effort = resolveConfiguredEffort(model.id, requestedEffort, providerSettings);

	const extraArgs: Record<string, string | null> = {};
	// Opus 4.7 defaults thinking.display to "omitted" (empty thinking text in stream).
	// Force summarized so thinking_delta events arrive. See anthropics/claude-agent-sdk-python#830.
	// Deliberately the raw flag, NOT the typed `thinking` option: every non-disabled
	// ThinkingConfig also emits `--thinking adaptive` or `--max-thinking-tokens`
	// (verified in sdk.mjs flag mapping), so the typed form cannot set display
	// without overriding the model's thinking mode alongside our `--effort`.
	if (effort) extraArgs["thinking-display"] = "summarized";
	const fallbackModel = fallbackModelForPrimaryModel(model.id);

	// Suppress claude.ai cloud MCP servers (Figma/Canva/etc. auto-discovered via OAuth
	// when the user is logged into Anthropic). These are a separate code path from
	// filesystem MCP and are NOT blocked by --strict-mcp-config or settingSources=undefined.
	// The native CC binary gates them on env var ENABLE_CLAUDEAI_MCP_SERVERS: setting it
	// to "0"/"false"/"no"/"off" makes the loader return early before any cloud fetch.
	// DISABLE_AUTO_COMPACT=1: pi owns context-management and propagates its own
	// /compact via session_compact (see handler in default export). Letting CC
	// also autocompact would double-flush the prompt cache and races pi's
	// threshold with CC's, including CC's anti-thrashing guard (issue #8).
	// Manual /compact in CC still works (we never invoke it).
	// When connectors are enabled, allow claude.ai cloud MCP servers so the
	// authenticated account's Gmail/Calendar/Drive tools load. Default stays "0".
	const childEnv = { ...process.env, ENABLE_CLAUDEAI_MCP_SERVERS: enableCloudMcp ? "1" : "0", DISABLE_AUTO_COMPACT: "1" };
	const queryOptions: NonNullable<Parameters<typeof query>[0]["options"]> = {
		cwd,
		model: model.id,
		env: childEnv,
		...connectorQueryOptions(enableCloudMcp, connectorWriteMode),
		permissionMode: "bypassPermissions",
		includePartialMessages: true,
		...(fallbackModel ? { fallbackModel } : {}),
		...(providerSettings.fastMode ? { settings: { fastMode: true } } : {}),
		systemPrompt: {
			type: "preset", preset: "claude_code",
			append: systemPromptAppend ? systemPromptAppend : undefined,
		},
		extraArgs,
		...(strictMcpConfigEnabled ? { strictMcpConfig: true } : {}),
		...(effort ? { effort } : {}),
		...(settingSources ? { settingSources } : {}),
		...(mcpServers || Object.keys(connectorServers).length > 0
			? { mcpServers: { ...(mcpServers ?? {}), ...connectorServers } as NonNullable<Parameters<typeof query>[0]["options"]>["mcpServers"] }
			: {}),
		...(resumeSessionId ? { resume: resumeSessionId } : {}),
		...(claudeExecutable ? { pathToClaudeCodeExecutable: claudeExecutable } : {}),
		spawnClaudeCodeProcess: spawnClaudeCodeWithDiagnostics,
		...makeCliDebugOptions("provider"),
	};

	debug("provider: fresh query",
		`model=${model.id} msgs=${context.messages.length} tools=${mcpTools.length}`,
		`resume=${resumeSessionId?.slice(0, 8) ?? "none"} effort=${effort ?? "default"}`,
		`fallback=${fallbackModel ?? "none"}`,
		`appendSys=${appendSystemPrompt} promptCtx=${promptContextAppend.labels.join(",") || "none"} strictMcp=${strictMcpConfigEnabled} fastMode=${providerSettings.fastMode === true} connectors=${enableCloudMcp}`,
		`claudeExec=${claudeExecutablePreflight ? `${claudeExecutablePreflight.fileType}:${claudeExecutablePreflight.path}` : "sdk-default"}`,
		`prompt=${promptText.slice(0, 60)}${promptBlocks ? " [+images]" : ""}`);

	// 3. Start SDK query and claim it for this context
	let wasAborted = false;
	let streamIdleTimedOut = false;
	const sdkQuery = query({ prompt, options: queryOptions });
	ctx().activeQuery = sdkQuery;

	// 4. Capture context for abort handling (must be AFTER pushContext)
	const abortCtx = ctx();

	const requestAbort = () => {
		// interrupt() asks the CLI to stop gracefully; close() kills it immediately.
		// Both are needed — interrupt alone lets the current API call finish.
		void sdkQuery.interrupt().catch(() => {});
		try { sdkQuery.close(); } catch {}
	};
	const streamIdleTimeoutMs = streamIdleTimeoutMsFromEnv();
	const streamIdleWatchdog = streamIdleTimeoutMs > 0
		? createStreamIdleWatchdog({
			getState: () => ({
				activeQuery: abortCtx.activeQuery,
				currentPiStream: abortCtx.currentPiStream,
				turnOutput: abortCtx.turnOutput,
				turnSawStreamEvent: abortCtx.turnSawStreamEvent,
				turnStarted: abortCtx.turnStarted,
			}),
			onTimeout: ({ idleMs, timeoutMs }) => {
				if (streamIdleTimedOut || wasAborted || options?.signal?.aborted || abortCtx.activeQuery !== sdkQuery) return;
				streamIdleTimedOut = true;
				abortCtx.deferredUserMessages = [];
				abortCtx.handledTerminalError = true;
				if (sharedSession) setSharedSession({ ...sharedSession, needsRebuild: true, forceRotate: true });
				const errorMessage = buildStreamIdleTimeoutErrorMessage(timeoutMs);
				debug("provider: stream idle timeout", `model=${model.id}`, `timeout=${timeoutMs}`, `idle=${idleMs}`);
				emitRateLimitEvent({
					idleMs,
					model: model.id,
					provider: PROVIDER_ID,
					rateLimitType: "stream_idle",
					reason: "Claude Code stream idle timeout",
					retryAfterMs: STREAM_IDLE_BACKOFF_HINT_MS,
					source: "claude-bridge",
					status: "rejected",
					timeoutMs,
				});
				piUI?.notify(`${RATE_LIMIT_TOKEN} Claude stream idle timeout after ${formatDurationShort(timeoutMs)} — retrying via rate-limit backoff`, "warning");
				if (abortCtx.turnOutput) {
					abortCtx.turnOutput.stopReason = "error";
					abortCtx.turnOutput.errorMessage = errorMessage;
					Object.assign(abortCtx.turnOutput as AssistantMessage & Record<string, unknown>, {
						rateLimitType: "stream_idle",
						retryAfterMs: STREAM_IDLE_BACKOFF_HINT_MS,
						streamIdleTimeoutMs: timeoutMs,
					});
				}
				abortCtx.currentPiStream?.push({ type: "error", reason: "error", error: abortCtx.turnOutput! });
				abortCtx.currentPiStream?.end();
				abortCtx.currentPiStream = null;
				requestAbort();
			},
			timeoutMs: streamIdleTimeoutMs,
		})
		: null;
	if (streamIdleWatchdog) {
		activeStreamIdleWatchdogs.set(abortCtx, streamIdleWatchdog);
		streamIdleWatchdog.refresh();
	}
	const onAbort = () => {
		wasAborted = true;
		// Prevent stale deferred messages from being replayed by parent on pop
		abortCtx.deferredUserMessages = [];
		reportToolResultMismatch(abortCtx, "abort", cwd, { forceRotate: true });
		const drained = drainPendingToolCalls(abortCtx, "abort");
		if (drained > 0) debug(`provider: abort drained ${drained} waiting MCP handler(s) as errors`);
		abortCtx.pendingResults.clear();
		requestAbort();
	};
	if (options?.signal) {
		if (options.signal.aborted) onAbort();
		else options.signal.addEventListener("abort", onAbort, { once: true });
	}

	// Background consumer — runs until query ends.
	// The handlers below use the CAPTURED abortCtx, never the live ctx(): the two
	// only differ while a reentrant (subagent) context is pushed, and a parent
	// query CAN end in that window (abort, child process death throwing out of
	// the generator). Live-ctx handlers there mutated the subagent's turn state
	// and stream and skipped the parent's own teardown entirely.
	consumeQuery(sdkQuery, customToolNameToPi, model, cwd, bridgeConfig, () => wasAborted)
		.then(async ({ capturedSessionId }) => {
			debug(`provider: consumeQuery completed, stopReason=${abortCtx.turnOutput?.stopReason}, error=${abortCtx.turnOutput?.errorMessage}, aborted=${wasAborted}`);
			if (streamIdleTimedOut) {
				abortCtx.deferredUserMessages = [];
				debug("provider: stream idle timeout already surfaced; skipping normal completion");
				return;
			}

			// --- Abort detection in normal completion path ---
			if (wasAborted || options?.signal?.aborted) {
				if (sharedSession) setSharedSession({ ...sharedSession, needsRebuild: true, forceRotate: true });
				abortCtx.deferredUserMessages = [];
				debug(`provider: abort detected, marked sharedSession needsRebuild + forceRotate`);
				if (abortCtx.turnOutput) {
					abortCtx.turnOutput.stopReason = "aborted";
					abortCtx.turnOutput.errorMessage = "Operation aborted";
				}
				abortCtx.currentPiStream?.push({ type: "error", reason: "aborted", error: abortCtx.turnOutput! });
				abortCtx.currentPiStream?.end();
				abortCtx.currentPiStream = null;
				return;
			}

			// --- Capture session ID ---
			const sessionId = capturedSessionId ?? sharedSession?.sessionId;
			if (sessionId) {
				const cursor = Math.max(context.messages.length, abortCtx.latestCursor, sharedSession?.cursor ?? 0);
				debug(`provider: query done, session=${sessionId.slice(0, 8)}, cursor=${cursor}`);
				setSharedSession({ sessionId, cursor, cwd });
			}

			// --- Replay deferred user messages as continuation queries ---
			// Only for outermost queries — reentrant (subagent) queries leave
			// deferred messages for the parent to handle after it finishes.
			try {
				while (abortCtx.deferredUserMessages.length > 0 && !isReentrant && !wasAborted) {
					const steerPrompt = abortCtx.deferredUserMessages.shift()!;
					debug(`provider: replaying deferred user message: ${steerPrompt.slice(0, 60)}`);
					abortCtx.resetTurnState(model);
					abortCtx.resetToolTracking();

					const resumeId = sharedSession?.sessionId;
					if (!resumeId) {
						debug(`WARNING: no session to resume for deferred message, dropping`);
						break;
					}

					const contOptions = { ...queryOptions, resume: resumeId, ...makeCliDebugOptions("continuation") };
					const contQuery = query({ prompt: steerPrompt, options: contOptions });
					abortCtx.activeQuery = contQuery;

					debug(`provider: continuation query, model=${model.id}, resume=${resumeId.slice(0, 8)}, prompt=${steerPrompt.slice(0, 60)}`);

					try {
						const { capturedSessionId: contSid } = await consumeQuery(contQuery, customToolNameToPi, model, cwd, bridgeConfig, () => wasAborted);
						const sid = contSid ?? sharedSession?.sessionId;
						if (sid) {
							setSharedSession({ sessionId: sid, cursor: sharedSession?.cursor ?? 0, cwd });
						}
					} catch (contError) {
						debug(`provider: continuation query error:`, contError);
						break;
					} finally {
						contQuery.close();
					}
				}
			} finally {
				// Guarantees restoration even if contQuery() throws synchronously
				abortCtx.activeQuery = sdkQuery;
			}

			finalizeCurrentStream(abortCtx.turnOutput?.stopReason, abortCtx);
		})
		.catch((error) => {
			debug(`provider: query error, model=${model.id}, aborted=${Boolean(options?.signal?.aborted)}, error=`, error);
			const suppressDuplicateError = abortCtx.handledTerminalError || streamIdleTimedOut;
			const openedExtraUsage = !suppressDuplicateError && isExtraUsageRequiredMessage(error) && launchExtraUsageHelperIfAllowed(cwd, bridgeConfig, "query error");
			if ((wasAborted || options?.signal?.aborted) && sharedSession) {
				setSharedSession({ ...sharedSession, needsRebuild: true, forceRotate: true });
			} else {
				setSharedSession(null);
			}
			abortCtx.deferredUserMessages = [];
			if (suppressDuplicateError) {
				debug("provider: suppressing duplicate query error after terminal error was already emitted");
				return;
			}
			if (abortCtx.turnOutput) {
				abortCtx.turnOutput.stopReason = options?.signal?.aborted ? "aborted" : "error";
				abortCtx.turnOutput.errorMessage = `${error instanceof Error ? error.message : String(error)}${openedExtraUsage ? "\n\nOpened Claude Code /extra-usage helper. Complete billing/admin flow in the browser, then retry the prompt." : ""}`;
			}
			abortCtx.currentPiStream?.push({ type: "error", reason: (abortCtx.turnOutput?.stopReason ?? "error") as "aborted" | "error", error: abortCtx.turnOutput! });
			abortCtx.currentPiStream?.end();
			abortCtx.currentPiStream = null;
		})
		.finally(() => {
			streamIdleWatchdog?.dispose();
			activeStreamIdleWatchdogs.delete(abortCtx);
			if (options?.signal) options.signal.removeEventListener("abort", onAbort);
			const cause = toolCallDrainCause({ wasAborted, signalAborted: options?.signal?.aborted, streamIdleTimedOut });
			teardownQuery(abortCtx, sdkQuery, cause, cwd, isReentrant);
			sdkQuery.close();
		});

	return stream;
}

function commandCwd(ctx: unknown): string {
	const value = (ctx as { cwd?: unknown })?.cwd;
	return typeof value === "string" && value.length > 0 ? value : process.cwd();
}

async function tryOpenExtensionManagerSettings(ctx: { ui: ExtensionUIContext }): Promise<boolean> {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const openQuickSettings = host[Symbol.for("vstack.pi.extension-manager.open-quick-settings")];
	if (typeof openQuickSettings !== "function") return false;
	try {
		await (openQuickSettings as (ctx: unknown, hint?: string) => Promise<void>)(ctx, "@vanillagreen/pi-claude-bridge");
		return true;
	} catch {
		return false;
	}
}

function showBridgeStatus(ctx: { ui: ExtensionUIContext; cwd?: string }): void {
	const config = loadConfig(commandCwd(ctx));
	ctx.ui.notify([
		`Claude bridge: ${config.enabled === false ? "disabled" : "enabled"}`,
		`Extra usage auto-helper: ${extraUsageAllowed(config) ? "on" : "off"} (settings)`,
		`Use /claude-bridge:extra to run Claude Code /extra-usage now.`,
	].join("\n"), "info");
}

// Read a credential file, treating any read error as "absent" — a missing or
// unreadable candidate must fall through to the next one, not abort resolution.
function readCredentialFile(path: string): string | undefined {
	try {
		return nodeReadFileSync(path, "utf8");
	} catch {
		return undefined;
	}
}

// Connector declarations for the query path (vstack#832), cached per credential
// scope. The inventory is one HTTPS round trip; doing it per TURN would add that
// latency to every message, and an account's connector set does not change
// mid-session. Keyed by CLAUDE_CONFIG_DIR because that is what selects the
// account — the org UUID in the request path is ignored, so two accounts on one
// host differ only by which credential directory was read.
//
// FAILS OPEN. If credentials or the inventory call fail we return no
// declarations and the turn proceeds exactly as it does today: connectors may
// race, which is the bug, but a network blip must not break the turn outright.
const connectorServerCache = new Map<string, Record<string, unknown>>();
const connectorServerPending = new Set<string>();

function connectorScopeKey(): string {
	return process.env.CLAUDE_CONFIG_DIR?.trim() || "<default>";
}

// Kick off the inventory fetch for the current credential scope. Fire and
// forget: the query path can only read a SYNCHRONOUS snapshot, because
// streamClaudeAgentSdk returns a stream and claims the SDK query handle in the
// same tick — there is no await boundary to hang a fetch on without
// restructuring abort handling.
//
// Primed at provider registration so the result is in hand well before the
// first turn (the call measured ~400ms against app startup). If a turn arrives
// first it declares nothing and behaves exactly as it does today — the race is
// back for that one turn, which is the bug, but never worse than the status quo.
//
// FAILS OPEN throughout: no credentials, a failed inventory, or a thrown call
// all resolve to "declare nothing" rather than breaking the turn.
export function primeConnectorServers(): void {
	const key = connectorScopeKey();
	if (connectorServerCache.has(key) || connectorServerPending.has(key)) return;
	connectorServerPending.add(key);
	void (async () => {
		try {
			const credentials = resolveClaudeOAuth(readCredentialFile);
			if (!credentials) {
				debug("connectors: no OAuth credentials; declaring none");
				connectorServerCache.set(key, {});
				return;
			}
			const inventory = await listAccountConnectors({ credentials });
			if (!inventory.ok) {
				debug(`connectors: inventory failed (${inventory.reason}); declaring none`);
				connectorServerCache.set(key, {});
				return;
			}
			const servers = connectorMcpServers(inventory);
			debug(`connectors: declaring ${Object.keys(servers).length} of ${inventory.connectors.length} installed`,
				Object.keys(servers).join(", ") || "none");
			connectorServerCache.set(key, servers);
			// Persist so the NEXT cold process has this synchronously. Priming always
			// loses the race against turn 1 in its own process; a cache written by an
			// earlier run is the only thing turn 1 can read in time (vstack#870).
			if (writeCachedConnectors(inventory.connectors, key)) {
				debug(`connectors: cached ${inventory.connectors.length} entries`);
			}
		} catch (error) {
			debug("connectors: declaration lookup threw; declaring none", error);
			connectorServerCache.set(key, {});
		} finally {
			connectorServerPending.delete(key);
		}
	})();
}

/** Synchronous snapshot for the query path; `{}` until priming resolves. */
function connectorServersSnapshot(): Record<string, unknown> {
	const key = connectorScopeKey();
	const ready = connectorServerCache.get(key);
	if (ready) return ready;
	// Always start (or continue) the live fetch — the cache is a head start, not
	// a replacement, and the refresh keeps the next process current.
	primeConnectorServers();
	// Fall back to the previous run's inventory, read synchronously. This is the
	// only thing that can populate turn 1 of a cold process, because priming
	// cannot finish before the first query is built (vstack#870).
	const cached = readCachedConnectors(key);
	if (!cached) return {};
	const servers = connectorMcpServers({ ok: true, complete: true, connectors: cached });
	if (Object.keys(servers).length === 0) return {};
	debug(`connectors: turn-1 declarations from cache — ${Object.keys(servers).join(", ")}`);
	return servers;
}

// Deterministic connector enumeration for the host app (vstack#838). Reports the
// failure reason rather than an empty list, so "no connectors" and "could not
// check" stay distinguishable.
async function reportConnectorInventory(ctx: { ui: ExtensionUIContext }): Promise<void> {
	const credentials = resolveClaudeOAuth(readCredentialFile);
	if (!credentials) {
		ctx.ui.notify("Claude bridge: no Claude OAuth credentials found — cannot enumerate connectors.", "error");
		return;
	}
	const inventory = await listAccountConnectors({ credentials });
	if (!inventory.ok) {
		ctx.ui.notify(`Claude bridge: connector enumeration failed — ${inventory.reason}`, "error");
		return;
	}
	if (inventory.connectors.length === 0) {
		ctx.ui.notify("Claude bridge: this account has no connectors installed.", "info");
		return;
	}
	const names = inventory.connectors.map((c) => c.name).join(", ");
	ctx.ui.notify(`Claude bridge: ${inventory.connectors.length} connector(s) installed — ${names}`, "info");
}

function registerBridgeCommands(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[COMMANDS_REGISTERED_KEY]) return;
	guard[COMMANDS_REGISTERED_KEY] = true;

	const runExtraUsage = async (ctx: { ui: ExtensionUIContext; cwd?: string }) => {
		const cwd = commandCwd(ctx);
		if (extraUsageHelperInFlight) {
			ctx.ui.notify("Claude extra usage helper already running.", "info");
			await extraUsageHelperInFlight.catch(() => undefined);
			return;
		}
		try {
			ctx.ui.notify("Claude extra usage helper starting…", "info");
			extraUsageHelperInFlight = runExtraUsageHelper(cwd)
				.finally(() => { extraUsageHelperInFlight = null; });
			const message = await extraUsageHelperInFlight;
			ctx.ui.notify(`Claude extra usage helper: ${message}`, "info");
		} catch (error) {
			const message = error instanceof Error ? error.message : String(error);
			ctx.ui.notify(`Claude extra usage helper failed: ${message}`, "error");
		}
	};

	pi.registerCommand("claude-bridge", {
		description: "Open Claude bridge settings/status",
		handler: async (args: string, ctx) => {
			if (args.trim()) ctx.ui.notify("Unknown /claude-bridge argument. Use /claude-bridge:extra to run Claude Code /extra-usage.", "warning");
			if (await tryOpenExtensionManagerSettings(ctx)) return;
			showBridgeStatus(ctx);
		},
	});
	pi.registerCommand("claude-bridge:extra", {
		description: "Run Claude Code /extra-usage through claude-bridge",
		handler: async (_args: string, ctx) => runExtraUsage(ctx),
	});
	pi.registerCommand("claude-bridge:connectors", {
		description: "List the Claude account's installed claude.ai connectors",
		handler: async (_args: string, ctx) => reportConnectorInventory(ctx),
	});
}

// --- Extension registration ---

export default function (pi: ExtensionAPI) {
	setExtensionApi(pi);
	// Disable non-essential Claude Code traffic (update checks, MCP registry, telemetry)
	process.env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1";

	const config = loadConfig(process.cwd());
	debug("loadConfig:", JSON.stringify(config));
	// Registered before the disabled early return: a bridge switched off by
	// claude-bridge.json is exactly when the settings editor has to show where
	// that value came from.
	registerExternalConfigResolver();
	registerBridgeCommands(pi);
	if (config.enabled === false) {
		debug("provider: disabled by configuration");
		return;
	}

	// Reset shared (Claude) conversation state on pi session lifecycle events.
	// Registration tokens are managed separately by applyProviderRegistration
	// (load / session_start / pre-spawn) and releaseProviderTokens (shutdown), so
	// a mid-session credential flip is handled while token ownership is intact.
	const clearSession = (event: string) => {
		debug(`${event}: clearing session ${sharedSession?.sessionId?.slice(0, 8) ?? "none"}`);
		setSharedSession(null);
	};

	pi.on("session_start", (event, ctx) => {
		recordProjectTrust(ctx);
		setPiUI(ctx.ui);
		if (event.reason === "new" || event.reason === "resume" || event.reason === "fork") {
			clearSession(`session_start:${event.reason}`);
		}
		// Note: "fork" intentionally omitted from restoration. createBranchedSession
		// copies the parent's persisted bridge entries into the fork; restoring from
		// them would --resume the parent's Claude jsonl and leak conversation past the
		// fork point. Letting the first fork turn rebuild is the correct path.
		if (event.reason === "startup" || event.reason === "resume") restoreSharedSessionFromPi(ctx);
		// Live availability flip: re-evaluate credential presence every
		// session_start so login/logout since load is reflected without /reload.
		applyProviderRegistration(`session_start:${event.reason}`);
	});
	pi.on("session_shutdown", () => {
		clearSession("session_shutdown");
		releaseProviderTokens("session_shutdown");
	});
	pi.on("message_end", (event, ctx) => {
		const message = (event as { message?: AssistantMessage }).message;
		if (message?.role === "assistant" && message.provider === PROVIDER_ID) schedulePersistSharedSession(ctx);
	});

	// pi /compact and session-tree navigation (rewind / fork-at-point /
	// branch switch) both mutate pi's messages array out from under the
	// bridge. syncSharedSession's REUSE check would otherwise see
	// slice(cursor) === [] (or skip entries) and keep --resume'ing a CC
	// session that no longer matches pi's history. /compact in particular
	// triggers CC's autocompact-thrashing guard (issue #8). Force the next
	// call down the REBUILD path so CC sees the current history.
	const markRebuild = (event: string) => {
		if (ctx().activeQuery) {
			reportToolResultMismatch(ctx(), event, sharedSession?.cwd ?? process.cwd());
		}
		if (sharedSession) {
			debug(`${event}: marking needsRebuild on session ${sharedSession.sessionId.slice(0, 8)}`);
			setSharedSession({ ...sharedSession, needsRebuild: true });
		}
	};
	pi.on("session_compact", () => markRebuild("session_compact"));
	pi.on("session_tree", () => markRebuild("session_tree"));

	// --- Provider ---
	//
	// Native registration (pi >=0.81): register unconditionally; the provider's
	// own auth check/resolve report whether Claude credentials exist, so pi
	// hides claude-bridge models while no account is connected and shows them
	// when one appears. session_start and pre-spawn re-upsert the provider to
	// force pi's availability recompute at those boundaries.
	//
	// applyProviderRegistration also claims the primary-instance token (first
	// load wins) and enforces the multi-instance guard: a non-primary subagent
	// reload always no-ops, so it never overwrites the parent's streamSimple nor
	// steals ownership. See PRIMARY_INSTANCE_KEY / ACTIVE_STREAM_SIMPLE_KEY.
	applyProviderRegistration("load");
}
