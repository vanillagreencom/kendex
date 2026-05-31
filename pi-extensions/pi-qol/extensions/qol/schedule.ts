import { truncateToWidth, type AutocompleteItem } from "@earendil-works/pi-tui";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { ansiGreen } from "./ansi.js";
import { stringifyError } from "./util.js";

export const SCHEDULE_ENTRY_TYPE = "qol-schedule";

const MAX_TIMER_DELAY_MS = 2_147_000_000;
const MAX_SCHEDULE_DELAY_MS = 30 * 24 * 60 * 60 * 1000;
const MAX_ACTIVE_SCHEDULES = 100;

interface ScheduleTimer {
	unref?: () => void;
}

export interface ScheduleClock {
	now(): number;
	setTimeout(callback: () => void, delayMs: number): ScheduleTimer;
	clearTimeout(timer: ScheduleTimer): void;
}

interface ScheduledMessage {
	createdAt: number;
	dueAt: number;
	id: string;
	message: string;
	timer?: ScheduleTimer;
}

type ScheduleEntryAction = "scheduled" | "delivered" | "cancelled" | "failed";

interface ScheduleEntryData {
	action: ScheduleEntryAction;
	cancelledAt?: number;
	createdAt?: number;
	deliveredAt?: number;
	dueAt?: number;
	failedAt?: number;
	id: string;
	message?: string;
}

export type ParsedScheduleCommand =
	| { kind: "list" }
	| { kind: "cancel"; all: boolean; id?: string }
	| { kind: "schedule"; delayMs: number; message: string }
	| { kind: "usage"; error?: string };

const DEFAULT_CLOCK: ScheduleClock = {
	now: () => Date.now(),
	setTimeout: (callback, delayMs) => setTimeout(callback, delayMs),
	clearTimeout: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
};

const SCHEDULE_COMPLETIONS: AutocompleteItem[] = [
	{ value: "list", label: "list", description: "Show pending scheduled messages" },
	{ value: "cancel ", label: "cancel <id|all>", description: "Cancel one scheduled message or all pending messages" },
	{ value: "20m ", label: "20m <message>", description: "Send a message after 20 minutes" },
	{ value: "1h30m ", label: "1h30m <message>", description: "Send a message after 1 hour 30 minutes" },
	{ value: "1h ", label: "1h <message>", description: "Send a message after 1 hour" },
];

export function getScheduleArgumentCompletions(prefix: string): AutocompleteItem[] | null {
	const query = prefix.trimStart().toLowerCase();
	const filtered = SCHEDULE_COMPLETIONS.filter((item) => item.value.toLowerCase().startsWith(query) || (item.label ?? item.value).toLowerCase().startsWith(query));
	return filtered.length > 0 ? filtered : null;
}

export function parseDurationMs(input: string): number | undefined {
	const text = input.trim().toLowerCase();
	if (!text) return undefined;
	if (/^\d+(?:\.\d+)?$/.test(text)) return clampScheduleDelay(Number(text) * 60 * 1000);

	let totalMs = 0;
	let matched = false;
	let previousRank = Number.POSITIVE_INFINITY;
	const seenUnits = new Set<string>();
	const re = /(\d+(?:\.\d+)?)(ms|seconds?|secs?|s|minutes?|mins?|min|m|hours?|hrs?|hr|h|days?|d)/gy;

	while (re.lastIndex < text.length) {
		const match = re.exec(text);
		if (!match) return undefined;
		const amount = Number(match[1]);
		const unit = scheduleUnit(match[2]);
		if (!Number.isFinite(amount) || amount < 0 || !unit) return undefined;
		if (seenUnits.has(unit.name) || unit.rank >= previousRank) return undefined;
		seenUnits.add(unit.name);
		previousRank = unit.rank;
		totalMs += amount * unit.multiplier;
		matched = true;
	}

	const delayMs = Math.round(totalMs);
	return matched ? clampScheduleDelay(delayMs) : undefined;
}

function clampScheduleDelay(delayMs: number): number | undefined {
	if (!Number.isFinite(delayMs) || delayMs <= 0 || delayMs > MAX_SCHEDULE_DELAY_MS) return undefined;
	return delayMs;
}

function scheduleUnit(unit: string): { multiplier: number; name: string; rank: number } | undefined {
	if (unit === "ms") return { multiplier: 1, name: "ms", rank: 0 };
	if (["s", "sec", "secs", "second", "seconds"].includes(unit)) return { multiplier: 1000, name: "s", rank: 1 };
	if (["m", "min", "mins", "minute", "minutes"].includes(unit)) return { multiplier: 60 * 1000, name: "m", rank: 2 };
	if (["h", "hr", "hrs", "hour", "hours"].includes(unit)) return { multiplier: 60 * 60 * 1000, name: "h", rank: 3 };
	if (["d", "day", "days"].includes(unit)) return { multiplier: 24 * 60 * 60 * 1000, name: "d", rank: 4 };
	return undefined;
}

