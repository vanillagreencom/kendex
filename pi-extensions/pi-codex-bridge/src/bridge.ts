import {
	collapseSystemMessages,
	createAssistantMessageEventStream,
	getCurrentSystemPrompt,
	getCurrentTools,
	type AssistantMessage,
	type AssistantMessageEventStream,
	type Message,
	type Model,
	type SimpleStreamOptions,
	type TranscriptContext,
} from "@earendil-works/pi-ai";
import { listCodexModels, startAppServer, type Launch } from "./app-server.js";
import { requireCodexLogin } from "./auth-presence.js";
import { ALLOWED_ITEM_TYPES, APPROVAL_POLICY, threadConfig, unreviewedFeature } from "./codex-policy.js";
import { buildDynamicTools, type DynamicToolCatalog } from "./dynamic-tools.js";
import type { IncomingNotification, IncomingRequest, ProtocolClient } from "./json-rpc.js";
import { API_ID, codexEffort, PROVIDER_ID } from "./models.js";
import {
	decodeDynamicToolCall,
	decodeEvent,
	decodeFeaturePage,
	decodeMcpServerNames,
	decodeThreadResume,
	decodeThreadStart,
	decodeTurnStart,
	requestThreadId,
	type CodexEvent,
	type CodexModel,
	type DynamicToolCall,
	type JsonObject,
	type JsonValue,
	type RequestId,
} from "./protocol.js";
import { answerToolCalls, type PendingToolCall, type ToolCallAnswer } from "./tool-pairing.js";
import { afterBoundary, encodeResponseId, findBoundary, replayInput } from "./transcript.js";

/** Threads one bridge keeps state for; the least recently used idle one goes first. */
export const MAX_THREADS = 16;
/** Server requests and notifications one thread may hold while no stream reads them. */
export const MAX_QUEUED_EVENTS = 1024;
/** Tool calls one turn may hold open for Pi. */
export const MAX_PENDING_CALLS = 64;
/** How long model discovery may hold Pi's startup. */
export const DISCOVERY_DEADLINE_MS = 15_000;

export type Connect = (launch: Launch) => Promise<ProtocolClient>;

type Queued =
	| { kind: "event"; event: Exclude<CodexEvent, { type: "mcpStartup" | "ignored" }>; raw: unknown }
	| { kind: "toolCall"; requestId: RequestId; call: DynamicToolCall; raw: unknown }
	| { kind: "refusal"; error: Error; turnId: string | null };

/** Everything Codex sends for one thread, kept in arrival order until a
 * stream reads it, so a request that arrives between two Pi streams waits for
 * the next one instead of being dropped. */
class ThreadQueue {
	#items: Queued[] = [];
	#wake: (() => void) | undefined;
	#full = false;

