import { calculateCost, type Api, type AssistantMessage, type Context, type JsonObject, type Model, type SystemMessage, type Tool, type Usage } from "@earendil-works/pi-ai";
import * as piAi from "@earendil-works/pi-ai";
import type { ResponseCreateParamsStreaming, ResponseInput, ResponseStreamEvent, Tool as OpenAITool } from "openai/resources/responses/responses.js";
import type { AssistantMessageEventStream } from "@earendil-works/pi-ai";
import {
	appendGrammarToolInputJsonDelta,
	closeGrammarToolInputJson,
	createGrammarToolInputProperties,
	getGrammarToolInput,
	getResponsesToolSupport,
	makeStrictJsonSchema,
	resolveGrammarSampling,
	resolveStrictSampling,
	resolveTranscriptTools,
	type GrammarInputBuffer,
} from "./openai-responses-compat.js";

export { createGrammarToolInputProperties, getResponsesToolSupport, resolveTranscriptTools, splitDeferredTools } from "./openai-responses-compat.js";

type MessageRole = Context["messages"][number]["role"];
type Message = Context["messages"][number];

interface ImageGenerationCallItem {
	type: "image_generation_call";
	id: string;
	status: string;
	result: string | null;
	revised_prompt?: string;
}

interface ImageGenerationCallBlock {
	type: "image_generation_call";
	item: ImageGenerationCallItem;
}

type InternalAssistantContent = Extract<Message, { role: "assistant" }>["content"][number] | ImageGenerationCallBlock;

export interface OpenAIResponsesStreamOptions {
	serviceTier?: ResponseCreateParamsStreaming["service_tier"];
	grammarToolInputProperties?: ReadonlyMap<string, string>;
	resolveServiceTier?: (
		responseServiceTier: ResponseCreateParamsStreaming["service_tier"] | undefined,
		requestServiceTier: ResponseCreateParamsStreaming["service_tier"] | undefined,
	) => ResponseCreateParamsStreaming["service_tier"] | undefined;
	applyServiceTierPricing?: (usage: Usage, serviceTier: ResponseCreateParamsStreaming["service_tier"] | undefined) => void;
}

type TextSignaturePhase = "commentary" | "final_answer";

interface ConvertResponsesMessagesOptions {
	grammarToolInputProperties?: ReadonlyMap<string, string>;
	/** Whether later system messages are sent in place; otherwise they fold into the leading prompt. */
	supportsMidConvoSystemMessages?: boolean;
	supportsAdditionalTools?: boolean;
	supportsToolSearch?: boolean;
	/** Tools a Pi below 0.86 loads by name from a tool result's `addedToolNames`. */
	deferredTools?: ReadonlyMap<string, Tool>;
	toolOptions?: ConvertResponsesToolsOptions;
	/**
	 * Effort of the reply being generated. When set, the thinking level travels as
	 * configuration_update items, one before every earlier reply of this model with the
	 * level recorded on it and one at the end, so a level change leaves earlier input,
	 * and the prompt cache, unchanged.
	 */
	configurationUpdateEffort?: string;
}

interface ConvertResponsesToolsOptions {
	strict?: boolean | null;
	supportsStrictMode?: boolean;
	supportsOpenAIGrammarTools?: boolean;
	deferLoading?: boolean;
}


/**
 * Pi 0.86.0 and later hand a provider a normalized transcript: its system
 * messages carry the prompt and the tool changes, its `systemPrompt` and `tools`
 * fields are absent, and pi-ai's replay helpers read them. An older Pi hands the
 * fields, no system message, and no replay helper. The field branches serve Pi
 * below 0.86.0; delete them once no supported Pi host is below that release.
 */
export function isTranscript(context: Context): boolean {
	return context.messages.some((message) => message.role === "system");
}

/** Later system messages stay in place where the model takes them; otherwise they fold into the leading one. */
export function resolveRequestTranscript(context: Context, supportsMidConvoSystemMessages: boolean | undefined): Context {
	return isTranscript(context) ? (piAi.resolveTranscript(context as never, supportsMidConvoSystemMessages) as unknown as Context) : context;
}

/** Every tool the context declares, the source of the grammar tools' input properties. */
export function declaredTools(context: Context): Tool[] {
	return isTranscript(context) ? piAi.getDeclaredTools(context.messages) : (context.tools ?? []);
}

/**
 * Precedes every additional_tools item after the first: without it a model reads the
 * latest item as the whole tool set once a removal was announced.
 */
function renderIncrementalToolsNotice(unavailable: ReadonlySet<string>): string {
	const notice = "This is an incremental tools update. Previously declared tools remain available unless explicitly marked unavailable. A tool declared again here is available again, and its latest definition replaces the earlier one.";
	return unavailable.size > 0 ? `${notice}\nStill unavailable: ${[...unavailable].join(", ")}.` : notice;
}

function renderToolRemovalNotice(names: readonly string[]): string {
	return `The following tools are no longer available. Do not call them:\n${names.map((name) => `- ${name}`).join("\n")}`;
}

function shortHash(str: string): string {
	let h1 = 0xdeadbeef;
	let h2 = 0x41c6ce57;
	for (let i = 0; i < str.length; i++) {
		const ch = str.charCodeAt(i);
		h1 = Math.imul(h1 ^ ch, 2654435761);
		h2 = Math.imul(h2 ^ ch, 1597334677);
	}
	h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
	h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
	return (h2 >>> 0).toString(36) + (h1 >>> 0).toString(36);
}

type ToolCallArguments = Extract<AssistantMessage["content"][number], { type: "toolCall" }>["arguments"];

