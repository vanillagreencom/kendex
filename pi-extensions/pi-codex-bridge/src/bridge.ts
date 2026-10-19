import {
	collapseSystemMessages,
	createAssistantMessageEventStream,
	getCurrentSystemPrompt,
	getCurrentTools,
	type AssistantMessage,
	type AssistantMessageEventStream,
	type ImageContent,
	type Message,
	type Model,
	type SimpleStreamOptions,
	type TextContent,
	type ToolResultMessage,
	type TranscriptContext,
} from "@earendil-works/pi-ai";
import { startAppServer } from "./app-server.js";
import { buildDynamicTools, type DynamicToolCatalog } from "./dynamic-tools.js";
import type { DynamicToolCall, JsonObject, JsonValue, RequestId, ServerMessage } from "./protocol.js";
import { deliverToolResults, type PendingToolCall } from "./tool-pairing.js";

const PROVIDER_ID = "pi-codex";
const API_ID = "codex-app-server";

interface BridgeSession {
	client: ProtocolClient;
	threadId: string;
	modelId: string;
	toolSignature: string;
	tools: DynamicToolCatalog;
	pending: Map<string, PendingToolCall>;
	activeTurnId?: string;
}

export interface ProtocolClient {
	request(method: string, params?: JsonObject): Promise<unknown>;
	respond(id: RequestId, result: unknown): void;
	respondError(id: RequestId, code: number, message: string): void;
	close(): void;
	on(event: "request" | "notification" | "closed", listener: (message: ServerMessage) => void): this;
	off(event: "request" | "notification" | "closed", listener: (message: ServerMessage) => void): this;
}

type StartClient = (executable: string, codexHome: string, env: NodeJS.ProcessEnv) => Promise<ProtocolClient>;

interface ThreadResponse {
	thread: { id: string };
}

interface TurnResponse {
	turn: { id: string };
}

function asObject(value: unknown, key: string): JsonObject {
	if (value === null || typeof value !== "object" || Array.isArray(value)) {
		throw new Error(`codex-protocol-invalid-${key}`);
	}
	return value as JsonObject;
}

function emptyUsage(): AssistantMessage["usage"] {
	return {
		input: 0,
		output: 0,
		cacheRead: 0,
		cacheWrite: 0,
		totalTokens: 0,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
	};
}

function outputMessage(model: Model<string>, threadId?: string): AssistantMessage {
	return {
		role: "assistant",
		content: [],
		api: API_ID,
		provider: PROVIDER_ID,
		model: model.id,
		responseId: threadId,
		usage: emptyUsage(),
		stopReason: "pending",
		timestamp: Date.now(),
	};
}

function textInput(content: string | Array<TextContent | ImageContent>): Array<JsonObject> {
	if (typeof content === "string") return [{ type: "text", text: content, text_elements: [] }];
	return content.map((item): JsonObject => {
		if (item.type === "text") return { type: "text", text: item.text, text_elements: [] };
		return { type: "image", url: `data:${item.mimeType};base64,${item.data}` };
	});
}

function serializedHistory(messages: Message[]): string {
	return messages
		.filter((message) => message.role !== "system")
		.map((message) => {
			if (message.role === "user") {
				const text = typeof message.content === "string"
					? message.content
					: message.content.filter((item) => item.type === "text").map((item) => item.text).join("\n");
				return `User:\n${text}`;
			}
			if (message.role === "assistant") {
				const text = message.content.filter((item) => item.type === "text").map((item) => item.text).join("\n");
				return `Assistant:\n${text}`;
			}
			return `Tool ${message.toolName}:\n${message.content.filter((item) => item.type === "text").map((item) => item.text).join("\n")}`;
		})
		.join("\n\n");
}

function latestThreadId(messages: Message[]): string | undefined {
	for (let index = messages.length - 1; index >= 0; index--) {
		const message = messages[index];
		if (message.role === "assistant" && message.provider === PROVIDER_ID && message.responseId) {
			return message.responseId;
		}
	}
	return undefined;
}

function inputAfterThreadMessage(messages: Message[], threadId: string | undefined): Array<JsonObject> {
	if (threadId === undefined) {
		return [{ type: "text", text: serializedHistory(messages), text_elements: [] }];
	}
	let boundary = -1;
	for (let index = messages.length - 1; index >= 0; index--) {
		const message = messages[index];
		if (message.role === "assistant" && message.responseId === threadId) {
			boundary = index;
			break;
		}
	}
	return messages.slice(boundary + 1).flatMap((message) => message.role === "user" ? textInput(message.content) : []);
}

