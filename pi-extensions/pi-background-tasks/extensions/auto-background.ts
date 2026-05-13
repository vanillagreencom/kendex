import { compactText, normalizedCommand, shellQuote } from "./format.js";
import { settingBoolean, settingString } from "./settings.js";
import type { BackgroundTaskSnapshot, BashBackgroundDecision } from "./types.js";

function parsePatternList(raw: string): RegExp[] {
	const patterns: RegExp[] = [];
	for (const line of raw.split(/\r?\n/)) {
		const trimmed = line.trim();
		if (!trimmed || trimmed.startsWith("#")) continue;
		const match = trimmed.match(/^\/(.*)\/([gimsuy]*)$/);
		try {
			patterns.push(match ? new RegExp(match[1], match[2]) : new RegExp(trimmed, "i"));
		} catch {
			// Ignore malformed optional user patterns; built-in safe patterns still apply.
		}
	}
	return patterns;
}

function matchesAnyRegex(command: string, patterns: RegExp[]): boolean {
	for (const pattern of patterns) {
		pattern.lastIndex = 0;
		if (pattern.test(command)) return true;
	}
	return false;
}

function loopIterationCount(command: string): number | null {
	const match = command.match(/\$\(\s*seq\s+(?:(\d+)\s+)?(\d+)\s*\)/i);
	if (!match) return null;
	const start = match[1] ? Number.parseInt(match[1], 10) : 1;
	const end = Number.parseInt(match[2] ?? "", 10);
	if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
	return Math.abs(end - start) + 1;
}

function sleepSeconds(command: string): number | null {
	const match = command.match(/\bsleep\s+((?:\d+(?:\.\d+)?)|(?:\.\d+))\s*([smhd])?\b/i);
	if (!match) return null;
	const value = Number.parseFloat(match[1] ?? "");
	if (!Number.isFinite(value)) return null;
	const unit = (match[2] ?? "s").toLowerCase();
	if (unit === "d") return value * 86_400;
	if (unit === "h") return value * 3_600;
	if (unit === "m") return value * 60;
	return value;
}

function looksLikeSessionMonitor(command: string): boolean {
	return /\b(?:pi-bridge|tmux|capture-pane|list-panes|has-session|delegate-state|subagent|session)\b/i.test(command);
}

export function autoBackgroundDecision(command: string, cwd?: string): BashBackgroundDecision | null {
	const normalized = normalizedCommand(command);
	if (!normalized) return null;
	if (matchesAnyRegex(normalized, parsePatternList(settingString("autoBackgroundPatterns", "", cwd)))) {
		return {
			forced: false,
			notifyOnExit: true,
			notifyOnOutput: false,
			reason: "matched configured auto-background pattern",
			title: `auto: ${compactText(normalized, 72)}`,
		};
	}

	if (/(?:^|[;&|]\s*)watch(?:\s|$)/i.test(normalized)) {
		return {
			forced: false,
			notifyOnExit: true,
			notifyOnOutput: false,
			reason: "watch-style command",
			title: `watch: ${compactText(normalized, 72)}`,
		};
	}

	if (/\b(?:tail|journalctl)\b[^\n;|&]*\s-[^\s;|&]*f\b/i.test(normalized)) {
		return {
			forced: false,
			notifyOnExit: true,
			notifyOnOutput: false,
			reason: "follow-mode log command",
			title: `follow: ${compactText(normalized, 72)}`,
		};
	}

	const delaySeconds = sleepSeconds(normalized);
	if (delaySeconds !== null && delaySeconds >= 5 && looksLikeSessionMonitor(normalized)) {
		return {
			forced: false,
			notifyOnExit: true,
			notifyOnOutput: false,
			reason: "delayed session/tmux monitoring command",
			title: `monitor: ${compactText(normalized, 72)}`,
		};
	}

	const hasShellLoop = /\b(?:for|while|until)\b/i.test(normalized) && /\bdo\b/i.test(normalized) && /\bdone\b/i.test(normalized);
	const hasSleep = /\bsleep\s+(?:\d+(?:\.\d+)?|\.\d+)/i.test(normalized);
	if (hasShellLoop && hasSleep) {
		const iterations = loopIterationCount(normalized);
		const looksLikeMonitor = looksLikeSessionMonitor(normalized);
		const longFiniteLoop = iterations !== null && iterations >= 30;
		const openEndedLoop = /\bwhile\s+(?:true|:)\b/i.test(normalized) || /\buntil\b/i.test(normalized);
		if (looksLikeMonitor || longFiniteLoop || openEndedLoop) {
			return {
				forced: false,
				notifyOnExit: true,
				notifyOnOutput: false,
				reason: looksLikeMonitor ? "session/tmux monitoring loop" : "long-running polling loop",
				title: `monitor: ${compactText(normalized, 72)}`,
			};
		}
	}

	return null;
}

export function forcedBackgroundDecision(command: string, cwd?: string): BashBackgroundDecision {
	return {
		forced: true,
		notifyOnExit: true,
		notifyOnOutput: settingBoolean("forcedBackgroundNotifyOnOutput", false, cwd),
		reason: "requested by background shortcut",
		title: `shortcut: ${compactText(normalizedCommand(command), 72)}`,
	};
}

export function bashBackgroundAckText(task: BackgroundTaskSnapshot, decision: BashBackgroundDecision): string {
	return [
		`Started ${task.id} (pid ${task.pid}) in the background.`,
		`Reason: ${decision.reason}.`,
		`Command: ${task.command}`,
		`Cwd: ${task.cwd}`,
		`Log: ${task.logFile}`,
		`Wakeups: exit=${task.notifyOnExit ? "yes" : "no"}, output=${task.notifyOnOutput ? (task.notifyPattern ?? "yes") : "no"}, mode=${task.notifyMode ?? "always"}${task.dedupeKey ? `, dedupeKey=${task.dedupeKey}` : ""}`,
		"Continue the turn without waiting. Use bg_task list/log/stop to inspect or terminate this task.",
	].join("\n");
}

export function bashBackgroundAck(task: BackgroundTaskSnapshot, decision: BashBackgroundDecision): string {
	return `printf '%s\\n' ${shellQuote(bashBackgroundAckText(task, decision))}`;
}
