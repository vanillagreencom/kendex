import { mock } from "bun:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import type { BackgroundTaskSnapshot } from "../../extensions/types.js";
import type { TUI } from "@earendil-works/pi-tui";
import type { MiniDashboardComponent, MiniDashboardFactory } from "../../extensions/stacked-widget.js";

// Only external peer exports and the Pi host boundary are mocked. Settings,
// restore, syncWidget, expiry and the shared stack run their production code.
mock.module("@earendil-works/pi-coding-agent", () => ({ getShellConfig: () => { throw new Error("unexpected spawn"); } }));
mock.module("@earendil-works/pi-ai", () => ({ StringEnum: (values: readonly string[]) => ({ enum: values }) }));
mock.module("@earendil-works/pi-tui", () => ({
	truncateToWidth: (text: string, width: number) => text.slice(0, width),
	visibleWidth: (text: string) => text.length,
	wrapTextWithAnsi: (text: string) => [text],
	matchesKey: () => false,
}));
mock.module("typebox", () => {
	const schema = (value?: unknown) => ({ schema: value });
	return { Type: { Object: schema, Optional: schema, String: schema, Number: schema, Boolean: schema } };
});

const { default: backgroundTasks } = await import("../../extensions/background-tasks.js");
const { setMiniDashboardWidget } = await import("../../extensions/stacked-widget.js");
const { BG_WIDGET_KEY, CONFIG_ID } = await import("../../extensions/constants.js");
const scenario = process.argv[2];
const seconds = Number(process.argv[3]);
const placement = scenario === "expiry-below" ? "belowEditor" : "aboveEditor";
writeFileSync(join(process.cwd(), "settings.json"), JSON.stringify({
	kendex: { extensionManager: { config: { [CONFIG_ID]: { widgetFinishedRetentionSeconds: seconds, widgetPlacement: placement } } } },
}));

const start = 1_700_000_000_000;
let now = start;
Date.now = () => now;
type Timer = { callback: () => void; delay: number; unref(): void };
const timers = new Set<Timer>();
globalThis.setTimeout = ((callback: () => void, delay: number) => {
	assert.ok(delay >= 1 && delay <= 2_147_483_647, `native-unsafe expiry delay: ${delay}`);
	const timer = { callback, delay, unref() {} };
	timers.add(timer);
	return timer;
}) as unknown as typeof setTimeout;
globalThis.clearTimeout = ((timer: Timer) => { timers.delete(timer); }) as unknown as typeof clearTimeout;
const nextTimer = () => {
	assert.equal(timers.size, 1, "exactly one pending expiry");
	return [...timers][0];
};
const fire = () => {
	const timer = nextTimer();
	timers.delete(timer);
	now += timer.delay;
	timer.callback();
};

const widgets = new Map<string, MiniDashboardComponent>();
const removals: string[] = [];
const theme = { fg: (_color: string, text: string) => text, bold: (text: string) => text } as unknown as Theme;
const tui = { terminal: { rows: 40 }, requestRender() {} } as unknown as TUI;
const stackKey = `kendex-mini-dashboard-stack-${placement === "aboveEditor" ? "above" : "below"}`;
const registry = () => (globalThis as unknown as Record<symbol, { entries: Map<string, unknown> }>)[Symbol.for("kendex.pi.mini-dashboard-stack")];
let session = 0;
function createSession(completed: boolean) {
	const id = `widget-${++session}`;
	const handlers = new Map<string, (event: unknown, ctx: ExtensionContext) => unknown>();
	const shortcuts = new Map<string, { handler: (ctx: ExtensionContext) => unknown }>();
	const pi = {
		on: (event: string, handler: (event: unknown, ctx: ExtensionContext) => unknown) => handlers.set(event, handler),
		registerShortcut: (key: string, definition: { handler: (ctx: ExtensionContext) => unknown }) => shortcuts.set(key, definition),
		registerTool() {}, registerCommand() {}, registerMessageRenderer() {}, appendEntry() {},
		sendMessage() { throw new Error("unexpected wake"); },
	} as unknown as ExtensionAPI;
	const ctx = {
		cwd: process.cwd(), hasUI: true, isIdle: () => true, isProjectTrusted: () => false,
		sessionManager: {
			getSessionId: () => id,
			getSessionFile: () => join(process.cwd(), `${id}.jsonl`),
			getBranch: () => completed ? [{ type: "message", message: { role: "toolResult", toolName: "bg_task", details: { tasks: [{
				id: "bg-1", title: "true", command: "true", cwd: process.cwd(), pid: 0, status: "completed", exitCode: 0,
				startedAt: start, updatedAt: start, lastOutputAt: null, expiresAt: null, outputBytes: 0,
				logFile: join(process.cwd(), "task.log"), notifyOnExit: false, notifyOnOutput: false, exitNotified: true,
			} satisfies BackgroundTaskSnapshot] } } }] : [],
		},
		ui: {
			notify(message: string) { throw new Error(message); },
			setWidget(key: string, factory: MiniDashboardFactory | undefined) {
				widgets.get(key)?.dispose?.();
				widgets.delete(key);
				if (factory) widgets.set(key, factory(tui, theme));
				else removals.push(key);
			},
		},
	} as unknown as ExtensionContext;
	backgroundTasks(pi);
	return {
		emit(event: string) {
			const handler = handlers.get(event);
			assert.ok(handler, `missing ${event} handler`);
			return handler({}, ctx);
		},
		hide() {
			const shortcut = shortcuts.get("alt+h");
			assert.ok(shortcut, "missing widget shortcut");
			return shortcut.handler(ctx);
		},
		ctx,
	};
}

