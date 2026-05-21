// Pre-compaction handoff artifact: writes a JSON snapshot of the previous
// summary, the most recent task panel state, and recently referenced file
// paths so an operator can recover continuity if the compaction summary
// drops something critical. The pure data-building + write logic lives here
// so it can be unit-tested without the pi-coding-agent / pi-ai peer deps.

import { mkdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";

import { QOL_BUDGET_HANDOFF_FOLDER, QOL_BUDGET_HANDOFF_LATEST } from "./constants.js";

export interface QolBudgetHandoff {
	reason: string;
	timestamp: number;
	sessionId: string;
	tokensBefore?: number;
	messageCount: number;
	previousSummary?: string;
	taskState?: unknown;
	artifactRefs: string[];
	model?: string;
}

function expandHome(input: string): string {
	if (input === "~") return homedir();
	if (input.startsWith("~/")) return join(homedir(), input.slice(2));
	return input;
}

export function piUserDir(): string {
	return resolve(expandHome(process.env.PI_CODING_AGENT_DIR?.trim() || "~/.pi/agent"));
}

export function safeFileName(value: string): string {
	return value.replace(/[^\w.-]+/g, "_");
}

export interface HandoffSessionAccessor {
	getSessionId?: () => string | undefined;
	getSessionFile?: () => string | undefined;
	getBranch?: () => unknown[];
}

export function sessionIdFromManager(sm: HandoffSessionAccessor, fallbackPid: number = process.pid): string {
	try {
		const id = typeof sm.getSessionId === "function" ? sm.getSessionId() : undefined;
		if (typeof id === "string" && id.trim()) return id;
	} catch {
		// Stale ctx may throw; fall through to file/pid.
	}
	try {
		const file = typeof sm.getSessionFile === "function" ? sm.getSessionFile() : undefined;
		if (typeof file === "string" && file.trim()) return basename(file, ".jsonl");
	} catch {
		// Same: fall through.
	}
	return `ephemeral-${fallbackPid}`;
}

/**
 * Walks the branch newest-first and returns the most recent task panel state
 * embedded in a tool result. Returns undefined when no task state is found.
 */
export function findLatestTaskState(branch: unknown[]): unknown {
	for (let i = branch.length - 1; i >= 0; i -= 1) {
		const entry = branch[i] as any;
		if (entry?.type !== "message" || entry.message?.role !== "toolResult") continue;
		const content = entry.message.content;
		const parts = Array.isArray(content) ? content : [];
		for (const part of parts) {
			if (part?.type !== "toolResult") continue;
			const details = part?.details;
			if (details && typeof details === "object" && "state" in (details as Record<string, unknown>)) {
				return (details as Record<string, unknown>).state;
			}
		}
	}
	return undefined;
}

const ARTIFACT_REF_PATTERN = /(?:^|\s|["'`(\[<])((?:\.{1,2}\/|\/|~\/)?[\w.\-+@/]+\.(?:md|json|jsonl|txt|log|ts|tsx|js|jsx|rs|toml|yml|yaml|html|sh|fish|bash|py|go|java|cs|cpp|h|hpp|sql|csv|env|lock|patch|diff))/g;

/**
 * Collects up to `maxRefs` file path-shaped strings from message contents,
 * walking newest-first. Used to give the handoff artifact a quick "if you
 * are recovering, here are recent files" pointer list.
 */
export function collectArtifactRefs(branch: unknown[], maxRefs = 20): string[] {
	const refs = new Set<string>();
	for (let i = branch.length - 1; i >= 0 && refs.size < maxRefs; i -= 1) {
		const entry = branch[i] as any;
		if (entry?.type !== "message") continue;
		const content = entry.message?.content;
		const parts = Array.isArray(content) ? content : [];
		for (const part of parts) {
			const text = typeof part?.text === "string" ? part.text : typeof part?.thinking === "string" ? part.thinking : "";
			if (!text) continue;
			ARTIFACT_REF_PATTERN.lastIndex = 0;
			let match: RegExpExecArray | null;
			while ((match = ARTIFACT_REF_PATTERN.exec(text)) !== null && refs.size < maxRefs) {
				if (match[1]) refs.add(match[1]);
			}
		}
	}
	return Array.from(refs);
}

export interface BuildHandoffInput {
	reason: string;
	sessionManager: HandoffSessionAccessor;
	preparation?: {
		messagesToSummarize?: unknown[];
		turnPrefixMessages?: unknown[];
		previousSummary?: string;
		tokensBefore?: number;
	};
	timestamp?: number;
}

export function buildBudgetHandoff(input: BuildHandoffInput): QolBudgetHandoff {
	const preparation = input.preparation ?? {};
	const messageCount = (preparation.messagesToSummarize?.length ?? 0) + (preparation.turnPrefixMessages?.length ?? 0);
	let branch: unknown[] = [];
	try {
		const raw = typeof input.sessionManager.getBranch === "function" ? input.sessionManager.getBranch() : [];
		branch = Array.isArray(raw) ? raw : [];
	} catch {
		branch = [];
	}
	return {
		artifactRefs: collectArtifactRefs(branch),
		messageCount,
		previousSummary: preparation.previousSummary,
		reason: input.reason,
		sessionId: sessionIdFromManager(input.sessionManager),
		taskState: findLatestTaskState(branch),
		timestamp: input.timestamp ?? Date.now(),
		tokensBefore: typeof preparation.tokensBefore === "number" ? preparation.tokensBefore : undefined,
	};
}

export interface HandoffWriteResult {
	path?: string;
	latestPath?: string;
	error?: string;
}

export function handoffStampedPath(baseDir: string, timestamp: number): string {
	return join(baseDir, `${new Date(timestamp).toISOString().replace(/[:.]/g, "-")}.json`);
}

export function handoffBaseDir(sessionId: string, root: string = piUserDir()): string {
	return join(root, "vstack", "sessions", safeFileName(sessionId), QOL_BUDGET_HANDOFF_FOLDER);
}

export interface WriteHandoffOptions {
	enabled: boolean;
	root?: string;
	/** Injection point so tests can stub fs without mocking node:fs. */
	writer?: (path: string, payload: string) => void;
	mkdir?: (path: string) => void;
}

function defaultMkdir(path: string): void {
	mkdirSync(path, { recursive: true, mode: 0o700 });
}

function defaultWriter(path: string, payload: string): void {
	writeFileSync(path, payload, { mode: 0o600 });
}

export function writeBudgetHandoffArtifact(handoff: QolBudgetHandoff, options: WriteHandoffOptions): HandoffWriteResult {
	if (!options.enabled) return {};
	const baseDir = handoffBaseDir(handoff.sessionId, options.root);
	const stampedPath = handoffStampedPath(baseDir, handoff.timestamp);
	const latestPath = join(dirname(baseDir), basename(baseDir), QOL_BUDGET_HANDOFF_LATEST);
	const mkdir = options.mkdir ?? defaultMkdir;
	const writer = options.writer ?? defaultWriter;
	try {
		mkdir(baseDir);
		const payload = JSON.stringify(handoff, null, 2);
		writer(stampedPath, payload);
		writer(latestPath, payload);
		return { latestPath, path: stampedPath };
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		return { error: message };
	}
}
