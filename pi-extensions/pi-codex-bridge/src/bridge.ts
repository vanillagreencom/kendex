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
import { ALLOWED_ITEM_TYPES, APPROVAL_POLICY, PI_TOOL_NAMESPACE, threadConfig, unreviewedFeature } from "./codex-policy.js";
import { buildDynamicTools, type DynamicToolCatalog } from "./dynamic-tools.js";
import { CodexRequestError, type IncomingNotification, type IncomingRequest, type ProtocolClient } from "./json-rpc.js";
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
import { afterBoundary, encodeResponseId, findBoundary, replayInput, systemPromptDigest } from "./transcript.js";

/** Threads one bridge keeps state for; the least recently used idle one goes first. */
export const MAX_THREADS = 16;
/** Server requests and notifications one thread may hold while no stream reads them. */
export const MAX_QUEUED_EVENTS = 1024;
/** Tool calls one turn may hold open for Pi. */
export const MAX_PENDING_CALLS = 64;
/** How long model discovery may hold Pi's startup. */
export const DISCOVERY_DEADLINE_MS = 15_000;

/** How long the version check plus the app-server handshake may take. */
export const HANDSHAKE_DEADLINE_MS = 15_000;

/** Start a connected client for `launch`. The connection owns its child from
 * the spawn. When `signal` aborts before the handshake ends, it stops that
 * child and only then rejects, so the bridge's close can wait for it. */
export type Connect = (launch: Launch, signal: AbortSignal) => Promise<ProtocolClient>;

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
	/** The turn the bridge last asked Codex to interrupt. */
	interruptedTurnId: string | null;
	/** Calls of the active turn that wait for Pi's results, in arrival order. */
	pending: PendingToolCall[];
	queue: ThreadQueue;
	/** A stream has claimed the thread. A stream claims it in the same step as
	 * the busy check, before any await, and only that stream releases it. */
	streaming: boolean;
	lastUsed: number;
}

type Plan =
	| { record: ThreadRecord; mode: "turn"; input: JsonObject[] }
	| { record: ThreadRecord; mode: "continue"; input: JsonObject[]; answers: ToolCallAnswer[] };

/** The bridge's one app-server client: none, in its handshake, or connected.
 * `promise` is what every stream and discovery awaits for that client. */
type ClientState =
	| { kind: "none" }
	| { kind: "opening"; controller: AbortController; promise: Promise<ProtocolClient> }
	| { kind: "open"; client: ProtocolClient; promise: Promise<ProtocolClient> };

const NO_CLIENT: ClientState = { kind: "none" };

function ignore(): void {}

