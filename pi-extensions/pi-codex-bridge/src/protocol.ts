// The one module that narrows values read from `codex app-server`. Every
// other module consumes the typed results below and never casts wire data.
// A value that does not have the shape Codex 0.163.0 documents is refused with
// `codex-protocol-invalid method=<method> field=<field>`.

export type RequestId = number | string;
export type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };
export type JsonObject = { [key: string]: JsonValue };

function invalid(method: string, field: string): Error {
	return new Error(`codex-protocol-invalid method=${method} field=${field}`);
}

function isObject(value: unknown): value is JsonObject {
	return value !== null && typeof value === "object" && !Array.isArray(value);
}

function object(value: unknown, method: string, field: string): JsonObject {
	if (!isObject(value)) throw invalid(method, field);
	return value;
}

function string(value: unknown, method: string, field: string): string {
	if (typeof value !== "string") throw invalid(method, field);
	return value;
}

function nullableString(value: unknown, method: string, field: string): string | null {
	if (value === null || value === undefined) return null;
	return string(value, method, field);
}

function array(value: unknown, method: string, field: string): unknown[] {
	if (!Array.isArray(value)) throw invalid(method, field);
	return value;
}

function count(value: unknown, method: string, field: string): number {
	if (typeof value !== "number" || !Number.isFinite(value) || value < 0) throw invalid(method, field);
	return value;
}

// --- JSON-RPC frames ---------------------------------------------------------

export type ServerFrame =
	| { kind: "response"; id: RequestId; result: unknown }
	| { kind: "error"; id: RequestId; code: number | null; message: string }
	| { kind: "request"; id: RequestId; method: string; params: JsonObject }
	| { kind: "notification"; method: string; params: JsonObject };

function requestId(value: unknown): RequestId {
	if (typeof value === "string" || (typeof value === "number" && Number.isInteger(value))) return value;
	throw invalid("jsonrpc", "id");
}

/** Classify one parsed line. `decodeResult` runs on a response's result before
 * this returns, so a response it narrows never leaves the parse whole. */
export function decodeFrame(value: unknown, decodeResult: (id: RequestId, result: unknown) => unknown): ServerFrame {
	const frame = object(value, "jsonrpc", "frame");
	const method = frame.method;
	if (method === undefined) {
		const id = requestId(frame.id);
		if (frame.error !== undefined) {
			const error = isObject(frame.error) ? frame.error : {};
			return {
				kind: "error",
				id,
				code: typeof error.code === "number" ? error.code : null,
				message: typeof error.message === "string" ? error.message : "",
			};
		}
		return { kind: "response", id, result: decodeResult(id, frame.result) };
	}
	const name = string(method, "jsonrpc", "method");
	const params = frame.params === undefined || frame.params === null ? {} : object(frame.params, name, "params");
	if (frame.id === undefined) return { kind: "notification", method: name, params };
	return { kind: "request", id: requestId(frame.id), method: name, params };
}

// --- Version -----------------------------------------------------------------

/** `codex --version` prints `codex-cli <version>`. */
export function decodeVersion(stdout: string): string {
	const match = /^codex-cli (\S+)\s*$/.exec(stdout);
	if (!match) throw invalid("--version", "stdout");
	return match[1];
}

// --- Responses ---------------------------------------------------------------

export interface CodexModel {
	model: string;
	displayName: string;
	hidden: boolean;
	inputModalities: string[];
	reasoningEfforts: string[];
}

