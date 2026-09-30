import { expect, test } from "bun:test";
import {
	createLogWriter, failedLogMarker, LOG_DRAIN_DEADLINE_MS, LOG_FLUSH_DELAY_MS, LOG_MAX_PENDING_BYTES, LOG_WRITE_NOW_BYTES,
} from "../extensions/log-writer.js";

type Step =
	| { append: [file: string, text: string] }
	| { fire: true }
	| { settleWrite: number; fails?: true }
	| { drain: true }
	| { flush: string }
	| { deadline: true };

// held: appends whose hold has not resolved. drained: the files the last drain
// or flush reported unwritten, "nothing" for a flush that returned null, or
// null while it is pending.
interface Observed { writes: [string, string][]; errors: string[]; timerArmed: boolean; held: number; drained: string[] | "nothing" | null }

const writeNow = "w".repeat(LOG_WRITE_NOW_BYTES);
const atCap = "c".repeat(LOG_MAX_PENDING_BYTES);
const writeFailed = (bytes: number) => failedLogMarker(bytes, "fixture append failure");

const rows: { name: string; steps: Step[]; expected: Observed }[] = [
	{
		name: "appends inside one window become one write per file",
		steps: [{ append: ["a.log", "one\n"] }, { append: ["b.log", "x\n"] }, { append: ["a.log", "two\n"] }, { fire: true }],
		expected: { writes: [["a.log", "one\ntwo\n"], ["b.log", "x\n"]], errors: [], timerArmed: false, held: 0, drained: null },
	},
	{
		name: "nothing is written before the window ends",
		steps: [{ append: ["a.log", "one\n"] }],
		expected: { writes: [], errors: [], timerArmed: true, held: 0, drained: null },
	},
	{
		name: "text appended during a write waits for it and for the next window",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { fire: true }, { settleWrite: 0 }, { fire: true }],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], errors: [], timerArmed: false, held: 0, drained: null },
	},
	{
		name: "pending text at the write-now size is written without the window",
		steps: [{ append: ["a.log", "one\n"] }, { append: ["a.log", writeNow] }],
		expected: { writes: [["a.log", "one\n" + writeNow]], errors: [], timerArmed: true, held: 0, drained: null },
	},
	{
		name: "pending text at the write-now size waits for the write in flight",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", writeNow] }],
		expected: { writes: [["a.log", "one\n"]], errors: [], timerArmed: true, held: 0, drained: null },
	},
	{
		name: "pending text at the cap behind a write in flight holds the producer and keeps every byte",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", atCap] }, { append: ["a.log", "more\n"] }],
		expected: { writes: [["a.log", "one\n"]], errors: [], timerArmed: true, held: 2, drained: null },
	},
	{
		name: "the end of the write in flight writes held text at once and releases the producer",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", atCap] }, { append: ["a.log", "more\n"] }, { settleWrite: 0 }],
		expected: { writes: [["a.log", "one\n"], ["a.log", atCap + "more\n"]], errors: [], timerArmed: true, held: 0, drained: null },
	},
	{
		name: "flush writes one file's pending text without the window and waits for it",
		steps: [{ append: ["a.log", "one\n"] }, { append: ["b.log", "x\n"] }, { flush: "a.log" }, { settleWrite: 0 }],
		expected: { writes: [["a.log", "one\n"]], errors: [], timerArmed: true, held: 0, drained: [] },
	},
	{
		name: "flush waits for the write in flight",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { flush: "a.log" }],
		expected: { writes: [["a.log", "one\n"]], errors: [], timerArmed: false, held: 0, drained: null },
	},
	{
		name: "flush of a file with nothing pending or in flight returns null",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0 }, { flush: "a.log" }],
		expected: { writes: [["a.log", "one\n"]], errors: [], timerArmed: false, held: 0, drained: "nothing" },
	},
	{
		name: "flush returns at the deadline when the write never settles",
		steps: [{ append: ["a.log", "one\n"] }, { flush: "a.log" }, { deadline: true }],
		expected: { writes: [["a.log", "one\n"]], errors: [], timerArmed: true, held: 0, drained: ["a.log"] },
	},
	{
		name: "a failed write is reported and its marker leads the next batch",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0, fails: true }, { append: ["a.log", "two\n"] }, { fire: true }],
		expected: { writes: [["a.log", "one\n"], ["a.log", writeFailed(4) + "two\n"]], errors: ["a.log"], timerArmed: false, held: 0, drained: null },
	},
	{
		name: "a failure marker alone arms no retry",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0, fails: true }],
		expected: { writes: [["a.log", "one\n"]], errors: ["a.log"], timerArmed: false, held: 0, drained: null },
	},
	{
		name: "a failure marker alone is written by drain",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0, fails: true }, { drain: true }, { settleWrite: 1 }],
		expected: { writes: [["a.log", "one\n"], ["a.log", writeFailed(4)]], errors: ["a.log"], timerArmed: false, held: 0, drained: [] },
	},
	{
		name: "drain writes pending text without the window and waits for every write",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { drain: true }, { settleWrite: 0 }, { settleWrite: 1 }],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], errors: [], timerArmed: false, held: 0, drained: [] },
	},
	{
		name: "a drain batch waits for the write in flight",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { drain: true }],
		expected: { writes: [["a.log", "one\n"]], errors: [], timerArmed: false, held: 0, drained: null },
	},
	{
		name: "text appended while a drain batch writes waits for that write",
		steps: [
			{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { drain: true }, { settleWrite: 0 },
			{ append: ["a.log", "three\n"] }, { fire: true },
		],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], errors: [], timerArmed: false, held: 0, drained: null },
	},
	{
		name: "drain waits only for text pending at the call",
		steps: [{ append: ["a.log", "one\n"] }, { drain: true }, { append: ["a.log", "two\n"] }, { settleWrite: 0 }],
		expected: { writes: [["a.log", "one\n"]], errors: [], timerArmed: true, held: 0, drained: [] },
	},
	{
		name: "drain returns at the deadline when a write never settles",
		steps: [{ append: ["a.log", "one\n"] }, { append: ["b.log", "x\n"] }, { drain: true }, { settleWrite: 1 }, { deadline: true }],
		expected: { writes: [["a.log", "one\n"], ["b.log", "x\n"]], errors: [], timerArmed: false, held: 0, drained: ["a.log"] },
	},
	{
		name: "drain with nothing pending resolves at once",
		steps: [{ drain: true }],
		expected: { writes: [], errors: [], timerArmed: false, held: 0, drained: [] },
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
		let drained: Observed["drained"] = null;
		let held = 0;
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
			if ("append" in step) {
				const hold = writer.append(...step.append);
				if (hold) {
					held += 1;
					void hold.then(() => { held -= 1; });
				}
			} else if ("flush" in step) {
				const flushed = writer.flush(step.flush, LOG_DRAIN_DEADLINE_MS);
				if (!flushed) drained = "nothing";
				else void flushed.then(({ unwritten }) => { drained = unwritten; });
			} else if ("fire" in step) {
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
		expect({ writes, errors, timerArmed: timer !== null, held, drained }, row.name).toStrictEqual(row.expected);
	}
});

test("output past the pending cap inside one window reaches the log whole through the producer's holds", async () => {
	// A producer that waits on each hold, as a task's paused output streams do,
	// against a disk that answers at once and a window that never fires.
	const chunk = "y\n".repeat(32 * 1024);
	const chunks = Math.ceil((5 * LOG_MAX_PENDING_BYTES) / chunk.length);
	const writes: string[] = [];
	let holds = 0;
	const writer = createLogWriter({
		append: async (_file, text) => { writes.push(text); },
		setTimer: () => ({ unref() {} }) as unknown as NodeJS.Timeout,
		clearTimer: () => {},
	});
	for (let index = 0; index < chunks; index++) {
		const hold = writer.append("a.log", chunk);
		if (hold) {
			holds += 1;
			await hold;
		}
	}
	await writer.drain(LOG_DRAIN_DEADLINE_MS);
	expect({
		bytes: writes.join("").length,
		whole: writes.join("") === chunk.repeat(chunks),
		held: holds > 0,
		largestWriteWithinCap: Math.max(...writes.map((text) => text.length)) <= LOG_MAX_PENDING_BYTES + chunk.length,
	}).toStrictEqual({ bytes: chunk.length * chunks, whole: true, held: true, largestWriteWithinCap: true });
});