/** Streamed function-call arguments, the interface of pi-ai's `ToolCallArgumentsStream`. */
interface ArgumentsStream {
	append(delta: string): ToolCallArguments;
	replace(text: string): { readonly delta: string | undefined; readonly arguments: ToolCallArguments };
	finish(): { arguments: ToolCallArguments; argumentsError?: string };
}

/**
 * Pi below 1.5.0 exports no `ToolCallArgumentsStream`: arguments stay `{}` until
 * the call completes, then parse once. Delete once no supported Pi host is below 1.5.0.
 */
class CompletedArgumentsStream implements ArgumentsStream {
	private text = "";
	append(delta: string): ToolCallArguments {
		this.text += delta;
		return {};
	}
	replace(text: string): { delta: string | undefined; arguments: ToolCallArguments } {
		const delta = text.startsWith(this.text) ? text.slice(this.text.length) : undefined;
		this.text = text;
		return { delta, arguments: {} };
	}
	finish(): { arguments: ToolCallArguments } {
		if (!this.text.trim()) return { arguments: {} };
		try {
			return { arguments: JSON.parse(this.text) as JsonObject };
		} catch {
			return { arguments: {} };
		}
	}
}

function createArgumentsStream(): ArgumentsStream {
	const Stream = (piAi as { ToolCallArgumentsStream?: new () => ArgumentsStream }).ToolCallArgumentsStream;
	return Stream ? new Stream() : new CompletedArgumentsStream();
}

/** A custom (grammar) tool call's streamed input and the JSON text of its initial input, sent with the first delta. */
interface CustomToolInput {
	property: string;
	buffer: GrammarInputBuffer;
	unsent: string;
}

function createCustomToolInput(property: string, initialInput: string): CustomToolInput {
	const buffer = { input: "", started: false, closed: false };
	return { property, buffer, unsent: appendGrammarToolInputJsonDelta(buffer, property, initialInput) ?? "" };
}

function sanitizeSurrogates(text: string): string {
	return text.replace(/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g, "");
}

function isImageGenerationCallBlock(block: InternalAssistantContent): block is ImageGenerationCallBlock {
	return block.type === "image_generation_call" && block.item?.type === "image_generation_call";
}

function sanitizeImageGenerationCallItem(item: unknown): ImageGenerationCallItem | undefined {
	if (!item || typeof item !== "object") return undefined;
	const candidate = item as Record<string, unknown>;
	if (candidate.type !== "image_generation_call") return undefined;
	if (typeof candidate.id !== "string" || candidate.id === "") return undefined;
	if (typeof candidate.status !== "string" || candidate.status === "") return undefined;
	if (!(typeof candidate.result === "string" || candidate.result === null)) return undefined;

	return {
		type: "image_generation_call",
		id: candidate.id,
		status: candidate.status,
		result: candidate.result,
		...(typeof candidate.revised_prompt === "string" ? { revised_prompt: candidate.revised_prompt } : {}),
	};
}

const NON_VISION_USER_IMAGE_PLACEHOLDER = "(image omitted: model does not support images)";
const NON_VISION_TOOL_IMAGE_PLACEHOLDER = "(tool image omitted: model does not support images)";

function replaceImagesWithPlaceholder(
	content: Extract<Message, { role: "user" }> extends { content: infer T } ? Exclude<T, string> : never,
	placeholder: string,
) {
	const result: Array<{ type: "text"; text: string } | { type: "image"; data: string; mimeType: string }> = [];
	let previousWasPlaceholder = false;
	for (const block of content) {
		if (block.type === "image") {
			if (!previousWasPlaceholder) {
				result.push({ type: "text", text: placeholder });
			}
			previousWasPlaceholder = true;
			continue;
		}
		result.push(block);
		previousWasPlaceholder = block.text === placeholder;
	}
	return result;
}

function downgradeUnsupportedImages(messages: Context["messages"], model: Model<Api>): Context["messages"] {
	if (model.input.includes("image")) return messages;
	return messages.map((msg) => {
		if (msg.role === "user" && Array.isArray(msg.content)) {
			return { ...msg, content: replaceImagesWithPlaceholder(msg.content, NON_VISION_USER_IMAGE_PLACEHOLDER) };
		}
		if (msg.role === "toolResult") {
			return { ...msg, content: replaceImagesWithPlaceholder(msg.content, NON_VISION_TOOL_IMAGE_PLACEHOLDER) };
		}
		return msg;
	});
}

