import { expect, test } from "bun:test";
import {
	createLogWriter, failedLogMarker, LOG_FLUSH_DELAY_MS, LOG_MAX_PENDING_BYTES, LOG_WRITE_NOW_BYTES, LOG_WRITE_STALL_MS, stalledLogMarker,
} from "../extensions/log-writer.js";

type Step =
	| { append: [file: string, text: string] }
	| { fire: true }
	| { settleWrite: number; fails?: true }
	| { stall: number }
	| { drain: true }
	| { flush: string };

// held: appends whose hold has not resolved. stallsArmed: writes in flight whose
// stall deadline has not fired. drained: the last flush or drain, "nothing" for
// a flush that returned null, "waiting" until it resolves, "done" after.
interface Observed {
	writes: [string, string][];
	diagnostics: [string, string][];
	timerArmed: boolean;
	stallsArmed: number;
	held: number;
	drained: "nothing" | "waiting" | "done" | null;
}

const writeNow = "w".repeat(LOG_WRITE_NOW_BYTES);
const atCap = "c".repeat(LOG_MAX_PENDING_BYTES);
const writeFailed = (bytes: number) => failedLogMarker(bytes, "fixture append failure");
const failed = ["task log append failed", "a.log"] as [string, string];
const stalled = ["task log write stalled", "a.log"] as [string, string];