export function parseScheduleCommandArgs(args: string): ParsedScheduleCommand {
	const trimmed = args.trim();
	if (!trimmed) return { kind: "list" };
	const firstSpace = trimmed.search(/\s/);
	const head = (firstSpace < 0 ? trimmed : trimmed.slice(0, firstSpace)).toLowerCase();
	const rest = firstSpace < 0 ? "" : trimmed.slice(firstSpace + 1).trim();
	if (head === "list" || head === "ls" || head === "status") return { kind: "list" };
	if (head === "cancel" || head === "clear") {
		if (!rest) return { kind: "usage", error: "Usage: /schedule cancel <id|all>" };
		if (rest.toLowerCase() === "all") return { kind: "cancel", all: true };
		return { kind: "cancel", all: false, id: rest };
	}
	const delayMs = parseDurationMs(head);
	if (delayMs === undefined) return { kind: "usage", error: "Usage: /schedule <duration> <message>" };
	if (!rest) return { kind: "usage", error: "Usage: /schedule <duration> <message>" };
	return { kind: "schedule", delayMs, message: rest };
}

export function formatScheduleDuration(ms: number): string {
	const totalSeconds = Math.max(0, Math.round(ms / 1000));
	const days = Math.floor(totalSeconds / 86_400);
	const hours = Math.floor((totalSeconds % 86_400) / 3600);
	const minutes = Math.floor((totalSeconds % 3600) / 60);
	const seconds = totalSeconds % 60;
	const parts: string[] = [];
	if (days) parts.push(`${days}d`);
	if (hours) parts.push(`${hours}h`);
	if (minutes) parts.push(`${minutes}m`);
	if (seconds || parts.length === 0) parts.push(`${seconds}s`);
	return parts.slice(0, 2).join(" ");
}

function previewMessage(message: string, max = 80): string {
	const singleLine = message.replace(/\s+/g, " ").trim();
	if (singleLine.length <= max) return singleLine;
	return `${singleLine.slice(0, Math.max(0, max - 1))}…`;
}

function formatDueTime(timestamp: number): string {
	return new Date(timestamp).toLocaleString();
}

function usageText(): string {
	return [
		"Usage: /schedule <duration> <message>",
		"Examples: /schedule 20m retry the previous request",
		"          /schedule 1h30m retry after the rate limit reset",
		"Durations: 20, 20m, 90s, 500ms, 1h45m30s (bare numbers mean minutes)",
		"Manage: /schedule list, /schedule cancel <id|all>",
	].join("\n");
}

function dataToJob(data: ScheduleEntryData): ScheduledMessage | undefined {
	if (data.action !== "scheduled") return undefined;
	if (!data.id || typeof data.id !== "string") return undefined;
	if (!data.message || typeof data.message !== "string") return undefined;
	if (typeof data.createdAt !== "number" || typeof data.dueAt !== "number") return undefined;
	if (!Number.isFinite(data.createdAt) || !Number.isFinite(data.dueAt)) return undefined;
	return { createdAt: data.createdAt, dueAt: data.dueAt, id: data.id, message: data.message };
}