export function decodeModelPage(result: unknown): { models: CodexModel[]; nextCursor: string | null } {
	const method = "model/list";
	const page = object(result, method, "result");
	const models = array(page.data, method, "data").map((raw): CodexModel => {
		const model = object(raw, method, "data[]");
		return {
			model: string(model.model, method, "data[].model"),
			displayName: string(model.displayName, method, "data[].displayName"),
			hidden: model.hidden === true,
			inputModalities: array(model.inputModalities, method, "data[].inputModalities")
				.map((entry) => string(entry, method, "data[].inputModalities[]")),
			reasoningEfforts: array(model.supportedReasoningEfforts, method, "data[].supportedReasoningEfforts")
				.map((entry) => string(object(entry, method, "data[].supportedReasoningEfforts[]").reasoningEffort, method, "data[].supportedReasoningEfforts[].reasoningEffort")),
		};
	});
	return { models, nextCursor: nullableString(page.nextCursor, method, "nextCursor") };
}

export function decodeThreadStart(result: unknown): { threadId: string } {
	const method = "thread/start";
	const thread = object(object(result, method, "result").thread, method, "thread");
	return { threadId: string(thread.id, method, "thread.id") };
}

/** The resumed thread and the id of its latest turn, read from the one-turn
 * `initialTurnsPage` the bridge asks for. */
export function decodeThreadResume(result: unknown): { threadId: string; lastTurnId: string | null } {
	const method = "thread/resume";
	const response = object(result, method, "result");
	const thread = object(response.thread, method, "thread");
	const page = object(response.initialTurnsPage, method, "initialTurnsPage");
	const turns = array(page.data, method, "initialTurnsPage.data");
	const last = turns.length === 0 ? null : string(object(turns[0], method, "initialTurnsPage.data[0]").id, method, "initialTurnsPage.data[0].id");
	return { threadId: string(thread.id, method, "thread.id"), lastTurnId: last };
}

export function decodeTurnStart(result: unknown): { turnId: string } {
	const method = "turn/start";
	const turn = object(object(result, method, "result").turn, method, "turn");
	return { turnId: string(turn.id, method, "turn.id") };
}

/**
 * The server names of the merged `config.mcp_servers`, and nothing else.
 *
 * `config/read` returns the whole effective configuration, each server's
 * command, args and env values included. The JSON-RPC client runs this
 * decoder inside the parse of the response line, so what the parse returns
 * is this list of names: no command, argument, env value or other config
 * field outlives the parse, and nothing here logs, writes or sends one.
 */
export function decodeMcpServerNames(result: unknown): string[] {
	const method = "config/read";
	const config = object(object(result, method, "result").config, method, "config");
	const servers = config.mcp_servers;
	if (servers === undefined || servers === null) return [];
	return Object.keys(object(servers, method, "config.mcp_servers")).sort();
}

export function decodeFeaturePage(result: unknown): { enabled: string[]; nextCursor: string | null } {
	const method = "experimentalFeature/list";
	const page = object(result, method, "result");
	const enabled: string[] = [];
	for (const raw of array(page.data, method, "data")) {
		const feature = object(raw, method, "data[]");
		const name = string(feature.name, method, "data[].name");
		if (typeof feature.enabled !== "boolean") throw invalid(method, "data[].enabled");
		if (feature.enabled) enabled.push(name);
	}
	return { enabled, nextCursor: nullableString(page.nextCursor, method, "nextCursor") };
}

// --- Server requests ---------------------------------------------------------

export interface DynamicToolCall {
	threadId: string;
	turnId: string;
	callId: string;
	namespace: string | null;
	tool: string;
	arguments: JsonObject;
}

export function decodeDynamicToolCall(params: JsonObject): DynamicToolCall {
	const method = "item/tool/call";
	return {
		threadId: string(params.threadId, method, "threadId"),
		turnId: string(params.turnId, method, "turnId"),
		callId: string(params.callId, method, "callId"),
		namespace: nullableString(params.namespace, method, "namespace"),
		tool: string(params.tool, method, "tool"),
		arguments: object(params.arguments, method, "arguments"),
	};
}

/** The thread a server request names, where it names one. */
export function requestThreadId(params: JsonObject): string | null {
	return typeof params.threadId === "string" ? params.threadId : null;
}

// --- Notifications -----------------------------------------------------------

export interface TokenUsage {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	total: number;
}