function transformMessages(
	messages: Context["messages"],
	model: Model<Api>,
	normalizeToolCallId?: (id: string, targetModel: Model<Api>, source: Extract<Message, { role: "assistant" }>) => string,
): Context["messages"] {
	const toolCallIdMap = new Map<string, string>();
	const imageAwareMessages = downgradeUnsupportedImages(messages, model);
	const transformed = imageAwareMessages.map((msg) => {
		if (msg.role === "user") return msg;
		if (msg.role === "toolResult") {
			const normalizedId = toolCallIdMap.get(msg.toolCallId);
			return normalizedId && normalizedId !== msg.toolCallId ? { ...msg, toolCallId: normalizedId } : msg;
		}
		if (msg.role === "assistant") {
			const assistantMsg = msg;
			const isSameModel =
				assistantMsg.provider === model.provider && assistantMsg.api === model.api && assistantMsg.model === model.id;
			const transformedContent = (assistantMsg.content as InternalAssistantContent[]).flatMap((block) => {
				if (isImageGenerationCallBlock(block)) return block;
				if (block.type === "thinking") {
					// Another model's thinking is dropped: sent as text, the new model reads it as part of its reply.
					if (!isSameModel) return [];
					if (block.redacted || block.thinkingSignature) return block;
					if (!block.thinking || block.thinking.trim() === "") return [];
					return block;
				}
				if (block.type === "text") return isSameModel ? block : { type: "text" as const, text: block.text };
				if (block.type === "toolCall") {
					let normalizedToolCall = block;
					if (!isSameModel && block.thoughtSignature) {
						normalizedToolCall = { ...block };
						delete normalizedToolCall.thoughtSignature;
					}
					if (!isSameModel && normalizeToolCallId) {
						const normalizedId = normalizeToolCallId(block.id, model, assistantMsg);
						if (normalizedId !== block.id) {
							toolCallIdMap.set(block.id, normalizedId);
							normalizedToolCall = { ...normalizedToolCall, id: normalizedId };
						}
					}
					return normalizedToolCall;
				}
				return block;
			});
			return { ...assistantMsg, content: transformedContent as Extract<Message, { role: "assistant" }>["content"] };
		}
		return msg;
	});

	const result: Context["messages"] = [];
	let pendingToolCalls: Array<Extract<Extract<Message, { role: "assistant" }>["content"][number], { type: "toolCall" }>> = [];
	let existingToolResultIds = new Set<string>();
	// A system message between a tool call and its results is emitted after the results,
	// so it never forces a synthetic result for a call answered later.
	const heldSystemMessages: Context["messages"] = [];

	const insertSyntheticToolResults = () => {
		for (const toolCall of pendingToolCalls) {
			if (!existingToolResultIds.has(toolCall.id)) {
				result.push({
					role: "toolResult",
					toolCallId: toolCall.id,
					toolName: toolCall.name,
					content: [{ type: "text", text: "No result provided" }],
					isError: true,
					timestamp: Date.now(),
				});
			}
		}
		pendingToolCalls = [];
		existingToolResultIds = new Set();
		result.push(...heldSystemMessages.splice(0));
	};

	for (const msg of transformed) {
		if (msg.role === "assistant") {
			insertSyntheticToolResults();
			if (msg.stopReason === "error" || msg.stopReason === "aborted") continue;
			const toolCalls = msg.content.filter((block) => block.type === "toolCall");
			if (toolCalls.length > 0) {
				pendingToolCalls = toolCalls;
				existingToolResultIds = new Set();
			}
			result.push(msg);
			continue;
		}
		if (msg.role === "toolResult") {
			existingToolResultIds.add(msg.toolCallId);
			result.push(msg);
			continue;
		}
		if (msg.role === "user") {
			insertSyntheticToolResults();
			result.push(msg);
			continue;
		}
		if (msg.role === "system" && pendingToolCalls.length > 0) {
			heldSystemMessages.push(msg);
			continue;
		}
		result.push(msg);
	}

	insertSyntheticToolResults();

	return result;
}

function encodeTextSignatureV1(id: string, phase?: string): string {
	const payload: { v: 1; id: string; phase?: string } = { v: 1, id };
	if (phase) payload.phase = phase;
	return JSON.stringify(payload);
}

function parseTextSignature(signature: string | undefined): { id: string; phase?: TextSignaturePhase } | undefined {
	if (!signature) return undefined;
	if (signature.startsWith("{")) {
		try {
			const parsed = JSON.parse(signature) as { v?: number; id?: string; phase?: TextSignaturePhase | string };
			if (parsed.v === 1 && typeof parsed.id === "string") {
				return parsed.phase === "commentary" || parsed.phase === "final_answer"
					? { id: parsed.id, phase: parsed.phase }
					: { id: parsed.id };
			}
		} catch {
			// Fall through to legacy plain-string handling.
		}
	}
	return { id: signature };
}