export function createScheduleController(pi: ExtensionAPI, clock: ScheduleClock = DEFAULT_CLOCK) {
	let onChange: (() => void) | undefined;
	let sequence = 0;
	const jobs = new Map<string, ScheduledMessage>();

	const notifyChanged = (): void => {
		try {
			onChange?.();
		} catch {
			// UI refresh hooks must never break schedule state transitions.
		}
	};

	const nextId = (): string => {
		let id = "";
		do {
			sequence += 1;
			id = `${clock.now().toString(36)}-${sequence.toString(36)}`;
		} while (jobs.has(id));
		return id;
	};

	const appendEntry = (data: ScheduleEntryData): void => {
		try {
			pi.appendEntry?.(SCHEDULE_ENTRY_TYPE, data);
		} catch {
			// Scheduling still works in-memory if session persistence is unavailable.
		}
	};

	const clearJobTimer = (job: ScheduledMessage): void => {
		if (!job.timer) return;
		clock.clearTimeout(job.timer);
		job.timer = undefined;
	};

	const armJob = (job: ScheduledMessage, ctx: ExtensionContext): void => {
		clearJobTimer(job);
		const remaining = Math.max(0, job.dueAt - clock.now());
		job.timer = clock.setTimeout(() => {
			if (!jobs.has(job.id)) return;
			if (clock.now() < job.dueAt) {
				armJob(job, ctx);
				return;
			}
			void deliver(job, ctx);
		}, Math.min(remaining, MAX_TIMER_DELAY_MS));
		job.timer.unref?.();
	};

	const deliver = async (job: ScheduledMessage, ctx: ExtensionContext): Promise<void> => {
		if (!jobs.has(job.id)) return;
		jobs.delete(job.id);
		clearJobTimer(job);
		notifyChanged();
		try {
			let idle = true;
			try {
				idle = ctx.isIdle?.() ?? true;
			} catch {
				idle = false;
			}
			await Promise.resolve(idle ? pi.sendUserMessage(job.message) : pi.sendUserMessage(job.message, { deliverAs: "followUp" }));
			appendEntry({ action: "delivered", deliveredAt: clock.now(), id: job.id });
			if (ctx.hasUI) ctx.ui.notify(`Scheduled message sent (${job.id}).`, "info");
		} catch (error) {
			appendEntry({ action: "failed", failedAt: clock.now(), id: job.id, message: stringifyError(error) });
			if (ctx.hasUI) ctx.ui.notify(`Scheduled message failed (${job.id}): ${stringifyError(error)}`, "error");
		}
	};

	const listText = (): string => {
		const now = clock.now();
		const pending = [...jobs.values()].sort((a, b) => a.dueAt - b.dueAt);
		if (pending.length === 0) return "No scheduled messages.";
		return [
			"Scheduled messages:",
			...pending.map((job) => `${job.id} — in ${formatScheduleDuration(job.dueAt - now)} (${formatDueTime(job.dueAt)}) — ${previewMessage(job.message)}`),
		].join("\n");
	};

	const schedule = (delayMs: number, message: string, ctx: ExtensionCommandContext): void => {
		if (jobs.size >= MAX_ACTIVE_SCHEDULES) {
			ctx.ui.notify(`Too many scheduled messages (${MAX_ACTIVE_SCHEDULES}). Cancel one before adding another.`, "warning");
			return;
		}
		const createdAt = clock.now();
		const job: ScheduledMessage = { createdAt, dueAt: createdAt + delayMs, id: nextId(), message };
		jobs.set(job.id, job);
		appendEntry({ action: "scheduled", createdAt: job.createdAt, dueAt: job.dueAt, id: job.id, message: job.message });
		armJob(job, ctx);
		notifyChanged();
		ctx.ui.notify(`Scheduled ${job.id} in ${formatScheduleDuration(delayMs)} (${formatDueTime(job.dueAt)}): ${previewMessage(message)}`, "info");
	};

	const cancel = (id: string): boolean => {
		const job = jobs.get(id);
		if (!job) return false;
		clearJobTimer(job);
		jobs.delete(id);
		appendEntry({ action: "cancelled", cancelledAt: clock.now(), id });
		notifyChanged();
		return true;
	};

	return {
		activeCount(): number {
			return jobs.size;
		},
		clearTimers(): void {
			for (const job of jobs.values()) clearJobTimer(job);
			const changed = jobs.size > 0;
			jobs.clear();
			if (changed) notifyChanged();
		},
		async handleCommand(args: string, ctx: ExtensionCommandContext): Promise<void> {
			const parsed = parseScheduleCommandArgs(args);
			if (parsed.kind === "usage") {
				ctx.ui.notify(`${parsed.error ?? "Invalid schedule command"}\n${usageText()}`, "warning");
				return;
			}
			if (parsed.kind === "list") {
				ctx.ui.notify(`${listText()}\n\n${usageText()}`, "info");
				return;
			}
			if (parsed.kind === "cancel") {
				if (parsed.all) {
					const count = jobs.size;
					for (const job of [...jobs.values()]) cancel(job.id);
					ctx.ui.notify(`Cancelled ${count} scheduled message(s).`, "info");
					return;
				}
				if (!parsed.id || !cancel(parsed.id)) {
					ctx.ui.notify(`No scheduled message found for ${parsed.id ?? "<missing id>"}.`, "warning");
					return;
				}
				ctx.ui.notify(`Cancelled scheduled message ${parsed.id}.`, "info");
				return;
			}
			schedule(parsed.delayMs, parsed.message, ctx);
		},
		restoreFromBranch(ctx: ExtensionContext): void {
			for (const job of jobs.values()) clearJobTimer(job);
			jobs.clear();
			const branch = ctx.sessionManager.getBranch?.() ?? [];
			for (const entry of branch as any[]) {
				if (entry?.type !== "custom" || entry.customType !== SCHEDULE_ENTRY_TYPE) continue;
				const data = entry.data as ScheduleEntryData | undefined;
				if (!data || typeof data !== "object") continue;
				if (data.action === "scheduled") {
					const job = dataToJob(data);
					if (job) jobs.set(job.id, job);
					continue;
				}
				if (typeof data.id === "string") jobs.delete(data.id);
			}
			for (const job of jobs.values()) armJob(job, ctx);
			notifyChanged();
		},
		renderPreviewLines(width: number): string[] {
			const pending = [...jobs.values()].sort((a, b) => a.dueAt - b.dueAt);
			const shown = pending.slice(0, 3).map((job) => {
				const line = `┃ Scheduled ${formatDueTime(job.dueAt)} — ${previewMessage(job.message, 120)}`;
				return truncateToWidth(ansiGreen(line), width, "");
			});
			if (pending.length > shown.length) shown.push(truncateToWidth(ansiGreen(`┃ Scheduled: +${pending.length - shown.length} more`), width, ""));
			return shown;
		},
		setOnChange(callback: (() => void) | undefined): void {
			onChange = callback;
		},
	};
}
