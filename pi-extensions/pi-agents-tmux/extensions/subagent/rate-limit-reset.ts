/**
 * Eager on the extension startup path: index.ts imports rate-limit-watchdog.ts
 * statically, so every module in that transitive static closure loads at
 * startup and none of them may take a node:* import. Pi 0.80.3's binary TS
 * loader resolves transpiled TS through data: URLs and a large module with
 * node:* imports trips Bun/JITI NameTooLong there. The provider fetch that
 * needs node:fs is rate-limit-quota.ts, dynamically imported. Not enforced.
 */

export const RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS = 10 * 60_000;

export function isRecord(value: unknown): value is Record<string, unknown> {
	return Boolean(value && typeof value === "object" && !Array.isArray(value));
}

export function extractRetryAfterMs(event: unknown): number | null {
	const seen = new Set<unknown>();
	const stack: unknown[] = [event];
	while (stack.length > 0) {
		const node = stack.pop();
		if (!node || typeof node !== "object" || seen.has(node)) continue;
		seen.add(node);
		const record = node as Record<string, unknown>;
		for (const key of ["retry_after_ms", "retryAfterMs", "retryAfter", "retry_after"]) {
			const value = record[key];
			if (typeof value === "number" && Number.isFinite(value) && value > 0) {
				// `retry_after` / `retryAfter` are conventionally seconds on
				// HTTP 429 responses; everything ending in `_ms` / `Ms` is
				// milliseconds. Normalise to ms.
				if (key === "retry_after_ms" || key === "retryAfterMs") return Math.floor(value);
				return Math.floor(value * 1000);
			}
			if (typeof value === "string" && value.trim()) {
				const parsed = Number(value);
				if (!Number.isFinite(parsed) || parsed <= 0) continue;
				if (key === "retry_after_ms" || key === "retryAfterMs") return Math.floor(parsed);
				return Math.floor(parsed * 1000);
			}
		}
		for (const child of Object.values(record)) {
			if (child && typeof child === "object") stack.push(child);
		}
	}
	return null;
}

export function extractResetAtMs(event: unknown, now: number = Date.now()): number | null {
	const structured = extractStructuredResetAtMs(event);
	if (structured !== null) return structured;

	const message = readAssistantMessage(event);
	if (!message) return null;
	return extractResetAtMsFromText(extractAssistantErrorText(message), now);
}


export const RESET_AT_MS_KEYS = new Set(["resetAtMs", "reset_at_ms", "resetsAtMs", "resets_at_ms"]);
export const RESET_AT_KEYS = new Set(["resetAt", "reset_at", "resetsAt", "resets_at"]);

export function extractStructuredResetAtMs(event: unknown): number | null {
	const seen = new Set<unknown>();
	const stack: unknown[] = [event];
	while (stack.length > 0) {
		const node = stack.pop();
		if (!isRecord(node) || seen.has(node)) continue;
		seen.add(node);
		for (const [key, value] of Object.entries(node)) {
			if (RESET_AT_MS_KEYS.has(key)) {
				const parsed = coerceResetTimestampMs(value, true);
				if (parsed !== null) return parsed;
			} else if (RESET_AT_KEYS.has(key)) {
				const parsed = coerceResetTimestampMs(value, false);
				if (parsed !== null) return parsed;
			}
			if (value && typeof value === "object") stack.push(value);
		}
	}
	return null;
}

export function coerceResetTimestampMs(value: unknown, knownMilliseconds: boolean): number | null {
	if (typeof value === "number" && Number.isFinite(value) && value > 0) {
		const milliseconds = knownMilliseconds || value >= 1_000_000_000_000 ? value : value * 1000;
		return Math.floor(milliseconds);
	}
	if (typeof value !== "string") return null;
	const trimmed = value.trim();
	if (!trimmed) return null;
	if (/^[0-9]+(?:\.[0-9]+)?$/.test(trimmed)) {
		const parsed = Number(trimmed);
		if (!Number.isFinite(parsed) || parsed <= 0) return null;
		const milliseconds = knownMilliseconds || parsed >= 1_000_000_000_000 ? parsed : parsed * 1000;
		return Math.floor(milliseconds);
	}
	const parsedDate = Date.parse(trimmed);
	return Number.isFinite(parsedDate) ? parsedDate : null;
}

