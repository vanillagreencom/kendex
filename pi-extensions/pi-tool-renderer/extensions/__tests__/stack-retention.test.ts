import { describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

import { clearTrackedToolExecutionComponents, refreshToolExecutionComponents, trackToolExecutionComponent } from "../tool-renderer/live-settings.js";
import { CONFIG_ID, clearPackageConfigCache } from "../tool-renderer/settings.js";
import { STACK_MAX_ITEMS, STACK_RESULT_MAX_CHARS, registerStackEvents, stackBatches, stackItems } from "../tool-renderer/stack.js";
import { useWorld } from "./helpers/world.js";

const world = useWorld();

type Handler = (event: any, ctx: any) => void;

/** The subset of Pi's extension API the stack registers on. */
function fakePi() {
	const handlers = new Map<string, Handler[]>();
	return {
		on(name: string, handler: Handler) {
			handlers.set(name, [...(handlers.get(name) ?? []), handler]);
		},
		emit(name: string, event: any, ctx: any) {
			for (const handler of handlers.get(name) ?? []) handler(event, ctx);
		},
	};
}

function stackSetting(cwd: string, enabled: boolean): void {
	writeFileSync(join(cwd, ".pi", "settings.json"), JSON.stringify({ kendex: { extensionManager: { config: { [CONFIG_ID]: { stackToolCalls: enabled } } } } }));
	clearPackageConfigCache();
}

function runReads(pi: ReturnType<typeof fakePi>, cwd: string, count: number, text = "line\n"): void {
	pi.emit("agent_start", {}, { cwd });
	for (let i = 0; i < count; i++) {
		pi.emit("tool_execution_start", { toolName: "read", toolCallId: `call-${i}`, args: { path: `f${i}` } }, { cwd });
		pi.emit("tool_execution_end", { toolName: "read", toolCallId: `call-${i}`, result: { content: [{ type: "text", text }] }, isError: false }, { cwd });
	}
	pi.emit("agent_end", {}, { cwd });
}

describe("stack retention", () => {
	test("keeps no stack items while stackToolCalls is off", () => {
		const { cwd } = world();
		stackSetting(cwd, false);
		const pi = fakePi();
		registerStackEvents(pi as any);
		pi.emit("session_start", {}, { cwd });
		runReads(pi, cwd, 1000);
		expect([stackItems.size, stackBatches.size]).toEqual([0, 0]);
	});

	test("bounds 1,000 stacked calls by item count and releases them on session_shutdown", () => {
		const { cwd } = world();
		stackSetting(cwd, true);
		const pi = fakePi();
		registerStackEvents(pi as any);
		pi.emit("session_start", {}, { cwd });
		runReads(pi, cwd, 1000);
		expect(stackItems.size).toBeGreaterThan(0);
		expect(stackItems.size).toBeLessThanOrEqual(STACK_MAX_ITEMS);
		expect(stackItems.has("call-999")).toBe(true);
		expect(stackItems.has("call-0")).toBe(false);
		pi.emit("session_shutdown", {}, { cwd });
		expect([stackItems.size, stackBatches.size]).toEqual([0, 0]);
	});

	test("caps the kept result text and counts lines from the whole result", () => {
		const { cwd } = world();
		stackSetting(cwd, true);
		const pi = fakePi();
		registerStackEvents(pi as any);
		pi.emit("session_start", {}, { cwd });
		const text = "0123456789\n".repeat(10_000);
		runReads(pi, cwd, 1, text);
		const item = stackItems.get("call-0")!;
		expect(item.resultText.length).toBe(STACK_RESULT_MAX_CHARS);
		expect(item.resultLines).toBe(10_000);
		expect(item.truncated).toBe(true);
	});
});

describe("tool-execution component tracking", () => {
	test("holds a tracked component weakly, so one Pi dropped is collected", async () => {
		clearTrackedToolExecutionComponents();
		let collected = false;
		const registry = new FinalizationRegistry(() => {
			collected = true;
		});
		(() => {
			const component = { invalidate: () => {} };
			trackToolExecutionComponent(component);
			registry.register(component, "component");
		})();
		for (let attempt = 0; attempt < 50 && !collected; attempt++) {
			Bun.gc(true);
			// FinalizationRegistry callbacks run on a later task, never inside gc().
			await new Promise((resolve) => setTimeout(resolve, 0));
		}
		expect(collected).toBe(true);
	});

	test("still refreshes a component Pi holds", () => {
		clearTrackedToolExecutionComponents();
		let invalidations = 0;
		const component = { invalidate: () => invalidations++ };
		trackToolExecutionComponent(component);
		trackToolExecutionComponent(component);
		refreshToolExecutionComponents();
		expect(invalidations).toBe(1);
	});
});
