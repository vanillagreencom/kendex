import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
	createRateLimitAutoResumeController,
	extractResetAtFromHeaders,
	extractResetAtFromText,
	looksLikeRateLimitText,
	parseDurationLikeMs,
	type RateLimitClock,
} from "../extensions/qol/rate-limit-auto-resume.ts";

interface FakeTimer {
	callback: () => void;
	cleared: boolean;
	delayMs: number;
	unref: () => void;
}

class FakeClock implements RateLimitClock {
	nowMs = Date.UTC(2026, 4, 23, 12, 0, 0);
	timers: FakeTimer[] = [];

	now(): number { return this.nowMs; }

	setTimeout(callback: () => void, delayMs: number): FakeTimer {
		const timer = { callback, cleared: false, delayMs, unref() {} };
		this.timers.push(timer);
		return timer;
	}

	clearTimeout(timer: FakeTimer): void { timer.cleared = true; }

	runNext(): void {
		const timer = this.timers.shift();
		if (!timer || timer.cleared) return;
		this.nowMs += timer.delayMs;
		timer.callback();
	}
}

let workdir = "";
const originalAgentDir = process.env.PI_CODING_AGENT_DIR;
const originalHome = process.env.HOME;

function writeQolConfig(values: Record<string, unknown>): void {
	writeFileSync(
		join(workdir, "settings.json"),
		`${JSON.stringify({ kendex: { extensionManager: { config: { "@vanillagreen/pi-qol": values } } } }, null, 2)}\n`,
		"utf8",
	);
}

function makeHarness(clock = new FakeClock()) {
	const sent: Array<{ content: string; options: unknown }> = [];
	const notifications: Array<{ message: string; level: string }> = [];
	const pi: any = {
		sendUserMessage(content: string, options: unknown) { sent.push({ content, options }); },
	};
	const ctx: any = {
		cwd: workdir,
		hasPendingMessages: () => false,
		hasUI: true,
		isIdle: () => true,
		sessionManager: { getBranch: () => [] },
		ui: { notify: (message: string, level: string) => notifications.push({ message, level }) },
	};
	return { clock, controller: createRateLimitAutoResumeController(pi, clock), ctx, notifications, sent };
}

beforeEach(() => {
	workdir = mkdtempSync(join(tmpdir(), "pi-qol-rate-limit-"));
	mkdirSync(join(workdir, ".pi"), { recursive: true });
	process.env.PI_CODING_AGENT_DIR = workdir;
	process.env.HOME = workdir;
});

afterEach(() => {
	try {
		if (workdir) rmSync(workdir, { force: true, recursive: true });
	} finally {
		if (originalAgentDir === undefined) delete process.env.PI_CODING_AGENT_DIR;
		else process.env.PI_CODING_AGENT_DIR = originalAgentDir;
		if (originalHome === undefined) delete process.env.HOME;
		else process.env.HOME = originalHome;
	}
});

const now = Date.UTC(2026, 4, 23, 12, 0, 0);

for (const [input, expected] of [["6m0s", 6 * 60 * 1000]] as const) {
	test(`parseDurationLikeMs: ${input}`, () => {
		expect(parseDurationLikeMs(input)).toBe(expected);
	});
}

for (const [headers, expected] of [
	[{ "retry-after": "60" }, { resetAt: now + 60_000, source: "retry-after" }],
	[{ "retry-after-ms": "1500" }, { resetAt: now + 1500, source: "retry-after-ms" }],
	[{ "x-ratelimit-reset-requests": "6m0s" }, { resetAt: now + 360_000, source: "x-ratelimit-reset-requests" }],
	[{ "anthropic-ratelimit-requests-reset": "2026-05-23T12:05:00Z" }, { resetAt: now + 300_000, source: "anthropic-ratelimit-requests-reset" }],
] as const) {
	test(`extractResetAtFromHeaders: ${expected.source}`, () => {
		expect(extractResetAtFromHeaders(headers, now)).toEqual(expected);
	});
}

for (const [input, expected] of [
	["Error: 429 Too Many Requests", true],
	["normal tool failure", false],
] as const) {
	test(`looksLikeRateLimitText: ${input}`, () => {
		expect(looksLikeRateLimitText(input)).toBe(expected);
	});
}

for (const [input, expected] of [
	["Rate limited. Try again in 2 minutes", { resetAt: now + 120_000, source: "text-duration" }],
] as const) {
	test(`extractResetAtFromText: ${input}`, () => {
		expect(extractResetAtFromText(input, now)).toEqual(expected);
	});
}

type Harness = ReturnType<typeof makeHarness>;