export function convertResponsesMessages<TApi extends Api>(
	model: Model<TApi>,
	context: Context,
	allowedToolCallProviders: ReadonlySet<string>,
	options?: ConvertResponsesMessagesOptions,
): ResponseInput {
	const messages: ResponseInput = [];
	const loadedToolNames = new Set<string>();
	const normalizeIdPart = (part: string) => {
		const sanitized = part.replace(/[^a-zA-Z0-9_-]/g, "_");
		const normalized = sanitized.length > 64 ? sanitized.slice(0, 64) : sanitized;
		return normalized.replace(/_+$/, "");
	};
	const buildForeignResponsesItemId = (itemId: string) => {
		const normalized = `fc_${shortHash(itemId)}`;
		return normalized.length > 64 ? normalized.slice(0, 64) : normalized;
	};
	const normalizeToolCallId = (id: string, _targetModel: Model<TApi>, source: Extract<Message, { role: "assistant" }>) => {
		if (!allowedToolCallProviders.has(model.provider)) return normalizeIdPart(id);
		if (!id.includes("|")) return normalizeIdPart(id);
		const [callId, itemId] = id.split("|");
		const normalizedCallId = normalizeIdPart(callId);
		const isForeignToolCall = source.provider !== model.provider || source.api !== model.api;
		let normalizedItemId = isForeignToolCall ? buildForeignResponsesItemId(itemId ?? "") : normalizeIdPart(itemId ?? "");
		if (!normalizedItemId.startsWith("fc_")) normalizedItemId = normalizeIdPart(`fc_${normalizedItemId}`);
		return `${normalizedCallId}|${normalizedItemId}`;
	};

	const source = resolveRequestTranscript(context, options?.supportsMidConvoSystemMessages);
	const transformedMessages = transformMessages(source.messages, model as Model<Api>, normalizeToolCallId as never);
	const compat = model.compat as { supportsDeveloperRole?: boolean } | undefined;
	const instructionRole = model.reasoning && compat?.supportsDeveloperRole !== false ? "developer" : "system";
	const toolSupport = getResponsesToolSupport(options ?? {});
	const transcriptTools = resolveTranscriptTools(source.messages, toolSupport);
	let declaredAdditionalTools = false;
	/** Tools announced as removed and not declared again since. */
	const unavailableTools = new Set<string>();
	const pushToolSearchLoad = (tools: readonly Tool[], seed: string): void => {
		const names = tools.map((tool) => tool.name);
		const callId = `pi_tool_load_${shortHash(`${seed}:${names.join(",")}`)}`;
		messages.push({
			type: "tool_search_call",
			call_id: callId,
			execution: "client",
			status: "completed",
			arguments: { query: names.join(" "), limit: names.length },
		} as ResponseInput[number]);
		messages.push({
			type: "tool_search_output",
			call_id: callId,
			execution: "client",
			status: "completed",
			tools: convertResponsesTools(tools, { ...options?.toolOptions, deferLoading: true }),
		} as ResponseInput[number]);
	};
	const appendSystemToolAdditions = (message: SystemMessage, seed: string): void => {
		const tools = message.toolsAdded ?? [];
		for (const tool of tools) unavailableTools.delete(tool.name);
		if (tools.length === 0) return;
		if (toolSupport === "changes") {
			if (declaredAdditionalTools) messages.push({ role: instructionRole, content: renderIncrementalToolsNotice(unavailableTools) });
			declaredAdditionalTools = true;
			messages.push({ type: "additional_tools", role: "developer", tools: convertResponsesTools(tools, options?.toolOptions) } as ResponseInput[number]);
			return;
		}
		if (toolSupport === "additions") pushToolSearchLoad(tools, seed);
	};
	const pushConfigurationUpdate = (effort: string): void => {
		messages.push({ type: "configuration_update", reasoning: { effort } } as ResponseInput[number]);
	};
	if (!isTranscript(source) && context.systemPrompt) {
		messages.push({ role: instructionRole, content: sanitizeSurrogates(context.systemPrompt) });
	}

	let msgIndex = 0;
	let sourceIndex = 0;
	let systemIndex = 0;
	for (const msg of transformedMessages) {
		const isLeadingSystemMessage = sourceIndex++ === 0 && msg.role === "system";
		if (msg.role === "system") {
			// transformMessages keeps system messages in order, so their position matches the transcript.
			const anchorsToolChanges = systemIndex++ >= transcriptTools.foldedSystemMessages;
			if (anchorsToolChanges) appendSystemToolAdditions(msg, `system:${msgIndex}`);
			const parts = [isLeadingSystemMessage ? piAi.getSystemMessageText(msg) : piAi.renderSystemMessageUpdate(msg)];
			if (anchorsToolChanges) {
				// A redefinition is a removal plus an addition of the same name; only true removals are announced.
				const added = new Set((msg.toolsAdded ?? []).map((tool) => tool.name));
				const removed = (msg.toolsRemoved ?? []).map((tool) => tool.name).filter((name) => !added.has(name));
				if (removed.length > 0) parts.push(renderToolRemovalNotice(removed));
				for (const name of removed) unavailableTools.add(name);
			}
			const text = parts.filter((part) => part.length > 0).join("\n\n");
			if (text.length > 0) messages.push({ role: instructionRole, content: sanitizeSurrogates(text) });
		} else if (msg.role === "user") {
			if (typeof msg.content === "string") {
				messages.push({ role: "user", content: [{ type: "input_text", text: sanitizeSurrogates(msg.content) }] });
			} else {
				const content = msg.content.map((item) =>
					item.type === "text"
						? { type: "input_text" as const, text: sanitizeSurrogates(item.text) }
						: { type: "input_image" as const, detail: "auto" as const, image_url: `data:${item.mimeType};base64,${item.data}` },
				);
				if (content.length > 0) messages.push({ role: "user", content });
			}
		} else if (msg.role === "assistant") {
			const output: ResponseInput = [];
			const isSameProviderAndApi = msg.provider === model.provider && msg.api === model.api;
			const isSameModel = isSameProviderAndApi && msg.model === model.id;
			const isDifferentModel = isSameProviderAndApi && msg.model !== model.id;
			let assistantBlockIndex = 0;
			for (const block of msg.content as InternalAssistantContent[]) {
				if (isImageGenerationCallBlock(block)) {
					const imageGenerationCall = sanitizeImageGenerationCallItem(block.item);
					if (imageGenerationCall) output.push(imageGenerationCall as ResponseInput[number]);
				} else if (block.type === "thinking") {
					if (block.thinkingSignature) output.push(JSON.parse(block.thinkingSignature));
				} else if (block.type === "text") {
					const parsedSignature = parseTextSignature(block.textSignature);
					let msgId = parsedSignature?.id ?? `msg_${msgIndex}_${assistantBlockIndex}`;
					if (msgId.length > 64) msgId = `msg_${shortHash(msgId)}`;
					output.push({
						type: "message",
						role: "assistant",
						content: [{ type: "output_text", text: sanitizeSurrogates(block.text), annotations: [] }],
						status: "completed",
						id: msgId,
						...(parsedSignature?.phase ? { phase: parsedSignature.phase } : {}),
					});
					assistantBlockIndex++;
				} else if (block.type === "toolCall") {
					const [callId, itemIdRaw] = block.id.split("|");
					const customInputProperty = options?.grammarToolInputProperties?.get(block.name);
					let itemId: string | undefined = itemIdRaw;
					// OpenAI refuses a replayed item id whose prefix does not match the item
					// type: fc_ for function_call, ctc_ for custom_tool_call.
					const itemIdPrefix = customInputProperty === undefined ? "fc_" : "ctc_";
					if (isDifferentModel || !itemId?.startsWith(itemIdPrefix)) itemId = undefined;
					if (customInputProperty !== undefined) {
						output.push({
							type: "custom_tool_call",
							...(itemId ? { id: itemId } : {}),
							call_id: callId,
							name: block.name,
							input: sanitizeSurrogates(getGrammarToolInput(block.name, block.arguments, customInputProperty)),
						} as ResponseInput[number]);
					} else {
						output.push({
							type: "function_call",
							...(itemId ? { id: itemId } : {}),
							call_id: callId,
							name: block.name,
							arguments: JSON.stringify(block.arguments),
						} as ResponseInput[number]);
					}
				}
			}
			if (output.length > 0) {
				const providerThinkingLevel = (msg as { providerThinkingLevel?: string }).providerThinkingLevel;
				if (options?.configurationUpdateEffort !== undefined && isSameModel && providerThinkingLevel !== undefined) pushConfigurationUpdate(providerThinkingLevel);
				messages.push(...output);
			}
		} else if (msg.role === "toolResult") {
			const textResult = msg.content.filter((c) => c.type === "text").map((c) => c.text).join("\n");
			const hasImages = msg.content.some((c) => c.type === "image");
			// Some providers refuse whitespace-only tool output; it takes the empty-output placeholder.
			const hasText = textResult.trim().length > 0;
			const [callId] = msg.toolCallId.split("|");
			const output = hasImages && model.input.includes("image")
				? [
						...(hasText ? [{ type: "input_text" as const, text: sanitizeSurrogates(textResult) }] : []),
						...msg.content
							.filter((block) => block.type === "image")
							.map((block) => ({
								type: "input_image" as const,
								detail: "auto" as const,
								image_url: `data:${block.mimeType};base64,${block.data}`,
							})),
					]
				: sanitizeSurrogates(hasText ? textResult : hasImages ? "(see attached image)" : "(no tool output)");
			messages.push({
				type: options?.grammarToolInputProperties?.has(msg.toolName) ? "custom_tool_call_output" : "function_call_output",
				call_id: callId,
				output,
			} as ResponseInput[number]);
			const deferredTools: Tool[] = [];
			for (const name of (msg as unknown as { addedToolNames?: string[] }).addedToolNames ?? []) {
				const tool = options?.deferredTools?.get(name);
				if (!tool || loadedToolNames.has(name)) continue;
				loadedToolNames.add(name);
				deferredTools.push(tool);
			}
			if (deferredTools.length > 0) pushToolSearchLoad(deferredTools, msg.toolCallId);
		}
		if (!isLeadingSystemMessage) msgIndex++;
	}
	if (options?.configurationUpdateEffort !== undefined) pushConfigurationUpdate(options.configurationUpdateEffort);

	return messages;
}

