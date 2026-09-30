import { describe, expect, test } from "bun:test";
import { writeFileSync } from "node:fs";
import { join } from "node:path";

import { clearTrackedToolExecutionComponents, refreshToolExecutionComponents, trackToolExecutionComponent } from "../tool-renderer/live-settings.js";
import { clearPackageConfigCache } from "../tool-renderer/package-config.js";
import { CONFIG_ID } from "../tool-renderer/settings.js";
import { STACK_MAX_ITEMS, STACK_RESULT_MAX_CHARS, registerStackEvents, renderStackedToolResult, stackBatches, stackItems } from "../tool-renderer/stack.js";
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

const theme = { fg: (_tone: string, text: string) => text, bold: (text: string) => text };

function readResult(text = "line\n") {
	return { content: [{ type: "text", text }] };
}

/** Start and finish `count` calls of `toolName` in one live run; `end: false`
 *  leaves the run open, as a turn still making calls. */
function runCalls(pi: ReturnType<typeof fakePi>, cwd: string, count: number, options: { prefix?: string; text?: string; toolName?: string; end?: boolean } = {}): string[] {
	const { prefix = "call", text = "line\n", toolName = "read", end = true } = options;
	const ids = Array.from({ length: count }, (_, i) => `${prefix}-${i}`);
	pi.emit("agent_start", {}, { cwd });
	for (const id of ids) {
		pi.emit("tool_execution_start", { toolName, toolCallId: id, args: { path: id, command: id } }, { cwd });
		pi.emit("tool_execution_end", { toolName, toolCallId: id, result: readResult(text), isError: false }, { cwd });
	}
	if (end) pi.emit("agent_end", {}, { cwd });
	return ids;
}

function runReads(pi: ReturnType<typeof fakePi>, cwd: string, count: number, text = "line\n"): void {
	runCalls(pi, cwd, count, { text });
}

function batchShape(): string[] {
	return [...stackBatches.values()].map((batch) => `${batch.anchorId}:${batch.items.length}`);
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

	for (const row of [
		{ toolName: "read", kept: "head" },
		{ toolName: "bash", kept: "tail" },
	]) {
		test(`caps the kept ${row.toolName} result text at its ${row.kept} and counts lines from the whole result`, () => {
			const { cwd } = world();
			stackSetting(cwd, true);
			const pi = fakePi();
			registerStackEvents(pi as any);
			pi.emit("session_start", {}, { cwd });
			const text = `HEAD\n${"0123456789\n".repeat(10_000)}TAIL`;
			runCalls(pi, cwd, 1, { text, toolName: row.toolName });
			const item = stackItems.get("call-0")!;
			expect({
				length: item.resultText.length,
				lines: item.resultLines,
				truncated: item.truncated,
				head: item.resultText.startsWith("HEAD"),
				tail: item.resultText.endsWith("TAIL"),
			}).toEqual({ length: STACK_RESULT_MAX_CHARS, lines: 10_002, truncated: true, head: row.kept === "head", tail: row.kept === "tail" });
		});
	}

	test("a render pass over evicted history leaves surviving batches and the live batch as they were", () => {
		const { cwd } = world();
		stackSetting(cwd, true);
		const pi = fakePi();
		registerStackEvents(pi as any);
		pi.emit("session_start", {}, { cwd });
		const history = [1, 2, 3, 4, 5].flatMap((run) => runCalls(pi, cwd, 60, { prefix: `r${run}` }));
		const live = runCalls(pi, cwd, 3, { prefix: "live", end: false });
		const before = batchShape();
		// Pi renders every tool display again, top to bottom, on ctrl+o or a resize.
		for (const id of [...history, ...live]) {
			renderStackedToolResult("read", readResult(), false, false, theme, { toolCallId: id, args: { path: id }, invalidate: () => {} }, cwd);
		}
		pi.emit("tool_execution_start", { toolName: "read", toolCallId: "live-3", args: { path: "live-3" } }, { cwd });
		expect({ shape: batchShape(), liveJoined: stackItems.get("live-3")?.batchId === stackItems.get("live-0")?.batchId })
			.toEqual({ shape: before.map((entry) => entry.startsWith("live-0:") ? "live-0:4" : entry), liveJoined: true });
		expect(before.at(-1)).toBe("live-0:3");
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
