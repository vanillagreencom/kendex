// vstack#108: detect Claude / pi-coding-agent rate-limit errors and
// schedule a retry with exponential backoff instead of falling through
// to the agent-end-watchdog's needs_completion synthetic outbox.
//
// Canonical event shape (confirmed from a real rate-limited session
// transcript under
// ~/.pi/agent/vstack/sessions/<id>/pi-agents-tmux/sessions/<agent>.jsonl):
//
//   { "type": "message", "message": {
//        "role": "assistant",
//        "stopReason": "error",
//        "api": "claude-bridge" | ...,
//        "errorMessage": "...API Error: Server is temporarily limiting requests..."
//   }}
//
// The watchdog also accepts shallow message_end-style envelopes (`event.message`
// or `event.data.message`) whose assistant `.errorMessage` or
// `.content[].text` matches the canonical prose AND whose stopReason is
// exactly "error". Non-assistant messages and assistant turns with a missing
// or non-error stopReason are not rate-limit events.
//
// Explicit `retry_after_ms` / `retryAfterMs` fields (Anthropic API occasionally
// provides one) win over the env-ladder backoff once the assistant error
// envelope has been classified as rate-limited. Claude Code session / usage
// caps may instead expose an absolute reset instant (`rate_limit_info.resetsAt`)
// or prose like "You've hit your session limit · resets 7:50pm
// (America/Los_Angeles)"; those schedule at the reset instant plus a small
// safety margin instead of cycling through the backoff ladder too early.
//
// Pure decision; the layered consumers (pi-agents-tmux subagent watchdog
// and the bash subscriber wake-event branch) do the actual setTimeout +
// pi-bridge steer side effects.

export const RATE_LIMIT_STEER_MESSAGE =
	"API rate limit was detected. Try to continue from where you left off." as const;

export const RATE_LIMIT_DEFAULT_MAX_ATTEMPTS = 5;
export const RATE_LIMIT_DEFAULT_BACKOFF_LADDER_SEC = [60, 120, 300, 600, 1800] as const;
export const RATE_LIMIT_RESET_MARGIN_MS = 5_000;
export const RATE_LIMIT_CLOCK_RESET_PAST_TOLERANCE_MS = 10 * 60_000;

