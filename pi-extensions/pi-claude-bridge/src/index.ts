import { type AssistantMessage, type AssistantMessageEventStream, type Context, type Model, type SimpleStreamOptions, type Tool } from "@earendil-works/pi-ai";
import * as piAi from "@earendil-works/pi-ai";
import { type ExtensionAPI, type ExtensionUIContext } from "@earendil-works/pi-coding-agent";
import { createSdkMcpServer, query, type EffortLevel, type SDKUserMessage, type SettingSource } from "@anthropic-ai/claude-agent-sdk";
import type { Base64ImageSource, ContentBlockParam, MessageParam } from "@anthropic-ai/sdk/resources";
import { PROVIDER_ID, messageContentToText } from "./convert.js";
import { buildModels, fallbackModelForPrimaryModel, modelDisplayName, FABLE_MODEL_ID } from "./models.js";
import { MCP_SERVER_NAME, MCP_TOOL_PREFIX, extractSkillsBlock } from "./skills.js";
import { extractAllToolResults as _extractAllToolResults, type McpResult } from "./extract-tool-results.js";
import { QueryContext, ctx, drainPendingToolCalls, popContext, stackDepth, pushContext, toolCallDrainCause } from "./query-state.js";
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
import { connectorMcpServers, connectorQueryOptions, connectorWriteModeFor, connectorsEnabledFor, isChildExecutedTool, settingSourcesForQuery } from "./connectors.js";
import { readCachedConnectors, writeCachedConnectors } from "./connector-cache.js";
import { cancelScheduledSessionPersistence, restoreSharedSessionFromPi, schedulePersistSharedSession, syncSharedSession } from "./session-persistence.js";
import { STREAM_IDLE_BACKOFF_HINT_MS, activeStreamIdleWatchdogs, buildStreamIdleTimeoutErrorMessage, createStreamIdleWatchdog, formatDurationShort, streamIdleTimeoutMsFromEnv } from "./stream-idle-watchdog.js";
import { RATE_LIMIT_AUTO_RESUME_EVENT, RATE_LIMIT_TOKEN, formatAllowedRateLimitWarning, formatResetTimestamp, isUsageLimitMessage, uniqueNonEmptyLines } from "./rate-limit.js";
import { mapToolArgs } from "./tool-mapping.js";
import { ensureTurnStarted, finalizeCurrentStream, finalizeToolUseTurnFromMcpInvocation, noteChildExecutedToolResults, processAssistantMessage, processStreamEvent, scheduleToolUseTurnEnd, updateTurnOutputModel } from "./assistant-stream.js";
import {
	accountSessionScope,
	classifyClaudeFailure,
	CLAUDE_BRIDGE_ACCOUNT_HOST_SYMBOL,
	rateLimitResetFromInfo,
	rateLimitResetMs,
	rateLimitTypeFromInfo,
	resolveClaudeAccountRouter,
	RetryEventBuffer,
	subscriberProfileEnv,
	type ClaudeAccountFailureKind,
	type ClaudeAccountRoute,
	type ClaudeAccountRouterV1,
	type ClaudeBridgeAccountHostV1,
} from "./account-router.js";

// Re-exports: the module decomposition must not change the bundle entry's
// public surface — unit tests and downstream consumers import these from
// bundle/index.js.
export { classifyClaudeExecutableBytes, preflightClaudeExecutable, resolveClaudeExecutable, spawnClaudeCodeWithDiagnostics, wrapClaudeSpawnErrorForSdk, type ClaudeExecutableFileType, type ClaudeExecutablePreflightResult } from "./claude-executable.js";
export { __testGetBridgeIntegrityState, __testSetBridgeIntegrityState, INTEGRITY_CUSTOM_TYPE, appendIntegrityEntry, reportToolResultMismatch } from "./bridge-state.js";
export { CONNECTOR_CALL_CUSTOM_TYPE, connectorResultByteSize, flushConnectorCallAudit, recordConnectorCallResult, setConnectorCallAuditSink, type ConnectorCallAuditData, type ConnectorCallAuditSink, type ConnectorCallOutcome } from "./connector-audit.js";
export { CLAUDE_AI_CONNECTOR_TOOL_PATTERNS, connectorMcpServers, connectorDeclarationsDisabled, CLAUDE_BRIDGE_TOOL_ISOLATION, CONNECTOR_DISCOVERY_TOOLS, CONNECTOR_WRITE_TOOLS, DISALLOWED_BUILTIN_TOOLS, connectorQueryOptions, connectorWriteDenyHook, connectorWriteModeFor, connectorWriteModeFromEnv, connectorsEnabledFor, connectorsEnabledFromEnv, isChildExecutedTool, isChildInternalTool, isConnectorTool, isConnectorWriteTool, settingSourcesForQuery, toolIsolationForQuery } from "./connectors.js";
export { cancelScheduledSessionPersistence, planIncrementalPromptBatch, restoreSharedSessionFromPi, shouldRestorePersistedBridgeEntry } from "./session-persistence.js";
export { NATIVE_PROVIDER_UNSUPPORTED_MESSAGE, buildNativeProvider, claudeAuthSourceLabel, supportsNativeProvider } from "./native-provider.js";
export { DEFAULT_STREAM_IDLE_TIMEOUT_MS, STREAM_IDLE_BACKOFF_HINT_MS, STREAM_IDLE_TIMEOUT_ENV, buildStreamIdleTimeoutErrorMessage, createStreamIdleWatchdog, streamIdleTimeoutMsFromEnv, type StreamIdleTimeoutInfo, type StreamIdleWatchdog, type StreamIdleWatchdogState } from "./stream-idle-watchdog.js";
export { ALLOWED_RATE_LIMIT_WARNING_UTILIZATION_THRESHOLD, formatAllowedRateLimitWarning, formatResetTimestamp, isUsageLimitMessage, normalizeRateLimitUtilization, resetTimestampMs, uniqueNonEmptyLines } from "./rate-limit.js";
export { mapToolName } from "./tool-mapping.js";
export { cancelScheduledToolUseEnd, endToolUseTurn, finalizeToolUseTurnFromMcpInvocation, noteChildExecutedToolResults, processAssistantMessage, processStreamEvent, reapStaleQueuedResults, scheduleToolUseTurnEnd } from "./assistant-stream.js";
export {
	accountSessionScope,
	claudeDirForProfile,
	classifyClaudeFailure,
	CLAUDE_ACCOUNT_ROUTER_SYMBOL,
	CLAUDE_BRIDGE_ACCOUNT_HOST_SYMBOL,
	commitsVisibleOutput,
	rateLimitResetFromInfo,
	rateLimitResetMs,
	rateLimitTypeFromInfo,
	RetryEventBuffer,
	subscriberProfileEnv,
	type ClaudeAccountFailureKind,
	type ClaudeAccountRoute,
	type ClaudeAccountRouterV1,
	type ClaudeBridgeAccountHostV1,
} from "./account-router.js";

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
// Deliberately NOT Symbol.for: rotation state rides options between the retry
// re-entry and the original call within ONE module instance only.
const ROTATION_STATE_KEY = Symbol("claude-bridge:rotationState");

