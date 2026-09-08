import { expect, mock, test } from "bun:test";
import "./preload.ts";

import type { ScheduleClock } from "../extensions/qol/schedule.ts";

const {
	createScheduleController,
	parseDurationMs,
	parseScheduleCommandArgs,
	SCHEDULE_ENTRY_TYPE,
} = await import("../extensions/qol/schedule.ts");

interface FakeTimer {
	callback: () => void;
	cleared: boolean;
	delayMs: number;
	unref: () => void;
}

class FakeClock implements ScheduleClock {
	nowMs = 1_700_000_000_000;
	timers: FakeTimer[] = [];

	now(): number {
		return this.nowMs;
	}

	setTimeout(callback: () => void, delayMs: number): FakeTimer {
		const timer = { callback, cleared: false, delayMs, unref() {} };
		this.timers.push(timer);
		return timer;
	}

	clearTimeout(timer: FakeTimer): void {
		timer.cleared = true;
	}

	runNext(): void {
		const timer = this.timers.shift();
		if (!timer || timer.cleared) return;
		this.nowMs += timer.delayMs;
		timer.callback();
	}
}

function makeHarness(clock = new FakeClock()) {
	const sent: Array<{ content: string; options: unknown }> = [];
	const entries: Array<{ customType: string; data: unknown }> = [];
	const notifications: Array<{ message: string; level: string }> = [];
	const pi: any = {
		appendEntry(customType: string, data: unknown) {
			entries.push({ customType, data });
		},
		sendUserMessage(content: string, options: unknown) {
			sent.push({ content, options });
		},
	};
	const ctx: any = {
		cwd: "/repo",
		hasUI: true,
		isIdle: () => true,
		sessionManager: { getBranch: () => [] },
		ui: { notify: mock((message: string, level: string) => notifications.push({ message, level })) },
	};
	return { clock, controller: createScheduleController(pi, clock), ctx, entries, notifications, sent };
}

for (const [input, expected] of [
	["20", 20 * 60 * 1000],
	["20m", 20 * 60 * 1000],
	["90s", 90 * 1000],
	["500ms", 500],
	["1.5h", 90 * 60 * 1000],
	["1h45m", 105 * 60 * 1000],
	["1h30s", 3_630_000],
	["45m10s", 2_710_000],
	["1h45m30s", (105 * 60 + 30) * 1000],
	["2d3h4m5s6ms", 2 * 24 * 60 * 60 * 1000 + 3 * 60 * 60 * 1000 + 4 * 60 * 1000 + 5 * 1000 + 6],
	["0m", undefined],
	["forever", undefined],
	["1h2h", undefined],
	["30s1h", undefined],
	["1h30", undefined],
	["1h30xs", undefined],
	["31d", undefined],
] as const) {
	test(`parseDurationMs: ${input}`, () => {
		expect(parseDurationMs(input)).toBe(expected);
	});
}

for (const [input, expected] of [
	["20m this is my message", { delayMs: 20 * 60 * 1000, kind: "schedule", message: "this is my message" }],
	["1h45m do thing later", { delayMs: 105 * 60 * 1000, kind: "schedule", message: "do thing later" }],
	["1h30s do thing later", { delayMs: 3_630_000, kind: "schedule", message: "do thing later" }],
	["45m10s do thing later", { delayMs: 2_710_000, kind: "schedule", message: "do thing later" }],
	["list", { kind: "list" }],
	["cancel all", { all: true, kind: "cancel" }],
	["cancel abc", { all: false, id: "abc", kind: "cancel" }],
] as const) {
	test(`parseScheduleCommandArgs: ${input}`, () => {
		expect(parseScheduleCommandArgs(input)).toEqual(expected);
	});
}

type Harness = ReturnType<typeof makeHarness>;