export function convertResponsesTools(tools: readonly Tool[], options?: ConvertResponsesToolsOptions): OpenAITool[] {
	const defaultStrict = options?.strict === undefined ? false : options.strict;
	const supportsStrictMode = options?.supportsStrictMode ?? true;
	const supportsOpenAIGrammarTools = options?.supportsOpenAIGrammarTools ?? false;
	return tools.map((tool) => {
		const grammar = resolveGrammarSampling(tool, supportsOpenAIGrammarTools);
		if (grammar) {
			return {
				type: "custom",
				name: tool.name,
				description: tool.description,
				format: { type: "grammar", syntax: grammar.format, definition: grammar.definition },
				...(options?.deferLoading ? { defer_loading: true } : {}),
			} as OpenAITool;
		}
		const constrainedStrict = resolveStrictSampling(tool, supportsStrictMode);
		const strict = constrainedStrict ?? defaultStrict;
		return {
			type: "function",
			name: tool.name,
			description: tool.description,
			parameters: strict === true ? makeStrictJsonSchema(tool.parameters) : (tool.parameters as unknown as Record<string, unknown>),
			...(options?.deferLoading ? { defer_loading: true } : {}),
			...(supportsStrictMode ? { strict } : {}),
		} as OpenAITool;
	});
}

export async function processResponsesStream<TApi extends Api>(
	openaiStream: AsyncIterable<ResponseStreamEvent>,
	output: AssistantMessage,
	stream: AssistantMessageEventStream,
	model: Model<TApi>,
	options?: OpenAIResponsesStreamOptions,
): Promise<void> {
	const blocks = output.content;
	const blockIndex = () => blocks.length - 1;
	type ThinkingBlock = Extract<AssistantMessage["content"][number], { type: "thinking" }>;
	type TextBlock = Extract<AssistantMessage["content"][number], { type: "text" }>;
	type ToolCallBlock = Extract<AssistantMessage["content"][number], { type: "toolCall" }>;

	// blockMatchesParts: the block's text equals its parts rendered in index order.
	// While it holds, a delta to the last existing part extends the text by exactly
	// that delta, so the block appends it instead of rendering every part again.
	type ReasoningState = {
		kind: "reasoning";
		blockIndex: number;
		block: ThinkingBlock;
		summaryParts: Map<number, { text: string }>;
		blockMatchesParts: boolean;
	};
	type MessageState = {
		kind: "message";
		blockIndex: number;
		block: TextBlock;
		parts: Map<number, { type: "output_text" | "refusal"; text: string }>;
		blockMatchesParts: boolean;
	};
	// A call's stream state stays here, never on its block, so it never reaches partials or transcripts.
	type FunctionCallState = {
		kind: "function_call";
		blockIndex: number;
		block: ToolCallBlock;
		input: { kind: "json"; arguments: ArgumentsStream } | ({ kind: "custom" } & CustomToolInput);
	};
	type OutputState = ReasoningState | MessageState | FunctionCallState;

	let sawTerminalResponseEvent = false;
	const outputStates = new Map<number, OutputState>();
	// Tool calls whose output_item.done has not arrived yet.
	const unfinishedToolCalls = new Set<ToolCallBlock>();
	const imageGenerationCallIds = new Set<string>();

	const appendImageGenerationCall = (item: unknown): void => {
		const imageGenerationCall = sanitizeImageGenerationCallItem(item);
		if (!imageGenerationCall || imageGenerationCallIds.has(imageGenerationCall.id)) return;
		imageGenerationCallIds.add(imageGenerationCall.id);
		(output.content as InternalAssistantContent[]).push({
			type: "image_generation_call",
			item: imageGenerationCall,
		});
	};

	const renderReasoningSummary = (summaryParts: Map<number, { text: string }>): string =>
		Array.from(summaryParts.entries())
			.sort(([a], [b]) => a - b)
			.map(([, part]) => part.text)
			.join("\n\n");

	const renderMessageText = (parts: Map<number, { type: "output_text" | "refusal"; text: string }>): string =>
		Array.from(parts.entries())
			.sort(([a], [b]) => a - b)
			.map(([, part]) => part.text)
			.join("");

	const emitAppendedDelta = (
		eventType: "thinking_delta" | "text_delta",
		contentIndex: number,
		previous: string,
		next: string,
	) => {
		if (next.startsWith(previous)) {
			const delta = next.slice(previous.length);
			if (delta.length > 0) {
				stream.push({ type: eventType, contentIndex, delta, partial: output });
			}
		}
	};
	const isLastPart = (parts: ReadonlyMap<number, unknown>, index: number): boolean => {
		for (const key of parts.keys()) if (key > index) return false;
		return true;
	};
	const appendReasoningSummaryDelta = (state: ReasoningState, summaryIndex: number, delta: string) => {
		const existing = state.summaryParts.get(summaryIndex);
		const summaryPart = existing ?? { text: "" };
		summaryPart.text += delta;
		if (existing && state.blockMatchesParts && isLastPart(state.summaryParts, summaryIndex)) {
			state.block.thinking += delta;
			if (delta.length > 0) stream.push({ type: "thinking_delta", contentIndex: state.blockIndex, delta, partial: output });
			return;
		}
		state.summaryParts.set(summaryIndex, summaryPart);
		const previousThinking = state.block.thinking;
		state.block.thinking = renderReasoningSummary(state.summaryParts);
		state.blockMatchesParts = true;
		emitAppendedDelta("thinking_delta", state.blockIndex, previousThinking, state.block.thinking);
	};
	const appendMessageDelta = (state: MessageState, contentIndex: number, type: "output_text" | "refusal", delta: string) => {
		const existing = state.parts.get(contentIndex);
		const messagePart = existing ?? { type, text: "" };
		if (messagePart.type !== type) return;
		messagePart.text += delta;
		if (existing && state.blockMatchesParts && isLastPart(state.parts, contentIndex)) {
			state.block.text += delta;
			if (delta.length > 0) stream.push({ type: "text_delta", contentIndex: state.blockIndex, delta, partial: output });
			return;
		}
		state.parts.set(contentIndex, messagePart);
		const previousText = state.block.text;
		state.block.text = renderMessageText(state.parts);
		state.blockMatchesParts = true;
		emitAppendedDelta("text_delta", state.blockIndex, previousText, state.block.text);
	};
	const pushToolCallDelta = (state: FunctionCallState, delta: string | undefined) => {
		if (delta !== undefined) stream.push({ type: "toolcall_delta", contentIndex: state.blockIndex, delta, partial: output });
	};
	const sendCustomInput = (block: ToolCallBlock, input: CustomToolInput, jsonDelta: string | undefined): string | undefined => {
		block.arguments = { [input.property]: input.buffer.input };
		if (input.unsent === "") return jsonDelta;
		const sent = input.unsent + (jsonDelta ?? "");
		input.unsent = "";
		return sent;
	};

	for await (const event of openaiStream) {
		if (event.type === "response.created") {
			output.responseId = event.response.id;
		} else if (event.type === "response.output_item.added") {
			const item = event.item as any;
			if (item.type === "reasoning") {
				const currentBlock: ThinkingBlock = { type: "thinking", thinking: "" };
				output.content.push(currentBlock);
				outputStates.set(event.output_index, {
					kind: "reasoning",
					blockIndex: blockIndex(),
					block: currentBlock,
					summaryParts: new Map(),
					blockMatchesParts: true,
				});
				stream.push({ type: "thinking_start", contentIndex: blockIndex(), partial: output });
			} else if (item.type === "message") {
				const currentBlock: TextBlock = { type: "text", text: "" };
				output.content.push(currentBlock);
				outputStates.set(event.output_index, {
					kind: "message",
					blockIndex: blockIndex(),
					block: currentBlock,
					parts: new Map(),
					blockMatchesParts: true,
				});
				stream.push({ type: "text_start", contentIndex: blockIndex(), partial: output });
			} else if (item.type === "function_call") {
				const args = createArgumentsStream();
				const currentBlock: ToolCallBlock = {
					type: "toolCall",
					id: `${item.call_id}|${item.id}`,
					name: item.name,
					arguments: item.arguments ? args.append(item.arguments) : {},
				};
				output.content.push(currentBlock);
				unfinishedToolCalls.add(currentBlock);
				outputStates.set(event.output_index, {
					kind: "function_call",
					blockIndex: blockIndex(),
					block: currentBlock,
					input: { kind: "json", arguments: args },
				});
				stream.push({ type: "toolcall_start", contentIndex: blockIndex(), partial: output });
			} else if (item.type === "custom_tool_call") {
				const property = options?.grammarToolInputProperties?.get(item.name) ?? "input";
				const input = item.input || "";
				const currentBlock: ToolCallBlock = {
					type: "toolCall",
					id: `${item.call_id}|${item.id}`,
					name: item.name,
					arguments: { [property]: input },
				};
				output.content.push(currentBlock);
				unfinishedToolCalls.add(currentBlock);
				outputStates.set(event.output_index, { kind: "function_call", blockIndex: blockIndex(), block: currentBlock, input: { kind: "custom", ...createCustomToolInput(property, input) } });
				stream.push({ type: "toolcall_start", contentIndex: blockIndex(), partial: output });
			}
		} else if (event.type === "response.reasoning_summary_part.added") {
			const state = outputStates.get(event.output_index);
			if (state?.kind === "reasoning") {
				state.summaryParts.set(event.summary_index, { text: event.part.text });
				state.blockMatchesParts = false;
			}
		} else if (event.type === "response.reasoning_summary_text.delta") {
			const state = outputStates.get(event.output_index);
			if (state?.kind === "reasoning") appendReasoningSummaryDelta(state, event.summary_index, event.delta);
		} else if (event.type === "response.reasoning_summary_part.done") {
			const state = outputStates.get(event.output_index);
			if (state?.kind === "reasoning") {
				state.summaryParts.set(event.summary_index, { text: event.part.text });
				state.block.thinking = renderReasoningSummary(state.summaryParts);
				state.blockMatchesParts = true;
			}
		} else if (event.type === "response.reasoning_text.delta") {
			const state = outputStates.get(event.output_index);
			if (state?.kind === "reasoning") {
				state.block.thinking += event.delta;
				state.blockMatchesParts = false;
				stream.push({ type: "thinking_delta", contentIndex: state.blockIndex, delta: event.delta, partial: output });
			}
		} else if (event.type === "response.content_part.added") {
			const state = outputStates.get(event.output_index);
			if (state?.kind === "message" && (event.part.type === "output_text" || event.part.type === "refusal")) {
				state.parts.set(event.content_index, {
					type: event.part.type,
					text: event.part.type === "output_text" ? event.part.text : event.part.refusal,
				});
				state.blockMatchesParts = false;
			}
		} else if (event.type === "response.output_text.delta") {
			const state = outputStates.get(event.output_index);
			if (state?.kind === "message") appendMessageDelta(state, event.content_index, "output_text", event.delta);
		} else if (event.type === "response.refusal.delta") {
			const state = outputStates.get(event.output_index);
			if (state?.kind === "message") appendMessageDelta(state, event.content_index, "refusal", event.delta);
		} else if (event.type === "response.function_call_arguments.delta") {
			const state = outputStates.get(event.output_index);
			if (state?.kind === "function_call" && state.input.kind === "json") {
				// Each delta is read once: re-parsing the whole text costs time quadratic in its length.
				state.block.arguments = state.input.arguments.append(event.delta);
				pushToolCallDelta(state, event.delta);
			}
		} else if (event.type === "response.function_call_arguments.done") {
			const state = outputStates.get(event.output_index);
			if (state?.kind === "function_call" && state.input.kind === "json") {
				const replaced = state.input.arguments.replace(event.arguments);
				state.block.arguments = replaced.arguments;
				if (replaced.delta) pushToolCallDelta(state, replaced.delta);
			}
		} else if ((event as any).type === "response.custom_tool_call_input.delta") {
			const customEvent = event as any;
			const state = outputStates.get(customEvent.output_index);
			if (state?.kind === "function_call" && state.input.kind === "custom") {
				pushToolCallDelta(state, sendCustomInput(state.block, state.input, appendGrammarToolInputJsonDelta(state.input.buffer, state.input.property, customEvent.delta)));
			}
		} else if ((event as any).type === "response.custom_tool_call_input.done") {
			const customEvent = event as any;
			const state = outputStates.get(customEvent.output_index);
			if (state?.kind === "function_call" && state.input.kind === "custom") {
				pushToolCallDelta(state, sendCustomInput(state.block, state.input, closeGrammarToolInputJson(state.input.buffer, state.input.property, customEvent.input)));
			}
		} else if (event.type === "response.output_item.done") {
			const item = event.item as any;
			if (item.type === "reasoning") {
				let state = outputStates.get(event.output_index);
				if (!state || state.kind !== "reasoning") {
					const currentBlock: ThinkingBlock = { type: "thinking", thinking: "" };
					output.content.push(currentBlock);
					state = { kind: "reasoning", blockIndex: blockIndex(), block: currentBlock, summaryParts: new Map(), blockMatchesParts: true };
					outputStates.set(event.output_index, state);
				}
				const summaryText = item.summary?.map((summary: { text?: string }) => summary.text ?? "").join("\n\n") || "";
				const contentText = (item as { content?: Array<{ text?: string }> }).content?.map((content) => content.text ?? "").filter(Boolean).join("\n\n") || "";
				state.block.thinking = summaryText || contentText || state.block.thinking;
				state.block.thinkingSignature = JSON.stringify(item);
				stream.push({ type: "thinking_end", contentIndex: state.blockIndex, content: state.block.thinking, partial: output });
				outputStates.delete(event.output_index);
			} else if (item.type === "message") {
				let state = outputStates.get(event.output_index);
				if (!state || state.kind !== "message") {
					const currentBlock: TextBlock = { type: "text", text: "" };
					output.content.push(currentBlock);
					state = { kind: "message", blockIndex: blockIndex(), block: currentBlock, parts: new Map(), blockMatchesParts: true };
					outputStates.set(event.output_index, state);
				}
				// Null-tolerant like the reasoning branch above: OpenAI-compatible streams
				// (e.g. vLLM) can emit an empty message item with content: null before a
				// function_call. Without the guard, item.content.map throws and the stream
				// aborts and silently drops the tool call.
				state.block.text = (item.content ?? []).map((content: { type?: string; text?: string; refusal?: string }) => (content.type === "output_text" ? content.text ?? "" : content.refusal ?? "")).join("");
				state.block.textSignature = encodeTextSignatureV1(item.id, item.phase ?? undefined);
				stream.push({ type: "text_end", contentIndex: state.blockIndex, content: state.block.text, partial: output });
				outputStates.delete(event.output_index);
			} else if (item.type === "function_call") {
				const state = outputStates.get(event.output_index);
				const args = state?.kind === "function_call" && state.input.kind === "json" ? state.input.arguments : createArgumentsStream();
				if (item.arguments) args.replace(item.arguments);
				const toolCall = state?.kind === "function_call"
					? state.block
					: (() => {
						const fallbackToolCall: ToolCallBlock = {
							type: "toolCall",
							id: `${item.call_id}|${item.id}`,
							name: item.name,
							arguments: {},
						};
						output.content.push(fallbackToolCall);
						return fallbackToolCall;
					})();
				// Malformed final arguments carry `argumentsError`, so validation reports the text the model sent.
				Object.assign(toolCall, args.finish());
				unfinishedToolCalls.delete(toolCall);
				const toolCallIndex = state?.kind === "function_call" ? state.blockIndex : blockIndex();
				stream.push({ type: "toolcall_end", contentIndex: toolCallIndex, toolCall, partial: output });
				outputStates.delete(event.output_index);
			} else if (item.type === "custom_tool_call") {
				let state = outputStates.get(event.output_index);
				if (!state || state.kind !== "function_call" || state.input.kind !== "custom") {
					const property = options?.grammarToolInputProperties?.get(item.name) ?? "input";
					const currentBlock: ToolCallBlock = {
						type: "toolCall",
						id: `${item.call_id}|${item.id}`,
						name: item.name,
						arguments: { [property]: "" },
					};
					output.content.push(currentBlock);
					state = { kind: "function_call", blockIndex: blockIndex(), block: currentBlock, input: { kind: "custom", ...createCustomToolInput(property, "") } };
				}
				if (state.input.kind === "custom") pushToolCallDelta(state, sendCustomInput(state.block, state.input, closeGrammarToolInputJson(state.input.buffer, state.input.property, item.input)));
				unfinishedToolCalls.delete(state.block);
				stream.push({ type: "toolcall_end", contentIndex: state.blockIndex, toolCall: state.block, partial: output });
				outputStates.delete(event.output_index);
			} else if (item.type === "image_generation_call") {
				appendImageGenerationCall(item);
				outputStates.delete(event.output_index);
			}
		} else if (event.type === "response.completed" || event.type === "response.incomplete") {
			sawTerminalResponseEvent = true;
			const response = event.response;
			const finalOutput = Array.isArray((response as { output?: unknown } | undefined)?.output)
				? ((response as unknown as { output: unknown[] }).output)
				: [];
			for (const item of finalOutput) {
				if ((item as { type?: unknown } | undefined)?.type === "image_generation_call") appendImageGenerationCall(item);
			}
			if (response?.id) output.responseId = response.id;
			if (response?.usage) {
				const inputDetails = response.usage.input_tokens_details as { cached_tokens?: number; cache_write_tokens?: number } | undefined;
				const cachedTokens = inputDetails?.cached_tokens || 0;
				const cacheWriteTokens = inputDetails?.cache_write_tokens || 0;
				const reasoningTokens = (response.usage as { output_tokens_details?: { reasoning_tokens?: number } }).output_tokens_details?.reasoning_tokens || 0;
				output.usage = {
					input: Math.max(0, (response.usage.input_tokens || 0) - cachedTokens - cacheWriteTokens),
					output: response.usage.output_tokens || 0,
					cacheRead: cachedTokens,
					cacheWrite: cacheWriteTokens,
					totalTokens: response.usage.total_tokens || 0,
					cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
				};
				(output.usage as Usage & { reasoning?: number }).reasoning = reasoningTokens;
			}
			calculateCost(model, output.usage);
			if (options?.applyServiceTierPricing) {
				const serviceTier = options.resolveServiceTier
					? options.resolveServiceTier(response?.service_tier, options.serviceTier)
					: (response?.service_tier ?? options.serviceTier);
				options.applyServiceTierPricing(output.usage, serviceTier);
			}
			output.stopReason = mapStopReason(response?.status);
			if (output.content.some((block) => block.type === "toolCall") && output.stopReason === "stop") {
				output.stopReason = "toolUse";
			}
		} else if (event.type === "error") {
			const details = [event.code, event.message].filter(Boolean).join(": ");
			throw new Error(details || "Unknown error");
		} else if (event.type === "response.failed") {
			sawTerminalResponseEvent = true;
			const error = event.response?.error;
			const details = (event.response as { incomplete_details?: { reason?: string } } | undefined)?.incomplete_details;
			const msg = error
				? `${error.code || "unknown"}: ${error.message || "no message"}`
				: details?.reason
					? `incomplete: ${details.reason}`
					: "Unknown error (no error details in response)";
			throw new Error(msg);
		}
	}
	if (!sawTerminalResponseEvent) {
		throw Object.assign(new Error("OpenAI Responses stream ended before a terminal response event"), { code: "RESPONSES_TERMINAL_MISSING" });
	}
	// The agent runs every tool call in the final message. Refuse calls whose output_item.done
	// never arrived: their arguments may be cut off, or mixed up when a server omits output_index.
	if (output.stopReason === "toolUse") {
		for (const toolCall of unfinishedToolCalls) {
			throw new Error(`OpenAI Responses stream completed with an unfinished tool call: ${toolCall.name} (${toolCall.id})`);
		}
	}
}

function mapStopReason(status: string | undefined): AssistantMessage["stopReason"] {
	if (!status) return "stop";
	switch (status) {
		case "completed":
			return "stop";
		case "incomplete":
			return "length";
		case "failed":
		case "cancelled":
			return "error";
		case "in_progress":
		case "queued":
			return "stop";
		default:
			throw new Error(`Unhandled stop reason: ${status}`);
	}
}
