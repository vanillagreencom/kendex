import { execFile } from "node:child_process";
import { writeFile } from "node:fs/promises";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import {
	DEFAULT_NOTIFICATION_BODY_MAX_CHARS,
	DEFAULT_NOTIFICATION_COOLDOWN_SECONDS,
	DEFAULT_NOTIFICATION_TITLE,
	DEFAULT_TMUX_MESSAGE_DURATION_MS,
	QUESTION_NOTIFY_DEDUP_MS,
	TMUX_COMMAND_TIMEOUT_MS,
} from "./constants.js";
import { settingBoolean, settingNumber, settingString } from "./settings.js";
import type { QuestionOpenedEventLike, QuestionRequestLike } from "./bridges.js";

export type QolNotificationKind = "ready" | "direction" | "question" | "task-complete" | "critical" | "test";
export type QolNotificationLevel = "info" | "warning" | "error";
/** The one Pi call notifications need: `pi.exec`, whose `timeout` kills a stalled tmux. */
export type QolNotificationExec = Pick<ExtensionAPI, "exec">;

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

interface TmuxPaneIdentity {
	paneTty: string;
	sessionId: string;
	windowId: string;
}

/**
 * The source pane's tty, session and window, looked up once per Pi session.
 * The ids (`$N`, `@N`) survive a session or window rename. A failed lookup is
 * not cached, so the next notification asks again.
 */
let tmuxIdentity: Promise<TmuxPaneIdentity | undefined> | undefined;
/**
 * Every terminal write joins this chain and runs alone, in queue order: a
 * write to a stalled terminal holds the writes behind it, not Pi, and ties up
 * one I/O thread rather than one per notification.
 */
let terminalWrites: Promise<void> = Promise.resolve();

/**
 * Runs one tmux command under `TMUX_COMMAND_TIMEOUT_MS`. Undefined means no
 * answer: a non-zero exit, a timeout, or a Pi runtime that went stale after
 * session replacement (`pi.exec` then throws). Pi reports a command its
 * timeout killed with `killed` and, when the signal left no exit status,
 * with code 0, so `killed` is read first.
 */
async function tmux(pi: QolNotificationExec, args: string[]): Promise<string | undefined> {
	try {
		const result = await pi.exec("tmux", args, { timeout: TMUX_COMMAND_TIMEOUT_MS });
		if (result.killed || result.code !== 0) return undefined;
		return result.stdout;
	} catch {
		return undefined;
	}
}

function sourceTmuxIdentity(pi: QolNotificationExec): Promise<TmuxPaneIdentity | undefined> {
	const pane = process.env.TMUX_PANE;
	if (!pane) return Promise.resolve(undefined);
	if (tmuxIdentity) return tmuxIdentity;
	const lookup = tmux(pi, ["display-message", "-p", "-t", pane, "#{pane_tty}\t#{session_id}\t#{window_id}"]).then((stdout) => {
		const [paneTty = "", sessionId = "", windowId = ""] = (stdout ?? "").replace(/\r?\n$/, "").split("\t");
		if (!paneTty || !sessionId || !windowId) return undefined;
		return { paneTty, sessionId, windowId };
	});
	tmuxIdentity = lookup;
	void lookup.then((identity) => {
		if (!identity && tmuxIdentity === lookup) tmuxIdentity = undefined;
	});
	return lookup;
}

/** Drops the cached tmux identity; the next Pi session looks it up again. */
export function forgetTmuxIdentity(): void {
	tmuxIdentity = undefined;
}

async function sourceTmuxWindowActive(pi: QolNotificationExec): Promise<boolean> {
	const pane = process.env.TMUX_PANE;
	if (!pane) return false;
	return (await tmux(pi, ["display-message", "-p", "-t", pane, "#{window_active}"]))?.trim() === "1";
}

async function tmuxClientTtys(pi: QolNotificationExec, identity: TmuxPaneIdentity | undefined): Promise<string[]> {
	if (!process.env.TMUX) return [];
	const args = ["list-clients", "-F", "#{client_tty}"];
	if (identity) args.splice(1, 0, "-t", identity.sessionId);
	const output = await tmux(pi, args);
	if (output === undefined) return [];
	return [...new Set(output.split(/\r?\n/).map((line) => line.trim()).filter(Boolean))];
}

function queueTerminalWrite(write: () => Promise<void>): Promise<void> {
	const queued = terminalWrites.then(write);
	terminalWrites = queued.catch(() => undefined);
	return queued;
}

async function writeRawToPaths(paths: string[], output: string): Promise<boolean> {
	let wrote = false;
	for (const path of paths) {
		try {
			await writeFile(path, output, "utf8");
			wrote = true;
		} catch {
			// Try remaining paths.
		}
	}
	return wrote;
}

