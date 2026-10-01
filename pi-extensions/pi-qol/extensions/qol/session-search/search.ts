import { setImmediate as yieldToInput } from "node:timers/promises";
import { DEFAULT_SESSION_SEARCH_LIMIT } from "../constants.js";
import { settingNumber } from "../settings.js";
import { stringifyError } from "../util.js";
import { sessionDisplayName, sessionResumeTitle, userMessagesForResult } from "./cache.js";
import { sessionRegexMatches, type SessionRegexMatch } from "./regex.js";
import type {
	QolParsedSessionQuery,
	QolSessionSearchHit,
	QolSessionSearchResult,
	QolSessionSearchSession,
	QolSessionUserMessage,
} from "./types.js";

export function normalizeSearchText(text: string): string {
	return text.toLowerCase().replace(/\s+/g, " ").trim();
}

export function parseSessionSearchQuery(query: string): QolParsedSessionQuery {
	const trimmed = query.trim();
	if (!trimmed) return { mode: "tokens", tokens: [] };
	if (trimmed.startsWith("re:")) {
		const source = trimmed.slice(3).trim();
		if (!source) return { error: "Empty regex", mode: "regex", tokens: [] };
		try {
			return { mode: "regex", regex: new RegExp(source, "i"), tokens: [] };
		} catch (error) {
			return { error: stringifyError(error), mode: "regex", tokens: [] };
		}
	}
	const tokens: QolParsedSessionQuery["tokens"] = [];
	let buffer = "";
	let inQuote = false;
	const flush = (kind: "fuzzy" | "phrase") => {
		const value = buffer.trim();
		buffer = "";
		if (value) tokens.push({ kind, value });
	};
	for (const char of trimmed) {
		if (char === '"') {
			flush(inQuote ? "phrase" : "fuzzy");
			inQuote = !inQuote;
		} else if (!inQuote && /\s/.test(char)) flush("fuzzy");
		else buffer += char;
	}
	if (inQuote) return { mode: "tokens", tokens: trimmed.split(/\s+/).filter(Boolean).map((value) => ({ kind: "fuzzy", value })) };
	flush("fuzzy");
	return { mode: "tokens", tokens };
}

export function searchStringScore(needle: string, haystack: string): number | undefined {
	const query = normalizeSearchText(needle);
	const text = normalizeSearchText(haystack);
	if (!query) return 0;
	let best: number | undefined;
	const record = (score: number) => { best = best === undefined ? score : Math.min(best, score); };
	if (/^[a-z0-9_]+$/i.test(query)) {
		for (const match of text.matchAll(/[a-z0-9_]+/gi)) {
			const word = match[0].toLowerCase();
			const penalty = Math.max(0, word.length - query.length);
			if (word === query) record(0);
			else if (word.startsWith(query)) record(10 + penalty);
			else if (word.includes(query)) record(100 + penalty);
		}
		return best;
	}
	return text.includes(query) ? 0 : undefined;
}

function snippetAround(text: string, start: number, length: number, width: number, lead = Math.floor(width / 3)): string {
	const safeStart = Math.max(0, start - Math.max(0, Math.min(width, lead)));
	const safeEnd = Math.min(text.length, Math.max(start + length, safeStart + width));
	return `${safeStart > 0 ? "…" : ""}${text.slice(safeStart, safeEnd)}${safeEnd < text.length ? "…" : ""}`;
}

export function resultFromSession(session: QolSessionSearchSession, rank = 0, snippets: string[] = []): QolSessionSearchResult {
	return { ...session, rank, snippets };
}

function matchTextSearch(text: string, parsed: QolParsedSessionQuery, regexMatches: Map<string, SessionRegexMatch | null>): { matches: boolean; score: number } {
	if (parsed.mode === "regex") return { matches: regexMatches.get(text) != null, score: 0 };
	let score = 0;
	for (const token of parsed.tokens) {
		const tokenScore = searchStringScore(token.value, text);
		if (tokenScore === undefined) return { matches: false, score: 0 };
		score += tokenScore;
	}
	return { matches: true, score };
}

function sessionTitleSearchText(session: QolSessionSearchSession): string {
	return [session.name ?? "", sessionResumeTitle(session), sessionDisplayName(session)].join("\n");
}

