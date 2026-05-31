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

test("parseDurationMs supports default minutes and explicit units", () => {
	expect(parseDurationMs("20")).toBe(20 * 60 * 1000);
	expect(parseDurationMs("20m")).toBe(20 * 60 * 1000);
	expect(parseDurationMs("90s")).toBe(90 * 1000);
	expect(parseDurationMs("500ms")).toBe(500);
	expect(parseDurationMs("1.5h")).toBe(90 * 60 * 1000);
	expect(parseDurationMs("0m")).toBeUndefined();
	expect(parseDurationMs("forever")).toBeUndefined();
});

test("parseDurationMs supports compact composite durations", () => {
	expect(parseDurationMs("1h45m")).toBe(105 * 60 * 1000);
	expect(parseDurationMs("1h30s")).toBe(3_630_000);
	expect(parseDurationMs("45m10s")).toBe(2_710_000);
	expect(parseDurationMs("1h45m30s")).toBe((105 * 60 + 30) * 1000);
	expect(parseDurationMs("2d3h4m5s6ms")).toBe(2 * 24 * 60 * 60 * 1000 + 3 * 60 * 60 * 1000 + 4 * 60 * 1000 + 5 * 1000 + 6);

	expect(parseDurationMs("1h2h")).toBeUndefined();
	expect(parseDurationMs("30s1h")).toBeUndefined();
	expect(parseDurationMs("1h30")).toBeUndefined();
	expect(parseDurationMs("1h30xs")).toBeUndefined();
	expect(parseDurationMs("31d")).toBeUndefined();
});

test("parseScheduleCommandArgs extracts delay and message", () => {
	expect(parseScheduleCommandArgs("20m this is my message")).toEqual({
		delayMs: 20 * 60 * 1000,
		kind: "schedule",
		message: "this is my message",
	});
	expect(parseScheduleCommandArgs("1h45m do thing later")).toEqual({
		delayMs: 105 * 60 * 1000,
		kind: "schedule",
		message: "do thing later",
	});
	expect(parseScheduleCommandArgs("1h30s do thing later")).toEqual({
		delayMs: 3_630_000,
		kind: "schedule",
		message: "do thing later",
	});
	expect(parseScheduleCommandArgs("45m10s do thing later")).toEqual({
		delayMs: 2_710_000,
		kind: "schedule",
		message: "do thing later",
	});
	expect(parseScheduleCommandArgs("list")).toEqual({ kind: "list" });
	expect(parseScheduleCommandArgs("cancel all")).toEqual({ all: true, kind: "cancel" });
	expect(parseScheduleCommandArgs("cancel abc")).toEqual({ all: false, id: "abc", kind: "cancel" });
});

test("handleCommand schedules a user message without sending immediately", async () => {
	const { clock, controller, ctx, entries, notifications, sent } = makeHarness();

	await controller.handleCommand("20m this is my message", ctx);

	expect(sent).toHaveLength(0);
	expect(controller.renderPreviewLines(200).join("\n")).toContain("this is my message");
	expect(clock.timers[0]?.delayMs).toBe(20 * 60 * 1000);
	expect(entries[0]?.customType).toBe(SCHEDULE_ENTRY_TYPE);
	expect(entries[0]?.data).toMatchObject({ action: "scheduled", message: "this is my message" });
	expect(notifications[0]?.message).toContain("Scheduled");

	clock.runNext();
	await Promise.resolve();

	expect(sent).toEqual([{ content: "this is my message", options: undefined }]);
	expect(entries[1]?.data).toMatchObject({ action: "delivered" });
	expect(controller.renderPreviewLines(200)).toEqual([]);
});

test("renderPreviewLines uses queued-message style and caps visible rows", async () => {
	const { controller, ctx } = makeHarness();
	await controller.handleCommand("1m first", ctx);
	await controller.handleCommand("2m second", ctx);
	await controller.handleCommand("3m third", ctx);
	await controller.handleCommand("4m fourth", ctx);

	const lines = controller.renderPreviewLines(200);
	expect(lines).toHaveLength(4);
	expect(lines[0]).toContain("┃ Scheduled");
	expect(lines[0]).toContain("first");
	expect(lines[0]).not.toContain("-1");
	expect(lines[3]).toContain("+1 more");
});

test("handleCommand queues as a follow-up when the timer fires while the agent is busy", async () => {
	const { clock, controller, ctx, sent } = makeHarness();
	ctx.isIdle = () => false;

	await controller.handleCommand("1m queued while busy", ctx);
	clock.runNext();
	await Promise.resolve();

	expect(sent).toEqual([{ content: "queued while busy", options: { deliverAs: "followUp" } }]);
});

test("cancel all clears pending timers", async () => {
	const { clock, controller, ctx, sent } = makeHarness();
	await controller.handleCommand("1m first", ctx);
	await controller.handleCommand("2m second", ctx);
	expect(controller.activeCount()).toBe(2);

	await controller.handleCommand("cancel all", ctx);
	expect(controller.activeCount()).toBe(0);

	clock.runNext();
	clock.runNext();
	await Promise.resolve();
	expect(sent).toHaveLength(0);
});

test("restoreFromBranch rearms unfinished scheduled messages", async () => {
	const clock = new FakeClock();
	const { controller, ctx, sent } = makeHarness(clock);
	ctx.sessionManager.getBranch = () => [
		{
			customType: SCHEDULE_ENTRY_TYPE,
			data: {
				action: "scheduled",
				createdAt: clock.now(),
				dueAt: clock.now() + 5000,
				id: "restore-1",
				message: "restored message",
			},
			type: "custom",
		},
	];

	controller.restoreFromBranch(ctx);
	expect(controller.activeCount()).toBe(1);
	expect(clock.timers[0]?.delayMs).toBe(5000);

	clock.runNext();
	await Promise.resolve();
	expect(sent[0]).toEqual({ content: "restored message", options: undefined });
});
