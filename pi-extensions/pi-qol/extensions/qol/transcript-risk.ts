// Transcript risk for /context: estimate serialized request payload size and
// warn before it crosses a char budget, even when the token count alone has
// not reached the context window. Keeps /context independent of compaction.ts
// (no summarizer/fs/artifact dependencies on the UI path).

import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { convertToLlm, serializeConversation } from "@earendil-works/pi-coding-agent";
import { evaluateTranscriptRisk, type TranscriptRiskResult } from "./budget-guard.js";

function stripThinking(messages: any[]): any[] {
	return messages.map((message: any) => {
		if (message.role !== "assistant" || !Array.isArray(message.content)) return message;
		return { ...message, content: message.content.filter((part: any) => part?.type !== "thinking") };
	});
}

export function transcriptRiskState(messages: AgentMessage[], threshold: number): TranscriptRiskResult {
	if (!Array.isArray(messages) || messages.length === 0 || threshold <= 0) {
		return { chars: 0, exceeded: false, messageCount: messages?.length ?? 0, threshold };
	}
	try {
		const serialized = serializeConversation(stripThinking(convertToLlm(messages)));
		return evaluateTranscriptRisk({ chars: serialized.length, messageCount: messages.length, threshold });
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return evaluateTranscriptRisk({ chars: 0, error: message, messageCount: messages.length, threshold });
	}
}
