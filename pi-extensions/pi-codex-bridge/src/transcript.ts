import type { ImageContent, Message, TextContent, ToolResultMessage } from "@earendil-works/pi-ai";
import { PROVIDER_ID } from "./models.js";
import type { JsonObject } from "./protocol.js";

/**
 * Where a Pi assistant message left its Codex thread: the thread, the turn
 * that produced the message, and the signature of the tools the thread was
 * started with. It is stored as the message's `responseId`.
 */
export interface Boundary {
	index: number;
	threadId: string;
	turnId: string;
	toolSignature: string;
	stopReason: "stop" | "toolUse";
}

const RESPONSE_ID_PREFIX = "codex-thread";

export function encodeResponseId(threadId: string, turnId: string, toolSignature: string): string {
	return `${RESPONSE_ID_PREFIX}:${threadId}:${turnId}:${toolSignature}`;
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
		if (parts?.length !== 4 || parts[0] !== RESPONSE_ID_PREFIX || parts.some((part) => part.length === 0)) continue;
		return { index, threadId: parts[1], turnId: parts[2], toolSignature: parts[3], stopReason: message.stopReason };
	}
	return undefined;
}

export function userInput(content: string | Array<TextContent | ImageContent>): JsonObject[] {
	if (typeof content === "string") return [{ type: "text", text: content, text_elements: [] }];
	return content.map((item): JsonObject => item.type === "text"
		? { type: "text", text: item.text, text_elements: [] }
		: { type: "image", url: `data:${item.mimeType};base64,${item.data}` });
}

/** What follows a boundary: the user input for Codex and the tool results. */
export function afterBoundary(messages: readonly Message[], boundary: Boundary): { input: JsonObject[]; toolResults: ToolResultMessage[] } {
	const later = messages.slice(boundary.index + 1);
	return {
		input: later.flatMap((message) => message.role === "user" ? userInput(message.content) : []),
		toolResults: later.filter((message): message is ToolResultMessage => message.role === "toolResult"),
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
	return message.content.flatMap((item): JsonObject[] => item.type === "image" ? [{ type: "image", url: `data:${item.mimeType};base64,${item.data}` }] : []);
}

/**
 * The first turn of a new thread: one text item that carries every earlier
 * message, the images those messages held, then the trailing user messages
 * with their own text and images, so a thread started for a transcript Codex
 * does not hold still sees the whole conversation.
 */
export function replayInput(messages: readonly Message[]): JsonObject[] {
	const conversation = messages.filter((message): message is ConversationMessage => message.role !== "system");
	let start = conversation.length;
	while (start > 0 && conversation[start - 1].role === "user") start--;
	const history = conversation.slice(0, start);
	const trailing = conversation.slice(start).flatMap((message) => message.role === "user" ? userInput(message.content) : []);
	if (history.length === 0) return trailing;
	const replay = `Conversation so far, replayed from Pi:\n\n${history.map(historyEntry).join("\n\n")}`;
	return [{ type: "text", text: replay, text_elements: [] }, ...history.flatMap(historyImages), ...trailing];
}
