import { execFile, execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	DEFAULT_NOTIFICATION_BODY_MAX_CHARS,
	DEFAULT_NOTIFICATION_COOLDOWN_SECONDS,
	DEFAULT_NOTIFICATION_TITLE,
	DEFAULT_TMUX_MESSAGE_DURATION_MS,
	QUESTION_NOTIFY_DEDUP_MS,
} from "./constants.js";
import { settingBoolean, settingNumber, settingString } from "./settings.js";
import type { QuestionOpenedEventLike, QuestionRequestLike } from "./bridges.js";

export type QolNotificationKind = "ready" | "direction" | "question" | "task-complete" | "critical" | "test";
export type QolNotificationLevel = "info" | "warning" | "error";

export interface QolNotificationService {
	notifyQuestionOpened(ctx: ExtensionContext | undefined, event: QuestionOpenedEventLike): boolean;
}

const lastNotificationAt = new Map<string, number>();
const lastQuestionNotificationAt = new Map<string, number>();
let tmuxMarkedTarget: string | undefined;
let tmuxOriginalWindowName: string | undefined;
let tmuxWindowMarkTimer: ReturnType<typeof setTimeout> | undefined;

export function sanitizeNotificationPart(input: string, maxChars = DEFAULT_NOTIFICATION_BODY_MAX_CHARS): string {
	const cleaned = input
		.replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, " ")
		.replace(/\s+/g, " ")
		.trim();
	return cleaned.length > maxChars ? `${cleaned.slice(0, Math.max(0, maxChars - 1))}…` : cleaned;
}