function toolResultsAfterThreadMessage(messages: Message[], threadId: string): ToolResultMessage[] {
	let boundary = -1;
	for (let index = messages.length - 1; index >= 0; index--) {
		const message = messages[index];
		if (message.role === "assistant" && message.responseId === threadId) {
			boundary = index;
			break;
		}
	}
	return messages.slice(boundary + 1).filter((message): message is ToolResultMessage => message.role === "toolResult");
}

function responseThread(value: unknown): ThreadResponse {
	const result = asObject(value, "thread-response");
	const thread = asObject(result.thread, "thread");
	if (typeof thread.id !== "string") throw new Error("codex-protocol-invalid-thread-id");
	return { thread: { id: thread.id } };
}

function responseTurn(value: unknown): TurnResponse {
	const result = asObject(value, "turn-response");
	const turn = asObject(result.turn, "turn");
	if (typeof turn.id !== "string") throw new Error("codex-protocol-invalid-turn-id");
	return { turn: { id: turn.id } };
}

function dynamicToolCall(message: ServerMessage): DynamicToolCall {
	const params = asObject(message.params, "dynamic-tool-call");
	if (
		typeof params.threadId !== "string"
		|| typeof params.turnId !== "string"
		|| typeof params.callId !== "string"
		|| (params.namespace !== null && typeof params.namespace !== "string")
		|| typeof params.tool !== "string"
	) throw new Error("codex-protocol-invalid-dynamic-tool-call");
	return {
		threadId: params.threadId,
		turnId: params.turnId,
		callId: params.callId,
		namespace: params.namespace,
		tool: params.tool,
		arguments: asObject(params.arguments, "dynamic-tool-arguments"),
	};
}

function updateUsage(output: AssistantMessage, params: JsonObject): void {
	const tokenUsage = asObject(params.tokenUsage, "token-usage");
	const last = asObject(tokenUsage.last, "token-usage-last");
	const input = typeof last.inputTokens === "number" ? last.inputTokens : 0;
	const outputTokens = typeof last.outputTokens === "number" ? last.outputTokens : 0;
	const cacheRead = typeof last.cachedInputTokens === "number" ? last.cachedInputTokens : 0;
	const cacheWrite = typeof last.cacheWriteInputTokens === "number" ? last.cacheWriteInputTokens : 0;
	output.usage = {
		input,
		output: outputTokens,
		cacheRead,
		cacheWrite,
		totalTokens: typeof last.totalTokens === "number" ? last.totalTokens : input + outputTokens,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
	};
}

export class CodexBridge {
	readonly executable: string;
	readonly codexHome: string;
	readonly cwd: string;
	readonly env: NodeJS.ProcessEnv;
	readonly startClient: StartClient;
	#sessions = new Map<string, BridgeSession>();

	constructor(options: {
		executable?: string;
		codexHome: string;
		cwd?: string;
		env?: NodeJS.ProcessEnv;
		startClient?: StartClient;
	}) {
		this.executable = options.executable ?? "codex";
		this.codexHome = options.codexHome;
		this.cwd = options.cwd ?? process.cwd();
		this.env = options.env ?? process.env;
		this.startClient = options.startClient ?? startAppServer;
	}

	streamSimple = (
		model: Model<string>,
		context: TranscriptContext,
		options?: SimpleStreamOptions,
	): AssistantMessageEventStream => {
		const stream = createAssistantMessageEventStream();
		void this.#run(stream, model, context, options);
		return stream;
	};

