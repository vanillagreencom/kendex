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
	error?: string;
}

export interface TranscriptRiskResult extends TranscriptRiskInput {
	exceeded: boolean;
}

export function evaluateTranscriptRisk(input: TranscriptRiskInput): TranscriptRiskResult {
	if (input.error) {
		return { chars: 0, error: input.error, exceeded: false, messageCount: input.messageCount, threshold: input.threshold };
	}
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

/**
 * Sentinel marker injected into customInstructions when budget guard triggers
 * a compaction. Detected by handleQolCompaction to force the bounded QOL path
 * + handoff artifact write regardless of the global compaction.customEnabled
 * setting.
 */
export const QOL_BUDGET_GUARD_SENTINEL = "[QOL_BUDGET_GUARD]";

export function isBudgetGuardCompaction(customInstructions: unknown): boolean {
	return typeof customInstructions === "string" && customInstructions.includes(QOL_BUDGET_GUARD_SENTINEL);
}

export interface SummarizeRequest {
	text: string;
	customInstructions?: string;
	previousSummary?: string;
	skipChunking: true;
}

export interface SummarizeOutcome {
	model: string;
	summary: string;
	via: "model" | "remote";
}

export type SummarizeFn = (request: SummarizeRequest) => Promise<SummarizeOutcome>;

export interface OrchestrateChunkedOptions {
	text: string;
	summarize: SummarizeFn;
	maxInputChars: number;
	signal?: AbortSignal;
	customInstructions?: string;
	previousSummary?: string;
	notify?: (message: string, level?: "info" | "warning" | "error") => void;
}

export interface OrchestrateChunkedResult extends SummarizeOutcome {
	chunkCount: number;
	reduceLevels: number;
	requestCount: number;
}

function instructionsForChunk(custom: string | undefined, index: number, total: number): string {
	const base = `This is chunk ${index + 1} of ${total} from a long conversation. Preserve all concrete files, commands, decisions, blockers, and current tasks visible in this chunk so a follow-up summary-of-summaries pass can stitch the timeline together.`;
	return custom?.trim() ? `${custom.trim()}\n\n${base}` : base;
}

function instructionsForReduce(custom: string | undefined, level: number, count: number): string {
	const base = `Tree-reduce level ${level}: merge the following ${count} chunk summaries (oldest first) into a single continuation summary. De-duplicate facts, keep exact files/commands/paths, preserve decisions, blockers, current tasks, and any artifact paths. If chunks contradict, prefer the most recent.`;
	return custom?.trim() ? `${custom.trim()}\n\n${base}` : base;
}

function partition(items: string[], maxChars: number, separator: string, minBatch: number = 1): string[][] {
	const groups: string[][] = [];
	let current: string[] = [];
	let currentLen = 0;
	const sepLen = separator.length;
	for (const item of items) {
		const projected = current.length === 0 ? item.length : currentLen + sepLen + item.length;
		if (current.length >= minBatch && projected > maxChars) {
			groups.push(current);
			current = [item];
			currentLen = item.length;
		} else {
			current.push(item);
			currentLen = projected;
		}
	}
	if (current.length > 0) groups.push(current);
	return groups;
}

/**
 * Bounded chunk + tree-reduce orchestrator. Every summarize() request gets
 * a text body that is guaranteed to be <= maxInputChars (the chunker enforces
 * the cap for source chunks; partition enforces it for reduce batches). When
 * a reduce batch contains a single partial that's already over cap the
 * orchestrator hard-truncates rather than retrying forever.
 */
export async function orchestrateChunkedSummary(options: OrchestrateChunkedOptions): Promise<OrchestrateChunkedResult> {
	const { customInstructions, maxInputChars, notify, previousSummary, signal, summarize, text } = options;
	if (maxInputChars <= 0 || text.length <= maxInputChars) {
		if (signal?.aborted) throw new Error("Compaction aborted");
		const single = await summarize({
			customInstructions,
			previousSummary,
			skipChunking: true,
			text,
		});
		return { ...single, chunkCount: 1, reduceLevels: 0, requestCount: 1 };
	}
	const chunks = chunkConversationText(text, maxInputChars);
	notify?.(`QOL chunked compaction: summarizing ${chunks.length} chunk(s) (input ${text.length.toLocaleString()} chars > ${maxInputChars.toLocaleString()} cap).`, "info");
	let requestCount = 0;
	const partials: string[] = [];
	let lastVia: "model" | "remote" = "model";
	let lastModel = "";
	let previous = previousSummary;
	for (let i = 0; i < chunks.length; i += 1) {
		if (signal?.aborted) throw new Error("Compaction aborted");
		const chunk = chunks[i] ?? "";
		const partial = await summarize({
			customInstructions: instructionsForChunk(customInstructions, i, chunks.length),
			previousSummary: previous,
			skipChunking: true,
			text: chunk,
		});
		requestCount += 1;
		if (!partial.summary.trim()) throw new Error(`Chunk ${i + 1}/${chunks.length} summary was empty`);
		partials.push(`### Chunk ${i + 1}/${chunks.length}\n${partial.summary.trim()}`);
		previous = partial.summary;
		lastVia = partial.via;
		lastModel = partial.model;
	}

	let level = partials;
	let reduceLevels = 0;
	const separator = "\n\n";
	const MAX_REDUCE_LEVELS = 12;
	while (true) {
		const combined = level.join(separator);
		if (combined.length <= maxInputChars) {
			if (signal?.aborted) throw new Error("Compaction aborted");
			const final = await summarize({
				customInstructions: instructionsForReduce(customInstructions, reduceLevels + 1, level.length),
				previousSummary,
				skipChunking: true,
				text: combined,
			});
			requestCount += 1;
			if (!final.summary.trim()) throw new Error("Final reduce summary was empty");
			return {
				chunkCount: chunks.length,
				model: final.model || lastModel,
				reduceLevels: reduceLevels + 1,
				requestCount,
				summary: final.summary,
				via: final.via || lastVia,
			};
		}
		reduceLevels += 1;
		if (reduceLevels > MAX_REDUCE_LEVELS) {
			// Defensive: refuse to spin forever if a model keeps emitting
			// summaries larger than the cap. Final summarize over the
			// hard-truncated joined level returns a bounded answer.
			const truncated = combined.slice(0, maxInputChars);
			const final = await summarize({
				customInstructions: instructionsForReduce(customInstructions, reduceLevels, level.length),
				previousSummary,
				skipChunking: true,
				text: truncated,
			});
			requestCount += 1;
			return {
				chunkCount: chunks.length,
				model: final.model || lastModel,
				reduceLevels,
				requestCount,
				summary: final.summary,
				via: final.via || lastVia,
			};
		}
		// Force-pair: at level >1 every batch must contain >=2 items so we
		// always make progress. The summarize() call gets a text that may
		// exceed the cap when each partial is itself near-cap; truncate to
		// cap so the request remains bounded.
		const minBatch = 2;
		const batches = partition(level, maxInputChars, separator, minBatch);
		const nextLevel: string[] = [];
		for (const batch of batches) {
			if (signal?.aborted) throw new Error("Compaction aborted");
			if (batch.length === 1) {
				const only = batch[0] ?? "";
				nextLevel.push(only.length > maxInputChars ? only.slice(0, maxInputChars) : only);
				continue;
			}
			let batchText = batch.join(separator);
			if (batchText.length > maxInputChars) batchText = batchText.slice(0, maxInputChars);
			const summary = await summarize({
				customInstructions: instructionsForReduce(customInstructions, reduceLevels, batch.length),
				previousSummary,
				skipChunking: true,
				text: batchText,
			});
			requestCount += 1;
			if (!summary.summary.trim()) throw new Error(`Tree-reduce level ${reduceLevels} batch summary was empty`);
			nextLevel.push(summary.summary);
			lastVia = summary.via;
			lastModel = summary.model;
		}
		if (nextLevel.length === 0) throw new Error("Tree-reduce collapsed to empty level");
		if (nextLevel.length >= level.length) {
			// No progress this round — fall back to hard truncation on the next
			// pass via the level-cap guard. This typically means the model is
			// emitting near-cap summaries; the MAX_REDUCE_LEVELS guard above
			// will eventually terminate the loop with a truncated final.
		}
		level = nextLevel;
		if (level.length === 1 && level[0]!.length <= maxInputChars) {
			return {
				chunkCount: chunks.length,
				model: lastModel,
				reduceLevels,
				requestCount,
				summary: level[0]!,
				via: lastVia,
			};
		}
	}
}
