import { basename } from "node:path";
import { forEachSessionJsonlLine } from "./session-lines.js";
import { oneLine } from "./text.js";
import type { SessionInfo, SessionUserMessage } from "./types.js";

export const sessionUserMessagesCache = new Map<string, SessionUserMessage[]>();

export function sessionFallbackName(session: SessionInfo): string {
	const file = basename(session.path || "session", ".jsonl");
	return oneLine(file, "session") || "session";
}

export function sessionResumeTitle(session: SessionInfo): string {
	const name = oneLine(session.name);
	if (name) return name;
	const first = oneLine(session.firstMessage);
	if (first && first !== "(no messages)") return first;
	return sessionFallbackName(session);
}

function messageContentText(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content.map((part: any) => {
		if (part?.type === "text" && typeof part.text === "string") return part.text;
		if (part?.type === "image") return "[image]";
		return "";
	}).filter(Boolean).join(" ");
}

function sessionMessageTimestamp(entry: any, message: any): number | undefined {
	if (typeof message?.timestamp === "number" && Number.isFinite(message.timestamp)) return message.timestamp;
	if (typeof entry?.timestamp === "number" && Number.isFinite(entry.timestamp)) return entry.timestamp;
	if (typeof entry?.timestamp === "string") {
		const parsed = new Date(entry.timestamp).getTime();
		if (!Number.isNaN(parsed)) return parsed;
	}
	return undefined;
}

function sessionUserMessages(sessionPath: string): SessionUserMessage[] {
	const cached = sessionUserMessagesCache.get(sessionPath);
	if (cached) return cached;
	const messages: SessionUserMessage[] = [];
	try {
		forEachSessionJsonlLine(sessionPath, (line) => {
			// Every user message line holds the JSON string "user"; skipping the
			// rest spares a parse of each assistant and tool record.
			if (!line.includes('"user"')) return;
			let entry: any;
			try { entry = JSON.parse(line); } catch { return; }
			const message = entry?.type === "message" ? entry.message : undefined;
			if (!message || message.role !== "user") return;
			const text = oneLine(messageContentText(message.content));
			if (!text) return;
			messages.push({ index: messages.length + 1, text, timestamp: sessionMessageTimestamp(entry, message) });
		});
	} catch {
		// Ignore unreadable sessions; callers fall back to SessionInfo.firstMessage.
	}
	sessionUserMessagesCache.set(sessionPath, messages);
	return messages;
}

export function userMessagesForSession(session: SessionInfo): SessionUserMessage[] {
	const messages = sessionUserMessages(session.path);
	if (messages.length > 0) return messages;
	const fallback = oneLine(session.firstMessage || "");
	return fallback ? [{ index: 1, text: fallback }] : [];
}

export function sessionTitleSearchText(session: SessionInfo): string {
	return [session.name ?? "", sessionResumeTitle(session), sessionFallbackName(session)].map((part) => oneLine(part)).join("\n");
}

export function isNamed(session: SessionInfo): boolean {
	return oneLine(session.name).length > 0;
}