export function buildPromptSnippet(message: QolSessionUserMessage, parsed: QolParsedSessionQuery, regexMatch?: SessionRegexMatch | null): string {
	// Worker offsets refer to the original prompt, before whitespace collapses.
	if (parsed.mode === "regex" && regexMatch) return snippetAround(message.text, regexMatch.index, Math.min(regexMatch.length, 160), 160, 24).replace(/\s+/g, " ").trim();
	const source = message.text.replace(/\s+/g, " ").trim();
	if (!source) return "";
	if (parsed.mode === "regex") return source.slice(0, 160);
	const lower = source.toLowerCase();
	for (const token of parsed.tokens) {
		const value = normalizeSearchText(token.value);
		if (!value) continue;
		const index = lower.indexOf(value);
		if (index >= 0) return snippetAround(source, index, value.length, 160, 24);
	}
	return source.slice(0, 160);
}

export function promptRecencyTime(hit: QolSessionSearchHit): number {
	if (typeof hit.message.timestamp === "number" && Number.isFinite(hit.message.timestamp)) return hit.message.timestamp;
	return hit.result.modified.getTime();
}

function compareSessionSearchHitsRecent(a: QolSessionSearchHit, b: QolSessionSearchHit): number {
	return promptRecencyTime(b) - promptRecencyTime(a)
		|| b.result.modified.getTime() - a.result.modified.getTime()
		|| b.message.index - a.message.index;
}

/** Search only prepared prompts. Yield between batches, cancel obsolete
 * queries, and run all regex matching in a deadline-owned worker. */
export async function searchQolSessionHits(sessions: QolSessionSearchSession[], query: string, cwd: string, signal: AbortSignal): Promise<QolSessionSearchHit[]> {
	signal.throwIfAborted();
	const limit = Math.max(1, Math.floor(settingNumber("sessionSearch.resultLimit", DEFAULT_SESSION_SEARCH_LIMIT, cwd)));
	const parsed = parseSessionSearchQuery(query);
	if (parsed.error) throw new Error(parsed.error);
	const regexMatches = new Map<string, SessionRegexMatch | null>();
	if (parsed.mode === "regex" && parsed.regex) {
		const texts = [...new Set(sessions.flatMap((session) => [sessionTitleSearchText(session), ...userMessagesForResult(resultFromSession(session)).map((message) => message.text)]))];
		const matches = await sessionRegexMatches(parsed.regex.source, texts, signal);
		texts.forEach((text, index) => regexMatches.set(text, matches[index]!));
	}
	const hits: QolSessionSearchHit[] = [];
	let batchStarted = performance.now();
	for (const session of sessions) {
		signal.throwIfAborted();
		const messages = userMessagesForResult(resultFromSession(session));
		let addedPromptHit = false;
		for (const message of messages) {
			const match = matchTextSearch(message.text, parsed, regexMatches);
			if (match.matches) {
				const snippet = buildPromptSnippet(message, parsed, regexMatches.get(message.text));
				hits.push({ message, rank: match.score, result: resultFromSession(session, match.score, [snippet]), snippet });
				addedPromptHit = true;
			}
			if (performance.now() - batchStarted >= 4) {
				await yieldToInput(undefined, { signal });
				batchStarted = performance.now();
			}
		}
		if (!addedPromptHit) {
			const titleMatch = matchTextSearch(sessionTitleSearchText(session), parsed, regexMatches);
			const message = messages[messages.length - 1];
			if (titleMatch.matches && message) {
				const snippet = buildPromptSnippet(message, { mode: "tokens", tokens: [] });
				hits.push({ message, rank: titleMatch.score, result: resultFromSession(session, titleMatch.score, [snippet]), snippet });
			}
		}
		// Only the best resultLimit hits need to stay alive between batches.
		if (hits.length > limit * 2) {
			hits.sort((a, b) => a.rank - b.rank || compareSessionSearchHitsRecent(a, b));
			hits.length = limit;
		}
	}
	signal.throwIfAborted();
	hits.sort((a, b) => a.rank - b.rank || compareSessionSearchHitsRecent(a, b));
	return hits.slice(0, limit);
}

export function formatSessionSearchDate(date: Date): string {
	const diffMs = Math.max(0, Date.now() - date.getTime());
	const diffMins = Math.floor(diffMs / 60_000);
	const diffHours = Math.floor(diffMs / 3_600_000);
	const diffDays = Math.floor(diffMs / 86_400_000);
	if (diffMins < 1) return "now";
	if (diffMins < 60) return `${diffMins}m ago`;
	if (diffHours < 24) return `${diffHours}h ago`;
	if (diffDays < 7) return `${diffDays}d ago`;
	return date.toLocaleDateString("en-GB", { day: "numeric", month: "short" });
}
