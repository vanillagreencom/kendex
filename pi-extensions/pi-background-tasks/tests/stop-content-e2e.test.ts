import { expect, test } from "bun:test";
import { WAKE_MANIFEST_FIELD_MAX_CHARS as cap } from "../extensions/wake-events.js";
import { runSpawnFixture, SPAWN_FIXTURE_TIMEOUT_MS } from "./fixtures/spawn-child-runner.js";

interface StopObservation {
	outcome: { kind: string };
	stopResult?: { content: { type: string; text: string }[]; details: { action: string; task: { id: string; command: string } } };
	notifications: [string, string][];
	after: { state: { id: string; status: string } };
	remainingTimers: unknown[];
	unexpected: unknown[];
}

const rows = [
	{ name: "tool pending stop retains bounded command and compact details", caller: "tool", signalGone: false, bomb: "X", status: "running" },
	{ name: "tool gone process returns bounded finalized stop content", caller: "tool", signalGone: true, bomb: "X", status: "stopped" },
	{ name: "slash pending stop notifies with the bounded command", caller: "slash", signalGone: false, bomb: "Y", status: "running" },
	{ name: "slash gone process notifies with bounded finalized content", caller: "slash", signalGone: true, bomb: "Y", status: "stopped" },
];

// The native boundary supplies child outcomes; the registered stop implementations remain real.
test("registered stop content rows", () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "stop content table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const prefix = "sleep 10 # ";
		const command = prefix + row.bomb.repeat(100_000);
		const expectedCommand = prefix + row.bomb.repeat(cap - prefix.length - 1) + "…";
		const observed = runSpawnFixture("spawn-extension.ts", { mode: "stop", command, caller: row.caller, signalGone: row.signalGone }) as StopObservation;
		const result = observed.stopResult;
		expect({
			kind: observed.outcome.kind,
			content: result?.content.map((part) => ({ type: part.type, bounded: part.text.length < cap + 128, commandRetained: part.text.includes(expectedCommand), taskRetained: part.text.includes("bg-1"), excludesBomb: !part.text.includes(row.bomb.repeat(cap + 1)) })),
			details: result ? { action: result.details.action, id: result.details.task.id, command: result.details.task.command, bounded: result.details.task.command.length <= cap, excludesBomb: !result.details.task.command.includes(row.bomb.repeat(cap + 1)) } : undefined,
			notifications: observed.notifications.map(([text, kind]) => ({ kind, bounded: text.length < cap + 128, commandRetained: text.includes(expectedCommand), taskRetained: text.includes("bg-1"), excludesBomb: !text.includes(row.bomb.repeat(cap + 1)) })),
			state: { id: observed.after.state.id, status: observed.after.state.status },
			remainingTimers: observed.remainingTimers, unexpected: observed.unexpected,
		}, row.name).toStrictEqual({
			kind: row.caller,
			content: row.caller === "tool" ? [{ type: "text", bounded: true, commandRetained: true, taskRetained: true, excludesBomb: true }] : undefined,
			details: row.caller === "tool" ? { action: "stop", id: "bg-1", command: expectedCommand, bounded: true, excludesBomb: true } : undefined,
			notifications: row.caller === "slash" ? [{ kind: "info", bounded: true, commandRetained: true, taskRetained: true, excludesBomb: true }] : [],
			state: { id: "bg-1", status: row.status }, remainingTimers: [], unexpected: [],
		});
	}
}, SPAWN_FIXTURE_TIMEOUT_MS * (rows.length + 1));
