import { execFile } from "node:child_process";
import { constants } from "node:fs";
import { open } from "node:fs/promises";
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

/** The source pane as one tmux query reports it when a notification fires. */
interface TmuxPaneState {
	paneTty: string;
	windowActive: boolean;
	sessionId: string;
	windowId: string;
	windowName: string;
}

/** `#W` is last: a window name may hold a tab, so every field after the fourth is the name. */
const PANE_STATE_FORMAT = "#{pane_tty}\t#{window_active}\t#{session_id}\t#{window_id}\t#W";

/**
 * Every terminal write joins this chain and runs alone, in queue order. Each
 * write opens its tty non-blocking, so a full terminal fails the write rather
 * than holding it, and the chain always advances.
 */
let terminalWrites: Promise<void> = Promise.resolve();
/** Bumped by `clearTmuxWindowMark`; a notification decided before the bump does not mark. */
let tmuxMarkGeneration = 0;

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

/**
 * Reads the source pane once per notification. The session and window are
 * read fresh each time: tmux `break-pane`, `join-pane` and `move-window` move
 * a pane to another window or session and keep its id and tty.
 */
async function sourceTmuxPaneState(pi: QolNotificationExec): Promise<TmuxPaneState | undefined> {
	const pane = process.env.TMUX_PANE;
	if (!pane) return undefined;
	const stdout = await tmux(pi, ["display-message", "-p", "-t", pane, PANE_STATE_FORMAT]);
	const [paneTty = "", windowActive = "", sessionId = "", windowId = "", ...name] = (stdout ?? "").replace(/\r?\n$/, "").split("\t");
	if (!paneTty || !sessionId || !windowId) return undefined;
	return { paneTty, windowActive: windowActive === "1", sessionId, windowId, windowName: name.join("\t") };
}

async function tmuxClientTtys(pi: QolNotificationExec, pane: TmuxPaneState | undefined): Promise<string[]> {
	if (!process.env.TMUX) return [];
	const args = ["list-clients", "-F", "#{client_tty}"];
	if (pane) args.splice(1, 0, "-t", pane.sessionId);
	const output = await tmux(pi, args);
	if (output === undefined) return [];
	return [...new Set(output.split(/\r?\n/).map((line) => line.trim()).filter(Boolean))];
}

function queueTerminalWrite(write: () => Promise<void>): Promise<void> {
	const queued = terminalWrites.then(write);
	terminalWrites = queued.catch(() => undefined);
	return queued;
}

/**
 * Writes to a terminal without waiting on it. A tmux client whose SSH link
 * dropped stays attached with a full tty buffer, and a blocking write to it
 * would hang until the link times out; non-blocking, it fails with `EAGAIN`.
 * `O_NOCTTY` keeps the open from making the tty Pi's controlling terminal.
 */
async function writeTty(path: string, output: string): Promise<void> {
	const handle = await open(path, constants.O_WRONLY | constants.O_NONBLOCK | constants.O_NOCTTY);
	try {
		await handle.writeFile(output, "utf8");
	} finally {
		await handle.close();
	}
}

async function writeRawToPaths(paths: string[], output: string): Promise<boolean> {
	let wrote = false;
	for (const path of paths) {
		try {
			await writeTty(path, output);
			wrote = true;
		} catch {
			// Try remaining paths.
		}
	}
	return wrote;
}

