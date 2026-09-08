import { expect, test } from "bun:test";
import { taskSnapshot } from "../extensions/snapshot.js";
import type { ManagedTask } from "../extensions/types.js";
import { fakeTask } from "./fixtures/lifecycle.js";

test("taskSnapshot serializes notification, session and termination fields", () => {
	const rows: {
		name: string;
		input: Partial<ManagedTask>;
		expected: { exitNotified: boolean; sessionId: string; terminationReason: ManagedTask["terminationReason"] };
	}[] = [
		{
			name: "completed task retains exit notification",
			input: { status: "completed", exitCode: 0, exitNotified: true, outputBytes: 89 },
			expected: { exitNotified: true, sessionId: "sess-1", terminationReason: undefined },
		},
		{
			name: "undefined exit notification becomes false",
			input: { exitNotified: undefined, outputBytes: 89 },
			expected: { exitNotified: false, sessionId: "sess-1", terminationReason: undefined },
		},
		{
			name: "session identity survives serialization",
			input: { sessionId: "sess-1", outputBytes: 89 },
			expected: { exitNotified: false, sessionId: "sess-1", terminationReason: undefined },
		},
		{
			name: "extension stop reason survives serialization",
			input: { exitCode: 0, status: "stopped", terminationReason: "extension-stop", sessionId: "sess-A", outputBytes: 12 },
			expected: { exitNotified: false, sessionId: "sess-A", terminationReason: "extension-stop" },
		},
		{
			name: "undefined termination reason stays undefined",
			input: { terminationReason: undefined, sessionId: "sess-A", outputBytes: 12 },
			expected: { exitNotified: false, sessionId: "sess-A", terminationReason: undefined },
		},
	];
	expect.assertions(rows.length + 1);
	expect(rows.length, "snapshot serialization rows must not be empty").toBeGreaterThan(0);
	for (const row of rows) {
		const snapshot = taskSnapshot(fakeTask(row.input));
		expect({
			exitNotified: snapshot.exitNotified,
			sessionId: snapshot.sessionId,
			terminationReason: snapshot.terminationReason,
		}, row.name).toStrictEqual(row.expected);
	}
});