	async close(): Promise<void> {
		for (const session of this.#sessions.values()) session.client.close();
		this.#sessions.clear();
	}

	async #session(
		model: Model<string>,
		threadId: string | undefined,
		tools: DynamicToolCatalog,
		systemPrompt: string,
	): Promise<BridgeSession> {
		const existing = threadId === undefined ? undefined : this.#sessions.get(threadId);
		if (existing) {
			if (existing.modelId !== model.id) throw new Error("codex-model-changed-start-new-session");
			if (existing.toolSignature !== tools.signature) throw new Error("codex-tool-set-changed-start-new-session");
			return existing;
		}

		const client = await this.startClient(this.executable, this.codexHome, this.env);
		if (threadId !== undefined) {
			const resumed = responseThread(await client.request("thread/resume", {
				threadId,
				model: model.id,
				cwd: this.cwd,
				approvalPolicy: "never",
				sandbox: "read-only",
			}));
			const session = {
				client,
				threadId: resumed.thread.id,
				modelId: model.id,
				toolSignature: tools.signature,
				tools,
				pending: new Map<string, PendingToolCall>(),
			};
			this.#sessions.set(session.threadId, session);
			return session;
		}

		const started = responseThread(await client.request("thread/start", {
			model: model.id,
			cwd: this.cwd,
			approvalPolicy: "never",
			sandbox: "read-only",
			baseInstructions: systemPrompt,
			dynamicTools: tools.declarations as unknown as JsonValue,
			ephemeral: false,
		}));
		const session = {
			client,
			threadId: started.thread.id,
			modelId: model.id,
			toolSignature: tools.signature,
			tools,
			pending: new Map<string, PendingToolCall>(),
		};
		this.#sessions.set(session.threadId, session);
		return session;
	}