// Each action records state before the next action can change it.
const lifecycleRows: Array<{
	name: string;
	actions: Array<(h: Harness) => unknown | Promise<unknown>>;
	expected: unknown[];
}> = [
	{
		name: "idle delivery waits for the timer and records session events",
		actions: [
			async ({ controller, ctx, clock, entries, notifications, sent }) => {
				await controller.handleCommand("20m this is my message", ctx);
				return {
					sent: [...sent],
					preview: controller.renderPreviewLines(200),
					delay: clock.timers[0]?.delayMs,
					entry: entries[0],
					notifications: notifications.map(({ level }) => level),
				};
			},
			async ({ controller, clock, entries, sent }) => {
				clock.runNext();
				await Promise.resolve();
				return { sent, entry: entries[1], preview: controller.renderPreviewLines(200) };
			},
		],
		expected: [
			{
				sent: [],
				preview: [expect.stringContaining("this is my message")],
				delay: 20 * 60 * 1000,
				entry: { customType: SCHEDULE_ENTRY_TYPE, data: expect.objectContaining({ action: "scheduled", message: "this is my message" }) },
				notifications: ["info"],
			},
			{
				sent: [{ content: "this is my message", options: undefined }],
				entry: { customType: SCHEDULE_ENTRY_TYPE, data: expect.objectContaining({ action: "delivered" }) },
				preview: [],
			},
		],
	},
	{
		name: "preview keeps queued style, hides ids and caps visible messages",
		actions: [async ({ controller, ctx }) => {
			await controller.handleCommand("1m first", ctx);
			await controller.handleCommand("2m second", ctx);
			await controller.handleCommand("3m third", ctx);
			await controller.handleCommand("4m fourth", ctx);
			const lines = controller.renderPreviewLines(200);
			return {
				lines,
				queuedStyle: lines[0]?.includes("┃"),
				showsId: lines[0]?.includes("-1"),
				showsHiddenMessage: lines.join("\n").includes("fourth"),
			};
		}],
		expected: [{
			lines: [expect.stringContaining("first"), expect.stringContaining("second"), expect.stringContaining("third"), expect.stringContaining("+1")],
			queuedStyle: true,
			showsId: false,
			showsHiddenMessage: false,
		}],
	},
	{
		name: "busy delivery uses followUp",
		actions: [async ({ clock, controller, ctx, sent }) => {
			ctx.isIdle = () => false;
			await controller.handleCommand("1m queued while busy", ctx);
			clock.runNext();
			await Promise.resolve();
			return sent;
		}],
		expected: [[{ content: "queued while busy", options: { deliverAs: "followUp" } }]],
	},
	{
		name: "cancel all clears timers and pending state",
		actions: [
			async ({ controller, ctx }) => {
				await controller.handleCommand("1m first", ctx);
				await controller.handleCommand("2m second", ctx);
				return controller.activeCount();
			},
			async ({ controller, ctx, clock }) => {
				await controller.handleCommand("cancel all", ctx);
				return { active: controller.activeCount(), cleared: clock.timers.map(({ cleared }) => cleared) };
			},
			async ({ clock, sent }) => {
				clock.runNext();
				clock.runNext();
				await Promise.resolve();
				return sent;
			},
		],
		expected: [2, { active: 0, cleared: [true, true] }, []],
	},
	{
		name: "branch restore rearms and delivers the pending message",
		actions: [
			({ controller, ctx, clock }) => {
				ctx.sessionManager.getBranch = () => [{
					customType: SCHEDULE_ENTRY_TYPE,
					data: { action: "scheduled", createdAt: clock.now(), dueAt: clock.now() + 5000, id: "restore-1", message: "restored message" },
					type: "custom",
				}];
				controller.restoreFromBranch(ctx);
				return { active: controller.activeCount(), delay: clock.timers[0]?.delayMs };
			},
			async ({ clock, sent }) => {
				clock.runNext();
				await Promise.resolve();
				return sent;
			},
		],
		expected: [{ active: 1, delay: 5000 }, [{ content: "restored message", options: undefined }]],
	},
];

for (const row of lifecycleRows) {
	test(`schedule lifecycle: ${row.name}`, async () => {
		const harness = makeHarness();
		try {
			const observed: unknown[] = [];
			for (const action of row.actions) observed.push(await action(harness));
			expect(observed).toStrictEqual(row.expected);
		} finally {
			harness.controller.clearTimers();
		}
	});
}
