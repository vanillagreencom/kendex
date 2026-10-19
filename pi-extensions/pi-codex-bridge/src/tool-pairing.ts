import type { ToolResultMessage } from "@earendil-works/pi-ai";
import type { DynamicToolCall, RequestId } from "./protocol.js";

interface ProtocolResponder {
	respond(id: RequestId, result: unknown): void;
}

export interface PendingToolCall {
	requestId: RequestId;
	params: DynamicToolCall;
	piToolName: string;
}

export function toolResultText(result: ToolResultMessage): string {
	const parts: string[] = [];
	for (const item of result.content) {
		if (item.type === "text") parts.push(item.text);
		else if (item.type === "image") parts.push(`[image ${item.mimeType}]`);
	}
	return parts.join("\n");
}

/** Answer each pending app-server request once, using the matching Pi call id. */
export function deliverToolResults(
	client: ProtocolResponder,
	pending: Map<string, PendingToolCall>,
	results: ToolResultMessage[],
): void {
	const seen = new Set<string>();
	for (const result of results) {
		if (seen.has(result.toolCallId)) throw new Error(`codex-tool-result-duplicate call=${result.toolCallId}`);
		seen.add(result.toolCallId);
		const call = pending.get(result.toolCallId);
		if (!call) throw new Error(`codex-tool-result-unmatched call=${result.toolCallId}`);
		if (call.piToolName !== result.toolName) {
			throw new Error(`codex-tool-result-name-mismatch call=${result.toolCallId}`);
		}
	}
	if (seen.size !== pending.size) {
		throw new Error(`codex-tool-result-missing count=${pending.size - seen.size}`);
	}
	for (const result of results) {
		const call = pending.get(result.toolCallId);
		if (!call) throw new Error(`codex-tool-result-unmatched call=${result.toolCallId}`);
		client.respond(call.requestId, {
			contentItems: [{ type: "inputText", text: toolResultText(result) }],
			success: !result.isError,
		});
		pending.delete(result.toolCallId);
	}
}
