import { createHash } from "node:crypto";
import { getCurrentSystemPrompt, type ImageContent, type Message, type TextContent, type ToolResultMessage } from "@earendil-works/pi-ai";
import { PROVIDER_ID } from "./models.js";
import type { JsonObject } from "./protocol.js";

/**
 * Where a Pi assistant message left its Codex thread. The message's
 * `responseId` stores the thread, the turn that produced the message, and the
 * two things Codex fixes at thread start: the signature of Pi's tools and the
 * digest of Pi's system prompt. The message itself gives the model that wrote
 * it and the tool calls it made.
 */
export interface Boundary {
	index: number;
	threadId: string;
	turnId: string;
	toolSignature: string;
	promptDigest: string;
	model: string;
	/** The message's tool calls, in order: the batch Codex waits on. */
	toolCallIds: string[];
	stopReason: "stop" | "toolUse";
}

const RESPONSE_ID_PREFIX = "codex-thread";

export function encodeResponseId(threadId: string, turnId: string, toolSignature: string, promptDigest: string): string {
	return `${RESPONSE_ID_PREFIX}:${threadId}:${turnId}:${toolSignature}:${promptDigest}`;
}

/** Identifies Pi's current system prompt. Codex takes the prompt only at
 * thread start (`baseInstructions`), so a thread serves only this prompt. */
export function systemPromptDigest(messages: readonly Message[]): string {
	return createHash("sha256").update(getCurrentSystemPrompt(messages)).digest("hex").slice(0, 16);
}

/** The latest pi-codex assistant message that ended cleanly. An errored or
 * aborted message is not a boundary: Codex may hold part of that turn while
 * Pi's transcript holds another part. */
export function findBoundary(messages: readonly Message[]): Boundary | undefined {
	for (let index = messages.length - 1; index >= 0; index--) {
		const message = messages[index];
		if (message.role !== "assistant" || message.provider !== PROVIDER_ID) continue;
		if (message.stopReason !== "stop" && message.stopReason !== "toolUse") continue;
		const parts = message.responseId?.split(":");
		if (parts?.length !== 5 || parts[0] !== RESPONSE_ID_PREFIX || parts.some((part) => part.length === 0)) continue;
		return {
			index,
			threadId: parts[1],
			turnId: parts[2],
			toolSignature: parts[3],
			promptDigest: parts[4],
			model: message.model,
			toolCallIds: message.content.flatMap((item) => item.type === "toolCall" ? [item.id] : []),
			stopReason: message.stopReason,
		};
	}
	return undefined;
}

function textItem(text: string): JsonObject {
	return { type: "text", text, text_elements: [] };
}

function imageItem(image: ImageContent): JsonObject {
	return { type: "image", url: `data:${image.mimeType};base64,${image.data}` };
}

export function userInput(content: string | Array<TextContent | ImageContent>): JsonObject[] {
	if (typeof content === "string") return [textItem(content)];
	return content.map((item) => item.type === "text" ? textItem(item.text) : imageItem(item));
}

/**
 * What follows a boundary: the user input for Codex and the tool results.
 * `clean` is false when anything else follows: another model's turn, a
 * pi-codex message that errored or was aborted, or tool results after a
 * boundary that called no tool. Codex then does not hold what Pi holds.
 */
export function afterBoundary(messages: readonly Message[], boundary: Boundary): { input: JsonObject[]; toolResults: ToolResultMessage[]; clean: boolean } {
	const later = messages.slice(boundary.index + 1);
	return {
		input: later.flatMap((message) => message.role === "user" ? userInput(message.content) : []),
		toolResults: later.filter((message): message is ToolResultMessage => message.role === "toolResult"),
		clean: later.every((message) => message.role === "user" || (message.role === "toolResult" && boundary.stopReason === "toolUse")),
	};
}

function text(content: string | Array<{ type: string; text?: string }>): string {
	if (typeof content === "string") return content;
	return content.flatMap((item) => item.type === "text" && typeof item.text === "string" ? [item.text] : []).join("\n");
}

type ConversationMessage = Exclude<Message, { role: "system" }>;

function historyEntry(message: ConversationMessage): string {
	if (message.role === "user") return `User:\n${text(message.content)}`;
	if (message.role === "toolResult") return `Tool result (${message.toolName}):\n${text(message.content)}`;
	const parts = message.content.flatMap((item) => {
		if (item.type === "text") return [item.text];
		if (item.type === "toolCall") return [`[called ${item.name} ${JSON.stringify(item.arguments)}]`];
		return [];
	});
	return `Assistant:\n${parts.join("\n")}`;
}

function historyImages(message: ConversationMessage): JsonObject[] {
	if (message.role !== "user" && message.role !== "toolResult") return [];
	if (typeof message.content === "string") return [];
	return message.content.flatMap((item) => item.type === "image" ? [imageItem(item)] : []);
}

/**
 * The first turn of a new thread: every earlier message as replayed text, in
 * order, each message's images right after its own text, then the trailing
 * user messages with their own text and images, so a thread started for a
 * transcript Codex does not hold still sees the whole conversation.
 */
export function replayInput(messages: readonly Message[]): JsonObject[] {
	const conversation = messages.filter((message): message is ConversationMessage => message.role !== "system");
	let start = conversation.length;
	while (start > 0 && conversation[start - 1].role === "user") start--;
	const history = conversation.slice(0, start);
	const trailing = conversation.slice(start).flatMap((message) => message.role === "user" ? userInput(message.content) : []);
	if (history.length === 0) return trailing;
	const replay: JsonObject[] = [];
	let entries = ["Conversation so far, replayed from Pi:"];
	for (const message of history) {
		entries.push(historyEntry(message));
		const images = historyImages(message);
		if (images.length === 0) continue;
		replay.push(textItem(entries.join("\n\n")), ...images);
		entries = [];
	}
	if (entries.length > 0) replay.push(textItem(entries.join("\n\n")));
	return [...replay, ...trailing];
}