export const RATE_LIMIT_ERROR_REGEX =
	/(temporarily limiting requests|rate[\s_-]?limit(?:ed)?|429|too many requests|(?:you(?:['’]?ve|\s+have)\s+hit\s+your\s+(?:session|usage)\s+limit)|\b(?:session|usage)\s+limit\b|[·•]\s*resets\b|\bresets?\s+(?:at\s+)?\d{1,2}(?::\d{2}){0,2}\s*(?:am|pm)?)/i;

export interface RateLimitWatchdogInput {
	event: unknown;
	paneId: string;
	attempt: number;
	lastRetryAt: number | null;
	now: number;
}

export type RateLimitSkipReason = "non-assistant" | "no-stopreason" | "stopreason-mismatch" | "no-prose";

export type RateLimitEventClassification =
	| { isRateLimitEvent: true }
	| { isRateLimitEvent: false; reason: RateLimitSkipReason };

export type RateLimitWatchdogDecision =
	| { kind: "not-rate-limited"; reason: RateLimitSkipReason }
	| {
		kind: "retry-at";
		at: number;
		attempt: number;
		hash: string;
		steerMessage: typeof RATE_LIMIT_STEER_MESSAGE;
	}
	| { kind: "exhausted"; attempt: number; reason: string };

export interface RateLimitWatchdogEnv {
	maxAttempts?: number;
	backoffLadderSec?: readonly number[];
	enabled?: boolean;
}

export function rateLimitWatchdogEnabledFromEnv(env: NodeJS.ProcessEnv = process.env): boolean {
	const raw = env.VSTACK_RATE_LIMIT_WATCHDOG?.trim();
	if (raw === undefined || raw === "") return true;
	return raw !== "0" && raw.toLowerCase() !== "false" && raw.toLowerCase() !== "off";
}

export function rateLimitMaxAttemptsFromEnv(env: NodeJS.ProcessEnv = process.env): number {
	const raw = env.VSTACK_RATE_LIMIT_MAX_ATTEMPTS?.trim();
	const parsed = raw ? Number(raw) : Number.NaN;
	if (!Number.isFinite(parsed) || parsed < 1) return RATE_LIMIT_DEFAULT_MAX_ATTEMPTS;
	return Math.floor(parsed);
}

export function rateLimitBackoffLadderFromEnv(env: NodeJS.ProcessEnv = process.env): number[] {
	const raw = env.VSTACK_RATE_LIMIT_BACKOFF_LADDER?.trim();
	if (!raw) return [...RATE_LIMIT_DEFAULT_BACKOFF_LADDER_SEC];
	const parts = raw
		.split(",")
		.map((part) => part.trim())
		.filter(Boolean)
		.map((part) => Number(part))
		.filter((value) => Number.isFinite(value) && value > 0)
		.map((value) => Math.floor(value));
	return parts.length > 0 ? parts : [...RATE_LIMIT_DEFAULT_BACKOFF_LADDER_SEC];
}

export function classifyRateLimitEvent(event: unknown): RateLimitEventClassification {
	const message = readAssistantMessage(event);
	if (!message) return { isRateLimitEvent: false, reason: "non-assistant" };
	const stopReason = readAssistantStopReason(message);
	if (!stopReason) return { isRateLimitEvent: false, reason: "no-stopreason" };
	if (stopReason !== "error") return { isRateLimitEvent: false, reason: "stopreason-mismatch" };
	const text = extractAssistantErrorText(message);
	if (!text || !RATE_LIMIT_ERROR_REGEX.test(text)) return { isRateLimitEvent: false, reason: "no-prose" };
	return { isRateLimitEvent: true };
}

export function isRateLimitEvent(event: unknown): boolean {
	return classifyRateLimitEvent(event).isRateLimitEvent;
}

export function isAssistantMessageEvent(event: unknown): boolean {
	return readAssistantMessage(event) !== null;
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
			if (typeof value === "string" && /^[0-9]+(?:\.[0-9]+)?$/.test(value)) {
				const parsed = Number(value);
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

export function decideRateLimitRetry(
	input: RateLimitWatchdogInput,
	envOverride: RateLimitWatchdogEnv = {},
): RateLimitWatchdogDecision {
	const classification = classifyRateLimitEvent(input.event);
	if (!classification.isRateLimitEvent) return { kind: "not-rate-limited", reason: classification.reason };

	const maxAttempts = envOverride.maxAttempts ?? rateLimitMaxAttemptsFromEnv();
	if (input.attempt >= maxAttempts) {
		return {
			attempt: input.attempt,
			kind: "exhausted",
			reason: `rate-limit retries exhausted after ${input.attempt} attempt${input.attempt === 1 ? "" : "s"}`,
		};
	}

	const ladder = envOverride.backoffLadderSec ?? rateLimitBackoffLadderFromEnv();
	const ladderIndex = Math.min(input.attempt, ladder.length - 1);
	const ladderMs = Math.max(0, Math.floor(ladder[ladderIndex]! * 1000));
	const explicitMs = extractRetryAfterMs(input.event);
	const resetAtMs = extractResetAtMs(input.event, input.now);
	// Anthropic-provided retry_after wins over the ladder when it requests
	// a longer wait (we don't want to retry before the API window resets);
	// otherwise the ladder governs. Session / usage caps expose absolute reset
	// instants rather than retry_after durations; never retry before that reset.
	const resetDelayMs = resetAtMs !== null ? Math.max(0, resetAtMs + RATE_LIMIT_RESET_MARGIN_MS - input.now) : null;
	const delayMs = Math.max(ladderMs, explicitMs ?? 0, resetDelayMs ?? 0);
	const at = input.now + delayMs;
	const nextAttempt = input.attempt + 1;
	const hash = `${input.paneId}:${nextAttempt}:${at}`;
	return { at, attempt: nextAttempt, hash, kind: "retry-at", steerMessage: RATE_LIMIT_STEER_MESSAGE };
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return value !== null && typeof value === "object";
}

const RESET_AT_MS_KEYS = new Set(["resetAtMs", "reset_at_ms", "resetsAtMs", "resets_at_ms"]);
const RESET_AT_KEYS = new Set(["resetAt", "reset_at", "resetsAt", "resets_at"]);

function extractStructuredResetAtMs(event: unknown): number | null {
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

function coerceResetTimestampMs(value: unknown, knownMilliseconds: boolean): number | null {
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

function readAssistantMessage(event: unknown): Record<string, unknown> | null {
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

function extractAssistantErrorText(message: Record<string, unknown>): string {
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

function readAssistantStopReason(message: Record<string, unknown>): string | null {
	const value = message.stopReason;
	return typeof value === "string" ? value : null;
}

// CLI entry: `printf '%s' "$event_json" | bun rate-limit-watchdog.ts decide --pane <id> --attempt <n> [--now <ms>]`
// Used by the bash pi subscriber (Layer B) so it can route rate-limit
// events through the same decision module without re-implementing the
// ladder math. Outputs the decision as JSON on stdout, exits 0.
// `--event` remains accepted for manual debugging; production callers
// should omit it so event JSON is read from stdin instead of process argv.
if (import.meta.main) {
	const args = process.argv.slice(2);
	const action = args.shift();
	if (action !== "decide") {
		process.stderr.write("Usage: rate-limit-watchdog.ts decide --pane <id> --attempt <n> [--now <ms>] < event.json\n");
		process.exit(2);
	}
	let eventJson = "";
	let paneId = "";
	let attempt = 0;
	let now = Date.now();
	for (let i = 0; i < args.length; i += 1) {
		const flag = args[i];
		switch (flag) {
			case "--event": eventJson = args[++i] ?? ""; break;
			case "--pane": paneId = args[++i] ?? ""; break;
			case "--attempt": attempt = Number(args[++i] ?? "0") || 0; break;
			case "--now": now = Number(args[++i] ?? `${Date.now()}`) || Date.now(); break;
			default:
				process.stderr.write(`Unknown flag: ${flag}\n`);
				process.exit(2);
		}
	}
	if (!eventJson) {
		eventJson = await Bun.stdin.text();
	}
	let event: unknown;
	try {
		event = JSON.parse(eventJson);
	} catch (error) {
		process.stderr.write(`invalid --event JSON: ${(error as Error).message}\n`);
		process.exit(2);
	}
	const decision = decideRateLimitRetry({ attempt, event, lastRetryAt: null, now, paneId });
	process.stdout.write(`${JSON.stringify(decision)}\n`);
	process.exit(0);
}
