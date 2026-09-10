import {
	CAVEMAN_BRIDGE_SYMBOL,
	CLAUDE_BILLING_IDENTITY_SYMBOL,
	PI_AGENTS_STATUSLINE_SYMBOL,
	QUESTION_SERVICE_SYMBOL,
	KENDEX_MODAL_LOCK_SYMBOL,
} from "./constants.js";

export interface CavemanBridge {
	isActive(): boolean;
	getMode(): string;
	getConfiguredMode?(cwd?: string): string;
	getLastActiveMode(): string;
	hasSessionOverride?(): boolean;
	isStatusBadgeEnabled?(cwd?: string): boolean;
	cycleMode?(cwd?: string): string;
	setMode?(mode: string, cwd?: string): string | undefined;
	subscribe(listener: () => void): () => void;
}

export interface PiAgentsStatuslineBridge {
	getCurrentSubagent(cwd?: string): { name: string; color?: string } | undefined;
}

/** The Claude bridge's published account surface. It answers with a login
 *  email only when the SDK confirmed one for the child that ran the request:
 *  an API key or a Bedrock, Vertex, Foundry, Anthropic-AWS or Mantle backend
 *  authenticates as something no config directory names, and a companion
 *  account router can rotate the profile per request without the environment
 *  changing. Reading a config directory here instead would name the wrong
 *  account in every one of those cases. */
export interface ClaudeBillingIdentityBridge {
	version: 1;
	currentLoginEmail(): string | undefined;
}

export interface QuestionRequestLike {
	header?: string;
	question?: string;
}

export interface QuestionOpenedEventLike {
	requestId?: string;
	request?: QuestionRequestLike;
	source?: string;
}

export interface QuestionServiceLike {
	listPending(): unknown[];
	subscribe(listener: (event: any) => void): () => void;
}

interface kendexModalLock {
	depth: number;
}

export function readCavemanBridge(): CavemanBridge | undefined {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const value = host[CAVEMAN_BRIDGE_SYMBOL];
	return value && typeof value === "object" ? (value as CavemanBridge) : undefined;
}

export function readClaudeBillingIdentityBridge(): ClaudeBillingIdentityBridge | undefined {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const value = host[CLAUDE_BILLING_IDENTITY_SYMBOL] as ClaudeBillingIdentityBridge | undefined;
	return value?.version === 1 && typeof value.currentLoginEmail === "function" ? value : undefined;
}

export function readPiAgentsStatuslineBridge(): PiAgentsStatuslineBridge | undefined {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const value = host[PI_AGENTS_STATUSLINE_SYMBOL];
	return value && typeof value === "object" && typeof (value as PiAgentsStatuslineBridge).getCurrentSubagent === "function"
		? (value as PiAgentsStatuslineBridge)
		: undefined;
}

export function getQuestionService(): QuestionServiceLike | undefined {
	const service = (globalThis as unknown as Record<PropertyKey, unknown>)[QUESTION_SERVICE_SYMBOL];
	if (!service || typeof service !== "object") return undefined;
	const candidate = service as Partial<QuestionServiceLike>;
	if (typeof candidate.subscribe === "function" && typeof candidate.listPending === "function") return candidate as QuestionServiceLike;
	return undefined;
}

export function acquirekendexModalLock(): () => void {
	const host = globalThis as unknown as Record<PropertyKey, unknown>;
	const existing = host[KENDEX_MODAL_LOCK_SYMBOL] as kendexModalLock | undefined;
	const lock = existing && typeof existing.depth === "number" ? existing : { depth: 0 };
	host[KENDEX_MODAL_LOCK_SYMBOL] = lock;
	lock.depth += 1;
	let released = false;
	return () => {
		if (released) return;
		released = true;
		lock.depth = Math.max(0, lock.depth - 1);
	};
}