function extractResetAtMsFromText(text: string, now: number): number | null {
	const resetMatch = text.match(/\bresets?\s+(?:at\s+)?([^\n]+)/i);
	if (!resetMatch) return null;
	const tail = (resetMatch[1] ?? "").trim();
	if (!tail) return null;

	const absolute = parseAbsoluteResetTail(tail);
	if (absolute !== null) return absolute;

	const clockMatch = tail.match(/^(?<clock>\d{1,2}(?::\d{2}){0,2}\s*(?:am|pm)?)(?:\s*\((?<timeZone>[^)]+)\))?/i);
	const clock = parseClockTime(clockMatch?.groups?.clock ?? "");
	if (!clock) return null;
	const timeZone = clockMatch?.groups?.timeZone?.trim();
	if (timeZone) return nextClockOccurrenceInTimeZone(clock, timeZone, now);
	return nextClockOccurrenceInLocalTime(clock, now);
}

function parseAbsoluteResetTail(tail: string): number | null {
	const withoutIanaZone = tail
		.replace(/[.;]\s*$/, "")
		.replace(/\s*\([A-Za-z_][A-Za-z0-9_+\-/.]+\)\s*$/, "")
		.trim();
	if (!/(\d{4}|\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\b|[+-]\d{2}:?\d{2}\b|\b(?:UTC|GMT|[A-Z]{2,4})\b)/i.test(withoutIanaZone)) {
		return null;
	}
	const parsed = Date.parse(withoutIanaZone);
	return Number.isFinite(parsed) ? parsed : null;
}