function windowsToastScript(title: string, body: string): string {
	const escapedTitle = title.replace(/'/g, "''");
	const escapedBody = body.replace(/'/g, "''");
	const type = "Windows.UI.Notifications";
	const mgr = `[${type}.ToastNotificationManager, ${type}, ContentType = WindowsRuntime]`;
	const template = `[${type}.ToastTemplateType]::ToastText02`;
	const toast = `[${type}.ToastNotification]::new($xml)`;
	return [
		`${mgr} > $null`,
		`$xml = [${type}.ToastNotificationManager]::GetTemplateContent(${template})`,
		`$xml.GetElementsByTagName('text')[0].AppendChild($xml.CreateTextNode('${escapedTitle}')) > $null`,
		`$xml.GetElementsByTagName('text')[1].AppendChild($xml.CreateTextNode('${escapedBody}')) > $null`,
		`[${type}.ToastNotificationManager]::CreateToastNotifier('${escapedTitle}').Show(${toast})`,
	].join("; ");
}

function tmuxPassthrough(sequence: string): string {
	return `\x1bPtmux;${sequence.replace(/\x1b/g, "\x1b\x1b")}\x1b\\`;
}

export function terminalBellSequence(muteBellSound: boolean): string | undefined {
	return muteBellSound ? undefined : "\x07";
}

export function osc777NotificationSequence(title: string, body: string, muteBellSound = false): string {
	const terminator = muteBellSound ? "\x1b\\" : "\x07";
	return `\x1b]777;notify;${title};${body}${terminator}`;
}

function notificationBellMuted(cwd?: string): boolean {
	return settingBoolean("notification.muteBellSound", false, cwd);
}

function sourcePaneTty(): string | undefined {
	try {
		if (!process.env.TMUX_PANE) return undefined;
		const tty = execFileSync("tmux", ["display-message", "-p", "-t", process.env.TMUX_PANE, "#{pane_tty}"], { encoding: "utf8" }).trim();
		return tty || undefined;
	} catch {
		return undefined;
	}
}

function sourceTmuxSession(): string | undefined {
	try {
		if (!process.env.TMUX_PANE) return undefined;
		const session = execFileSync("tmux", ["display-message", "-p", "-t", process.env.TMUX_PANE, "#{session_name}"], { encoding: "utf8" }).trim();
		return session || undefined;
	} catch {
		return undefined;
	}
}

export function sourceTmuxWindowActive(): boolean {
	try {
		if (!process.env.TMUX_PANE) return false;
		const active = execFileSync("tmux", ["display-message", "-p", "-t", process.env.TMUX_PANE, "#{window_active}"], { encoding: "utf8" }).trim();
		return active === "1";
	} catch {
		return false;
	}
}

function tmuxClientTtys(): string[] {
	try {
		if (!process.env.TMUX) return [];
		const session = sourceTmuxSession();
		const args = ["list-clients", "-F", "#{client_tty}"];
		if (session) args.splice(1, 0, "-t", session);
		const output = execFileSync("tmux", args, { encoding: "utf8" });
		return [...new Set(output.split(/\r?\n/).map((line) => line.trim()).filter(Boolean))];
	} catch {
		return [];
	}
}

function writeRawToPaths(paths: string[], output: string): boolean {
	let wrote = false;
	for (const path of paths) {
		try {
			writeFileSync(path, output, "utf8");
			wrote = true;
		} catch {
			// Try remaining paths.
		}
	}
	return wrote;
}

function writeToTerminal(output: string): void {
	const tty = sourcePaneTty();
	try {
		writeFileSync(tty ?? "/dev/tty", output, "utf8");
		return;
	} catch {
		// Fall through to stdout best-effort.
	}
	try {
		if (process.stdout.isTTY) process.stdout.write(output);
	} catch {
		// Notification best-effort only.
	}
}

function writeTerminalSequence(sequence: string, cwd?: string): void {
	if (process.env.TMUX && settingBoolean("notification.tmuxNativeClientTty", true, cwd)) {
		// Inactive tmux windows do not forward arbitrary OSC output to the terminal.
		// Send native terminal notifications straight to attached tmux client TTYs,
		// while the explicit terminal bell still goes through the source pane when unmuted.
		if (writeRawToPaths(tmuxClientTtys(), sequence)) return;
	}
	const output = process.env.TMUX && settingBoolean("notification.tmuxPassthrough", true, cwd) ? tmuxPassthrough(sequence) : sequence;
	writeToTerminal(output);
}

function writeTerminalBell(cwd?: string): void {
	// Match Claude-style hooks: resolve the source pane TTY and write raw BEL there.
	// This lets tmux set window_bell_flag for the correct source window.
	const sequence = terminalBellSequence(notificationBellMuted(cwd));
	if (sequence) writeToTerminal(sequence);
}

function notifyOSC777(title: string, body: string, cwd?: string): void {
	writeTerminalSequence(osc777NotificationSequence(title, body, notificationBellMuted(cwd)), cwd);
}

function notifyOSC99(title: string, body: string, cwd?: string): void {
	writeTerminalSequence(`\x1b]99;i=1:d=0;${title}\x1b\\`, cwd);
	writeTerminalSequence(`\x1b]99;i=1:p=body;${body}\x1b\\`, cwd);
}

function notifyWindows(title: string, body: string): void {
	execFile("powershell.exe", ["-NoProfile", "-Command", windowsToastScript(title, body)], () => undefined);
}

function notifyNativeTerminal(title: string, body: string, cwd?: string): void {
	const protocol = settingString("notification.oscProtocol", "auto", cwd);
	if (process.env.WT_SESSION) {
		notifyWindows(title, body);
		return;
	}
	if (protocol === "off") return;
	if (protocol === "osc99" || (protocol === "auto" && process.env.KITTY_WINDOW_ID)) {
		notifyOSC99(title, body, cwd);
		return;
	}
	notifyOSC777(title, body, cwd);
}

function notifyTmux(title: string, body: string, cwd?: string): void {
	if (!process.env.TMUX && !process.env.TMUX_PANE) return;
	const duration = Math.max(500, Math.floor(settingNumber("notification.tmuxMessageDurationMs", DEFAULT_TMUX_MESSAGE_DURATION_MS, cwd)));
	const message = `${title}: ${body}`;
	const args = ["display-message", "-d", String(duration)];
	if (process.env.TMUX_PANE) args.push("-t", process.env.TMUX_PANE);
	args.push(message);
	execFile("tmux", args, () => undefined);
}

export function clearTmuxWindowMark(): void {
	if (tmuxWindowMarkTimer) clearTimeout(tmuxWindowMarkTimer);
	tmuxWindowMarkTimer = undefined;
	const target = tmuxMarkedTarget;
	const original = tmuxOriginalWindowName;
	tmuxMarkedTarget = undefined;
	tmuxOriginalWindowName = undefined;
	if (!target || !original) return;
	execFile("tmux", ["rename-window", "-t", target, original], () => undefined);
}

function markTmuxWindow(cwd?: string): void {
	if (!settingBoolean("notification.tmuxWindowMark", false, cwd)) return;
	if (!process.env.TMUX || !process.env.TMUX_PANE) return;
	const mark = sanitizeNotificationPart(settingString("notification.tmuxWindowMarkText", "!", cwd), 12) || "!";
	const prefix = `${mark} `;
	execFile("tmux", ["display-message", "-p", "-t", process.env.TMUX_PANE, "#{session_name}:#{window_index}"], (targetError, targetStdout) => {
		if (targetError) return;
		const target = targetStdout.trim();
		if (!target) return;
		execFile("tmux", ["display-message", "-p", "-t", process.env.TMUX_PANE!, "#W"], (nameError, nameStdout) => {
			if (nameError) return;
			const current = nameStdout.replace(/\r?\n$/, "");
			if (!current) return;
			const original = current.startsWith(prefix) ? current.slice(prefix.length) : current;
			if (!tmuxMarkedTarget || tmuxMarkedTarget !== target) {
				tmuxMarkedTarget = target;
				tmuxOriginalWindowName = original;
			}
			if (!current.startsWith(prefix)) execFile("tmux", ["rename-window", "-t", target, `${prefix}${current}`], () => undefined);
			const duration = Math.max(0, Math.floor(settingNumber("notification.tmuxWindowMarkDurationMs", 0, cwd)));
			if (tmuxWindowMarkTimer) clearTimeout(tmuxWindowMarkTimer);
			if (duration > 0) {
				tmuxWindowMarkTimer = setTimeout(clearTmuxWindowMark, duration);
				tmuxWindowMarkTimer.unref?.();
			}
		});
	});
}

function notificationEnabledFor(kind: QolNotificationKind, cwd?: string): boolean {
	if (!settingBoolean("notification.enabled", true, cwd)) return false;
	switch (kind) {
		case "ready": return settingBoolean("notification.onAgentReady", true, cwd);
		case "direction": return settingBoolean("notification.onDirectionNeeded", true, cwd);
		case "question": return settingBoolean("notification.onQuestion", true, cwd);
		case "task-complete": return settingBoolean("notification.onTaskComplete", true, cwd);
		case "critical": return settingBoolean("notification.onCritical", true, cwd);
		case "test": return true;
	}
}

export function sendQolNotification(ctx: ExtensionContext | undefined, kind: QolNotificationKind, body: string, level: QolNotificationLevel = "info", key: string = kind): void {
	const cwd = ctx?.cwd;
	if (ctx && !ctx.hasUI) return;
	if (!notificationEnabledFor(kind, cwd)) return;
	const cooldownMs = Math.max(0, settingNumber("notification.cooldownSeconds", DEFAULT_NOTIFICATION_COOLDOWN_SECONDS, cwd) * 1000);
	const now = Date.now();
	const last = lastNotificationAt.get(key) ?? 0;
	if (cooldownMs > 0 && now - last < cooldownMs) return;
	lastNotificationAt.set(key, now);

	const title = sanitizeNotificationPart(settingString("notification.title", DEFAULT_NOTIFICATION_TITLE, cwd), 80) || DEFAULT_NOTIFICATION_TITLE;
	const text = sanitizeNotificationPart(body, Math.max(40, Math.floor(settingNumber("notification.bodyMaxChars", DEFAULT_NOTIFICATION_BODY_MAX_CHARS, cwd))));
	const tmuxWindowActive = sourceTmuxWindowActive();
	if (settingBoolean("notification.bell", true, cwd) && (!tmuxWindowActive || settingBoolean("notification.bellWhenActive", false, cwd))) writeTerminalBell(cwd);
	if (settingBoolean("notification.native", true, cwd)) notifyNativeTerminal(title, text, cwd);
	if (!tmuxWindowActive) markTmuxWindow(cwd);
	if (settingBoolean("notification.tmux", false, cwd)) notifyTmux(title, text, cwd);
	if (ctx?.hasUI && settingBoolean("notification.piUi", false, cwd)) ctx.ui.notify(text, level);
}

function questionNotificationTitle(request?: QuestionRequestLike): string {
	if (typeof request?.header === "string" && request.header.trim()) return request.header.trim();
	if (typeof request?.question === "string" && request.question.trim()) return request.question.trim();
	return "Question";
}

export function notifyQuestionOpened(ctx: ExtensionContext | undefined, event: QuestionOpenedEventLike, keyPrefix = "question"): void {
	const title = questionNotificationTitle(event.request);
	const key = `${keyPrefix}:${event.requestId ?? title}`;
	const now = Date.now();
	const last = lastQuestionNotificationAt.get(key) ?? 0;
	if (now - last < QUESTION_NOTIFY_DEDUP_MS) return;
	lastQuestionNotificationAt.set(key, now);
	for (const [storedKey, timestamp] of lastQuestionNotificationAt) {
		if (now - timestamp > 60_000) lastQuestionNotificationAt.delete(storedKey);
	}
	sendQolNotification(ctx, "question", `Input required: ${title}`, "warning", key);
}
