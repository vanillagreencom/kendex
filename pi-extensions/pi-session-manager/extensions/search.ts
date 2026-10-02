import { Script, createContext } from "node:vm";
import { ansiRed, oneLine } from "./text.js";
import { sessionTitleSearchText, userMessagesForSession } from "./session-data.js";
import type { MatchResult, ParsedQuery, SearchToken, SessionInfo, SessionUserMessage } from "./types.js";

/** How long one `re:` evaluation may run: over a batch of sessions, then over each session alone when the batch runs past it, or over one snippet. */
const REGEX_DEADLINE_MS = 250;

export class RegexTimeoutError extends Error {
	constructor() {
		super(`Regex ran past ${REGEX_DEADLINE_MS} ms; simplify the pattern`);
		this.name = "RegexTimeoutError";
	}
}

// A running RegExp cannot be interrupted from JavaScript. A vm timeout terminates
// whatever runs inside the script, backtracking included. Each timed run starts a
// watchdog, so callers batch their regex work into one run.
const regexContext = createContext({ run: undefined as (() => unknown) | undefined });
const regexScript = new Script("run()");

function withinRegexDeadline<T>(run: () => T): T {
	regexContext.run = run;
	try {
		return regexScript.runInContext(regexContext, { timeout: REGEX_DEADLINE_MS }) as T;
	} catch (error) {
		if ((error as { code?: unknown } | null)?.code === "ERR_SCRIPT_EXECUTION_TIMEOUT") throw new RegexTimeoutError();
		throw error;
	} finally {
		regexContext.run = undefined;
	}
}

function normalizeSearchText(text: string): string {
	return oneLine(text).toLowerCase();
}

export function parseQuery(query: string): ParsedQuery {
	const trimmed = query.trim();
	if (!trimmed) return { mode: "tokens", tokens: [] };

	if (trimmed.startsWith("re:")) {
		const source = trimmed.slice(3).trim();
		if (!source) return { mode: "regex", tokens: [], error: "Empty regex" };
		try {
			return { mode: "regex", tokens: [], regex: new RegExp(source, "i") };
		} catch (error) {
			return { mode: "regex", tokens: [], error: error instanceof Error ? error.message : String(error) };
		}
	}

	const tokens: SearchToken[] = [];
	let buffer = "";
	let inQuote = false;
	let unclosed = false;
	const flush = (kind: "fuzzy" | "phrase") => {
		const value = buffer.trim();
		buffer = "";
		if (value) tokens.push({ kind, value });
	};

	for (let i = 0; i < trimmed.length; i++) {
		const ch = trimmed[i]!;
		if (ch === '"') {
			if (inQuote) {
				flush("phrase");
				inQuote = false;
			} else {
				flush("fuzzy");
				inQuote = true;
			}
			continue;
		}
		if (!inQuote && /\s/.test(ch)) {
			flush("fuzzy");
			continue;
		}
		buffer += ch;
	}

	if (inQuote) unclosed = true;
	if (unclosed) {
		return {
			mode: "tokens",
			tokens: trimmed.split(/\s+/).filter(Boolean).map((value) => ({ kind: "fuzzy", value })),
		};
	}

	flush("fuzzy");
	return { mode: "tokens", tokens };
}

function searchWordLengthPenalty(word: string, query: string): number {
	return Math.max(0, word.length - query.length);
}

function searchStringScore(needle: string, haystack: string): number | undefined {
	const query = normalizeSearchText(needle);
	const text = normalizeSearchText(haystack);
	if (!query) return 0;
	let best: number | undefined;
	const record = (score: number) => {
		best = best === undefined ? score : Math.min(best, score);
	};
	if (/^[a-z0-9_]+$/i.test(query)) {
		for (const match of text.matchAll(/[a-z0-9_]+/gi)) {
			const word = match[0].toLowerCase();
			if (word === query) record(0);
			else if (word.startsWith(query)) record(10 + searchWordLengthPenalty(word, query));
			else if (word.includes(query)) record(100 + searchWordLengthPenalty(word, query));
		}
		return best;
	}
	return text.includes(query) ? 0 : undefined;
}