interface RotationRequestState {
	excludedProfileIds: Set<string>;
	attempts: number;
	/** Model id already announced via toast for this request, so up to 16
	 *  rotation attempts don't repeat an identical switch notice. */
	announcedModelId?: string;
}

type BridgeStreamOptions = SimpleStreamOptions & {
	[ROTATION_STATE_KEY]?: RotationRequestState;
};

// MODELS is buildModels(getModels("anthropic")) — projection kept in models.js.
const MODELS = buildModels(getModels("anthropic"));

type SdkQueryFactory = typeof query;
let sdkQueryFactory: SdkQueryFactory = query;

/** Test seam for exercising the real bridge retry/session orchestration without
 *  spending Claude usage. Production never calls this. */
export function __testSetSdkQueryFactory(factory?: SdkQueryFactory): void {
	sdkQueryFactory = factory ?? query;
}

function emitRateLimitEvent(payload: Record<string, unknown>): void {
	try {
		extensionApi?.events?.emit?.(RATE_LIMIT_AUTO_RESUME_EVENT, payload);
	} catch {
		// Cross-extension broker is best-effort only.
	}
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
	safeNotify(`Pi Claude: fast mode is enabled in settings but Claude Code declined it — ${text}.`, "warning");
}

/** Local /usage probe for the reciprocal account-host service: the companion
 *  account manager asks the bridge (the SDK owner) to read a profile's identity
 *  and usage figures under that profile's credential scope. */
// This is a published entry point (BRIDGE_ACCOUNT_HOST.probeProfile) and
// `signal` is optional, so a stalled child with no caller signal would hang the
// returned promise forever and leak the process. The internal deadline bounds
// every call; generous next to the in-query probe's 1.5s race because a cold
// child spawn is part of the budget here.
const ACCOUNT_PROBE_DEADLINE_MS = 10_000;

export async function probeClaudeAccountProfile(input: {
	profile: ClaudeAccountRoute;
	cwd: string;
	signal?: AbortSignal;
	/** Deadline override for tests; production callers use the default. */
	deadlineMs?: number;
}): Promise<{
	identity?: { email?: string; organization?: string; subscriptionType?: string; authMethod?: string };
	usage?: unknown;
}> {
	const config = loadConfig(input.cwd);
	const claudeExecutable = resolveClaudeExecutable(config.provider?.pathToClaudeCodeExecutable);
	if (claudeExecutable) preflightClaudeExecutable(claudeExecutable, input.cwd);
	const probe = sdkQueryFactory({
		prompt: "/usage",
		options: {
			cwd: input.cwd,
			env: {
				...subscriberProfileEnv(input.profile),
				ENABLE_CLAUDEAI_MCP_SERVERS: "0",
				DISABLE_AUTO_COMPACT: "1",
			},
			maxTurns: 1,
			permissionMode: "bypassPermissions",
			...(claudeExecutable ? { pathToClaudeCodeExecutable: claudeExecutable } : {}),
			spawnClaudeCodeProcess: spawnClaudeCodeWithDiagnostics,
			...makeCliDebugOptions("account-probe"),
		},
	});
	const onAbort = () => {
		void probe.interrupt().catch(() => {});
		try { probe.close(); } catch {}
	};
	if (input.signal?.aborted) onAbort();
	else input.signal?.addEventListener("abort", onAbort, { once: true });
	let controls: Promise<{
		identity?: { email?: string; organization?: string; subscriptionType?: string; authMethod?: string };
		usage?: unknown;
	}> | undefined;
	let deadlineTimer: ReturnType<typeof setTimeout> | undefined;
	const deadline = new Promise<"deadline">((resolveDeadline) => {
		deadlineTimer = setTimeout(() => {
			debug(`account-probe: deadline expired for ${input.profile.label}; killing probe child`);
			onAbort();
			resolveDeadline("deadline");
		}, input.deadlineMs ?? ACCOUNT_PROBE_DEADLINE_MS);
		deadlineTimer.unref?.();
	});
	const consume = (async () => {
		for await (const message of probe) {
			if (message.type === "system" && (message as any).subtype === "init" && !controls) {
				controls = Promise.allSettled([
					probe.accountInfo(),
					probe.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET(),
				]).then(([identityResult, usageResult]) => ({
					...(identityResult.status === "fulfilled" ? { identity: {
						email: identityResult.value.email,
						organization: identityResult.value.organization,
						subscriptionType: identityResult.value.subscriptionType,
					} } : {}),
					...(usageResult.status === "fulfilled" ? { usage: usageResult.value } : {}),
				}));
			}
		}
		return controls ? await controls : {};
	})();
	try {
		// The race — not close() alone — is what guarantees the promise settles: a
		// truly wedged child can survive close(), and then the for-await above
		// never ends.
		const result = await Promise.race([consume, deadline]);
		return result === "deadline" ? {} : result;
	} finally {
		clearTimeout(deadlineTimer);
		input.signal?.removeEventListener("abort", onAbort);
		probe.close();
		// After a deadline kill the consumer may still reject; that outcome is
		// already accounted for.
		void consume.catch(() => {});
	}
}

const BRIDGE_ACCOUNT_HOST: ClaudeBridgeAccountHostV1 = {
	version: 1,
	probeProfile: probeClaudeAccountProfile,
};

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

/** Combine one or more consecutive user messages into a single SDK prompt.
 *
 *  Representation divergence, accepted on purpose: this MERGES N pi user
 *  messages into ONE Claude user record ("\n\n"-joined), while a REBUILD
 *  (convertPiMessages in convert.ts) imports the same pi history as N separate
 *  user records. Streaming N SDKUserMessages instead would collapse N pi turns
 *  into one Pi reply with double-counted usage, so the join stays. The merged
 *  form is only ever a query's live prompt — it is never re-imported, so the
 *  two representations never meet in one session file. */
function extractUserPrompt(messages: Context["messages"]): string | null {
	if (messages.length === 0 || messages.some((message) => message.role !== "user")) return null;
	return messages.map((message) =>
		typeof message.content === "string" ? message.content : messageContentToText(message.content) || "",
	).join("\n\n");
}

/** Combine consecutive user messages as ContentBlockParam[] while preserving images.
 *  Returns null if no images — caller should fall back to the string prompt.
 *  Same N-into-1 merge as extractUserPrompt (see its comment for why). */
