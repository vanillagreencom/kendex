import {
	DEFAULT_LOG_TAIL_MAX_CHARS,
	DEFAULT_OUTPUT_ALERT_MAX_CHARS,
	DEFAULT_OUTPUT_BUFFER_MAX_CHARS,
} from "./constants.js";
import { settingNumber } from "./settings.js";
import type { BackgroundLogTruncation, BackgroundTaskSnapshot, BackgroundTaskStatus } from "./types.js";
import { WAKE_MANIFEST_FIELD_MAX_CHARS, truncateForTranscript } from "./wake-events.js";

// Transcript-facing summary-line cap (vstack#210 round 2). bg_task list /
// /bg list / dashboard summaries render task title/command directly into
// transcript content; an agent-controlled 100KB title would otherwise leak
// past pi-output-policy. Keep summaries terse (one-line use) so this is
// tighter than the full manifest cap.
export const TASK_DISPLAY_NAME_MAX_CHARS = 96;

export function tailText(text: string, maxChars: number = settingNumber("outputAlertMaxChars", DEFAULT_OUTPUT_ALERT_MAX_CHARS)): string {
	if (text.length <= maxChars) return text;
	return `[...truncated]\n${text.slice(-maxChars)}`;
}

export function taskLogTruncation(output: string, logFile: string, cwd?: string): BackgroundLogTruncation | undefined {
	const maxChars = Math.max(1, Math.floor(settingNumber("logTailMaxChars", DEFAULT_LOG_TAIL_MAX_CHARS, cwd)));
	if (output.length <= maxChars) return undefined;
	// Transcript-bounded path. The on-disk log is canonical; the truncation
	// descriptor lives in tool-result details where an agent-controlled
	// `cwd`/`taskDir` setting could otherwise pump a multi-KB string per
	// inspection (vstack#210 round 2).
	const safeLogFile = truncateForTranscript(logFile, WAKE_MANIFEST_FIELD_MAX_CHARS) ?? "";
	return { direction: "tail", fullOutputPath: safeLogFile, shownChars: maxChars, totalChars: output.length, truncated: true };
}

export function formatTaskLog(output: string, logFile: string, cwd?: string): string {
	if (!output) return "(empty)";
	const truncation = taskLogTruncation(output, logFile, cwd);
	if (!truncation) return output;
	const safeLogFile = truncateForTranscript(logFile, WAKE_MANIFEST_FIELD_MAX_CHARS) ?? "";
	return `[...truncated]\n${output.slice(-truncation.shownChars)}\n\n[Background log truncated. Showing last ${truncation.shownChars} of ${truncation.totalChars} character(s). Full log: ${safeLogFile}]`;
}

export function trimOutputBuffer(output: string, lastAnnouncedLength: number): { output: string; lastAnnouncedLength: number } {
	const maxChars = settingNumber("outputBufferMaxChars", DEFAULT_OUTPUT_BUFFER_MAX_CHARS);
	if (output.length <= maxChars) return { output, lastAnnouncedLength };
	const overflow = output.length - maxChars;
	return {
		lastAnnouncedLength: Math.max(0, lastAnnouncedLength - overflow),
		output: output.slice(-maxChars),
	};
}

export function formatDuration(ms: number): string {
	const safe = Math.max(0, ms);
	if (safe < 1_000) return `${safe}ms`;
	const seconds = safe / 1_000;
	if (seconds < 60) return `${seconds.toFixed(seconds >= 10 ? 0 : 1)}s`;
	const minutes = Math.floor(seconds / 60);
	const remSeconds = Math.floor(seconds % 60);
	if (minutes < 60) return remSeconds > 0 ? `${minutes}m ${remSeconds}s` : `${minutes}m`;
	const hours = Math.floor(minutes / 60);
	const remMinutes = minutes % 60;
	return remMinutes > 0 ? `${hours}h ${remMinutes}m` : `${hours}h`;
}

export function formatRelativeTime(timestamp: number, now: number = Date.now()): string {
	const diff = timestamp - now;
	const abs = Math.abs(diff);
	const suffix = diff >= 0 ? "from now" : "ago";
	if (abs < 1_000) return diff >= 0 ? "now" : "just now";
	if (abs < 60_000) return `${Math.floor(abs / 1_000)}s ${suffix}`;
	if (abs < 3_600_000) return `${Math.floor(abs / 60_000)}m ${suffix}`;
	if (abs < 86_400_000) return `${Math.floor(abs / 3_600_000)}h ${suffix}`;
	return `${Math.floor(abs / 86_400_000)}d ${suffix}`;
}