	push(item: Queued): void {
		if (this.#full) return;
		if (this.#items.length >= MAX_QUEUED_EVENTS - 1) {
			this.#full = true;
			this.#items.push({ kind: "refusal", error: new Error(`codex-request-queue-full limit=${MAX_QUEUED_EVENTS}`), turnId: null });
		} else {
			this.#items.push(item);
		}
		this.#wake?.();
	}

	async next(): Promise<Queued> {
		while (this.#items.length === 0) await new Promise<void>((resolve) => (this.#wake = resolve));
		this.#wake = undefined;
		return this.#items.shift()!;
	}

	/** The tool call at the head of the queue, taken, if one is there. */
	takeToolCall(): Extract<Queued, { kind: "toolCall" }> | undefined {
		const head = this.#items[0];
		if (head?.kind !== "toolCall") return undefined;
		this.#items.shift();
		return head;
	}
}

interface ThreadRecord {
	threadId: string;
	tools: DynamicToolCatalog;
	/** The latest turn the bridge started on this thread. */
	lastTurnId: string | null;
	/** That turn while Codex has not completed it. */
	activeTurnId: string | null;
	/** Calls of the active turn that wait for Pi's results, in arrival order. */
	pending: PendingToolCall[];
	queue: ThreadQueue;
	streaming: boolean;
	lastUsed: number;
}

type Plan =
	| { record: ThreadRecord; mode: "turn"; input: JsonObject[] }
	| { record: ThreadRecord; mode: "continue"; input: JsonObject[]; answers: ToolCallAnswer[] };

function emptyUsage(): AssistantMessage["usage"] {
	return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
}

function firstLine(error: unknown): string {
	return (error instanceof Error ? error.message : "codex-bridge-error").split("\n", 1)[0];
}

export interface BridgeOptions {
	codexHome: string;
	executable?: string;
	cwd?: string;
	env?: NodeJS.ProcessEnv;
	/** Test seam: extra `-c` launch overrides. */
	configOverrides?: readonly string[];
	/** Test seam: how a launch becomes a connected client. */
	connect?: Connect;
}

/**
 * One bridge per Pi extension runtime. It owns one `codex app-server` child,
 * the table of threads it drives, each thread's queue of server requests and
 * notifications, and the tool calls waiting on Pi. `close` releases all of it.
 */
export class CodexBridge {
	readonly codexHome: string;
	readonly #launch: Launch;
	readonly #connect: Connect;
	#client: Promise<ProtocolClient> | undefined;
	#current: ProtocolClient | undefined;
	#threads = new Map<string, ThreadRecord>();

	constructor(options: BridgeOptions) {
		this.codexHome = options.codexHome;
		this.#launch = {
			executable: options.executable ?? "codex",
			codexHome: options.codexHome,
			cwd: options.cwd ?? process.cwd(),
			env: options.env ?? process.env,
			configOverrides: options.configOverrides ?? [],
		};
		this.#connect = options.connect ?? ((launch) => startAppServer(launch));
	}

	/** Pi's stream entry point. A missing login throws before any process starts. */
	streamSimple = (model: Model<string>, context: TranscriptContext, options?: SimpleStreamOptions): AssistantMessageEventStream => {
		requireCodexLogin(this.codexHome);
		const stream = createAssistantMessageEventStream();
		void this.#run(stream, model, context, options);
		return stream;
	};

	/** The account's models through this bridge's own client, bounded by a
	 * deadline so a stalled Codex cannot hold Pi's startup. */
	async discoverModels(deadlineMs = DISCOVERY_DEADLINE_MS): Promise<{ models: CodexModel[]; notice?: string }> {
		let timer: NodeJS.Timeout | undefined;
		const deadline = new Promise<never>((_, reject) => {
			timer = setTimeout(() => reject(new Error(`codex-discovery-timeout after_ms=${deadlineMs}`)), deadlineMs);
		});
		try {
			const client = await Promise.race([this.#client ??= this.#open(), deadline]);
			return { models: await Promise.race([listCodexModels(client), deadline]) };
		} catch (error) {
			this.#closeClient(error instanceof Error ? error : new Error("codex-discovery-failed"));
			return { models: [], notice: firstLine(error) };
		} finally {
			clearTimeout(timer);
		}
	}

	async close(): Promise<void> {
		this.#closeClient(new Error("codex-bridge-closed"));
		this.#threads.clear();
	}

	// --- Client and router ---------------------------------------------------

	#open(): Promise<ProtocolClient> {
		const opening = this.#connect(this.#launch).then((client) => {
			if (this.#client !== opening) {
				client.kill(new Error("codex-bridge-closed"));
				throw new Error("codex-bridge-closed");
			}
			this.#current = client;
			client.on("request", (frame) => this.#onRequest(client, frame));
			client.on("notification", (frame) => this.#onNotification(client, frame));
			client.on("closed", (error) => this.#onClosed(client, error));
			return client;
		});
		opening.catch(() => {
			if (this.#client === opening) this.#client = undefined;
		});
		return opening;
	}

	#closeClient(reason: Error): void {
		const opening = this.#client;
		this.#client = undefined;
		this.#current?.kill(reason);
		this.#current = undefined;
		opening?.then((client) => client.kill(reason), () => undefined);
	}

	#onClosed(client: ProtocolClient, error: Error): void {
		if (this.#current !== client) return;
		this.#current = undefined;
		this.#client = undefined;
		for (const record of this.#threads.values()) record.queue.push({ kind: "refusal", error, turnId: null });
		this.#threads.clear();
	}

	/** A guard that cannot be held by refusing one turn: stop the child and
	 * every process it started, and fail every stream on it. */
	#breach(client: ProtocolClient, error: Error): void {
		client.kill(error);
	}

	#interrupt(client: ProtocolClient, record: ThreadRecord): void {
		if (record.activeTurnId === null) return;
		void client.request("turn/interrupt", { threadId: record.threadId, turnId: record.activeTurnId }).catch(() => undefined);
	}

	/** Refuse the turn a server request belongs to; a request no thread of
	 * this bridge owns is a breach. */
	#refuse(client: ProtocolClient, threadId: string | null, error: Error): void {
		const records = threadId === null
			? [...this.#threads.values()].filter((record) => record.activeTurnId !== null)
			: [this.#threads.get(threadId)];
		for (const record of records) {
			if (record === undefined) {
				this.#breach(client, new Error(`codex-foreign-thread thread=${threadId}`));
				return;
			}
			this.#interrupt(client, record);
			record.queue.push({ kind: "refusal", error, turnId: record.activeTurnId });
		}
	}

	#onNotification(client: ProtocolClient, frame: IncomingNotification): void {
		let event: CodexEvent;
		try {
			event = decodeEvent(frame.method, frame.params);
		} catch (error) {
			this.#breach(client, error as Error);
			return;
		}
		if (event.type === "ignored") return;
		if (event.type === "mcpStartup") {
			if (event.status === "starting") this.#breach(client, new Error(`codex-mcp-started name=${event.name}`));
			return;
		}
		const record = this.#threads.get(event.threadId);
		if (record === undefined) {
			if (event.type === "turnStarted" || event.type === "itemStarted") {
				this.#breach(client, new Error(`codex-foreign-thread thread=${event.threadId}`));
			}
			return;
		}
		if (event.type === "itemStarted" && !ALLOWED_ITEM_TYPES.has(event.itemType)) {
			this.#interrupt(client, record);
			record.queue.push({ kind: "refusal", error: new Error(`codex-native-item type=${event.itemType}`), turnId: event.turnId });
			return;
		}
		record.queue.push({ kind: "event", event, raw: frame });
	}

	#onRequest(client: ProtocolClient, frame: IncomingRequest): void {
		const { id, method, params } = frame;
		if (method === "item/tool/call") {
			let call: DynamicToolCall;
			try {
				call = decodeDynamicToolCall(params);
			} catch (error) {
				client.respondError(id, -32602, "codex-tool-call-refused");
				this.#refuse(client, requestThreadId(params), error as Error);
				return;
			}
			const record = this.#threads.get(call.threadId);
			if (record === undefined) {
				client.respondError(id, -32602, "codex-tool-call-refused");
				this.#breach(client, new Error(`codex-foreign-thread thread=${call.threadId}`));
				return;
			}
			record.queue.push({ kind: "toolCall", requestId: id, call, raw: frame });
			return;
		}
		let error: Error;
		if (method === "item/commandExecution/requestApproval" || method === "item/fileChange/requestApproval") {
			client.respond(id, { decision: "decline" });
			error = new Error(`codex-native-approval-declined method=${method}`);
		} else if (method === "execCommandApproval" || method === "applyPatchApproval") {
			client.respond(id, { decision: "abort" });
			error = new Error(`codex-native-approval-declined method=${method}`);
		} else if (method === "account/chatgptAuthTokens/refresh") {
			client.respondError(id, -32601, "codex-credential-refresh-refused");
			error = new Error(`codex-credential-refresh-refused method=${method}`);
		} else {
			client.respondError(id, -32601, "codex-server-request-refused");
			error = new Error(`codex-server-request-refused method=${method}`);
		}
		this.#refuse(client, requestThreadId(params), error);
	}

	// --- Threads -------------------------------------------------------------

	#register(record: ThreadRecord): void {
		this.#threads.delete(record.threadId);
		this.#threads.set(record.threadId, record);
		while (this.#threads.size > MAX_THREADS) {
			const idle = [...this.#threads.values()]
				.filter((candidate) => candidate !== record && !candidate.streaming && candidate.activeTurnId === null)
				.sort((a, b) => a.lastUsed - b.lastUsed)[0];
			if (idle === undefined) throw new Error(`codex-thread-table-full limit=${MAX_THREADS}`);
			this.#threads.delete(idle.threadId);
		}
	}

	#record(threadId: string, tools: DynamicToolCatalog, lastTurnId: string | null): ThreadRecord {
		return { threadId, tools, lastTurnId, activeTurnId: null, pending: [], queue: new ThreadQueue(), streaming: false, lastUsed: Date.now() };
	}

