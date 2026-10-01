export type QolSessionSearchScope = "current" | "all";

export interface QolSessionSearchSession {
	allMessagesText: string;
	created: Date;
	cwd: string;
	firstMessage: string;
	id: string;
	messageCount: number;
	modified: Date;
	name?: string;
	parentSessionPath?: string;
	path: string;
	/** Prepared once per index load, not read from disk during a query. */
	canonicalCwd?: string;
	userMessages?: QolSessionUserMessage[];
}

/** The session-search index as the overlay sees it: still loading, loaded,
 *  or failed with the load's error. */
export type QolSessionSearchLoad =
	| { status: "loading" }
	| { status: "ready"; sessions: QolSessionSearchSession[] }
	| { status: "failed"; error: string };

export interface QolSessionSearchResult extends QolSessionSearchSession {
	rank: number;
	snippets: string[];
}

export interface QolSessionUserMessage {
	entryId?: string;
	index: number;
	parentId?: string | null;
	text: string;
	timestamp?: number;
}

export interface QolSessionSearchHit {
	message: QolSessionUserMessage;
	rank: number;
	result: QolSessionSearchResult;
	snippet: string;
}

export interface QolParsedSessionQuery {
	mode: "tokens" | "regex";
	tokens: Array<{ kind: "fuzzy" | "phrase"; value: string }>;
	regex?: RegExp;
	error?: string;
}

export interface QolSessionSearchState {
	cursor: number;
	query: string;
	results: QolSessionSearchHit[];
	selected: number;
	scope: QolSessionSearchScope;
	total: number;
}

export interface QolSessionMessagesState {
	messages: QolSessionUserMessage[];
	result: QolSessionSearchResult;
	selected: number;
}

export interface QolSessionActionState {
	message: QolSessionUserMessage;
	result: QolSessionSearchResult;
}

export interface QolSessionContextConfirmState {
	message: QolSessionUserMessage;
	result: QolSessionSearchResult;
	returnScreen: "search" | "messages" | "actions";
	type: "summarize" | "newSession";
}

export interface QolSessionForkConfirmState {
	messages: QolSessionUserMessage[];
	result: QolSessionSearchResult;
	returnScreen: "search" | "messages" | "actions";
	selected: number;
}

export interface QolSessionConfirmModelState {
	result: QolSessionSearchResult;
	returnScreen: "search" | "messages" | "actions";
	selected: 0 | 1;
	previousModel: { provider: string; id: string };
	currentModel: { provider: string; id: string };
}

export interface QolSessionSearchPendingMessage {
	content: string;
	details: Record<string, unknown>;
}

export interface QolSessionPaletteAction {
	type: "cancel" | "resume" | "fork" | "copy" | "summarize" | "newSession";
	customPrompt?: string;
	keepCurrentModel?: boolean;
	message?: QolSessionUserMessage;
	result?: QolSessionSearchResult;
}