function parseClockTime(raw: string): { hour: number; minute: number; second: number } | null {
	const match = raw.trim().match(/^(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*(am|pm)?$/i);
	if (!match) return null;
	let hour = Number(match[1]);
	const minute = match[2] === undefined ? 0 : Number(match[2]);
	const second = match[3] === undefined ? 0 : Number(match[3]);
	const meridiem = match[4]?.toLowerCase();
	if (!Number.isInteger(hour) || !Number.isInteger(minute) || !Number.isInteger(second)) return null;
	if (minute < 0 || minute > 59 || second < 0 || second > 59) return null;
	if (meridiem) {
		if (hour < 1 || hour > 12) return null;
		if (hour === 12) hour = 0;
		if (meridiem === "pm") hour += 12;
	} else if (hour < 0 || hour > 23) {
		return null;
	}
	return { hour, minute, second };
}

function nextClockOccurrenceInLocalTime(
	clock: { hour: number; minute: number; second: number },
	now: number,
): number {
	const candidate = new Date(now);
	candidate.setHours(clock.hour, clock.minute, clock.second, 0);
	if (candidate.getTime() > now) {
		const previous = new Date(candidate);
		previous.setDate(previous.getDate() - 1);
		if (now - previous.getTime() <= RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS) return previous.getTime();
		return candidate.getTime();
	}
	if (candidate.getTime() <= now) {
		const elapsedMs = now - candidate.getTime();
		if (elapsedMs <= RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS) return candidate.getTime();
		candidate.setDate(candidate.getDate() + 1);
	}
	return candidate.getTime();
}

function nextClockOccurrenceInTimeZone(
	clock: { hour: number; minute: number; second: number },
	timeZone: string,
	now: number,
): number | null {
	const nowParts = zonedDateParts(now, timeZone);
	if (!nowParts) return null;
	const previousDate = new Date(Date.UTC(nowParts.year, nowParts.month - 1, nowParts.day - 1));
	const previousCandidate = zonedLocalTimeToUtcMs(
		previousDate.getUTCFullYear(),
		previousDate.getUTCMonth() + 1,
		previousDate.getUTCDate(),
		clock.hour,
		clock.minute,
		clock.second,
		timeZone,
	);
	if (previousCandidate !== null && previousCandidate <= now && now - previousCandidate <= RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS) {
		return previousCandidate;
	}
	for (let dayOffset = 0; dayOffset < 3; dayOffset += 1) {
		const date = new Date(Date.UTC(nowParts.year, nowParts.month - 1, nowParts.day + dayOffset));
		const candidate = zonedLocalTimeToUtcMs(
			date.getUTCFullYear(),
			date.getUTCMonth() + 1,
			date.getUTCDate(),
			clock.hour,
			clock.minute,
			clock.second,
			timeZone,
		);
		if (candidate === null) continue;
		if (candidate > now) return candidate;
		if (now - candidate <= RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS) return candidate;
	}
	return null;
}

function zonedDateParts(utcMs: number, timeZone: string): { year: number; month: number; day: number } | null {
	const parts = formatZonedParts(utcMs, timeZone);
	if (!parts) return null;
	return { day: parts.day, month: parts.month, year: parts.year };
}

function zonedLocalTimeToUtcMs(
	year: number,
	month: number,
	day: number,
	hour: number,
	minute: number,
	second: number,
	timeZone: string,
): number | null {
	const localAsUtc = Date.UTC(year, month - 1, day, hour, minute, second);
	const firstOffset = timeZoneOffsetMs(timeZone, localAsUtc);
	if (firstOffset === null) return null;
	let candidate = localAsUtc - firstOffset;
	const secondOffset = timeZoneOffsetMs(timeZone, candidate);
	if (secondOffset === null) return null;
	if (secondOffset !== firstOffset) candidate = localAsUtc - secondOffset;
	return candidate;
}

function timeZoneOffsetMs(timeZone: string, utcMs: number): number | null {
	const parts = formatZonedParts(utcMs, timeZone);
	if (!parts) return null;
	const zonedAsUtc = Date.UTC(parts.year, parts.month - 1, parts.day, parts.hour, parts.minute, parts.second);
	return zonedAsUtc - utcMs;
}

function formatZonedParts(
	utcMs: number,
	timeZone: string,
): { year: number; month: number; day: number; hour: number; minute: number; second: number } | null {
	try {
		const formatter = new Intl.DateTimeFormat("en-US", {
			day: "2-digit",
			hour: "2-digit",
			hourCycle: "h23",
			minute: "2-digit",
			month: "2-digit",
			second: "2-digit",
			timeZone,
			year: "numeric",
		});
		const values = Object.fromEntries(
			formatter
				.formatToParts(new Date(utcMs))
				.filter((part) => part.type !== "literal")
				.map((part) => [part.type, Number(part.value)]),
		) as Record<string, number>;
		const { day, hour, minute, month, second, year } = values;
		if (![day, hour, minute, month, second, year].every((value) => Number.isFinite(value))) return null;
		return { day, hour, minute, month, second, year };
	} catch {
		return null;
	}
}

export function readAssistantMessage(event: unknown): Record<string, unknown> | null {
	if (!isRecord(event)) return null;
	const directMessage = event.message;
	if (isRecord(directMessage) && directMessage.role === "assistant") return directMessage;
	const data = event.data;
	if (isRecord(data)) {
		const dataMessage = data.message;
		if (isRecord(dataMessage) && dataMessage.role === "assistant") return dataMessage;
	}
	return null;
}

export function extractAssistantErrorText(message: Record<string, unknown>): string {
	const parts: string[] = [];
	for (const key of ["errorMessage", "error_message"]) {
		const value = message[key];
		if (typeof value === "string" && value) parts.push(value);
	}
	const content = message.content;
	if (Array.isArray(content)) {
		for (const item of content) {
			if (!isRecord(item)) continue;
			const text = item.text;
			if (typeof text === "string" && text) parts.push(text);
		}
	}
	return parts.join("\n");
}

export function readAssistantStopReason(message: Record<string, unknown>): string | null {
	const value = message.stopReason;
	return typeof value === "string" ? value : null;
}