const rows: { name: string; steps: Step[]; expected: Observed }[] = [
	{
		name: "appends inside one window become one write per file",
		steps: [{ append: ["a.log", "one\n"] }, { append: ["b.log", "x\n"] }, { append: ["a.log", "two\n"] }, { fire: true }],
		expected: { writes: [["a.log", "one\ntwo\n"], ["b.log", "x\n"]], diagnostics: [], timerArmed: false, stallsArmed: 2, held: 0, drained: null },
	},
	{
		name: "nothing is written before the window ends",
		steps: [{ append: ["a.log", "one\n"] }],
		expected: { writes: [], diagnostics: [], timerArmed: true, stallsArmed: 0, held: 0, drained: null },
	},
	{
		name: "text appended during a write waits for it and for the next window",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { fire: true }, { settleWrite: 0 }, { fire: true }],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], diagnostics: [], timerArmed: false, stallsArmed: 1, held: 0, drained: null },
	},
	{
		name: "pending text at the write-now size is written without the window",
		steps: [{ append: ["a.log", "one\n"] }, { append: ["a.log", writeNow] }],
		expected: { writes: [["a.log", "one\n" + writeNow]], diagnostics: [], timerArmed: true, stallsArmed: 1, held: 0, drained: null },
	},
	{
		name: "pending text at the write-now size waits for the write in flight",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", writeNow] }],
		expected: { writes: [["a.log", "one\n"]], diagnostics: [], timerArmed: true, stallsArmed: 1, held: 0, drained: null },
	},
	{
		name: "pending text at the cap behind a write in flight holds the producer and keeps every byte",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", atCap] }, { append: ["a.log", "more\n"] }],
		expected: { writes: [["a.log", "one\n"]], diagnostics: [], timerArmed: true, stallsArmed: 1, held: 2, drained: null },
	},
	{
		name: "the end of the write in flight writes held text at once and releases the producer",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", atCap] }, { append: ["a.log", "more\n"] }, { settleWrite: 0 }],
		expected: { writes: [["a.log", "one\n"], ["a.log", atCap + "more\n"]], diagnostics: [], timerArmed: true, stallsArmed: 1, held: 0, drained: null },
	},
	{
		name: "flush writes one file's pending text without the window and waits for it",
		steps: [{ append: ["a.log", "one\n"] }, { append: ["b.log", "x\n"] }, { flush: "a.log" }, { settleWrite: 0 }],
		expected: { writes: [["a.log", "one\n"]], diagnostics: [], timerArmed: true, stallsArmed: 0, held: 0, drained: "done" },
	},
	{
		name: "flush waits for the write in flight",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { flush: "a.log" }],
		expected: { writes: [["a.log", "one\n"]], diagnostics: [], timerArmed: false, stallsArmed: 1, held: 0, drained: "waiting" },
	},
	{
		name: "flush of a file with nothing pending or in flight returns null",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0 }, { flush: "a.log" }],
		expected: { writes: [["a.log", "one\n"]], diagnostics: [], timerArmed: false, stallsArmed: 0, held: 0, drained: "nothing" },
	},
	{
		name: "a stalled write frees a waiting flush and the producer's hold, and reports the file once",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", atCap] }, { flush: "a.log" }, { stall: 0 }],
		expected: { writes: [["a.log", "one\n"]], diagnostics: [stalled], timerArmed: true, stallsArmed: 0, held: 0, drained: "done" },
	},
	{
		name: "during a stall text past the cap is counted, and its marker follows the kept text once the write settles",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", atCap] }, { stall: 0 }, { append: ["a.log", "lost\n"] }, { settleWrite: 0 }],
		expected: { writes: [["a.log", "one\n"], ["a.log", atCap + stalledLogMarker(5)]], diagnostics: [stalled], timerArmed: true, stallsArmed: 1, held: 0, drained: null },
	},
	{
		name: "a write chained behind a stalled write starts unstalled, so text at the cap holds the producer and is kept",
		steps: [
			{ append: ["a.log", "one\n"] }, { flush: "a.log" }, { append: ["a.log", "two\n"] }, { flush: "a.log" }, { stall: 0 }, { settleWrite: 0 },
			{ append: ["a.log", atCap] }, { append: ["a.log", "more\n"] }, { settleWrite: 1 },
		],
		expected: {
			writes: [["a.log", "one\n"], ["a.log", "two\n"], ["a.log", atCap + "more\n"]], diagnostics: [stalled], timerArmed: true, stallsArmed: 1, held: 0, drained: "done",
		},
	},
	{
		name: "a failed batch that carries a stall marker counts the counted bytes in its failure marker",
		steps: [
			{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", atCap] }, { stall: 0 }, { append: ["a.log", "lost\n"] }, { settleWrite: 0 },
			{ settleWrite: 1, fails: true }, { append: ["a.log", "two\n"] }, { fire: true },
		],
		expected: {
			writes: [["a.log", "one\n"], ["a.log", atCap + stalledLogMarker(5)], ["a.log", writeFailed(atCap.length + 5) + "two\n"]],
			diagnostics: [stalled, failed], timerArmed: false, stallsArmed: 1, held: 0, drained: null,
		},
	},
	{
		name: "flush of a stalled file takes no batch and resolves at once, so text past the cap stays counted",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", atCap] }, { stall: 0 }, { flush: "a.log" }, { append: ["a.log", "lost\n"] }, { settleWrite: 0 }],
		expected: { writes: [["a.log", "one\n"], ["a.log", atCap + stalledLogMarker(5)]], diagnostics: [stalled], timerArmed: true, stallsArmed: 1, held: 0, drained: "done" },
	},
	{
		name: "drain does not wait for a stalled write",
		steps: [{ append: ["a.log", "one\n"] }, { append: ["b.log", "x\n"] }, { drain: true }, { settleWrite: 1 }, { stall: 0 }],
		expected: { writes: [["a.log", "one\n"], ["b.log", "x\n"]], diagnostics: [stalled], timerArmed: false, stallsArmed: 0, held: 0, drained: "done" },
	},
	{
		name: "a failed write is reported and its marker leads the next batch",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0, fails: true }, { append: ["a.log", "two\n"] }, { fire: true }],
		expected: { writes: [["a.log", "one\n"], ["a.log", writeFailed(4) + "two\n"]], diagnostics: [failed], timerArmed: false, stallsArmed: 1, held: 0, drained: null },
	},
	{
		name: "a failure marker alone arms no retry",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0, fails: true }],
		expected: { writes: [["a.log", "one\n"]], diagnostics: [failed], timerArmed: false, stallsArmed: 0, held: 0, drained: null },
	},
	{
		name: "a failure marker alone is written by drain",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { settleWrite: 0, fails: true }, { drain: true }, { settleWrite: 1 }],
		expected: { writes: [["a.log", "one\n"], ["a.log", writeFailed(4)]], diagnostics: [failed], timerArmed: false, stallsArmed: 0, held: 0, drained: "done" },
	},
	{
		name: "drain writes pending text without the window and waits for every write",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { drain: true }, { settleWrite: 0 }, { settleWrite: 1 }],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], diagnostics: [], timerArmed: false, stallsArmed: 0, held: 0, drained: "done" },
	},
	{
		name: "a drain batch waits for the write in flight",
		steps: [{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { drain: true }],
		expected: { writes: [["a.log", "one\n"]], diagnostics: [], timerArmed: false, stallsArmed: 1, held: 0, drained: "waiting" },
	},
	{
		name: "text appended while a drain batch writes waits for that write",
		steps: [
			{ append: ["a.log", "one\n"] }, { fire: true }, { append: ["a.log", "two\n"] }, { drain: true }, { settleWrite: 0 },
			{ append: ["a.log", "three\n"] }, { fire: true },
		],
		expected: { writes: [["a.log", "one\n"], ["a.log", "two\n"]], diagnostics: [], timerArmed: false, stallsArmed: 1, held: 0, drained: "waiting" },
	},
	{
		name: "drain waits only for text pending at the call",
		steps: [{ append: ["a.log", "one\n"] }, { drain: true }, { append: ["a.log", "two\n"] }, { settleWrite: 0 }],
		expected: { writes: [["a.log", "one\n"]], diagnostics: [], timerArmed: true, stallsArmed: 0, held: 0, drained: "done" },
	},
	{
		name: "drain with nothing pending resolves at once",
		steps: [{ drain: true }],
		expected: { writes: [], diagnostics: [], timerArmed: false, stallsArmed: 0, held: 0, drained: "done" },
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
		const diagnostics: [string, string][] = [];
		let timer: (() => void) | null = null;
		// Stall deadlines in the order the writes armed them; null once fired or cleared.
		const stalls: ((() => void) | null)[] = [];
		let drained: Observed["drained"] = null;
		let held = 0;
		const writer = createLogWriter({
			append(file, text) {
				writes.push([file, text]);
				return new Promise<void>((resolve, reject) => outcomes.push({ resolve, reject }));
			},
			logDiagnostic(message, { file }) { diagnostics.push([message, file]); },
			setTimer(cb, ms) {
				if (ms === LOG_FLUSH_DELAY_MS) timer = cb;
				else if (ms === LOG_WRITE_STALL_MS) stalls.push(cb);
				else throw new Error(`log_writer_test.delay=${ms}`);
				return { ms, stall: stalls.length - 1, unref() {} } as unknown as NodeJS.Timeout;
			},
			clearTimer(handle) {
				const { ms, stall } = handle as unknown as { ms: number; stall: number };
				if (ms === LOG_FLUSH_DELAY_MS) timer = null;
				else stalls[stall] = null;
			},
		});
		const track = (done: Promise<void> | null) => {
			if (!done) drained = "nothing";
			else {
				drained = "waiting";
				void done.then(() => { drained = "done"; });
			}
		};
		for (const step of row.steps) {
			if ("append" in step) {
				const hold = writer.append(...step.append);
				if (hold) {
					held += 1;
					void hold.then(() => { held -= 1; });
				}
			} else if ("flush" in step) {
				track(writer.flush(step.flush));
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
			} else if ("stall" in step) {
				const fire = stalls[step.stall];
				if (!fire) throw new Error(`log_writer_test.stall=no-pending-timer index=${step.stall}`);
				stalls[step.stall] = null;
				fire();
			} else track(writer.drain());
			await settle();
		}
		const stallsArmed = stalls.filter((stall) => stall !== null).length;
		expect({ writes, diagnostics, timerArmed: timer !== null, stallsArmed, held, drained }, row.name).toStrictEqual(row.expected);
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
	await writer.drain();
	expect({
		bytes: writes.join("").length,
		whole: writes.join("") === chunk.repeat(chunks),
		held: holds > 0,
		largestWriteWithinCap: Math.max(...writes.map((text) => text.length)) <= LOG_MAX_PENDING_BYTES + chunk.length,
	}).toStrictEqual({ bytes: chunk.length * chunks, whole: true, held: true, largestWriteWithinCap: true });
});