export type TurnStatus = "completed" | "interrupted" | "failed";

export type CodexEvent =
	| { type: "agentDelta"; threadId: string; turnId: string; itemId: string; delta: string }
	| { type: "reasoningDelta"; threadId: string; turnId: string; itemId: string; delta: string }
	| { type: "itemStarted"; threadId: string; turnId: string; itemType: string }
	| { type: "agentMessageCompleted"; threadId: string; turnId: string; itemId: string; text: string }
	| { type: "turnStarted"; threadId: string; turnId: string }
	| { type: "turnCompleted"; threadId: string; turnId: string; status: TurnStatus; error: string | null }
	| { type: "tokenUsage"; threadId: string; turnId: string; usage: TokenUsage }
	| { type: "mcpStartup"; name: string; status: string }
	| { type: "ignored"; method: string };

function usage(value: unknown, method: string): TokenUsage {
	const last = object(object(value, method, "tokenUsage").last, method, "tokenUsage.last");
	return {
		input: count(last.inputTokens, method, "tokenUsage.last.inputTokens"),
		output: count(last.outputTokens, method, "tokenUsage.last.outputTokens"),
		cacheRead: count(last.cachedInputTokens, method, "tokenUsage.last.cachedInputTokens"),
		cacheWrite: count(last.cacheWriteInputTokens, method, "tokenUsage.last.cacheWriteInputTokens"),
		total: count(last.totalTokens, method, "tokenUsage.last.totalTokens"),
	};
}

export function decodeEvent(method: string, params: JsonObject): CodexEvent {
	switch (method) {
		case "item/agentMessage/delta":
		case "item/reasoning/summaryTextDelta":
			return {
				type: method === "item/agentMessage/delta" ? "agentDelta" : "reasoningDelta",
				threadId: string(params.threadId, method, "threadId"),
				turnId: string(params.turnId, method, "turnId"),
				itemId: string(params.itemId, method, "itemId"),
				delta: string(params.delta, method, "delta"),
			};
		case "item/started": {
			const item = object(params.item, method, "item");
			return {
				type: "itemStarted",
				threadId: string(params.threadId, method, "threadId"),
				turnId: string(params.turnId, method, "turnId"),
				itemType: string(item.type, method, "item.type"),
			};
		}
		case "item/completed": {
			const item = object(params.item, method, "item");
			if (item.type !== "agentMessage") return { type: "ignored", method };
			return {
				type: "agentMessageCompleted",
				threadId: string(params.threadId, method, "threadId"),
				turnId: string(params.turnId, method, "turnId"),
				itemId: string(item.id, method, "item.id"),
				text: string(item.text, method, "item.text"),
			};
		}
		case "turn/started":
			return {
				type: "turnStarted",
				threadId: string(params.threadId, method, "threadId"),
				turnId: string(object(params.turn, method, "turn").id, method, "turn.id"),
			};
		case "turn/completed": {
			const turn = object(params.turn, method, "turn");
			const status = string(turn.status, method, "turn.status");
			if (status !== "completed" && status !== "interrupted" && status !== "failed") throw invalid(method, "turn.status");
			const error = turn.error === null || turn.error === undefined ? null : object(turn.error, method, "turn.error");
			return {
				type: "turnCompleted",
				threadId: string(params.threadId, method, "threadId"),
				turnId: string(turn.id, method, "turn.id"),
				status,
				error: error === null ? null : nullableString(error.message, method, "turn.error.message"),
			};
		}
		case "thread/tokenUsage/updated":
			return {
				type: "tokenUsage",
				threadId: string(params.threadId, method, "threadId"),
				turnId: string(params.turnId, method, "turnId"),
				usage: usage(params.tokenUsage, method),
			};
		case "mcpServer/startupStatus/updated":
			return {
				type: "mcpStartup",
				name: string(params.name, method, "name"),
				status: string(params.status, method, "status"),
			};
		default:
			return { type: "ignored", method };
	}
}