function emptyUsage(): AssistantMessage["usage"] {
	return { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
}

/** Whether a message's tool calls are the calls Codex waits on, in order. */
function sameBatch(callIds: readonly string[], pending: readonly PendingToolCall[]): boolean {
	return callIds.length === pending.length && pending.every((call, index) => call.callId === callIds[index]);
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
	/** Test seam: the version check and handshake deadline. */
	handshakeDeadlineMs?: number;
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
	#state: ClientState = NO_CLIENT;
	/** Children being stopped, and opens being aborted; close waits for each. */
	#stopping = new Set<Promise<void>>();
	/** The threads of the current client; its teardown drops them. */
	#threads = new Map<string, ThreadRecord>();

	constructor(options: BridgeOptions) {
		this.codexHome = options.codexHome;
		this.#launch = {
			executable: options.executable ?? "codex",
			codexHome: options.codexHome,
			cwd: options.cwd ?? process.cwd(),
			env: options.env ?? process.env,
			configOverrides: options.configOverrides ?? [],
			handshakeTimeoutMs: options.handshakeDeadlineMs ?? HANDSHAKE_DEADLINE_MS,
		};
		this.#connect = options.connect ?? ((launch, signal) => startAppServer(launch, signal));
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
			const client = await Promise.race([this.#client(), deadline]);
			return { models: await Promise.race([listCodexModels(client), deadline]) };
		} catch (error) {
			void this.#closeClient(error instanceof Error ? error : new Error("codex-discovery-failed"));
			return { models: [], notice: firstLine(error) };
		} finally {
			clearTimeout(timer);
		}
	}

	/** Stop the child, and every stream on it, and wait for the child to exit,
	 * a child still in its handshake included. */
	async close(): Promise<void> {
		void this.#closeClient(new Error("codex-bridge-closed"));
		await Promise.all(this.#stopping);
	}

	#track(stopped: Promise<void>): Promise<void> {
		const tracked: Promise<void> = stopped.finally(() => this.#stopping.delete(tracked));
		this.#stopping.add(tracked);
		return tracked;
	}

	// --- Client and router ---------------------------------------------------

	/** The current client, opening one when there is none. */
	#client(): Promise<ProtocolClient> {
		if (this.#state.kind !== "none") return this.#state.promise;
		const controller = new AbortController();
		const promise = this.#connect(this.#launch, controller.signal).then(
			(client) => this.#adopt(controller, client),
			(error: unknown) => {
				if (this.#state.kind === "opening" && this.#state.controller === controller) this.#state = NO_CLIENT;
				throw error;
			},
		);
		this.#state = { kind: "opening", controller, promise };
		return promise;
	}

	/** Take a client whose handshake ended. An open the bridge released while
	 * it ran stops its child before it settles, so close can wait for it. */
	async #adopt(controller: AbortController, client: ProtocolClient): Promise<ProtocolClient> {
		const state = this.#state;
		if (state.kind !== "opening" || state.controller !== controller) {
			const reason = controller.signal.reason instanceof Error ? controller.signal.reason : new Error("codex-bridge-closed");
			await client.kill(reason);
			throw reason;
		}
		this.#state = { kind: "open", client, promise: state.promise };
		client.on("request", (frame) => this.#onRequest(client, frame));
		client.on("notification", (frame) => this.#onNotification(client, frame));
		// An exit nobody asked for, or the client's own protocol stop.
		client.on("closed", (error) => void this.#closeClient(error, client));
		return client;
	}

	/**
	 * The one teardown of a client. It refuses every stream on the client and
	 * drops the client's thread records, then aborts an open still in its
	 * handshake, which stops that child, or stops the connected child. `close`
	 * waits for either. `from` names the client a breach or an exit concerns: a
	 * client the bridge already released is only stopped.
	 */
	#closeClient(reason: Error, from?: ProtocolClient): Promise<void> {
		const state = this.#state;
		if (from !== undefined && (state.kind !== "open" || state.client !== from)) return this.#track(from.kill(reason));
		this.#state = NO_CLIENT;
		for (const record of this.#threads.values()) record.queue.push({ kind: "refusal", error: reason, turnId: null });
		this.#threads.clear();
		if (state.kind === "none") return Promise.resolve();
		if (state.kind === "opening") {
			state.controller.abort(reason);
			return this.#track(state.promise.then(ignore, ignore));
		}
		return this.#track(state.client.kill(reason));
	}

	/** Stop the record's active turn. Codex refusing that while the client is
	 * open leaves a turn running that the bridge cannot stop: a breach. */
	#interrupt(client: ProtocolClient, record: ThreadRecord): void {
		const turnId = record.activeTurnId;
		if (turnId === null || record.interruptedTurnId === turnId) return;
		record.interruptedTurnId = turnId;
		void client.request("turn/interrupt", { threadId: record.threadId, turnId }).catch((error) => {
			// A turn that ended before the interrupt reached Codex needs no stop.
			if (error instanceof CodexRequestError && error.kind === "no-active-turn") return;
			void this.#closeClient(new Error(`codex-interrupt-failed thread=${record.threadId} turn=${turnId}`), client);
		});
	}

	/** Refuse the turn a server request belongs to; a request no thread of
	 * this bridge owns is a breach. */
	#refuse(client: ProtocolClient, threadId: string | null, error: Error): void {
		const records = threadId === null
			? [...this.#threads.values()].filter((record) => record.activeTurnId !== null)
			: [this.#threads.get(threadId)];
		for (const record of records) {
			if (record === undefined) {
				void this.#closeClient(new Error(`codex-foreign-thread thread=${threadId}`), client);
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
			void this.#closeClient(error as Error, client);
			return;
		}
		if (event.type === "ignored") return;
		if (event.type === "mcpStartup") {
			if (event.status === "starting") void this.#closeClient(new Error(`codex-mcp-started name=${event.name}`), client);
			return;
		}
		const record = this.#threads.get(event.threadId);
		if (record === undefined) {
			if (event.type === "turnStarted" || event.type === "itemStarted") {
				void this.#closeClient(new Error(`codex-foreign-thread thread=${event.threadId}`), client);
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
				void this.#closeClient(new Error(`codex-foreign-thread thread=${call.threadId}`), client);
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

	/** A new record, claimed by the stream that asked for it. */
	#record(threadId: string, tools: DynamicToolCatalog, lastTurnId: string | null): ThreadRecord {
		return { threadId, tools, lastTurnId, activeTurnId: null, interruptedTurnId: null, pending: [], queue: new ThreadQueue(), streaming: true, lastUsed: Date.now() };
	}

	/** Answer a turn the bridge no longer continues, so Codex does not wait on
	 * it, and stop it. A record the bridge dropped went with its stopped child. */
	#abandon(client: ProtocolClient, record: ThreadRecord): void {
		if (record.activeTurnId === null || this.#threads.get(record.threadId) !== record) return;
		for (const answer of answerToolCalls(record.pending, [])) client.respond(answer.requestId, answer.result);
		record.pending = [];
		this.#interrupt(client, record);
		record.activeTurnId = null;
	}

	/** End a claim whose stream has ended: stop its turn and free the thread. */
	#release(client: ProtocolClient, record: ThreadRecord): void {
		this.#abandon(client, record);
		record.streaming = false;
	}

	/** Names only: `config/read` is decoded to the configured MCP server names
	 * inside its own parse. A read that fails refuses the thread. Only Codex's
	 * own error reply means it could not load its configuration; a closed
	 * client or a malformed reply keeps its own key. */
	async #mcpServerNames(client: ProtocolClient): Promise<string[]> {
		try {
			return await client.requestDecoded("config/read", { cwd: this.#launch.cwd }, decodeMcpServerNames);
		} catch (error) {
			if (!(error instanceof CodexRequestError)) throw error;
			throw new Error(`codex-mcp-names-unread\n${error.message}\nCodex could not load its configuration for CODEX_HOME=${this.codexHome}. Run \`codex\` with that CODEX_HOME to see the error.`);
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
		let resumed: { threadId: string; lastTurnId: string | null };
		try {
			resumed = await client.requestDecoded("thread/resume", {
				threadId,
				model: model.id,
				cwd: this.#launch.cwd,
				approvalPolicy: APPROVAL_POLICY,
				sandbox: "read-only",
				config: threadConfig(names),
				excludeTurns: true,
				initialTurnsPage: { limit: 1, sortDirection: "desc", itemsView: "notLoaded" },
			}, decodeThreadResume);
		} catch (error) {
			// A CODEX_HOME without the thread: a fresh home, another home, or pruned
			// sessions. Pi's transcript still holds the conversation to replay.
			if (error instanceof CodexRequestError && error.kind === "thread-not-found") return undefined;
			throw error;
		}
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
	 * message is the boundary (`findBoundary`). The bridge reuses its thread only
	 * when the thread was started for Pi's current tools and system prompt,
	 * nothing but user input and that turn's tool results follows the message,
	 * and the thread's latest turn is that turn. A tool continuation also needs
	 * the boundary's model to be the selected one, since tool answers and
	 * `turn/steer` carry no model, and the boundary's tool calls to be the batch
	 * Codex waits on. Otherwise it starts a new thread and replays the
	 * transcript, so Codex never holds turns Pi has dropped, misses another
	 * model's turns, calls a tool Pi no longer has or keeps a stale prompt. Any
	 * turn the plan does not continue is abandoned, so Codex is not left waiting
	 * on it. The plan's record comes claimed by the calling stream.
	 */
	async #plan(client: ProtocolClient, model: Model<string>, messages: Message[], tools: DynamicToolCatalog, promptDigest: string): Promise<Plan> {
		const boundary = findBoundary(messages);
		const record = boundary === undefined ? undefined : this.#threads.get(boundary.threadId);
		if (record?.streaming) throw new Error(`codex-thread-busy thread=${record.threadId}`);
		const after = boundary === undefined ? undefined : afterBoundary(messages, boundary);
		const matches = boundary !== undefined && after!.clean && boundary.toolSignature === tools.signature && boundary.promptDigest === promptDigest;
		let plan: Plan | undefined;
		if (matches && record !== undefined) {
			if (boundary.stopReason === "toolUse" && record.activeTurnId === boundary.turnId && boundary.model === model.id && sameBatch(boundary.toolCallIds, record.pending)) {
				plan = { record, mode: "continue", input: after!.input, answers: answerToolCalls(record.pending, after!.toolResults) };
			} else if (boundary.stopReason === "stop" && record.activeTurnId === null && record.lastTurnId === boundary.turnId) {
				plan = { record, mode: "turn", input: after!.input };
			}
		}
		if (plan !== undefined) plan.record.streaming = true;
		for (const other of this.#threads.values()) {
			if (other !== plan?.record && other.activeTurnId !== null && !other.streaming) this.#abandon(client, other);
		}
		if (plan !== undefined) return plan;
		if (matches && record === undefined && boundary.stopReason === "stop") {
			const resumed = await this.#resumeThread(client, model, boundary.threadId, boundary.turnId, tools);
			if (resumed !== undefined) return { record: resumed, mode: "turn", input: after!.input };
		}
		const started = await this.#startThread(client, model, messages, tools);
		return { record: started, mode: "turn", input: replayInput(messages) };
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
		const signal = options?.signal;
		let client: ProtocolClient | undefined;
		/** The record this stream claimed, once #plan hands it over. */
		let record: ThreadRecord | undefined;
		/** A request this stream stopped waiting for holds the claim instead. */
		let handedOver = false;
		let reading = false;
		// Armed before the first await, and every wait races it, so an abort ends
		// the stream at once. Work the stream stopped waiting for stays with the
		// bridge: an open with its handshake deadline, a request with its claim.
		let rejectAborted: ((error: Error) => void) | undefined;
		const aborted = new Promise<never>((_, reject) => (rejectAborted = reject));
		aborted.catch(ignore);
		const untilAborted = <T>(work: Promise<T>): Promise<T> => {
			work.catch(ignore);
			// A race with work that has already settled would miss an earlier abort.
			return signal?.aborted ? aborted : Promise.race([work, aborted]);
		};
		// While the stream reads the turn, the abort ends that read rather than
		// waiting for Codex to complete the interrupted turn.
		const onAbort = () => {
			const error = new Error("codex-request-aborted");
			rejectAborted?.(error);
			if (reading && record !== undefined && record.activeTurnId !== null) record.queue.push({ kind: "refusal", error, turnId: record.activeTurnId });
		};
		signal?.addEventListener("abort", onAbort, { once: true });
		try {
			if (signal?.aborted) throw new Error("codex-request-aborted");
			const messages = collapseSystemMessages(context).messages;
			const tools = buildDynamicTools(getCurrentTools(messages));
			const promptDigest = systemPromptDigest(messages);
			const open = await untilAborted(this.#client());
			client = open;
			const planning = this.#plan(open, model, messages, tools, promptDigest);
			const plan = await untilAborted(planning).catch((error: unknown) => {
				// A plan that settles after this stream ended hands its claim back.
				void planning.then((late) => this.#release(open, late.record), ignore);
				throw error;
			});
			const claimed = plan.record;
			record = claimed;
			claimed.lastUsed = Date.now();

			if (plan.mode === "continue") {
				const payload = { method: "item/tool/call", answers: plan.answers, steer: plan.input };
				const sent = ((await untilAborted(Promise.resolve(options?.onPayload?.(payload, model)))) ?? payload) as typeof payload;
				for (const answer of sent.answers) open.respond(answer.requestId, answer.result);
				claimed.pending = [];
				if (sent.steer.length > 0) {
					await untilAborted(open.request("turn/steer", { threadId: claimed.threadId, expectedTurnId: claimed.activeTurnId, input: sent.steer }));
				}
			} else {
				if (plan.input.length === 0) throw new Error("codex-turn-input-empty");
				const effort = codexEffort(model, options?.reasoning);
				const params: JsonObject = {
					threadId: claimed.threadId,
					input: plan.input,
					model: model.id,
					approvalPolicy: APPROVAL_POLICY,
					environments: [],
					...(effort === null ? {} : { effort }),
				};
				const sent = ((await untilAborted(Promise.resolve(options?.onPayload?.(params, model)))) ?? params) as JsonObject;
				const starting = open.requestDecoded("turn/start", sent, decodeTurnStart).then(({ turnId }) => {
					claimed.activeTurnId = turnId;
					claimed.lastTurnId = turnId;
				});
				await untilAborted(starting).catch((error: unknown) => {
					// Until Codex answers, the claim stays with the request. A turn it
					// starts after this stream ended runs for nobody and is stopped.
					handedOver = true;
					void starting.then(ignore, ignore).then(() => this.#release(open, claimed));
					throw error;
				});
			}
			await untilAborted(Promise.resolve(options?.onResponse?.({ status: 200, headers: {} }, model)));
			output.responseId = encodeResponseId(claimed.threadId, claimed.activeTurnId!, tools.signature, promptDigest);
			stream.push({ type: "start", partial: output });
			reading = true;
			await this.#consume(stream, output, model, claimed, options);
		} catch (error) {
			if (client !== undefined && record !== undefined && !handedOver) this.#abandon(client, record);
			output.stopReason = signal?.aborted ? "aborted" : "error";
			output.errorMessage = error instanceof Error ? error.message : "codex-bridge-error";
			stream.push({ type: "error", reason: output.stopReason, error: output });
			stream.end();
		} finally {
			signal?.removeEventListener("abort", onAbort);
			if (record !== undefined && !handedOver) record.streaming = false;
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
			if (call.namespace !== PI_TOOL_NAMESPACE) throw new Error(`codex-tool-call-namespace-refused namespace=${call.namespace}`);
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
				if (options?.signal?.aborted) throw new Error("codex-request-aborted");
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
					// Pi reads a message's usage as the context of its latest model
					// request, so each request's usage replaces the last. Codex counts
					// cached and cache-written tokens inside its input count; Pi keeps
					// them apart, as its own Responses adapter does.
					output.usage = {
						input: Math.max(0, event.usage.input - event.usage.cacheRead - event.usage.cacheWrite),
						output: event.usage.output,
						cacheRead: event.usage.cacheRead,
						cacheWrite: event.usage.cacheWrite,
						totalTokens: event.usage.total,
						cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
					};
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
