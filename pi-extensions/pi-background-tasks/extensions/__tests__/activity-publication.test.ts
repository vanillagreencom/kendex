import { expect, test } from "bun:test";
import { fakeTask } from "../../tests/fixtures/lifecycle.js";
import { publishBackgroundTaskActivity, publishBackgroundTaskStarted, type PiActivityEvent } from "../activity.js";

const brokerSymbol = Symbol.for("kendex.pi.activity");

test("activity publication retains the ordered task trace", () => {
	const globals = globalThis as unknown as Record<PropertyKey, unknown>;
	const previous = Object.getOwnPropertyDescriptor(globalThis, brokerSymbol);
	const events: PiActivityEvent[] = [];
	const running = fakeTask({ id: "bg-7", command: "printf ready", output: "ready\n", outputBytes: 6, updatedAt: 1_700_000_001_000 });
	try {
		globals[brokerSymbol] = { publish(event: PiActivityEvent) { events.push(event); } };
		publishBackgroundTaskStarted(running);
		publishBackgroundTaskActivity("output", running, { matchedPattern: "ready", newOutputTail: "ready\n", sequence: 2 });
		publishBackgroundTaskActivity("exit", { ...running, status: "completed", exitCode: 0, updatedAt: 1_700_000_002_000 }, { sequence: 3 });
		expect(events.map((event) => ({
			type: event.type, importance: event.importance, severity: event.severity,
			source: event.source, task: event.refs?.bg_task_id,
			pattern: event.details?.matched_pattern, tail: event.details?.new_output_tail,
			sequence: event.details?.sequence,
		}))).toStrictEqual([
			{ type: "bg_task.started", importance: "noisy", severity: "info", source: "pi-bg-task", task: "bg-7", pattern: undefined, tail: undefined, sequence: 0 },
			{ type: "bg_task.output_matched", importance: "noisy", severity: "info", source: "pi-bg-task", task: "bg-7", pattern: "ready", tail: "ready\n", sequence: 2 },
			{ type: "bg_task.completed", importance: "normal", severity: "success", source: "pi-bg-task", task: "bg-7", pattern: undefined, tail: undefined, sequence: 3 },
		]);
	} finally {
		if (previous) Object.defineProperty(globalThis, brokerSymbol, previous);
		else delete globals[brokerSymbol];
	}
});