async function writeToTerminal(identity: TmuxPaneIdentity | undefined, output: string): Promise<void> {
	try {
		await writeFile(identity?.paneTty ?? "/dev/tty", output, "utf8");
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

async function writeTerminalSequence(pi: QolNotificationExec, identity: TmuxPaneIdentity | undefined, sequence: string, cwd?: string): Promise<void> {
	// Inactive tmux windows do not forward arbitrary OSC output to the terminal.
	// Send native terminal notifications straight to attached tmux client TTYs,
	// while the explicit terminal bell still goes through the source pane when unmuted.
	const clientTtys = process.env.TMUX && settingBoolean("notification.tmuxNativeClientTty", true, cwd) ? await tmuxClientTtys(pi, identity) : [];
	const output = process.env.TMUX && settingBoolean("notification.tmuxPassthrough", true, cwd) ? tmuxPassthrough(sequence) : sequence;
	await queueTerminalWrite(async () => {
		if (await writeRawToPaths(clientTtys, sequence)) return;
		await writeToTerminal(identity, output);
	});
}

function writeTerminalBell(identity: TmuxPaneIdentity | undefined, cwd?: string): Promise<void> {
	// Match Claude-style hooks: resolve the source pane TTY and write raw BEL there.
	// This lets tmux set window_bell_flag for the correct source window.
	const sequence = terminalBellSequence(notificationBellMuted(cwd));
	if (!sequence) return Promise.resolve();
	return queueTerminalWrite(() => writeToTerminal(identity, sequence));
}

function notifyOSC777(pi: QolNotificationExec, identity: TmuxPaneIdentity | undefined, title: string, body: string, cwd?: string): Promise<void> {
	return writeTerminalSequence(pi, identity, osc777NotificationSequence(title, body, notificationBellMuted(cwd)), cwd);
}

async function notifyOSC99(pi: QolNotificationExec, identity: TmuxPaneIdentity | undefined, title: string, body: string, cwd?: string): Promise<void> {
	await writeTerminalSequence(pi, identity, `\x1b]99;i=1:d=0;${title}\x1b\\`, cwd);
	await writeTerminalSequence(pi, identity, `\x1b]99;i=1:p=body;${body}\x1b\\`, cwd);
}

function notifyWindows(title: string, body: string): void {
	execFile("powershell.exe", ["-NoProfile", "-Command", windowsToastScript(title, body)], () => undefined);
}

async function notifyNativeTerminal(pi: QolNotificationExec, identity: TmuxPaneIdentity | undefined, title: string, body: string, cwd?: string): Promise<void> {
	const protocol = settingString("notification.oscProtocol", "auto", cwd);
	if (process.env.WT_SESSION) {
		notifyWindows(title, body);
		return;
	}
	if (protocol === "off") return;
	if (protocol === "osc99" || (protocol === "auto" && process.env.KITTY_WINDOW_ID)) {
		await notifyOSC99(pi, identity, title, body, cwd);
		return;
	}
	await notifyOSC777(pi, identity, title, body, cwd);
}

function notifyTmux(pi: QolNotificationExec, title: string, body: string, cwd?: string): void {
	if (!process.env.TMUX && !process.env.TMUX_PANE) return;
	const duration = Math.max(500, Math.floor(settingNumber("notification.tmuxMessageDurationMs", DEFAULT_TMUX_MESSAGE_DURATION_MS, cwd)));
	const message = `${title}: ${body}`;
	const args = ["display-message", "-d", String(duration)];
	if (process.env.TMUX_PANE) args.push("-t", process.env.TMUX_PANE);
	args.push(message);
	void tmux(pi, args);
}

export function clearTmuxWindowMark(pi: QolNotificationExec): void {
	if (tmuxWindowMarkTimer) clearTimeout(tmuxWindowMarkTimer);
	tmuxWindowMarkTimer = undefined;
	const target = tmuxMarkedTarget;
	const original = tmuxOriginalWindowName;
	tmuxMarkedTarget = undefined;
	tmuxOriginalWindowName = undefined;
	if (!target || !original) return;
	void tmux(pi, ["rename-window", "-t", target, original]);
}

async function markTmuxWindow(pi: QolNotificationExec, identity: TmuxPaneIdentity | undefined, cwd?: string): Promise<void> {
	if (!settingBoolean("notification.tmuxWindowMark", false, cwd)) return;
	if (!process.env.TMUX || !process.env.TMUX_PANE || !identity) return;
	const mark = sanitizeNotificationPart(settingString("notification.tmuxWindowMarkText", "!", cwd), 12) || "!";
	const prefix = `${mark} `;
	const target = identity.windowId;
	const current = (await tmux(pi, ["display-message", "-p", "-t", process.env.TMUX_PANE, "#W"]))?.replace(/\r?\n$/, "");
	if (!current) return;
	const original = current.startsWith(prefix) ? current.slice(prefix.length) : current;
	if (!tmuxMarkedTarget || tmuxMarkedTarget !== target) {
		tmuxMarkedTarget = target;
		tmuxOriginalWindowName = original;
	}
	if (!current.startsWith(prefix)) void tmux(pi, ["rename-window", "-t", target, `${prefix}${current}`]);
	const duration = Math.max(0, Math.floor(settingNumber("notification.tmuxWindowMarkDurationMs", 0, cwd)));
	if (tmuxWindowMarkTimer) clearTimeout(tmuxWindowMarkTimer);
	if (duration > 0) {
		tmuxWindowMarkTimer = setTimeout(() => clearTmuxWindowMark(pi), duration);
		tmuxWindowMarkTimer.unref?.();
	}
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

async function deliverTerminalNotification(pi: QolNotificationExec, title: string, text: string, cwd?: string): Promise<void> {
	const [identity, tmuxWindowActive] = await Promise.all([sourceTmuxIdentity(pi), sourceTmuxWindowActive(pi)]);
	if (settingBoolean("notification.bell", true, cwd) && (!tmuxWindowActive || settingBoolean("notification.bellWhenActive", false, cwd))) await writeTerminalBell(identity, cwd);
	if (settingBoolean("notification.native", true, cwd)) await notifyNativeTerminal(pi, identity, title, text, cwd);
	if (!tmuxWindowActive) await markTmuxWindow(pi, identity, cwd);
	if (settingBoolean("notification.tmux", false, cwd)) notifyTmux(pi, title, text, cwd);
}

/**
 * Decides and records the notification synchronously, then delivers the
 * terminal and tmux channels in the background: the returned promise settles
 * when delivery is done, and no caller on Pi's event path awaits it, so a
 * stalled tmux server or terminal never holds up a turn end.
 */
export function sendQolNotification(pi: QolNotificationExec, ctx: ExtensionContext | undefined, kind: QolNotificationKind, body: string, level: QolNotificationLevel = "info", key: string = kind): Promise<void> {
	const cwd = ctx?.cwd;
	if (ctx && !ctx.hasUI) return Promise.resolve();
	if (!notificationEnabledFor(kind, cwd)) return Promise.resolve();
	const cooldownMs = Math.max(0, settingNumber("notification.cooldownSeconds", DEFAULT_NOTIFICATION_COOLDOWN_SECONDS, cwd) * 1000);
	const now = Date.now();
	const last = lastNotificationAt.get(key) ?? 0;
	if (cooldownMs > 0 && now - last < cooldownMs) return Promise.resolve();
	lastNotificationAt.set(key, now);

	const title = sanitizeNotificationPart(settingString("notification.title", DEFAULT_NOTIFICATION_TITLE, cwd), 80) || DEFAULT_NOTIFICATION_TITLE;
	const text = sanitizeNotificationPart(body, Math.max(40, Math.floor(settingNumber("notification.bodyMaxChars", DEFAULT_NOTIFICATION_BODY_MAX_CHARS, cwd))));
	if (ctx?.hasUI && settingBoolean("notification.piUi", false, cwd)) ctx.ui.notify(text, level);
	// Every channel already absorbs its own failure; this catch keeps an
	// unexpected throw from becoming an unhandled rejection, which ends Pi.
	return deliverTerminalNotification(pi, title, text, cwd).catch(() => undefined);
}

function questionNotificationTitle(request?: QuestionRequestLike): string {
	if (typeof request?.header === "string" && request.header.trim()) return request.header.trim();
	if (typeof request?.question === "string" && request.question.trim()) return request.question.trim();
	return "Question";
}

export function notifyQuestionOpened(pi: QolNotificationExec, ctx: ExtensionContext | undefined, event: QuestionOpenedEventLike, keyPrefix = "question"): void {
	const title = questionNotificationTitle(event.request);
	const key = `${keyPrefix}:${event.requestId ?? title}`;
	const now = Date.now();
	const last = lastQuestionNotificationAt.get(key) ?? 0;
	if (now - last < QUESTION_NOTIFY_DEDUP_MS) return;
	lastQuestionNotificationAt.set(key, now);
	for (const [storedKey, timestamp] of lastQuestionNotificationAt) {
		if (now - timestamp > 60_000) lastQuestionNotificationAt.delete(storedKey);
	}
	void sendQolNotification(pi, ctx, "question", `Input required: ${title}`, "warning", key);
}
