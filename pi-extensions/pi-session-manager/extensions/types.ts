import type { SessionManager, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";

export const INSTALL_SYMBOL = Symbol.for("kendex.pi-session-manager.installed");
export const KENDEX_MODAL_LOCK_SYMBOL = Symbol.for("kendex.pi.modal-lock");
export const PACKAGE_ID = "@vanillagreen/pi-session-manager";
export const DEFAULT_SHORTCUT = "f1";
export const DEFAULT_WIDTH = 112;
export const DEFAULT_ROWS = 12;
export const POPUP_HEIGHT_RATIO = 0.9;
export const POPUP_PADDING_X = 2;
export const POPUP_PADDING_Y = 1;
export const POPUP_MARGIN_ROWS = 1;
export const ROW_META_MAX_WIDTH = 44;

export type SessionInfo = Awaited<ReturnType<typeof SessionManager.list>>[number];
export type Scope = "current" | "all";
export type SortMode = "threaded" | "recent" | "relevance";
export type NameFilter = "all" | "named";
export type Mode = "browse" | "loading" | "rename" | "confirm-delete" | "confirm-delete-all" | "confirm-model" | "deleting";

export type SessionAction = { type: "resume"; path: string; title: string; keepCurrentModel?: boolean } | { type: "cancel" };
export type SessionManagerContext = ExtensionCommandContext | ExtensionContext;

export interface ModelInfo {
	provider: string;
	id: string;
}

export interface kendexModalLock {
	depth: number;
}

export interface SearchToken {
	kind: "fuzzy" | "phrase";
	value: string;
}

export interface ParsedQuery {
	mode: "tokens" | "regex";
	tokens: SearchToken[];
	regex?: RegExp;
	error?: string;
}

export interface MatchResult {
	matches: boolean;
	score: number;
}

export interface FlatSessionNode {
	session: SessionInfo;
	depth: number;
	isLast: boolean;
	ancestorContinues: boolean[];
	score: number;
	snippet?: string;
}

export interface SessionUserMessage {
	index: number;
	text: string;
	timestamp?: number;
}

export interface SessionTreeNode {
	session: SessionInfo;
	children: SessionTreeNode[];
}

export type kendexConfig = Record<string, unknown>;
