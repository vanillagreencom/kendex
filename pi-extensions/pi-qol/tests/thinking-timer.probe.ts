// Plain Bun child: the package test preload must not replace Pi's component.
import { AssistantMessageComponent, initTheme } from "@earendil-works/pi-coding-agent";
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type * as Timer from "../extensions/qol/thinking-timer.ts";
import { THINKING_TIMER_PATCH_SYMBOL, THINKING_TIMER_STORE_SYMBOL } from "../extensions/qol/constants.ts";
import { runtimeCopy } from "./search-fixture.ts";

const control = process.argv[2] === "direct-only";
const patches = control ? [{ file: "qol/thinking-timer.ts", from: "const label = child.child ?? child;", to: "const label = child;" }] : [];
const proto = AssistantMessageComponent.prototype;
const original = proto.updateContent;
const globals = globalThis as unknown as Record<PropertyKey, unknown>;
const previousStore = globals[THINKING_TIMER_STORE_SYMBOL];
const originalNow = Date.now;

try {
	initTheme("dark", false);
	await runtimeCopy<typeof Timer>("qol/thinking-timer.ts", patches, async (timer, root) => {
		timer.installThinkingTimerPatch();
		Date.now = () => 3000;
		const message: AssistantMessage = {
			role: "assistant", api: "anthropic-messages", provider: "anthropic", model: "component-fixture",
			content: [{ type: "thinking", thinking: "component fixture" }], timestamp: 100,
			stopReason: "stop", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
		};
		for (const row of [
			{ name: "streaming", start: 1500, duration: undefined, expected: "1.5s" },
			{ name: "finished", start: undefined, duration: 62000, expected: "1:02.0" },
		]) {
			const store: Timer.ThinkingTimerStore = { cwd: root, enabled: true, starts: new Map(), durations: new Map(), labels: new Map() };
			const key = timer.thinkingTimerKey(message.timestamp, 0);
			if (row.start !== undefined) store.starts.set(key, row.start);
			if (row.duration !== undefined) store.durations.set(key, row.duration);
			globals[THINKING_TIMER_STORE_SYMBOL] = store;
			const component = new AssistantMessageComponent(message, true);
			const label = store.labels.get(key);
			if (!label || !component.render(80).some((line) => line.includes(` ${row.expected}`))) {
				throw new Error(`thinking-timer: elapsed-missing case=${row.name}`);
			}
			// The ticker keeps this reference; updating it must reach the native renderer.
			label.setText("timer-reference-fixture");
			if (!component.render(80).some((line) => line.includes("timer-reference-fixture"))) {
				throw new Error(`thinking-timer: label-detached case=${row.name}`);
			}
		}
	});
	console.log("thinking-timer: proved");
} catch (error) {
	console.error(error instanceof Error ? error.message : String(error));
	process.exitCode = 1;
} finally {
	proto.updateContent = original;
	delete (proto as unknown as Record<PropertyKey, unknown>)[THINKING_TIMER_PATCH_SYMBOL];
	if (previousStore === undefined) delete globals[THINKING_TIMER_STORE_SYMBOL];
	else globals[THINKING_TIMER_STORE_SYMBOL] = previousStore;
	Date.now = originalNow;
}
