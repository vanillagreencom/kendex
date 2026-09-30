import { expect, test } from "bun:test";
import { createLogWriter, droppedLogMarker, LOG_FLUSH_DELAY_MS, LOG_MAX_PENDING_BYTES } from "../extensions/log-writer.js";

type Step =
	| { append: [file: string, text: string] }
	| { fire: true }
	| { settleWrite: number; fails?: true }
	| { drain: true };

interface Observed { writes: [string, string][]; errors: string[]; timerArmed: boolean; drained: boolean }

const big = "b".repeat(LOG_MAX_PENDING_BYTES);

const rows: { name: string; steps: Step[]; expected: Observed }[] = [
	{
		name: "appends inside one window become one write per file",
		steps: [{ append: ["a.log", "one\n"] }, { append: ["b.log", "x\n"] }, { append: ["a.log", "two\n"] }, { fire: true }],
		expected: { writes: [["a.log", "one\ntwo\n"], ["b.log", "x\n"]], errors: [], timerArmed: false, drained: false },
	},
	{
		name: "nothing is written before the window ends",
		steps: [{ append: ["a.log", "one\n"] }],
		expected: { writes: [], errors: [], timerArmed: true, drained: false },
	},
	{
		name: "text appended during a write waits for it and for the next window",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { fire: true }, { settleWrite: 0 }, { fire: true }],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], errors: [], timerArmed: false, drained: false },
	},
	{
		name: "text past the pending cap is dropped and counted in a marker",
		steps: [{ append: ["a.log", big] }, { append: ["a.log", "lost\n"] }, { fire: true }],
		expected: { writes: [["a.log", big + droppedLogMarker(5)]], errors: [], timerArmed: false, drained: false },
	},
	{
		name: "a failed write is reported and later text still lands",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0, fails: true }, { append: ["a.log", "two\n"] }, { fire: true }],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], errors: ["a.log"], timerArmed: false, drained: false },
	},
	{
		name: "drain writes pending text without the window and waits for every write",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { drain: true }, { settleWrite: 0 }, { settleWrite: 1 }],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], errors: [], timerArmed: false, drained: true },
	},
	{
		name: "drain with nothing pending resolves at once",
		steps: [{ drain: true }],
		expected: { writes: [], errors: [], timerArmed: false, drained: true },
	},
];

// Resolved writes and their continuations land before the next macrotask.
const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

test("task log writer batches, bounds and drains appends", async () => {
	expect.assertions(rows.length + 1);
	expect(rows.length, "log writer table must contain cases").toBeGreaterThan(0);
	for (const row of rows) {
		const writes: [string, string][] = [];
		const outcomes: { resolve: () => void; reject: (error: Error) => void }[] = [];
		const errors: string[] = [];
		let timer: (() => void) | null = null;
		let drained = false;
		const writer = createLogWriter({
			append(file, text) {
				writes.push([file, text]);
				return new Promise<void>((resolve, reject) => outcomes.push({ resolve, reject }));
			},
			onError(file) { errors.push(file); },
			setTimer(cb, ms) {
				if (ms !== LOG_FLUSH_DELAY_MS) throw new Error(`log_writer_test.delay=${ms}`);
				timer = cb;
				return { unref() {} } as unknown as NodeJS.Timeout;
			},
			clearTimer() { timer = null; },
		});
		for (const step of row.steps) {
			if ("append" in step) writer.append(...step.append);
			else if ("fire" in step) {
				const fire = timer;
				if (!fire) throw new Error("log_writer_test.fire=no-pending-timer");
				timer = null;
				fire();
			} else if ("settleWrite" in step) {
				const outcome = outcomes[step.settleWrite];
				if (!outcome) throw new Error(`log_writer_test.write_missing=${step.settleWrite}`);
				if (step.fails) outcome.reject(new Error("fixture append failure"));
				else outcome.resolve();
			} else void writer.drain().then(() => { drained = true; });
			await settle();
		}
		expect({ writes, errors, timerArmed: timer !== null, drained }, row.name).toStrictEqual(row.expected);
	}
});
