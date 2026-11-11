import type { ToolResultMessage } from "@earendil-works/pi-ai";
import type { RequestId } from "./protocol.js";

export interface PendingToolCall {
	requestId: RequestId;
	callId: string;
	piToolName: string;
}

type ContentItem = { type: "inputText"; text: string } | { type: "inputImage"; imageUrl: string };

/** A `DynamicToolCallResponse` addressed to the server request it answers. */
export interface ToolCallAnswer {
	requestId: RequestId;
	result: { contentItems: ContentItem[]; success: boolean };
}

/** Sent for a call Pi's transcript carries no result for, as when the user
 * aborted while the tool ran. The model reads it as a failed call. */
export const LOST_TOOL_RESULT_TEXT =
	"tool-result-lost=interrupted\n"
	+ "Pi Codex bridge: the result of this tool call was lost (the turn was interrupted). "
	+ "Treat the call as failed; it may or may not have executed. Run the tool again if its output is still needed.";

function contentItems(result: ToolResultMessage): ContentItem[] {
	const items = result.content.map((item): ContentItem => item.type === "text"
		? { type: "inputText", text: item.text }
		: { type: "inputImage", imageUrl: `data:${item.mimeType};base64,${item.data}` });
	return items.length > 0 ? items : [{ type: "inputText", text: "" }];
}

/**
 * One answer per pending call, in the order the calls arrived. A call with a
 * Pi result is answered with it; a call without one is answered as lost. A
 * result that matches no pending call, repeats one, or names another tool is
 * refused before any answer is built, so a refused batch answers nothing.
 */
export function answerToolCalls(pending: readonly PendingToolCall[], results: readonly ToolResultMessage[]): ToolCallAnswer[] {
	const byCall = new Map(pending.map((call) => [call.callId, call]));
	const resultByCall = new Map<string, ToolResultMessage>();
	for (const result of results) {
		if (resultByCall.has(result.toolCallId)) throw new Error(`codex-tool-result-duplicate call=${result.toolCallId}`);
		const call = byCall.get(result.toolCallId);
		if (!call) throw new Error(`codex-tool-result-unmatched call=${result.toolCallId}`);
		if (call.piToolName !== result.toolName) throw new Error(`codex-tool-result-name-mismatch call=${result.toolCallId}`);
		resultByCall.set(result.toolCallId, result);
	}
	return pending.map((call) => {
		const result = resultByCall.get(call.callId);
		return {
			requestId: call.requestId,
			result: result
				? { contentItems: contentItems(result), success: !result.isError }
				: { contentItems: [{ type: "inputText", text: LOST_TOOL_RESULT_TEXT }], success: false },
		};
	});
}