async function writeToTerminal(pane: TmuxPaneState | undefined, output: string): Promise<void> {
	try {
		await writeTty(pane?.paneTty ?? "/dev/tty", output);
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

async function writeTerminalSequence(pi: QolNotificationExec, pane: TmuxPaneState | undefined, sequence: string, cwd?: string): Promise<void> {
	// Inactive tmux windows do not forward arbitrary OSC output to the terminal.
	// Send native terminal notifications straight to attached tmux client TTYs,
	// while the explicit terminal bell still goes through the source pane when unmuted.
	const clientTtys = process.env.TMUX && settingBoolean("notification.tmuxNativeClientTty", true, cwd) ? await tmuxClientTtys(pi, pane) : [];
	const output = process.env.TMUX && settingBoolean("notification.tmuxPassthrough", true, cwd) ? tmuxPassthrough(sequence) : sequence;
	await queueTerminalWrite(async () => {
		if (await writeRawToPaths(clientTtys, sequence)) return;
		await writeToTerminal(pane, output);
	});
}

function writeTerminalBell(pane: TmuxPaneState | undefined, cwd?: string): Promise<void> {
	// Match Claude-style hooks: resolve the source pane TTY and write raw BEL there.
	// This lets tmux set window_bell_flag for the correct source window.
	const sequence = terminalBellSequence(notificationBellMuted(cwd));
	if (!sequence) return Promise.resolve();
	return queueTerminalWrite(() => writeToTerminal(pane, sequence));
}

function notifyOSC777(pi: QolNotificationExec, pane: TmuxPaneState | undefined, title: string, body: string, cwd?: string): Promise<void> {
	return writeTerminalSequence(pi, pane, osc777NotificationSequence(title, body, notificationBellMuted(cwd)), cwd);
}

async function notifyOSC99(pi: QolNotificationExec, pane: TmuxPaneState | undefined, title: string, body: string, cwd?: string): Promise<void> {
	await writeTerminalSequence(pi, pane, `\x1b]99;i=1:d=0;${title}\x1b\\`, cwd);
	await writeTerminalSequence(pi, pane, `\x1b]99;i=1:p=body;${body}\x1b\\`, cwd);
}

function notifyWindows(title: string, body: string): void {
	execFile("powershell.exe", ["-NoProfile", "-Command", windowsToastScript(title, body)], () => undefined);
}

async function notifyNativeTerminal(pi: QolNotificationExec, pane: TmuxPaneState | undefined, title: string, body: string, cwd?: string): Promise<void> {
	const protocol = settingString("notification.oscProtocol", "auto", cwd);
	if (process.env.WT_SESSION) {
		notifyWindows(title, body);
		return;
	}
	if (protocol === "off") return;
	if (protocol === "osc99" || (protocol === "auto" && process.env.KITTY_WINDOW_ID)) {
		await notifyOSC99(pi, pane, title, body, cwd);
		return;
	}
	await notifyOSC777(pi, pane, title, body, cwd);
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

/** Renames the marked window back, if one is marked. */
function unmarkTmuxWindow(pi: QolNotificationExec): void {
	const target = tmuxMarkedTarget;
	const original = tmuxOriginalWindowName;
	tmuxMarkedTarget = undefined;
	tmuxOriginalWindowName = undefined;
	if (!target || !original) return;
	void tmux(pi, ["rename-window", "-t", target, original]);
}

/** Removes the window mark, and keeps a notification still in flight from setting one. */
export function clearTmuxWindowMark(pi: QolNotificationExec): void {
	tmuxMarkGeneration += 1;
	if (tmuxWindowMarkTimer) clearTimeout(tmuxWindowMarkTimer);
	tmuxWindowMarkTimer = undefined;
	unmarkTmuxWindow(pi);
}

function markTmuxWindow(pi: QolNotificationExec, pane: TmuxPaneState | undefined, generation: number, cwd?: string): void {
	if (!settingBoolean("notification.tmuxWindowMark", false, cwd)) return;
	if (!process.env.TMUX || !pane || generation !== tmuxMarkGeneration) return;
	const mark = sanitizeNotificationPart(settingString("notification.tmuxWindowMarkText", "!", cwd), 12) || "!";
	const prefix = `${mark} `;
	const target = pane.windowId;
	const current = pane.windowName;
	if (!current) return;
	// The pane moved to another window since the last mark: that window gets its name back.
	if (tmuxMarkedTarget && tmuxMarkedTarget !== target) unmarkTmuxWindow(pi);
	if (!tmuxMarkedTarget) {
		tmuxMarkedTarget = target;
		tmuxOriginalWindowName = current.startsWith(prefix) ? current.slice(prefix.length) : current;
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

/**
 * The window mark and the tmux message never touch the terminal, so they start
 * beside the terminal writes rather than behind them.
 */
async function deliverTerminalNotification(pi: QolNotificationExec, title: string, text: string, markGeneration: number, cwd?: string): Promise<void> {
	const pane = await sourceTmuxPaneState(pi);
	const windowActive = pane?.windowActive ?? false;
	if (!windowActive) markTmuxWindow(pi, pane, markGeneration, cwd);
	if (settingBoolean("notification.tmux", false, cwd)) notifyTmux(pi, title, text, cwd);
	if (settingBoolean("notification.bell", true, cwd) && (!windowActive || settingBoolean("notification.bellWhenActive", false, cwd))) await writeTerminalBell(pane, cwd);
	if (settingBoolean("notification.native", true, cwd)) await notifyNativeTerminal(pi, pane, title, text, cwd);
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
	return deliverTerminalNotification(pi, title, text, tmuxMarkGeneration, cwd).catch(() => undefined);
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
