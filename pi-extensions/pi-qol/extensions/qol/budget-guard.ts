// Pure helpers for the long-session compaction budget guard. Kept dependency-free
// so the chunking + risk math can be unit-tested without pulling the pi-ai or
// pi-coding-agent peer deps. The wiring into the qol extension (settings reads,
// session manager, ctx.compact) lives in compaction.ts and qol.ts.

export interface BudgetTriggerInput {
	enabled: boolean;
	tokens: number;
	contextWindow?: number;
	tokenLimit: number;
	percentLimit: number;
}

export interface BudgetTrigger {
	reason: string;
	key: string;
	tokens: number;
	contextWindow?: number;
	percent?: number;
}

export function computeBudgetTrigger(input: BudgetTriggerInput): BudgetTrigger | undefined {
	if (!input.enabled) return undefined;
	if (!Number.isFinite(input.tokens) || input.tokens <= 0) return undefined;
	const tokenLimit = Math.floor(input.tokenLimit);
	if (tokenLimit > 0 && input.tokens >= tokenLimit) {
		const bucket = Math.floor(input.tokens / Math.max(1, tokenLimit));
		return {
			contextWindow: input.contextWindow,
			key: `tokens:${tokenLimit}:${bucket}`,
			percent: input.contextWindow ? (input.tokens / input.contextWindow) * 100 : undefined,
			reason: `${input.tokens.toLocaleString()} tokens >= ${tokenLimit.toLocaleString()} budget token limit`,
			tokens: input.tokens,
		};
	}
	const percentLimit = input.percentLimit;
	if (percentLimit > 0 && input.contextWindow) {
		const percent = (input.tokens / input.contextWindow) * 100;
		if (percent >= percentLimit) {
			const bucket = Math.floor(percent / Math.max(1, percentLimit));
			return {
				contextWindow: input.contextWindow,
				key: `percent:${percentLimit}:${bucket}`,
				percent,
				reason: `${percent.toFixed(1)}% context >= ${percentLimit}% budget guard`,
				tokens: input.tokens,
			};
		}
	}
	return undefined;
}

export function chunkConversationText(text: string, maxChars: number): string[] {
	if (maxChars <= 0 || text.length <= maxChars) return [text];
	const chunks: string[] = [];
	const breaks = /\n{2,}/g;
	let cursor = 0;
	while (cursor < text.length) {
		const remaining = text.length - cursor;
		if (remaining <= maxChars) {
			chunks.push(text.slice(cursor));
			break;
		}
		const slice = text.slice(cursor, cursor + maxChars);
		breaks.lastIndex = 0;
		let breakAt = -1;
		let match: RegExpExecArray | null;
		// Pick the latest paragraph break inside the slice so chunks land on
		// message boundaries. The half-slice floor avoids degenerate tiny chunks
		// when the only paragraph break is right at the start of the window.
		while ((match = breaks.exec(slice)) !== null) {
			if (match.index >= Math.floor(maxChars / 2)) breakAt = match.index + match[0].length;
		}
		const end = breakAt > 0 ? cursor + breakAt : cursor + maxChars;
		chunks.push(text.slice(cursor, end));
		cursor = end;
	}
	return chunks;
}

export interface TranscriptRiskInput {
	chars: number;
	threshold: number;
	messageCount: number;
}

export interface TranscriptRiskResult extends TranscriptRiskInput {
	exceeded: boolean;
}

export function evaluateTranscriptRisk(input: TranscriptRiskInput): TranscriptRiskResult {
	if (input.threshold <= 0 || input.messageCount <= 0 || input.chars <= 0) {
		return { chars: input.chars, exceeded: false, messageCount: input.messageCount, threshold: input.threshold };
	}
	return {
		chars: input.chars,
		exceeded: input.chars >= input.threshold,
		messageCount: input.messageCount,
		threshold: input.threshold,
	};
}
