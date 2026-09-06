// mapWithConcurrencyLimit as a table of scripts over deferred mappers: the
// pool starts, the script finishes one mapper at a time, and each step reads
// back as one line naming the mappers that started since the last step and,
// on the step where the pool settles, what it settled with. No mapper runs
// on a clock; the script is the only thing that releases one.

import assert from "node:assert/strict";
import test from "node:test";
import { mapWithConcurrencyLimit } from "../extensions/subagent/dispatch.js";

// Each step finishes the mapper of one item, with a value or a throw.
type Step = number | { throws: number };

function flush(): Promise<void> {
	return new Promise((resolve) => setImmediate(resolve));
}

// Items are letters; a mapper records itself as the item with the index it
// was handed, so a mapper called with a stale or shifted index reddens.
async function poolLine(count: number, concurrency: number, script: Step[]): Promise<string> {
	const items = Array.from({ length: count }, (_, i) => String.fromCharCode(97 + i));
	const releases = new Map<number, { resolve: (value: string) => void; reject: (error: Error) => void }>();
	const started: string[] = [];
	let settled: string | undefined;
	const pool = mapWithConcurrencyLimit(items, concurrency, (item, index) => {
		started.push(`${item}${index}`);
		return new Promise<string>((resolve, reject) => releases.set(index, { reject, resolve }));
	});
	pool.then(
		(results) => (settled = `results=[${results.join(",")}]`),
		(error: Error) => (settled = `rejected(${error.message})`),
	);
	// A step naming a mapper that never started is a mis-scripted row, not a line.
	const release = (index: number) => {
		const r = releases.get(index);
		if (!r) throw new Error(`script releases ${items[index]}${index} before it started`);
		return r;
	};
	const lines: string[] = [];
	let seen = 0;
	const step = async (event: string) => {
		await flush();
		lines.push(`${event} [${started.slice(seen).join(",")}]${settled ? ` ${settled}` : ""}`);
		seen = started.length;
	};
	await step("start");
	for (const s of script) {
		if (typeof s === "number") {
			release(s).resolve(`${items[s]}${s}`);
			await step(`${items[s]}${s} done ->`);
		} else {
			release(s.throws).reject(new Error(`${items[s.throws]} boom`));
			await step(`${items[s.throws]}${s.throws} threw ->`);
		}
	}
	if (!settled) lines.push("pending");
	return lines.join("; ");
}

// label | items | concurrency | script | expect
const rows: Array<[string, number, number, Step[], string]> = [
	["no items settle empty without a mapper call", 0, 4, [], "start [] results=[]"],
	["one item under a wide limit", 1, 8, [0], "start [a0]; a0 done -> [] results=[a0]"],
	["a limit above the item count starts every item", 3, 8, [2, 0, 1], "start [a0,b1,c2]; c2 done -> []; a0 done -> []; b1 done -> [] results=[a0,b1,c2]"],
	["each finish picks up the next index, results by submission index", 6, 2, [1, 0, 2, 3, 5, 4], "start [a0,b1]; b1 done -> [c2]; a0 done -> [d3]; c2 done -> [e4]; d3 done -> [f5]; f5 done -> []; e4 done -> [] results=[a0,b1,c2,d3,e4,f5]"],
	["the pool settles only when the last mapper finishes", 3, 2, [0, 2], "start [a0,b1]; a0 done -> [c2]; c2 done -> []; pending"],
	["a fractional limit floors", 4, 2.7, [0, 1], "start [a0,b1]; a0 done -> [c2]; b1 done -> [d3]; pending"],
	["a limit of zero runs one worker", 3, 0, [0, 1, 2], "start [a0]; a0 done -> [b1]; b1 done -> [c2]; c2 done -> [] results=[a0,b1,c2]"],
	["a throw rejects the pool with the mapper's error", 4, 2, [{ throws: 1 }], "start [a0,b1]; b1 threw -> [] rejected(b boom)"],
	["a throw after the pool is full rejects with that item's error", 4, 2, [0, { throws: 2 }], "start [a0,b1]; a0 done -> [c2]; c2 threw -> [] rejected(c boom)"],
];

test("mapWithConcurrencyLimit", async () => {
	for (const [label, count, concurrency, script, expect] of rows) assert.equal(await poolLine(count, concurrency, script), expect, label);
});