	async #run(
		stream: AssistantMessageEventStream,
		model: Model<string>,
		context: TranscriptContext,
		options?: SimpleStreamOptions,
	): Promise<void> {
		const transcript = collapseSystemMessages(context);
		const tools = buildDynamicTools(getCurrentTools(transcript.messages));
		let output = outputMessage(model);
		let session: BridgeSession | undefined;
		let ended = false;
		let textIndex: number | undefined;
		let thinkingIndex: number | undefined;
		let toolEndTimer: NodeJS.Timeout | undefined;

		const cleanup = () => {
			if (toolEndTimer !== undefined) clearTimeout(toolEndTimer);
			if (session) {
				session.client.off("request", onRequest);
				session.client.off("notification", onNotification);
				session.client.off("closed", onClosed);
			}
			options?.signal?.removeEventListener("abort", onAbort);
		};

		const fail = (error: unknown) => {
			if (ended) return;
			ended = true;
			cleanup();
			if (session) {
				session.client.close();
				this.#sessions.delete(session.threadId);
			}
			output.stopReason = options?.signal?.aborted ? "aborted" : "error";
			output.errorMessage = error instanceof Error ? error.message : "codex-bridge-error";
			stream.push({ type: "error", reason: output.stopReason, error: output });
			stream.end();
		};

		const finishToolBatch = () => {
			if (ended || !session || session.pending.size === 0) return;
			ended = true;
			cleanup();
			output.stopReason = "toolUse";
			stream.push({ type: "done", reason: "toolUse", message: output });
			stream.end();
		};

		const onRequest = (message: ServerMessage) => {
			if (ended || !session || message.id === undefined || typeof message.method !== "string") return;
			if (message.method !== "item/tool/call") {
				const key = message.method === "account/chatgptAuthTokens/refresh"
					? "codex-credential-refresh-refused"
					: "codex-native-tool-refused";
				session.client.respondError(message.id, -32601, key);
				fail(new Error(`${key} method=${message.method}`));
				return;
			}
			try {
				const call = dynamicToolCall(message);
				if (call.threadId !== session.threadId || call.turnId !== session.activeTurnId) {
					throw new Error("codex-tool-call-session-mismatch");
				}
				if (call.namespace !== null) throw new Error("codex-tool-call-namespace-refused");
				const piToolName = session.tools.piNameByCodexName.get(call.tool);
				if (!piToolName) throw new Error(`codex-tool-call-unknown tool=${call.tool}`);
				if (session.pending.has(call.callId)) throw new Error(`codex-tool-call-duplicate call=${call.callId}`);
				session.pending.set(call.callId, { requestId: message.id as RequestId, params: call, piToolName });
				const contentIndex = output.content.length;
				const toolCall = { type: "toolCall" as const, id: call.callId, name: piToolName, arguments: call.arguments };
				output.content.push(toolCall);
				stream.push({ type: "toolcall_start", contentIndex, partial: output });
				stream.push({ type: "toolcall_end", contentIndex, toolCall, partial: output });
				if (toolEndTimer !== undefined) clearTimeout(toolEndTimer);
				toolEndTimer = setTimeout(finishToolBatch, 0);
			} catch (error) {
				session.client.respondError(message.id, -32602, "codex-tool-call-refused");
				fail(error);
			}
		};

		const onNotification = (message: ServerMessage) => {
			if (ended || !session || typeof message.method !== "string") return;
			try {
				const params = asObject(message.params ?? {}, "notification");
				if (typeof params.threadId === "string" && params.threadId !== session.threadId) return;
				if (typeof params.turnId === "string" && session.activeTurnId && params.turnId !== session.activeTurnId) return;
				if (message.method === "item/agentMessage/delta") {
					if (typeof params.delta !== "string") throw new Error("codex-protocol-invalid-agent-delta");
					if (textIndex === undefined) {
						textIndex = output.content.length;
						output.content.push({ type: "text", text: "" });
						stream.push({ type: "text_start", contentIndex: textIndex, partial: output });
					}
					const content = output.content[textIndex];
					if (content.type !== "text") throw new Error("codex-text-state-invalid");
					content.text += params.delta;
					stream.push({ type: "text_delta", contentIndex: textIndex, delta: params.delta, partial: output });
					return;
				}
				if (message.method === "item/reasoning/summaryTextDelta") {
					if (typeof params.delta !== "string") throw new Error("codex-protocol-invalid-reasoning-delta");
					if (thinkingIndex === undefined) {
						thinkingIndex = output.content.length;
						output.content.push({ type: "thinking", thinking: "" });
						stream.push({ type: "thinking_start", contentIndex: thinkingIndex, partial: output });
					}
					const content = output.content[thinkingIndex];
					if (content.type !== "thinking") throw new Error("codex-thinking-state-invalid");
					content.thinking += params.delta;
					stream.push({ type: "thinking_delta", contentIndex: thinkingIndex, delta: params.delta, partial: output });
					return;
				}
				if (message.method === "thread/tokenUsage/updated") {
					updateUsage(output, params);
					return;
				}
				if (message.method !== "turn/completed") return;
				const turn = asObject(params.turn, "completed-turn");
				if (turn.id !== session.activeTurnId) return;
				if (turn.status === "completed") {
					ended = true;
					cleanup();
					if (thinkingIndex !== undefined) {
						const content = output.content[thinkingIndex];
						if (content.type === "thinking") stream.push({ type: "thinking_end", contentIndex: thinkingIndex, content: content.thinking, partial: output });
					}
					if (textIndex !== undefined) {
						const content = output.content[textIndex];
						if (content.type === "text") stream.push({ type: "text_end", contentIndex: textIndex, content: content.text, partial: output });
					}
					session.activeTurnId = undefined;
					output.stopReason = "stop";
					stream.push({ type: "done", reason: "stop", message: output });
					stream.end();
					return;
				}
				if (turn.status === "interrupted") {
					fail(new Error("codex-turn-interrupted"));
					return;
				}
				fail(new Error("codex-turn-failed"));
			} catch (error) {
				fail(error);
			}
		};

		const onClosed = () => fail(new Error("codex-app-server-closed"));
		const onAbort = () => {
			if (!session?.activeTurnId || ended) return;
			void session.client.request("turn/interrupt", {
				threadId: session.threadId,
				turnId: session.activeTurnId,
			}).catch(fail);
		};

		try {
			const threadId = latestThreadId(transcript.messages);
			session = await this.#session(model, threadId, tools, getCurrentSystemPrompt(transcript.messages));
			output = outputMessage(model, session.threadId);
			stream.push({ type: "start", partial: output });
			session.client.on("request", onRequest);
			session.client.on("notification", onNotification);
			session.client.on("closed", onClosed);
			options?.signal?.addEventListener("abort", onAbort, { once: true });

			if (session.pending.size > 0) {
				const results = toolResultsAfterThreadMessage(transcript.messages, session.threadId);
				deliverToolResults(session.client, session.pending, results);
				return;
			}

			if (session.activeTurnId !== undefined) throw new Error("codex-turn-already-active");
			const turn = responseTurn(await session.client.request("turn/start", {
				threadId: session.threadId,
				input: inputAfterThreadMessage(transcript.messages, threadId),
				model: model.id,
				effort: options?.reasoning ?? null,
			}));
			session.activeTurnId = turn.turn.id;
		} catch (error) {
			fail(error);
		}
	}
}