let active = createSession(true);
try {
	await active.emit("session_start");
	assert.ok(registry().entries.has(BG_WIDGET_KEY));
	assert.match(widgets.get(stackKey)!.render(120).join("\n"), /bg-1/);
	const first = nextTimer();
	assert.equal(first.delay, Math.min(Math.floor(seconds * 1_000) + 1, 2_147_483_647));
	await active.emit("session_compact");
	assert.ok(!timers.has(first), "resync cancels previous expiry");
	nextTimer();
	if (scenario === "sibling") {
		setMiniDashboardWidget(active.ctx, "sibling", 20, () => ({ render: () => ["sibling"], invalidate() {} }));
	}
	if (["hide", "shutdown", "switch"].includes(scenario)) {
		if (scenario === "hide") await active.hide();
		else await active.emit("session_shutdown");
		assert.equal(timers.size, 0, "cleanup cancels expiry");
		assert.ok(!registry().entries.has(BG_WIDGET_KEY));
		assert.ok(removals.includes(stackKey), "host widget unregistered");
		if (scenario === "switch") {
			// Pi replaces the extension instance between shutdown and session_start.
			active = createSession(false);
			await active.emit("session_start");
		}
		now += 60_000;
		assert.equal(timers.size, 0);
		assert.ok(!registry().entries.has(BG_WIDGET_KEY));
	} else if (scenario === "overflow") {
		fire();
		assert.ok(registry().entries.has(BG_WIDGET_KEY));
		assert.equal(nextTimer().delay, 2_147_483_647);
	} else {
		const retention = Math.floor(seconds * 1_000);
		if (retention + 1 > 2_147_483_647) {
			fire();
			assert.ok(registry().entries.has(BG_WIDGET_KEY), "bounded recheck must preserve retention");
			assert.equal(nextTimer().delay, start + retention - now + 1, "recompute remaining delay");
		}
		// Inclusive boundary: rendering at the deadline still includes the task.
		now = start + retention;
		assert.match(widgets.get(stackKey)!.render(120).join("\n"), /bg-1/);
		const last = nextTimer();
		timers.delete(last);
		now++;
		last.callback();
		assert.ok(!registry().entries.has(BG_WIDGET_KEY), "expiry removes registry entry without a task event");
		assert.equal(timers.size, 0);
		if (scenario === "sibling") {
			assert.ok(registry().entries.has("sibling"));
			assert.deepEqual(widgets.get(stackKey)!.render(120), ["sibling"]);
			assert.ok(!removals.includes(stackKey), "sibling keeps host stack registered");
			setMiniDashboardWidget(active.ctx, "sibling", 20, undefined);
		} else {
			assert.ok(removals.includes(stackKey), "expiry calls host unregister");
			assert.ok(!widgets.has(stackKey));
		}
	}
} finally {
	await active.emit("session_shutdown");
}