export function parseOutputMatcher(pattern: string | undefined): ((text: string) => boolean) | null {
	const needle = pattern?.trim();
	if (!needle) return null;

	const regexMatch = needle.match(/^\/(.*)\/([gimsuy]*)$/);
	if (regexMatch) {
		try {
			const regex = new RegExp(regexMatch[1], regexMatch[2]);
			return (text: string) => {
				regex.lastIndex = 0;
				return regex.test(text);
			};
		} catch {
			// Invalid regex falls through to substring matching.
		}
	}

	const lower = needle.toLowerCase();
	return (text: string) => text.toLowerCase().includes(lower);
}

export function summarizeTaskStatus(
	status: BackgroundTaskStatus,
	exitCode: number | null,
	terminationReason?: string,
): string {
	const base = baseStatusLabel(status, exitCode);
	if (!terminationReason || terminationReason === "self-exit") return base;
	// vstack#97: surface the non-self-exit cause inline so operators reading
	// `bg_status list` can tell extension-stop from session-shutdown from a
	// reconcile-on-restart coercion. Self-exit termination matches the
	// historical wording so unchanged completed/failed rows stay terse.
	return `${base} (${terminationReason})`;
}

function baseStatusLabel(status: BackgroundTaskStatus, exitCode: number | null): string {
	switch (status) {
		case "running":
			return "running";
		case "completed":
			return `completed (exit ${exitCode ?? 0})`;
		case "failed":
			return `failed (exit ${exitCode ?? "?"})`;
		case "timed_out":
			return exitCode === null ? "timed out" : `timed out (exit ${exitCode})`;
		case "stopped":
			return exitCode === null ? "stopped" : `stopped (exit ${exitCode})`;
	}
}

export function taskDisplayName(task: Pick<BackgroundTaskSnapshot, "title" | "command">): string {
	return task.title.trim() || task.command.trim();
}

/**
 * Transcript-safe display name (vstack#210 round 2). Caller used to embed
 * the unbounded title/command into list / dashboard / spawn content strings
 * without truncation; a 100KB title would have leaked past pi-output-policy.
 * Use this whenever the result ends up directly in a transcript-facing
 * `content` string.
 */
export function taskDisplayNameForTranscript(
	task: Pick<BackgroundTaskSnapshot, "title" | "command">,
	maxChars: number = TASK_DISPLAY_NAME_MAX_CHARS,
): string {
	return compactText(taskDisplayName(task), maxChars);
}

export function buildTaskSummaryLine(task: BackgroundTaskSnapshot, now: number = Date.now()): string {
	const activityAt = task.lastOutputAt ?? task.updatedAt;
	return `${task.id} · ${summarizeTaskStatus(task.status, task.exitCode, task.terminationReason)} · pid ${task.pid} · ${taskDisplayNameForTranscript(
		task,
	)} · ${formatRelativeTime(activityAt, now)}`;
}

export function taskActivityAt(task: Pick<BackgroundTaskSnapshot, "lastOutputAt" | "updatedAt">): number {
	return task.lastOutputAt ?? task.updatedAt;
}

export function taskElapsedMs(task: Pick<BackgroundTaskSnapshot, "startedAt" | "status" | "updatedAt">, now: number = Date.now()): number {
	return (task.status === "running" ? now : task.updatedAt) - task.startedAt;
}

export function compactText(value: string, maxChars = 80): string {
	const compact = value.replace(/\s+/g, " ").trim();
	return compact.length > maxChars ? `${compact.slice(0, Math.max(0, maxChars - 1))}…` : compact;
}

export function shellQuote(value: string): string {
	return `'${value.replace(/'/g, `'\\''`)}'`;
}

export function normalizedCommand(command: string): string {
	return command.replace(/\s+/g, " ").trim();
}

export function formatShortcutHint(shortcut: string): string {
	return shortcut.toLowerCase();
}

export function lineCount(text: string): number {
	if (!text) return 0;
	return text.split(/\r?\n/).length;
}

export function takeTailLines(text: string, maxLines: number): { hidden: number; lines: string[]; total: number } {
	const lines = text.trimEnd().length > 0 ? text.trimEnd().split(/\r?\n/) : [];
	const limit = Math.max(1, Math.floor(maxLines));
	return { hidden: Math.max(0, lines.length - limit), lines: lines.slice(-limit), total: lines.length };
}