function matchTextSearch(text: string, parsed: ParsedQuery): MatchResult {
	if (parsed.mode === "regex") {
		if (!parsed.regex) return { matches: false, score: 0 };
		parsed.regex.lastIndex = 0;
		const index = text.search(parsed.regex);
		return index < 0 ? { matches: false, score: 0 } : { matches: true, score: 0 };
	}
	if (parsed.tokens.length === 0) return { matches: true, score: 0 };
	let score = 0;
	for (const token of parsed.tokens) {
		const tokenScore = searchStringScore(token.value, text);
		if (tokenScore === undefined) return { matches: false, score: 0 };
		score += tokenScore;
	}
	return { matches: true, score };
}

function matchSession(session: SessionInfo, messages: SessionUserMessage[], parsed: ParsedQuery): MatchResult {
	if (parsed.mode === "tokens" && parsed.tokens.length === 0) return { matches: true, score: 0 };
	let best: number | undefined;
	for (const message of messages) {
		const match = matchTextSearch(message.text, parsed);
		if (!match.matches) continue;
		best = best === undefined ? match.score : Math.min(best, match.score);
	}
	if (best !== undefined) return { matches: true, score: best };
	const titleMatch = matchTextSearch(sessionTitleSearchText(session), parsed);
	return titleMatch.matches ? titleMatch : { matches: false, score: 0 };
}

/**
 * Match a batch of sessions, one result per session in order. Transcripts are read
 * before any deadline starts. A regex query runs the whole batch under one
 * deadline; past it, each session reruns under its own, and `RegexTimeoutError`
 * is thrown only when one session alone runs past the deadline.
 */
export function matchSessions(sessions: SessionInfo[], parsed: ParsedQuery): MatchResult[] {
	const messages = sessions.map((session) => userMessagesForSession(session));
	const matchAt = (index: number) => matchSession(sessions[index]!, messages[index]!, parsed);
	if (parsed.mode !== "regex") return sessions.map((_, index) => matchAt(index));
	try {
		return withinRegexDeadline(() => sessions.map((_, index) => matchAt(index)));
	} catch (error) {
		if (!(error instanceof RegexTimeoutError) || sessions.length === 1) throw error;
		return sessions.map((_, index) => withinRegexDeadline(() => matchAt(index)));
	}
}

function snippetAround(text: string, start: number, length: number, width: number): string {
	const safeStart = Math.max(0, start - Math.floor(width / 3));
	const safeEnd = Math.min(text.length, start + length + Math.floor((width * 2) / 3));
	const prefix = safeStart > 0 ? "…" : "";
	const suffix = safeEnd < text.length ? "…" : "";
	return `${prefix}${text.slice(safeStart, safeEnd)}${suffix}`;
}

/** The preview of a session's first matching prompt; a regex query throws `RegexTimeoutError` past its deadline. */
export function buildSnippet(session: SessionInfo, parsed: ParsedQuery): string | undefined {
	const messages = userMessagesForSession(session);
	return parsed.mode === "regex" ? withinRegexDeadline(() => snippetFromMessages(messages, parsed)) : snippetFromMessages(messages, parsed);
}

function snippetFromMessages(messages: SessionUserMessage[], parsed: ParsedQuery): string | undefined {
	if (parsed.mode === "tokens" && parsed.tokens.length === 0) return messages[messages.length - 1]?.text.slice(0, 180);
	for (const message of messages) {
		const source = message.text;
		if (!matchTextSearch(source, parsed).matches) continue;
		if (parsed.mode === "regex" && parsed.regex) {
			parsed.regex.lastIndex = 0;
			const match = parsed.regex.exec(source);
			return match ? snippetAround(source, match.index, match[0].length, 180) : source.slice(0, 180);
		}
		const lower = source.toLowerCase();
		for (const token of parsed.tokens) {
			const value = normalizeSearchText(token.value);
			if (!value) continue;
			const index = lower.indexOf(value.toLowerCase());
			if (index >= 0) return snippetAround(source, index, value.length, 180);
		}
		return source.slice(0, 180);
	}
	return undefined;
}

export function styleSearchMatches(text: string, query: string): string {
	let styled = text;
	const parsed = parseQuery(query);
	if (parsed.mode !== "tokens") return styled;
	for (const token of parsed.tokens) {
		const value = token.value.trim();
		if (!value || value.length > 80) continue;
		try {
			styled = styled.replace(new RegExp(value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "gi"), (match) => ansiRed(match));
		} catch {
			// Keep unstyled text if a token cannot be highlighted safely.
		}
	}
	return styled;
}