function extractUserPromptBlocks(messages: Context["messages"]): ContentBlockParam[] | null {
	if (messages.length === 0 || messages.some((message) => message.role !== "user")) return null;

	let hasImage = false;
	const blocks: ContentBlockParam[] = [];
	for (let messageIndex = 0; messageIndex < messages.length; messageIndex++) {
		const content = messages[messageIndex].content;
		if (messageIndex > 0) blocks.push({ type: "text", text: "\n\n" });
		if (typeof content === "string") {
			if (content) blocks.push({ type: "text", text: content });
			continue;
		}
		if (!Array.isArray(content)) {
			debug(`extractUserPromptBlocks: content is ${typeof content}`);
			continue;
		}
		debug(`extractUserPromptBlocks: ${content.length} blocks, types=${content.map((b: any) => b.type).join(",")}`);
		for (const block of content) {
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
	}
	return hasImage ? blocks : null;
}

export interface DeferredUserReplayPlan {
	// Index where the trailing consecutive user run begins (=== messages.length
	// when the context doesn't end in a user message).
	runStart: number;
	userMessageCount: number;
	// All trailing user messages combined into one replay prompt, or null when
	// there is nothing usable to replay (no trailing users, or all-empty text).
	prompt: string | null;
}

/** Plan replay of user messages pi injected mid-query (steer drain, followUp).
 *  Captures the ENTIRE trailing consecutive user run, not just the last
 *  message — dropping the earlier ones was silent input loss (vstack#967). */
export function planDeferredUserReplay(messages: Context["messages"]): DeferredUserReplayPlan {
	let runStart = messages.length;
	while (runStart > 0 && messages[runStart - 1]?.role === "user") runStart--;
	const trailingUsers = messages.slice(runStart);
	const prompt = trailingUsers.length > 0 ? extractUserPrompt(trailingUsers) : null;
	return {
		runStart,
		userMessageCount: trailingUsers.length,
		prompt: prompt?.trim() ? prompt : null,
	};
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
interface ClaudeAttemptFailure {
	kind?: ClaudeAccountFailureKind;
	message: string;
	rateLimitInfo?: Record<string, unknown>;
}

interface ConsumeQueryResult {
	capturedSessionId?: string;
	failure?: ClaudeAttemptFailure;
}

async function consumeQuery(
	sdkQuery: ReturnType<typeof query>,
	// The CAPTURED context of the query being consumed, never the live ctx():
	// an MCP tool can push a reentrant subagent context while this iterator is
	// suspended, and reading live state then would consult the WRONG query — a
	// recovered success could retain its failure and surface an error, or a
	// child session id could stamp the subagent's context.
	queryCtx: QueryContext,
	customToolNameToPi: Map<string, string>,
	model: Model<any>,
	bridgeConfig: Config,
	wasAborted: () => boolean,
	account?: ClaudeAccountRoute,
	router?: ClaudeAccountRouterV1,
): Promise<ConsumeQueryResult> {
	let capturedSessionId: string | undefined;
	let failure: ClaudeAttemptFailure | undefined;
	let accountProbe: Promise<void> | undefined;

	for await (const message of sdkQuery) {
		if (wasAborted()) break;
		activeStreamIdleWatchdogs.get(queryCtx)?.noteChunk();
		if (account) {
			debug("consumeQuery: managed message", JSON.stringify({
				type: message.type,
				subtype: (message as any).subtype,
				error: (message as any).error,
				eventType: (message as any).event?.type,
				deltaType: (message as any).event?.delta?.type,
				contentType: (message as any).event?.content_block?.type,
			}));
		}
		if (!queryCtx.turnOutput) continue;
		if (!queryCtx.currentPiStream && !(message.type === "assistant" && queryCtx.turnSawToolCall)) continue;

		switch (message.type) {
			case "stream_event":
				processStreamEvent(message, customToolNameToPi, model);
				break;
			case "assistant": {
				// Claude Code emits a synthetic assistant text block carrying friendly
				// rate/auth error copy before the SDK throws. On a managed attempt it
				// is not model output: forwarding it would commit the stream and make
				// safe pre-output account failover impossible, so hold it as failure
				// metadata. A legacy attempt renders it exactly as before.
				const sdkError = (message as any).error;
				if (sdkError && account) {
					if (!failure) failure = { kind: classifyClaudeFailure(sdkError), message: String(sdkError) };
					break;
				}
				processAssistantMessage(message, model, customToolNameToPi);
				break;
			}
			case "result":
				// A failure signal followed by a result whose visible output already
				// committed (e.g. the SDK's fallback-model reroute recovering after a
				// rejected rate limit) means the query ultimately SUCCEEDED: the
				// failure was informational and must neither surface an error after
				// the answer nor skip session persistence.
				if (failure && message.subtype === "success" && queryCtx.committedOutput) {
					debug(`consumeQuery: clearing informational ${failure.kind ?? "unclassified"} failure — query recovered with committed output`);
					failure = undefined;
				}
				// The SDK can label the synthetic friendly error carrier as a
				// successful result immediately before its iterator throws. Once a
				// managed attempt holds a terminal failure signal, that text is still
				// error metadata, not assistant output.
				if (account && failure) break;
				if (!queryCtx.turnSawStreamEvent && message.subtype === "success") {
					const text = message.result || "";
					// The no-stream-events assistant fallback may have already rendered
					// this exact text (it does not set turnSawStreamEvent) — re-pushing
					// it here is the other half of the duplicated-output bug.
					if (queryCtx.turnBlocks.some((b: any) => b.type === "text" && b.text === text)) {
						debug("consumeQuery: result text already rendered by assistant fallback; skipping duplicate");
						break;
					}
					ensureTurnStarted(queryCtx);
					queryCtx.turnBlocks.push({ type: "text", text });
					const idx = queryCtx.turnBlocks.length - 1;
					queryCtx.currentPiStream?.push({ type: "text_start", contentIndex: idx, partial: queryCtx.turnOutput });
					queryCtx.currentPiStream?.push({ type: "text_delta", contentIndex: idx, delta: text, partial: queryCtx.turnOutput });
					queryCtx.currentPiStream?.push({ type: "text_end", contentIndex: idx, content: text, partial: queryCtx.turnOutput });
				} else if (message.subtype !== "success") {
					const errorLines = Array.isArray((message as any).errors) ? uniqueNonEmptyLines((message as any).errors) : [];
					const errors = errorLines.length > 0 ? errorLines.join("\n") : String((message as any).result || message.subtype || "Claude Code request failed");
					const usageLimit = isUsageLimitMessage(message);
					if (!failure || !failure.rateLimitInfo) {
						failure = { kind: usageLimit ? "rate-limit" : classifyClaudeFailure(errors), message: errors };
					}
					// Managed attempts keep terminal error copy buffered as metadata so
					// a pre-output failure can move to another subscription profile.
					if (account) break;
					if (usageLimit) {
						// isUsageLimitMessage matches the CLI's own usage-limit copy (SDK
						// USAGE_LIMIT_ERROR_PREFIXES). Surface it immediately, exactly as
						// before, and suppress the SDK's raw follow-up throw.
						queryCtx.handledTerminalError = true;
						queryCtx.turnOutput.stopReason = "error";
						queryCtx.turnOutput.errorMessage = errors;
						queryCtx.currentPiStream?.push({ type: "error", reason: "error", error: queryCtx.turnOutput });
						queryCtx.currentPiStream?.end();
						queryCtx.currentPiStream = null;
					}
					// Other non-success subtypes (error_max_turns,
					// error_during_execution) surface at completion via the held
					// failure — an explicit error event where these turns previously
					// ended silently. Session persistence and deferred replay still run.
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
					if (account && router && !accountProbe) {
						accountProbe = Promise.allSettled([
							sdkQuery.accountInfo().then((info) => router.recordIdentity(account.profileId, {
								email: info.email,
								organization: info.organization,
								subscriptionType: info.subscriptionType,
							})),
							sdkQuery.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET()
								.then((usage) => router.recordUsage(account.profileId, usage)),
						]).then(() => undefined);
					}
				} else if ((message as any).subtype === "model_refusal_fallback") {
					const originalModel = (message as any).original_model;
					const fallbackModel = (message as any).fallback_model;
					updateTurnOutputModel(fallbackModel);
					debug("consumeQuery: model_refusal_fallback", JSON.stringify({ originalModel, fallbackModel }));
					// Notify only for reroutes we configured, so an unexpected pairing from
					// Claude Code is still logged above but not announced as one of ours.
					if (typeof fallbackModel === "string" && typeof originalModel === "string" && fallbackModelForPrimaryModel(originalModel) === fallbackModel) {
						safeNotify(
							`Pi Claude switched ${modelDisplayName(originalModel)} to ${modelDisplayName(fallbackModel)} after Claude Code safety fallback.`,
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
				const info = (message as any).rate_limit_info as Record<string, unknown> | undefined;
				debug("consumeQuery: rate_limit_event", JSON.stringify(info).slice(0, 300));
				if (info?.status === "rejected") {
					const rateLimitType = rateLimitTypeFromInfo(info);
					const resetAt = rateLimitResetFromInfo(info);
					const resetAtMs = rateLimitResetMs(info);
					const reason = `${rateLimitType ?? "unknown"} rate limit`;
					if (account && router) {
						// Rotation may still recover this request, so hold the rejection
						// as failure metadata and teach the router the reset time now.
						// Surfacing (event + toast) happens once in surfaceFailure — only
						// if the attempt is not replayed on another profile.
						failure = { kind: "rate-limit", message: reason, rateLimitInfo: info };
						router.recordRateLimit(account.profileId, info, model.id);
					} else {
						// Legacy: notify once and set NO failure state. The SDK's own
						// fallback-model path may still stream a successful recovery, and
						// that turn must complete exactly like any other success.
						const resetsAt = formatResetTimestamp(resetAtMs ?? resetAt);
						emitRateLimitEvent({
							model: model.id,
							provider: model.provider,
							rateLimitType,
							reason,
							resetAt,
							...(Number.isFinite(resetAtMs) ? { resetAtMs } : {}),
							source: "claude-bridge",
							status: "rejected",
						});
						piUI?.notify(`${RATE_LIMIT_TOKEN} Claude ${reason} hit — resets ${resetsAt}`, "warning");
					}
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

	if (accountProbe) {
		await Promise.race([
			accountProbe,
			new Promise<void>((resolve) => setTimeout(resolve, 1_500)),
		]);
	}
	debug(`consumeQuery: for-await loop exited, wasAborted=${wasAborted()}, capturedSessionId=${capturedSessionId?.slice(0, 8) ?? "none"}, failure=${failure?.kind ?? "none"}`);
	return { capturedSessionId, failure };
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
	if (g[CLAUDE_BRIDGE_ACCOUNT_HOST_SYMBOL] === BRIDGE_ACCOUNT_HOST) {
		g[CLAUDE_BRIDGE_ACCOUNT_HOST_SYMBOL] = undefined;
	}
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
	const credentialed = hasClaudeCredentials() || Boolean(resolveClaudeAccountRouter());
	debug(`${trigger}: native registration upsert, credentialed=${credentialed} (module=${moduleInstanceId})`);
	// Start the connector inventory now, not on the first turn: the query path
	// can only read a synchronous snapshot, so priming here is what gets the
	// declarations in place before turn 1 (vstack#832). Fire and forget —
	// registration must not wait on the network. Primes the DEFAULT credential
	// scope only; managed profiles are primed per request in their own scope.
	if (hasClaudeCredentials() && connectorsEnabledFor(loadConfig(process.cwd()))) primeConnectorServers();
	// Claim ordering: stream guard BEFORE registerProvider so a concurrent
	// subagent can never observe a registered provider without an owner.
	g[ACTIVE_STREAM_SIMPLE_KEY] = streamClaudeAgentSdk;
	try {
		nativeProviderInstance ??= buildNativeProvider(
			_piAi,
			MODELS,
			streamClaudeAgentSdk as (...args: unknown[]) => unknown,
			process.env,
			// Availability includes a companion account pool: the router owns
			// credentials the direct existence probes cannot see.
			() => hasClaudeCredentials() || Boolean(resolveClaudeAccountRouter()),
		);
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
 *  Two cases: tool result delivery (active query) or fresh query. Exported for
 *  the rotation-stream unit tests, which drive it with a fake SDK factory. */
export function streamClaudeAgentSdk(model: Model<any>, context: Context, options?: SimpleStreamOptions): AssistantMessageEventStream {
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
		// The cursor may only advance over messages actually captured for replay:
		// claiming Claude owns a user message that was never deferred is permanent
		// silent input loss (vstack#967 — only the LAST of several trailing user
		// messages was captured while the cursor skipped them all).
		let capturedThrough = context.messages.length;
		if (lastMsgRole === "user") {
			const replay = planDeferredUserReplay(context.messages);
			if (replay.prompt) {
				ctx().deferredUserMessages.push(replay.prompt);
				debug(`provider: deferred ${replay.userMessageCount} user message(s) for replay after query: ${replay.prompt.slice(0, 60)}`);
			} else {
				capturedThrough = replay.runStart;
				diagDump("deferred_user_replay_skipped", {
					contextLength: context.messages.length,
					runStart: replay.runStart,
					userMessageCount: replay.userMessageCount,
					messageRoles: context.messages.map((m, i) => `[${i}]${m.role}`).join(" "),
				});
			}
		}

		if (sharedSession) sharedSession.cursor = capturedThrough;
		queryCtx.latestCursor = Math.max(queryCtx.latestCursor, capturedThrough);
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
	// if neither a direct Claude login nor a companion account pool exists,
	// (a) re-upsert the provider (primary-only) so pi's availability recompute
	// hides the models, and (b) fail this request with a clear, actionable
	// message instead of letting the SDK spawn die with a generic error. The
	// check is cheap (existsSync + env reads only, no credential contents).
	if (!hasClaudeCredentials() && !resolveClaudeAccountRouter()) {
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
	ctx().committedOutput = false;

	// --- Account routing (optional) ---
	// A companion router selects the subscription profile for this attempt.
	// Rotation state rides the options object so a retry re-entry excludes the
	// profiles that already failed this request.
	const router = resolveClaudeAccountRouter();
	const rotationOptions = options as BridgeStreamOptions | undefined;
	const rotationState: RotationRequestState = rotationOptions?.[ROTATION_STATE_KEY] ?? {
		excludedProfileIds: new Set<string>(),
		attempts: 0,
	};
	let account: ClaudeAccountRoute | undefined;
	if (router) {
		try {
			account = router.acquire({
				modelId: model.id,
				sessionId: options?.sessionId,
				excludedProfileIds: [...rotationState.excludedProfileIds],
				forceRerank: rotationState.attempts > 0,
				reason: rotationState.attempts > 0 ? "automatic-failover" : undefined,
			});
			rotationState.attempts += 1;
		} catch (error) {
			// No profile is available (all cooling down / none configured). Fail
			// the request before spawning anything, carrying the router's reset
			// hint so pi-qol can schedule an auto-resume.
			const message = error instanceof Error ? error.message : String(error);
			const resetAtMs = Number((error as { resetAtMs?: unknown })?.resetAtMs);
			const rateLimitType = (error as { rateLimitType?: unknown })?.rateLimitType;
			if (ctx().turnOutput) {
				ctx().turnOutput.stopReason = "error";
				ctx().turnOutput.errorMessage = message;
				if (Number.isFinite(resetAtMs)) {
					Object.assign(ctx().turnOutput as AssistantMessage & Record<string, unknown>, { resetAtMs, rateLimitType });
				}
			}
			if (Number.isFinite(resetAtMs)) {
				emitRateLimitEvent({
					model: model.id,
					provider: model.provider,
					rateLimitType: rateLimitType ?? "all_accounts",
					reason: message,
					resetAt: new Date(resetAtMs).toISOString(),
					resetAtMs,
					source: "claude-bridge",
					status: "rejected",
				});
			}
			const errorOutput = ctx().turnOutput!;
			if (isReentrant) popContext();
			queueMicrotask(() => {
				stream.push({ type: "error", reason: "error", error: errorOutput });
				stream.end();
			});
			return stream;
		}
	}
	const queryModel = account?.modelId && account.modelId !== model.id
		? { ...model, id: account.modelId, name: modelDisplayName(account.modelId) }
		: model;
	if (queryModel.id !== model.id) {
		// Stamp the output model on EVERY attempt (each retry resets turn state),
		// but toast each distinct model at most once per request: with up to 16
		// rotation attempts, every retry re-enters this block and would otherwise
		// repeat an identical switch notice. A DIFFERENT model first selected
		// mid-rotation still announces itself.
		updateTurnOutputModel(queryModel.id);
		if (rotationState.announcedModelId !== queryModel.id) {
			rotationState.announcedModelId = queryModel.id;
			safeNotify(
				account?.fallbackReason === "fable-quota"
					? `Every ready account rejected Claude Fable; using ${modelDisplayName(queryModel.id)}.`
					: `Pi Claude switched to ${modelDisplayName(queryModel.id)}.`,
				"info",
			);
		}
	}
	// Buffer protocol setup events until the first visible output so a failed
	// pre-output attempt can be retried on another profile without leaking a
	// duplicate `start` frame into Pi. The query context is captured ONCE here:
	// commit can fire while a reentrant subagent context is pushed, and stamping
	// the live ctx() then would mark the WRONG query as committed and leave this
	// one replayable after visible output.
	const attemptCtx = ctx();
	const attemptBuffer = account
		? new RetryEventBuffer(stream, () => attemptCtx.markOutputCommitted())
		: undefined;
	if (attemptBuffer) attemptCtx.currentPiStream = attemptBuffer as unknown as AssistantMessageEventStream;

	const { mcpTools, customToolNameToSdk, customToolNameToPi } = resolveMcpTools(context);

	// Config + executable preflight run BEFORE syncSharedSession on purpose: the
	// sync's REBUILD path is destructive (deleteSession + createSession + save),
	// so a misconfigured executable must fail this query while the previous
	// session file is still intact.
	const bridgeConfig = loadConfig(cwd);
	const providerSettings = bridgeConfig.provider ?? {};
	const claudeExecutable = resolveClaudeExecutable(providerSettings.pathToClaudeCodeExecutable);
	const claudeExecutablePreflight = claudeExecutable ? preflightClaudeExecutable(claudeExecutable, cwd) : undefined;

	const accountScope = accountSessionScope(account);
	const cursorBeforeSync = sharedSession?.cursor ?? null;
	const { sessionId: resumeSessionId, promptStart } = syncSharedSession(context.messages, cwd, customToolNameToSdk, queryModel.id, accountScope);
	const promptMessages = context.messages.slice(promptStart);
	const promptBlocks = extractUserPromptBlocks(promptMessages);
	let promptText = extractUserPrompt(promptMessages) ?? "";

	// Guard: a prompt with no usable content means the last context message
	// isn't a user message (or the batch was all-empty — joined batches turn ""
	// into "\n\n", so test the trimmed text, not truthiness). Should never
	// happen with the state stack fix — dump diagnostics if it does.
	if (!promptText.trim() && !promptBlocks) {
		diagDump("empty_prompt", {
			contextLength: context.messages.length,
			lastMsgRole: lastMsg?.role,
			isReentrant,
			stackDepth: stackDepth(),
			activeQueryExists: ctx().activeQuery !== null,
			cursorBeforeSync,
			promptStart,
			promptRoles: promptMessages.map((m) => m.role).join(" "),
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
	const connectorServers = enableCloudMcp ? connectorServersSnapshot(accountScope.claudeConfigDir) : {};
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
	// Connectors mode needs settings resolution ON but restricted to USER scope
	// only — project/local settings files can smuggle `env`/`apiKeyHelper` from
	// a hostile checkout (vstack#990). Full rationale on settingSourcesForQuery.
	const settingSources: SettingSource[] | undefined = settingSourcesForQuery(
		enableCloudMcp, appendSystemPrompt, providerSettings.settingSources);
	const strictMcpConfigEnabled = !appendSystemPrompt && providerSettings.strictMcpConfig !== false;
	// Prefer the model's own thinkingLevelMap when present (pi-ai 0.72+ ships
	// per-model overrides — e.g. opus-4-7 wants xhigh→xhigh, not xhigh→max).
	// Fall back to our generic table for older pi-ai or unmapped levels.
	const requestedEffort = options?.reasoning
		? ((queryModel as any).thinkingLevelMap?.[options.reasoning] as EffortLevel | undefined)
			?? REASONING_TO_EFFORT[options.reasoning]
		: undefined;
	const effort = resolveConfiguredEffort(queryModel.id, requestedEffort, providerSettings);

	const extraArgs: Record<string, string | null> = {};
	// Opus 4.7 defaults thinking.display to "omitted" (empty thinking text in stream).
	// Force summarized so thinking_delta events arrive. See anthropics/claude-agent-sdk-python#830.
	// Deliberately the raw flag, NOT the typed `thinking` option: every non-disabled
	// ThinkingConfig also emits `--thinking adaptive` or `--max-thinking-tokens`
	// (verified in sdk.mjs flag mapping), so the typed form cannot set display
	// without overriding the model's thinking mode alongside our `--effort`.
	if (effort) extraArgs["thinking-display"] = "summarized";
	// With a managed Fable pool, let every account's model-scoped allowance run
	// out (rotation) before changing models — the CLI's own Opus fallback would
	// silently skip accounts whose Fable quota is still available. Once the
	// router explicitly selects Opus, its normal Opus→4.8 safety fallback is
	// back on.
	const fallbackModel = account && model.id === FABLE_MODEL_ID && queryModel.id === model.id
		? undefined
		: fallbackModelForPrimaryModel(queryModel.id);

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
	const childEnv = {
		...(account ? subscriberProfileEnv(account) : process.env),
		ENABLE_CLAUDEAI_MCP_SERVERS: enableCloudMcp ? "1" : "0",
		DISABLE_AUTO_COMPACT: "1",
	};
	const queryOptions: NonNullable<Parameters<typeof query>[0]["options"]> = {
		cwd,
		model: queryModel.id,
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
		`model=${queryModel.id} requested=${model.id} msgs=${context.messages.length} tools=${mcpTools.length}`,
		`resume=${resumeSessionId?.slice(0, 8) ?? "none"} effort=${effort ?? "default"} account=${account?.label ?? "legacy"}`,
		`fallback=${fallbackModel ?? "none"}`,
		`appendSys=${appendSystemPrompt} promptCtx=${promptContextAppend.labels.join(",") || "none"} strictMcp=${strictMcpConfigEnabled} fastMode=${providerSettings.fastMode === true} connectors=${enableCloudMcp}`,
		`claudeExec=${claudeExecutablePreflight ? `${claudeExecutablePreflight.fileType}:${claudeExecutablePreflight.path}` : "sdk-default"}`,
		`prompt=${promptText.slice(0, 60)}${promptBlocks ? " [+images]" : ""}`);

	// 3. Start SDK query and claim it for this context
	let wasAborted = false;
	let streamIdleTimedOut = false;
	let retryRequested = false;
	let retryFailure: ClaudeAttemptFailure | undefined;
	const sdkQuery = sdkQueryFactory({ prompt, options: queryOptions });
	ctx().activeQuery = sdkQuery;

	// 4. Capture context for abort handling (must be AFTER pushContext)
	const abortCtx = ctx();
	let accountFailureRecorded = false;
	const recordAttemptFailure = (failure: ClaudeAttemptFailure): void => {
		// Rate-limit failures carry rateLimitInfo and were already recorded via
		// router.recordRateLimit in consumeQuery.
		if (
			accountFailureRecorded || !account || !router || !failure.kind ||
			failure.rateLimitInfo || wasAborted || options?.signal?.aborted
		) return;
		router.recordFailure(account.profileId, failure.kind, queryModel.id);
		accountFailureRecorded = true;
	};

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
				if (sharedSession) setSharedSession({ ...sharedSession, needsRebuild: true, forceRotate: true });
				const errorMessage = buildStreamIdleTimeoutErrorMessage(timeoutMs);
				debug("provider: stream idle timeout", `model=${queryModel.id}`, `timeout=${timeoutMs}`, `idle=${idleMs}`);
				const idleFailure: ClaudeAttemptFailure = { kind: "network", message: errorMessage };
				recordAttemptFailure(idleFailure);
				// A managed attempt that went idle before ANY visible output can move
				// to the next profile instead of surfacing the timeout.
				if (account && router && !abortCtx.committedOutput && attemptBuffer?.hasCommittedOutput !== true && rotationState.attempts < 16) {
					rotationState.excludedProfileIds.add(account.profileId);
					retryRequested = true;
					retryFailure = idleFailure;
					attemptBuffer?.discard();
					abortCtx.currentPiStream = null;
					requestAbort();
					return;
				}
				abortCtx.handledTerminalError = true;
				emitRateLimitEvent({
					idleMs,
					model: queryModel.id,
					provider: queryModel.provider,
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
		reportToolResultMismatch(abortCtx, "abort", cwd, {
			expectedInterruption: true,
			forceRotate: true,
		});
		const drained = drainPendingToolCalls(abortCtx, "abort");
		if (drained > 0) debug(`provider: abort drained ${drained} waiting MCP handler(s) as errors`);
		abortCtx.pendingResults.clear();
		requestAbort();
	};
	if (options?.signal) {
		if (options.signal.aborted) onAbort();
		else options.signal.addEventListener("abort", onAbort, { once: true });
	}

	// Decide whether a classified failure may be replayed on the next profile.
	// Records the failure with the router either way (a post-output failure is
	// not replayable but the next prompt's routing should still avoid the
	// unhealthy account). The buffer's own committed flag backs up the context
	// flag in case the two ever disagree.
	const requestRotation = (failure: ClaudeAttemptFailure): boolean => {
		recordAttemptFailure(failure);
		const committed = abortCtx.committedOutput || attemptBuffer?.hasCommittedOutput === true;
		const eligible = Boolean(account && router && failure.kind && !committed && !wasAborted && !options?.signal?.aborted && rotationState.attempts < 16);
		debug("provider: account rotation decision", JSON.stringify({
			eligible,
			account: account?.label,
			kind: failure.kind,
			committedOutput: committed,
			wasAborted,
			signalAborted: options?.signal?.aborted === true,
			attempts: rotationState.attempts,
		}));
		if (!eligible || !account || !router || !failure.kind) return false;
		rotationState.excludedProfileIds.add(account.profileId);
		retryRequested = true;
		retryFailure = failure;
		attemptBuffer?.discard();
		abortCtx.currentPiStream = null;
		debug(`provider: rotating account after ${failure.kind}, from=${account.label}, attempt=${rotationState.attempts}`);
		return true;
	};

	const surfaceFailure = (failure: ClaudeAttemptFailure, aborted = false): void => {
		attemptBuffer?.commit();
		if (failure.rateLimitInfo) {
			// Managed rate-limit that will NOT rotate — this is the single place its
			// event + toast are emitted (the legacy path emitted inline instead).
			const info = failure.rateLimitInfo;
			const resetAt = rateLimitResetFromInfo(info);
			const resetAtMs = rateLimitResetMs(info);
			emitRateLimitEvent({
				model: queryModel.id, provider: queryModel.provider, rateLimitType: rateLimitTypeFromInfo(info),
				reason: failure.message, resetAt,
				...(Number.isFinite(resetAtMs) ? { resetAtMs } : {}),
				source: "claude-bridge", status: "rejected",
			});
			piUI?.notify(`${RATE_LIMIT_TOKEN} Claude ${failure.message} — resets ${formatResetTimestamp(resetAtMs ?? resetAt)}`, "warning");
		}
		if (abortCtx.turnOutput) {
			abortCtx.turnOutput.stopReason = aborted ? "aborted" : "error";
			abortCtx.turnOutput.errorMessage = failure.message;
		}
		abortCtx.currentPiStream?.push({ type: "error", reason: aborted ? "aborted" : "error", error: abortCtx.turnOutput! });
		abortCtx.currentPiStream?.end();
		abortCtx.currentPiStream = null;
	};

	// Background consumer — runs until this attempt's query ends. Before any
	// visible output, a classified failure on a managed attempt is replayed once
	// on each remaining profile; after output/connector dispatch, replay is
	// forbidden and the failure surfaces.
	// The handlers below use the CAPTURED abortCtx, never the live ctx(): the two
	// only differ while a reentrant (subagent) context is pushed, and a parent
	// query CAN end in that window (abort, child process death throwing out of
	// the generator). Live-ctx handlers there mutated the subagent's turn state
	// and stream and skipped the parent's own teardown entirely.
	consumeQuery(sdkQuery, abortCtx, customToolNameToPi, queryModel, bridgeConfig, () => wasAborted, account, router)
		.then(async ({ capturedSessionId, failure }) => {
			debug(`provider: consumeQuery completed, stopReason=${abortCtx.turnOutput?.stopReason}, failure=${failure?.kind ?? "none"}, aborted=${wasAborted}`);
			if (streamIdleTimedOut) {
				abortCtx.deferredUserMessages = [];
				debug(`provider: stream idle timeout ${retryRequested ? "queued account rotation" : "already surfaced"}; skipping normal completion`);
				return;
			}

			// --- Abort detection in normal completion path ---
			if (wasAborted || options?.signal?.aborted) {
				if (sharedSession) setSharedSession({ ...sharedSession, needsRebuild: true, forceRotate: true });
				abortCtx.deferredUserMessages = [];
				debug(`provider: abort detected, marked sharedSession needsRebuild + forceRotate`);
				surfaceFailure({ message: "Operation aborted" }, true);
				return;
			}

			// --- Failure held by consumeQuery ---
			if (failure) {
				if (requestRotation(failure)) return;
				// Not replayable (legacy, post-output, unclassified, or attempts
				// exhausted): surface an explicit error — unless the usage-limit path
				// already did — and persist the session record: the child session
				// advanced through this query, so dropping it would force a full
				// rebuild next turn. But NEVER run the deferred-replay loop from
				// here — surfacing ended the Pi stream, so a continuation query's
				// output would be invisible while its tool side effects still
				// execute. Deferred user input is dropped, as on main's pre-router
				// failure paths.
				if (!abortCtx.handledTerminalError) surfaceFailure(failure);
				abortCtx.deferredUserMessages = [];
				const failedSessionId = capturedSessionId ?? sharedSession?.sessionId;
				if (failedSessionId) {
					const cursor = Math.max(context.messages.length, abortCtx.latestCursor, sharedSession?.cursor ?? 0);
					debug(`provider: terminal failure, persisting session=${failedSessionId.slice(0, 8)}, cursor=${cursor}, account=${account?.label ?? "legacy"}`);
					setSharedSession({ sessionId: failedSessionId, cursor, cwd, ...accountScope });
				}
				return;
			}

			// --- Capture session ID ---
			const sessionId = capturedSessionId ?? sharedSession?.sessionId;
			if (sessionId) {
				const cursor = Math.max(context.messages.length, abortCtx.latestCursor, sharedSession?.cursor ?? 0);
				debug(`provider: query done, session=${sessionId.slice(0, 8)}, cursor=${cursor}, account=${account?.label ?? "legacy"}`);
				// Fresh record on purpose: a transient mid-turn needsRebuild/forceRotate
				// must not survive a completed query and force a rebuild next turn.
				setSharedSession({ sessionId, cursor, cwd, ...accountScope });
			}
			// The failure branch above returned, so reaching here means success.
			if (account && router) router.recordSuccess(account.profileId, options?.sessionId);

			// --- Replay deferred user messages as continuation queries ---
			// Only for outermost queries — reentrant (subagent) queries leave
			// deferred messages for the parent to handle after it finishes.
			try {
				while (abortCtx.deferredUserMessages.length > 0 && !isReentrant && !wasAborted) {
					const steerPrompt = abortCtx.deferredUserMessages.shift()!;
					debug(`provider: replaying deferred user message: ${steerPrompt.slice(0, 60)}`);
					abortCtx.resetTurnState(queryModel);
					abortCtx.resetToolTracking();

					const resumeId = sharedSession?.sessionId;
					if (!resumeId) {
						debug(`WARNING: no session to resume for deferred message, dropping`);
						break;
					}

					const contOptions = { ...queryOptions, resume: resumeId, ...makeCliDebugOptions("continuation") };
					const contQuery = sdkQueryFactory({ prompt: steerPrompt, options: contOptions });
					abortCtx.activeQuery = contQuery;

					debug(`provider: continuation query, model=${queryModel.id}, resume=${resumeId.slice(0, 8)}, account=${account?.label ?? "legacy"}, prompt=${steerPrompt.slice(0, 60)}`);

					try {
						const continuation = await consumeQuery(contQuery, abortCtx, customToolNameToPi, queryModel, bridgeConfig, () => wasAborted, account, router);
						if (continuation.failure) {
							// Continuations never rotate: the original prompt already
							// committed on this account.
							recordAttemptFailure(continuation.failure);
							if (!abortCtx.handledTerminalError) surfaceFailure(continuation.failure);
							break;
						}
						const sid = continuation.capturedSessionId ?? sharedSession?.sessionId;
						if (sid) {
							setSharedSession({ sessionId: sid, cursor: sharedSession?.cursor ?? 0, cwd, ...accountScope });
						}
					} catch (contError) {
						debug(`provider: continuation query error:`, contError);
						const continuationFailure: ClaudeAttemptFailure = {
							kind: classifyClaudeFailure(contError),
							message: contError instanceof Error ? contError.message : String(contError),
						};
						recordAttemptFailure(continuationFailure);
						if (!abortCtx.handledTerminalError) surfaceFailure(continuationFailure);
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
			debug(`provider: query error, model=${queryModel.id}, aborted=${Boolean(options?.signal?.aborted)}, error=`, error);
			const suppressDuplicateError = abortCtx.handledTerminalError || (streamIdleTimedOut && !retryRequested);
			if ((wasAborted || options?.signal?.aborted) && sharedSession) {
				setSharedSession({ ...sharedSession, needsRebuild: true, forceRotate: true });
			}
			abortCtx.deferredUserMessages = [];
			if (suppressDuplicateError || retryRequested) {
				debug("provider: suppressing duplicate query error after terminal handling");
				return;
			}
			const failure: ClaudeAttemptFailure = {
				kind: classifyClaudeFailure(error),
				message: error instanceof Error ? error.message : String(error),
			};
			if (requestRotation(failure)) return;
			if (!wasAborted && !options?.signal?.aborted) setSharedSession(null);
			surfaceFailure(failure, Boolean(options?.signal?.aborted));
		})
		.finally(() => {
			streamIdleWatchdog?.dispose();
			activeStreamIdleWatchdogs.delete(abortCtx);
			if (options?.signal) options.signal.removeEventListener("abort", onAbort);
			const cause = toolCallDrainCause({ wasAborted, signalAborted: options?.signal?.aborted, streamIdleTimedOut });
			teardownQuery(abortCtx, sdkQuery, cause, cwd, isReentrant);
			sdkQuery.close();
		})
		.then(async () => {
			// --- Account retry re-entry ---
			// Runs AFTER teardown so the failed attempt's query state is fully
			// released. The recursive call re-enters the fresh-query path with the
			// rotation state carrying the excluded profiles; its events forward
			// into this attempt's still-unstarted Pi stream.
			if (!retryRequested) return;
			if (wasAborted || options?.signal?.aborted) {
				// An abort landed AFTER rotation was queued: requestRotation already
				// discarded the attempt buffer and nulled currentPiStream, and only
				// the retry loop below would have ended the outer stream. Skipping
				// the retry without terminating here left the consumer hanging on a
				// stream that never ends.
				debug("provider: abort after queued account retry — terminating stream without retrying");
				if (abortCtx.turnOutput) {
					abortCtx.turnOutput.stopReason = "aborted";
					abortCtx.turnOutput.errorMessage = "Operation aborted";
				}
				stream.push({ type: "error", reason: "aborted", error: abortCtx.turnOutput! });
				stream.end();
				return;
			}
			debug(`provider: starting account retry after ${retryFailure?.kind ?? "failure"}; excluded=${[...rotationState.excludedProfileIds].join(",")}`);
			const retryStream = streamClaudeAgentSdk(model, context, {
				...(options ?? {}),
				[ROTATION_STATE_KEY]: rotationState,
			} as BridgeStreamOptions);
			try {
				for await (const event of retryStream) stream.push(event);
			} finally {
				stream.end();
			}
		})
		.catch((error) => {
			debug("provider: account retry pipeline failed:", error);
			if (abortCtx.turnOutput) {
				abortCtx.turnOutput.stopReason = "error";
				abortCtx.turnOutput.errorMessage = error instanceof Error ? error.message : String(error);
			}
			stream.push({ type: "error", reason: "error", error: abortCtx.turnOutput! });
			stream.end();
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
		`Pi Claude: ${config.enabled === false ? "disabled" : "enabled"}`,
		"Claude account billing settings (including Extra Usage) are managed in Claude.",
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

function connectorScopeKey(claudeConfigDir: string | undefined = process.env.CLAUDE_CONFIG_DIR): string {
	return claudeConfigDir?.trim() || "<default>";
}

// Credential resolution env for a selected scope: managed requests always pass
// their RESOLVED dir (accountSessionScope), so the parent's CLAUDE_CONFIG_DIR
// never leaks into another profile's lookup; legacy passes undefined and keeps
// the process-env rule.
function connectorCredentialEnv(claudeConfigDir: string | undefined = process.env.CLAUDE_CONFIG_DIR): NodeJS.ProcessEnv {
	const env = { ...process.env };
	if (claudeConfigDir?.trim()) env.CLAUDE_CONFIG_DIR = claudeConfigDir.trim();
	else delete env.CLAUDE_CONFIG_DIR;
	return env;
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
export function primeConnectorServers(claudeConfigDir?: string): void {
	const key = connectorScopeKey(claudeConfigDir);
	if (connectorServerCache.has(key) || connectorServerPending.has(key)) return;
	connectorServerPending.add(key);
	void (async () => {
		try {
			const credentials = resolveClaudeOAuth(readCredentialFile, connectorCredentialEnv(claudeConfigDir));
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
function connectorServersSnapshot(claudeConfigDir?: string): Record<string, unknown> {
	const key = connectorScopeKey(claudeConfigDir);
	const ready = connectorServerCache.get(key);
	if (ready) return ready;
	// Always start (or continue) the live fetch — the cache is a head start, not
	// a replacement, and the refresh keeps the next process current.
	primeConnectorServers(claudeConfigDir);
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
async function reportConnectorInventory(ctx: {
	ui: ExtensionUIContext;
	model?: Model<any>;
	sessionManager?: { getSessionId?: () => string };
}): Promise<void> {
	// With a router active, enumerate the CURRENT route's account rather than
	// whatever the process env points at.
	const account = ctx.model
		? resolveClaudeAccountRouter()?.current(ctx.model.id, ctx.sessionManager?.getSessionId?.())
		: undefined;
	const credentials = resolveClaudeOAuth(readCredentialFile, connectorCredentialEnv(account ? accountSessionScope(account).claudeConfigDir : undefined));
	if (!credentials) {
		ctx.ui.notify("Pi Claude: no Claude OAuth credentials found — cannot enumerate connectors.", "error");
		return;
	}
	const inventory = await listAccountConnectors({ credentials });
	if (!inventory.ok) {
		ctx.ui.notify(`Pi Claude: connector enumeration failed — ${inventory.reason}`, "error");
		return;
	}
	if (inventory.connectors.length === 0) {
		ctx.ui.notify("Pi Claude: this account has no connectors installed.", "info");
		return;
	}
	const names = inventory.connectors.map((c) => c.name).join(", ");
	ctx.ui.notify(`Pi Claude: ${inventory.connectors.length} connector(s) installed — ${names}`, "info");
}

function registerBridgeCommands(pi: ExtensionAPI): void {
	const guard = pi as unknown as Record<PropertyKey, unknown>;
	if (guard[COMMANDS_REGISTERED_KEY]) return;
	guard[COMMANDS_REGISTERED_KEY] = true;

	pi.registerCommand("pi-claude", {
		description: "Open Pi Claude settings/status",
		handler: async (args: string, ctx) => {
			if (args.trim()) ctx.ui.notify("Unknown /pi-claude argument.", "warning");
			if (await tryOpenExtensionManagerSettings(ctx)) return;
			showBridgeStatus(ctx);
		},
	});
	pi.registerCommand("pi-claude:connectors", {
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
	// Publish the reciprocal account-host service (a local /usage probe) for the
	// companion account manager. Primary instance only — a subagent reload must
	// not swap the owner from under an in-flight probe.
	if (claimPrimaryInstance()) {
		const host = globalThis as Record<symbol, any>;
		host[CLAUDE_BRIDGE_ACCOUNT_HOST_SYMBOL] = BRIDGE_ACCOUNT_HOST;
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
		cancelScheduledSessionPersistence();
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