const lifecycleRows: Array<{
	name: string;
	enabled: boolean;
	actions: Array<(h: Harness) => unknown | Promise<unknown>>;
	expected: unknown[];
}> = [
	...[
		{
			name: "external rate-limit event",
			hint: ({ controller, ctx, clock }: Harness) => controller.noteExternalRateLimitEvent({ resetAtMs: clock.now() + 60_000, source: "test", status: "rejected" }, ctx),
			messages: [{ errorMessage: "429 rate limit", role: "assistant" }],
		},
		{
			name: "external reset retained through message_end without a reset",
			hint: ({ controller, ctx, clock }: Harness) => {
				controller.noteExternalRateLimitEvent({ resetAtMs: clock.now() + 60_000, source: "test", status: "rejected" }, ctx);
				controller.noteMessageEnd({ message: { errorMessage: "You're out of extra usage", role: "assistant", stopReason: "error" } }, ctx);
			},
			messages: [{ errorMessage: "429 rate limit", role: "assistant" }],
		},
		{
			name: "provider response headers",
			hint: ({ controller, ctx }: Harness) => controller.noteProviderResponse({ headers: { "retry-after": "60" }, status: 429 }, ctx),
			messages: [{ errorMessage: "429 rate limit", role: "assistant" }],
		},
		{
			name: "message_end text",
			hint: ({ controller, ctx }: Harness) => controller.noteMessageEnd({ message: { errorMessage: "You're out of extra usage. Try again in 60 seconds", role: "assistant", stopReason: "error" } }, ctx),
			messages: [{ errorMessage: "request failed", role: "assistant", stopReason: "error" }],
		},
		{
			name: "agent_end text",
			hint: undefined,
			messages: [{ errorMessage: "429 rate limit. Try again in 60 seconds", role: "assistant", stopReason: "error" }],
		},
	].map(({ name, hint, messages }) => ({
		name: `${name} schedules the configured message after reset plus buffer`,
		enabled: true,
		actions: [
			(h: Harness) => {
				hint?.(h);
				const scheduled = h.controller.noteAgentEnd({ messages }, h.ctx);
				return {
					scheduled,
					delay: h.clock.timers[0]?.delayMs,
					preview: h.controller.renderPreviewLines(200),
					notifications: h.notifications.map(({ level }) => level),
					sent: [...h.sent],
				};
			},
			async ({ clock, sent }: Harness) => {
				clock.runNext();
				await Promise.resolve();
				return sent;
			},
		],
		expected: [
			{ scheduled: true, delay: 70_000, preview: [expect.stringContaining("[rate-limit]")], notifications: ["warning"], sent: [] },
			[{ content: "resume now", options: undefined }],
		],
	})),
	{
		name: "disabled setting creates no timer",
		enabled: false,
		actions: [({ clock, controller, ctx, sent }) => {
			controller.noteExternalRateLimitEvent({ resetAtMs: clock.now() + 60_000, status: "rejected" }, ctx);
			const scheduled = controller.noteAgentEnd({ messages: [{ errorMessage: "429 rate limit", role: "assistant" }] }, ctx);
			return { scheduled, sent, timers: clock.timers };
		}],
		expected: [{ scheduled: false, sent: [], timers: [] }],
	},
	{
		name: "successful assistant turn ignores a transient provider 429",
		enabled: true,
		actions: [({ clock, controller, ctx }) => {
			controller.noteProviderResponse({ headers: { "retry-after": "60" }, status: 429 }, ctx);
			const scheduled = controller.noteAgentEnd({ messages: [{ content: [{ text: "done", type: "text" }], role: "assistant", stopReason: "stop" }] }, ctx);
			return { scheduled, timers: clock.timers };
		}],
		expected: [{ scheduled: false, timers: [] }],
	},
	...[
		{ name: "setting disabled before delivery", cancel: (_h: Harness) => writeQolConfig({ "rateLimitAutoResume.enabled": false }), cleared: false },
		{ name: "new turn before delivery", cancel: ({ controller, ctx }: Harness) => controller.noteAgentStart(ctx), cleared: true },
	].map(({ name, cancel, cleared }) => ({
		name,
		enabled: true,
		actions: [
			({ controller, clock, ctx }: Harness) => {
				controller.noteExternalRateLimitEvent({ resetAtMs: clock.now() + 60_000, status: "rejected" }, ctx);
				return controller.noteAgentEnd({ messages: [{ errorMessage: "429 rate limit", role: "assistant" }] }, ctx);
			},
			async (h: Harness) => {
				cancel(h);
				const timerCleared = h.clock.timers[0]?.cleared;
				h.clock.runNext();
				await Promise.resolve();
				return { timerCleared, sent: h.sent, preview: h.controller.renderPreviewLines(200) };
			},
		],
		expected: [true, { timerCleared: cleared, sent: [], preview: [] }],
	})),
];

for (const row of lifecycleRows) {
	test(`rate-limit lifecycle: ${row.name}`, async () => {
		writeQolConfig({
			"rateLimitAutoResume.bufferSeconds": 10,
			"rateLimitAutoResume.enabled": row.enabled,
			"rateLimitAutoResume.message": "resume now",
		});
		const harness = makeHarness();
		try {
			harness.controller.noteAgentStart(harness.ctx);
			const observed: unknown[] = [];
			for (const action of row.actions) observed.push(await action(harness));
			expect(observed).toStrictEqual(row.expected);
		} finally {
			harness.controller.clearTimers();
		}
	});
}
