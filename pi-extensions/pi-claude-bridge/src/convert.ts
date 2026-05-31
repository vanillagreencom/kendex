// Pure pi→Anthropic message conversion helpers.
// Extracted so they can be tested without pulling in the full extension runtime.

import type { Message as PiMessage } from "@earendil-works/pi-ai";
import type { ContentBlock, Message as SessionMessage } from "cc-session-io";
import { pascalCase } from "change-case";

export const PROVIDER_ID = "claude-bridge";

export const PI_TO_SDK_TOOL_NAME: Record<string, string> = {
	read: "Read", write: "Write", edit: "Edit", bash: "Bash",
};

export function sanitizeToolId(id: string, cache: Map<string, string>): string {
	const existing = cache.get(id);
	if (existing) return existing;
	const clean = id.replace(/[^a-zA-Z0-9_-]/g, "_");
	cache.set(id, clean);
	return clean;
}

export function mapPiToolNameToSdk(name: string, customToolNameToSdk?: Map<string, string>): string {
	if (!name) return "";
	const normalized = name.toLowerCase();
	if (customToolNameToSdk) {
		const mapped = customToolNameToSdk.get(name) ?? customToolNameToSdk.get(normalized);
		if (mapped) return mapped;
	}
	if (PI_TO_SDK_TOOL_NAME[normalized]) return PI_TO_SDK_TOOL_NAME[normalized];
	return pascalCase(name);
}

export function messageContentToText(
	content: string | Array<{ type: string; text?: string; data?: string; mimeType?: string }>,
): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	const parts = [];
	let hasText = false;
	for (const block of content) {
		if (block.type === "text" && block.text) { parts.push(block.text); hasText = true; }
		else if (block.type !== "text" && block.type !== "image") { parts.push(`[${block.type}]`); }
	}
	return hasText ? parts.join("\n") : "";
}

function imageBlockToAnthropic(block: { data?: string; mimeType?: string }): ContentBlock | undefined {
	if (!block.data || !block.mimeType) return undefined;
	return { type: "image", source: { type: "base64", media_type: block.mimeType, data: block.data } } as ContentBlock;
}

function toolResultContentToAnthropic(
	content: string | Array<{ type: string; text?: string; data?: string; mimeType?: string }>,
): string | ContentBlock[] {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	const blocks: ContentBlock[] = [];
	for (const block of content) {
		if (block.type === "text" && block.text) {
			blocks.push({ type: "text", text: block.text });
		} else if (block.type === "image") {
			const image = imageBlockToAnthropic(block);
			if (image) blocks.push(image);
		} else if (block.type) {
			blocks.push({ type: "text", text: `[${block.type}]` });
		}
	}
	if (blocks.length === 0) return "";
	if (blocks.every((block) => block.type === "text")) return blocks.map((block) => (block as { text: string }).text).join("\n");
	return blocks;
}

function assistantProvenancePrefix(msg: PiMessage): string | undefined {
	if (msg.role !== "assistant") return undefined;
	const provider = typeof (msg as any).provider === "string" ? (msg as any).provider : undefined;
	const model = typeof (msg as any).model === "string" ? (msg as any).model : undefined;
	const api = typeof (msg as any).api === "string" ? (msg as any).api : undefined;
	if (!provider && !model && !api) return undefined;
	if (provider === PROVIDER_ID || api === "anthropic") return undefined;
	return `[Prior Pi assistant response from ${provider ?? api ?? "unknown-provider"}${model ? `/${model}` : ""}]\n`;
}

/** Convert pi message array to Anthropic API format. */
export function convertPiMessages(
	messages: PiMessage[],
	customToolNameToSdk?: Map<string, string>,
): { anthropicMessages: SessionMessage[]; sanitizedIds: Map<string, string> } {
	const anthropicMessages = [];
	const sanitizedIds = new Map();

	for (let i = 0; i < messages.length; i++) {
		const msg = messages[i];
		if (msg.role === "user") {
			if (typeof msg.content === "string") {
				anthropicMessages.push({ role: "user", content: msg.content || "[empty]" });
			} else if (Array.isArray(msg.content)) {
				const parts = [];
				for (const block of msg.content) {
					if (block.type === "text" && block.text) parts.push({ type: "text", text: block.text });
					else if (block.type === "image" && block.data && block.mimeType) {
						parts.push(imageBlockToAnthropic(block));
					}
				}
				anthropicMessages.push({ role: "user", content: parts.filter(Boolean).length ? parts.filter(Boolean) as ContentBlock[] : "[image]" });
			} else {
				anthropicMessages.push({ role: "user", content: "[empty]" });
			}
		} else if (msg.role === "assistant") {
			const content = Array.isArray(msg.content) ? msg.content : [];
			const blocks = [];
			const provenance = assistantProvenancePrefix(msg);
			if (provenance) blocks.push({ type: "text", text: provenance });
			for (const block of content) {
				if (block.type === "text" && block.text) {
					blocks.push({ type: "text", text: block.text });
				} else if (block.type === "thinking") {
					const sig = block.thinkingSignature;
					const isAnthropicProvider = msg.provider === PROVIDER_ID || msg.api === "anthropic";
					if (isAnthropicProvider && sig) {
						blocks.push({ type: "thinking", thinking: block.thinking ?? "", signature: sig });
					}
				} else if (block.type === "toolCall") {
					const toolName = mapPiToolNameToSdk(block.name, customToolNameToSdk);
					blocks.push({ type: "tool_use", id: sanitizeToolId(block.id, sanitizedIds), name: toolName, input: block.arguments ?? {} });
				}
			}
			if (!blocks.length) blocks.push({ type: "text", text: "[incompatible content omitted]" });
			anthropicMessages.push({ role: "assistant", content: blocks });
		} else if (msg.role === "toolResult") {
			const blocks = [];
			for (; i < messages.length; i++) {
				const toolMsg = messages[i];
				if (toolMsg.role !== "toolResult") { i--; break; }
				const content = toolResultContentToAnthropic(toolMsg.content);
				blocks.push({
					type: "tool_result",
					tool_use_id: sanitizeToolId(toolMsg.toolCallId, sanitizedIds),
					content: content || "",
					is_error: toolMsg.isError,
				});
			}
			anthropicMessages.push({ role: "user", content: blocks });
		}
	}

	return { anthropicMessages, sanitizedIds };
}
