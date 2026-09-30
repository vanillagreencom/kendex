import { expect, test } from "bun:test";
import {
	createLogWriter, droppedLogMarker, LOG_DRAIN_DEADLINE_MS, LOG_FELL_BEHIND_REASON, LOG_FLUSH_DELAY_MS, LOG_MAX_PENDING_BYTES,
} from "../extensions/log-writer.js";

type Step =
	| { append: [file: string, text: string] }
	| { fire: true }
	| { settleWrite: number; fails?: true }
	| { drain: true }
	| { deadline: true };

// drained: the files drain reported unwritten, or null while it is pending.
interface Observed { writes: [string, string][]; errors: string[]; timerArmed: boolean; drained: string[] | null }

const big = "b".repeat(LOG_MAX_PENDING_BYTES);
const nearCap = "n".repeat(LOG_MAX_PENDING_BYTES - 3);
const fellBehind = (bytes: number) => droppedLogMarker(bytes, LOG_FELL_BEHIND_REASON);
const writeFailed = (bytes: number) => droppedLogMarker(bytes, "log write failed: fixture append failure");

const rows: { name: string; steps: Step[]; expected: Observed }[] = [
	{
		name: "appends inside one window become one write per file",
		steps: [{ append: ["a.log", "one\n"] }, { append: ["b.log", "x\n"] }, { append: ["a.log", "two\n"] }, { fire: true }],
		expected: { writes: [["a.log", "one\ntwo\n"], ["b.log", "x\n"]], errors: [], timerArmed: false, drained: null },
	},
	{
		name: "nothing is written before the window ends",
		steps: [{ append: ["a.log", "one\n"] }],
		expected: { writes: [], errors: [], timerArmed: true, drained: null },
	},
	{
		name: "text appended during a write waits for it and for the next window",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { fire: true }, { settleWrite: 0 }, { fire: true }],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], errors: [], timerArmed: false, drained: null },
	},
	{
		name: "text past the pending cap is dropped and counted in a marker",
		steps: [{ append: ["a.log", big] }, { append: ["a.log", "lost\n"] }, { fire: true }],
		expected: { writes: [["a.log", big + fellBehind(5)]], errors: [], timerArmed: false, drained: null },
	},
	{
		name: "a chunk that fits after a drop joins the gap, so the marker sits at the gap",
		steps: [{ append: ["a.log", nearCap] }, { append: ["a.log", "lost\n"] }, { append: ["a.log", "ok\n"] }, { fire: true }],
		expected: { writes: [["a.log", nearCap + fellBehind(8)]], errors: [], timerArmed: false, drained: null },
	},
	{
		name: "a failed write is reported and its marker leads the next batch",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0, fails: true }, { append: ["a.log", "two\n"] }, { fire: true }],
		expected: { writes: [["a.log", "one\n"], ["a.log", writeFailed(4) + "two\n"]], errors: ["a.log"], timerArmed: false, drained: null },
	},
	{
		name: "a failure marker alone arms no retry",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0, fails: true }],
		expected: { writes: [["a.log", "one\n"]], errors: ["a.log"], timerArmed: false, drained: null },
	},
	{
		name: "a failure marker alone is written by drain",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0, fails: true }, { drain: true }, { settleWrite: 1 }],
		expected: { writes: [["a.log", "one\n"], ["a.log", writeFailed(4)]], errors: ["a.log"], timerArmed: false, drained: [] },
	},
	{
		name: "drain writes pending text without the window and waits for every write",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { drain: true }, { settleWrite: 0 }, { settleWrite: 1 }],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], errors: [], timerArmed: false, drained: [] },
	},
	{
		name: "a drain batch waits for the write in flight",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { drain: true }],
		expected: { writes: [["a.log", "one\n"]], errors: [], timerArmed: false, drained: null },
	},
	{
		name: "text appended while a drain batch writes waits for that write",
		steps: [
			{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { drain: true }, { settleWrite: 0 },
			{ append: ["a.log", "three\n"] }, { fire: true },
		],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], errors: [], timerArmed: false, drained: null },
	},
	{
		name: "drain waits only for text pending at the call",
		steps: [{ append: ["a.log", "one\n"] }, { drain: true }, { append: ["a.log", "two\n"] }, { settleWrite: 0 }],
		expected: { writes: [["a.log", "one\n"]], errors: [], timerArmed: true, drained: [] },
	},
	{
		name: "drain returns at the deadline when a write never settles",
		steps: [{ append: ["a.log", "one\n"] }, { append: ["b.log", "x\n"] }, { drain: true }, { settleWrite: 1 }, { deadline: true }],
		expected: { writes: [["a.log", "one\n"], ["b.log", "x\n"]], errors: [], timerArmed: false, drained: ["a.log"] },
	},
	{
		name: "drain with nothing pending resolves at once",
		steps: [{ drain: true }],
		expected: { writes: [], errors: [], timerArmed: false, drained: [] },
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
		let deadline: (() => void) | null = null;
		let drained: string[] | null = null;
		const writer = createLogWriter({
			append(file, text) {
				writes.push([file, text]);
				return new Promise<void>((resolve, reject) => outcomes.push({ resolve, reject }));
			},
			onError(file) { errors.push(file); },
			setTimer(cb, ms) {
				if (ms === LOG_FLUSH_DELAY_MS) timer = cb;
				else if (ms === LOG_DRAIN_DEADLINE_MS) deadline = cb;
				else throw new Error(`log_writer_test.delay=${ms}`);
				return { ms, unref() {} } as unknown as NodeJS.Timeout;
			},
			clearTimer(handle) {
				if ((handle as unknown as { ms: number }).ms === LOG_FLUSH_DELAY_MS) timer = null;
				else deadline = null;
			},
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
			} else if ("deadline" in step) {
				const fire = deadline;
				if (!fire) throw new Error("log_writer_test.deadline=no-pending-timer");
				deadline = null;
				fire();
			} else void writer.drain(LOG_DRAIN_DEADLINE_MS).then(({ unwritten }) => { drained = unwritten; });
			await settle();
		}
		expect({ writes, errors, timerArmed: timer !== null, drained }, row.name).toStrictEqual(row.expected);
	}
});