	/** Answer a turn the bridge no longer continues, so Codex does not wait on
	 * it, and stop it. */
	#abandon(client: ProtocolClient, record: ThreadRecord): void {
		for (const answer of answerToolCalls(record.pending, [])) client.respond(answer.requestId, answer.result);
		record.pending = [];
		this.#interrupt(client, record);
		record.activeTurnId = null;
	}

	/** Names only: `config/read` is decoded to the configured MCP server names
	 * inside its own parse. A read that fails refuses the thread. */
	async #mcpServerNames(client: ProtocolClient): Promise<string[]> {
		try {
			return await client.requestDecoded("config/read", { cwd: this.#launch.cwd }, decodeMcpServerNames);
		} catch (error) {
			throw new Error(`codex-mcp-names-unread\n${firstLine(error)}`);
		}
	}

	/** Refuse a thread on which any feature no review covers is enabled, before
	 * its first turn. */
	async #auditFeatures(client: ProtocolClient, threadId: string): Promise<void> {
		const enabled: string[] = [];
		let cursor: string | null = null;
		do {
			const page: { enabled: string[]; nextCursor: string | null } = await client.requestDecoded("experimentalFeature/list", { threadId, ...(cursor === null ? {} : { cursor }) }, decodeFeaturePage);
			enabled.push(...page.enabled);
			cursor = page.nextCursor;
		} while (cursor !== null);
		const unreviewed = unreviewedFeature(enabled);
		if (unreviewed !== undefined) throw new Error(`codex-feature-unreviewed name=${unreviewed}`);
	}

	async #startThread(client: ProtocolClient, model: Model<string>, messages: Message[], tools: DynamicToolCatalog): Promise<ThreadRecord> {
		const names = await this.#mcpServerNames(client);
		const { threadId } = await client.requestDecoded("thread/start", {
			model: model.id,
			cwd: this.#launch.cwd,
			approvalPolicy: APPROVAL_POLICY,
			sandbox: "read-only",
			baseInstructions: getCurrentSystemPrompt(messages),
			dynamicTools: tools.declarations as unknown as JsonValue,
			ephemeral: false,
			environments: [],
			config: threadConfig(names),
		}, decodeThreadStart);
		const record = this.#record(threadId, tools, null);
		this.#register(record);
		try {
			await this.#auditFeatures(client, threadId);
		} catch (error) {
			this.#threads.delete(threadId);
			throw error;
		}
		return record;
	}

	/** A cold resume, used only when Codex's latest turn is Pi's boundary. */
	async #resumeThread(client: ProtocolClient, model: Model<string>, threadId: string, turnId: string, tools: DynamicToolCatalog): Promise<ThreadRecord | undefined> {
		const names = await this.#mcpServerNames(client);
		const resumed = await client.requestDecoded("thread/resume", {
			threadId,
			model: model.id,
			cwd: this.#launch.cwd,
			approvalPolicy: APPROVAL_POLICY,
			sandbox: "read-only",
			config: threadConfig(names),
			excludeTurns: true,
			initialTurnsPage: { limit: 1, sortDirection: "desc", itemsView: "notLoaded" },
		}, decodeThreadResume);
		if (resumed.lastTurnId !== turnId) return undefined;
		const record = this.#record(resumed.threadId, tools, turnId);
		this.#register(record);
		try {
			await this.#auditFeatures(client, record.threadId);
		} catch (error) {
			this.#threads.delete(record.threadId);
			throw error;
		}
		return record;
	}

	/**
	 * Which Codex thread serves this transcript. Pi's latest clean pi-codex
	 * message names a thread, a turn and a tool signature. The bridge continues
	 * that thread only when the signature matches Pi's current tools and the
	 * thread's latest turn is that turn; otherwise it starts a new thread and
	 * replays the transcript, so Codex never holds turns Pi has dropped or calls
	 * a tool Pi no longer has.
	 */
	async #plan(client: ProtocolClient, model: Model<string>, messages: Message[], tools: DynamicToolCatalog): Promise<Plan> {
		const boundary = findBoundary(messages);
		if (boundary !== undefined && boundary.toolSignature === tools.signature) {
			const after = afterBoundary(messages, boundary);
			const record = this.#threads.get(boundary.threadId);
			if (record !== undefined) {
				if (boundary.stopReason === "toolUse" && record.activeTurnId === boundary.turnId && record.pending.length > 0) {
					return { record, mode: "continue", input: after.input, answers: answerToolCalls(record.pending, after.toolResults) };
				}
				if (boundary.stopReason === "stop" && record.activeTurnId === null && record.lastTurnId === boundary.turnId) {
					return { record, mode: "turn", input: after.input };
				}
				this.#abandon(client, record);
			} else if (boundary.stopReason === "stop") {
				const resumed = await this.#resumeThread(client, model, boundary.threadId, boundary.turnId, tools);
				if (resumed !== undefined) return { record: resumed, mode: "turn", input: after.input };
			}
		}
		const record = await this.#startThread(client, model, messages, tools);
		return { record, mode: "turn", input: replayInput(messages) };
	}

	// --- Streams -------------------------------------------------------------

	async #run(stream: AssistantMessageEventStream, model: Model<string>, context: TranscriptContext, options?: SimpleStreamOptions): Promise<void> {
		const output: AssistantMessage = {
			role: "assistant",
			content: [],
			api: API_ID,
			provider: PROVIDER_ID,
			model: model.id,
			usage: emptyUsage(),
			stopReason: "pending" as AssistantMessage["stopReason"],
			timestamp: Date.now(),
		};
		let record: ThreadRecord | undefined;
		let client: ProtocolClient | undefined;
		const signal = options?.signal;
		// Armed before the first await: an abort during the version check, the
		// handshake or thread setup ends the stream at once. Setup that completes
		// later leaves its child and thread with this bridge, which owns them.
		let rejectAborted: ((error: Error) => void) | undefined;
		const aborted = new Promise<never>((_, reject) => (rejectAborted = reject));
		aborted.catch(() => undefined);
		const onAbort = () => {
			rejectAborted?.(new Error("codex-request-aborted"));
			if (client !== undefined && record !== undefined) this.#interrupt(client, record);
		};
		signal?.addEventListener("abort", onAbort, { once: true });
		try {
			if (signal?.aborted) throw new Error("codex-request-aborted");
			const messages = collapseSystemMessages(context).messages;
			const tools = buildDynamicTools(getCurrentTools(messages));
			client = await Promise.race([this.#client ??= this.#open(), aborted]);
			const plan = await Promise.race([this.#plan(client, model, messages, tools), aborted]);
			record = plan.record;
			if (record.streaming) throw new Error(`codex-thread-busy thread=${record.threadId}`);
			record.streaming = true;
			record.lastUsed = Date.now();

			if (plan.mode === "continue") {
				const payload = { method: "item/tool/call", answers: plan.answers, steer: plan.input };
				const sent = ((await options?.onPayload?.(payload, model)) ?? payload) as typeof payload;
				for (const answer of sent.answers) client.respond(answer.requestId, answer.result);
				record.pending = [];
				if (sent.steer.length > 0) {
					await client.request("turn/steer", { threadId: record.threadId, expectedTurnId: record.activeTurnId, input: sent.steer });
				}
			} else {
				if (plan.input.length === 0) throw new Error("codex-turn-input-empty");
				const effort = codexEffort(model, options?.reasoning);
				const params: JsonObject = {
					threadId: record.threadId,
					input: plan.input,
					model: model.id,
					approvalPolicy: APPROVAL_POLICY,
					environments: [],
					...(effort === null ? {} : { effort }),
				};
				const sent = ((await options?.onPayload?.(params, model)) ?? params) as JsonObject;
				const { turnId } = await client.requestDecoded("turn/start", sent, decodeTurnStart);
				record.activeTurnId = turnId;
				record.lastTurnId = turnId;
			}
			await options?.onResponse?.({ status: 200, headers: {} }, model);
			output.responseId = encodeResponseId(record.threadId, record.activeTurnId!, tools.signature);
			if (signal?.aborted) throw new Error("codex-request-aborted");
			stream.push({ type: "start", partial: output });
			await this.#consume(stream, output, model, record, options);
		} catch (error) {
			if (client !== undefined && record !== undefined && record.activeTurnId !== null) this.#abandon(client, record);
			output.stopReason = signal?.aborted ? "aborted" : "error";
			output.errorMessage = error instanceof Error ? error.message : "codex-bridge-error";
			stream.push({ type: "error", reason: output.stopReason, error: output });
			stream.end();
		} finally {
			signal?.removeEventListener("abort", onAbort);
			if (record !== undefined) record.streaming = false;
		}
	}

	/** Read the thread's queue until the turn completes or Codex waits on a
	 * tool call. Codex holds a turn on each `item/tool/call` until the bridge
	 * answers it, so that request is what ends a tool batch. */
	async #consume(stream: AssistantMessageEventStream, output: AssistantMessage, model: Model<string>, record: ThreadRecord, options?: SimpleStreamOptions): Promise<void> {
		const textIndex = new Map<string, number>();
		const thinkingIndex = new Map<string, number>();
		const closeBlocks = () => {
			for (const index of thinkingIndex.values()) {
				const block = output.content[index];
				if (block.type === "thinking") stream.push({ type: "thinking_end", contentIndex: index, content: block.thinking, partial: output });
			}
			for (const index of textIndex.values()) {
				const block = output.content[index];
				if (block.type === "text") stream.push({ type: "text_end", contentIndex: index, content: block.text, partial: output });
			}
		};
		const appendText = (itemId: string, delta: string) => {
			let index = textIndex.get(itemId);
			if (index === undefined) {
				index = output.content.length;
				textIndex.set(itemId, index);
				output.content.push({ type: "text", text: "" });
				stream.push({ type: "text_start", contentIndex: index, partial: output });
			}
			const block = output.content[index];
			if (block.type !== "text") throw new Error("codex-text-state-invalid");
			block.text += delta;
			stream.push({ type: "text_delta", contentIndex: index, delta, partial: output });
		};
		const addToolCall = (requestId: RequestId, call: DynamicToolCall) => {
			if (call.turnId !== record.activeTurnId) throw new Error(`codex-tool-call-turn-mismatch turn=${call.turnId}`);
			if (call.namespace !== null) throw new Error(`codex-tool-call-namespace-refused namespace=${call.namespace}`);
			const piToolName = record.tools.piNameByCodexName.get(call.tool);
			if (piToolName === undefined) throw new Error(`codex-tool-call-unknown tool=${call.tool}`);
			if (record.pending.some((pending) => pending.callId === call.callId)) throw new Error(`codex-tool-call-duplicate call=${call.callId}`);
			if (record.pending.length >= MAX_PENDING_CALLS) throw new Error(`codex-tool-calls-full limit=${MAX_PENDING_CALLS}`);
			record.pending.push({ requestId, callId: call.callId, piToolName });
			const contentIndex = output.content.length;
			const toolCall = { type: "toolCall" as const, id: call.callId, name: piToolName, arguments: call.arguments };
			output.content.push(toolCall);
			stream.push({ type: "toolcall_start", contentIndex, partial: output });
			stream.push({ type: "toolcall_end", contentIndex, toolCall, partial: output });
		};

		while (true) {
			const item = await record.queue.next();
			if (item.kind === "refusal") {
				if (item.turnId !== null && item.turnId !== record.activeTurnId) continue;
				throw item.error;
			}
			await options?.onProviderStreamEvent?.(item.raw, model);
			if (item.kind === "toolCall") {
				addToolCall(item.requestId, item.call);
				for (let next = record.queue.takeToolCall(); next !== undefined; next = record.queue.takeToolCall()) {
					await options?.onProviderStreamEvent?.(next.raw, model);
					addToolCall(next.requestId, next.call);
				}
				closeBlocks();
				output.stopReason = "toolUse";
				stream.push({ type: "done", reason: "toolUse", message: output });
				stream.end();
				return;
			}
			const event = item.event;
			if (event.turnId !== record.activeTurnId) continue;
			switch (event.type) {
				case "agentDelta":
					appendText(event.itemId, event.delta);
					break;
				case "agentMessageCompleted": {
					const index = textIndex.get(event.itemId);
					const shown = index === undefined ? "" : (output.content[index] as { text: string }).text;
					if (event.text.length > shown.length && event.text.startsWith(shown)) appendText(event.itemId, event.text.slice(shown.length));
					break;
				}
				case "reasoningDelta": {
					let index = thinkingIndex.get(event.itemId);
					if (index === undefined) {
						index = output.content.length;
						thinkingIndex.set(event.itemId, index);
						output.content.push({ type: "thinking", thinking: "" });
						stream.push({ type: "thinking_start", contentIndex: index, partial: output });
					}
					const block = output.content[index];
					if (block.type !== "thinking") throw new Error("codex-thinking-state-invalid");
					block.thinking += event.delta;
					stream.push({ type: "thinking_delta", contentIndex: index, delta: event.delta, partial: output });
					break;
				}
				case "tokenUsage":
					output.usage.input += event.usage.input;
					output.usage.output += event.usage.output;
					output.usage.cacheRead += event.usage.cacheRead;
					output.usage.cacheWrite += event.usage.cacheWrite;
					output.usage.totalTokens += event.usage.total;
					break;
				case "turnCompleted":
					record.activeTurnId = null;
					if (event.status === "completed") {
						closeBlocks();
						output.stopReason = "stop";
						stream.push({ type: "done", reason: "stop", message: output });
						stream.end();
						return;
					}
					if (event.status === "interrupted") throw new Error(options?.signal?.aborted ? "codex-request-aborted" : "codex-turn-interrupted");
					throw new Error(`codex-turn-failed${event.error ? `\n${event.error.split("\n", 1)[0]}` : ""}`);
				default:
					break;
			}
		}
	}
}
