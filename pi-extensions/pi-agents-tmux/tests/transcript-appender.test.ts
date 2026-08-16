import assert from "node:assert/strict";
import { test } from "bun:test";
import { createTranscriptAppender } from "../extensions/subagent/runner.js";

// Concurrent appendFile calls on one path land in any order; the appender must
// write records strictly in call order even when an earlier write is slow.
test("transcript records land in call order when an earlier write finishes late", async () => {
	let landed = "";
	let call = 0;
	const release: Array<() => void> = [];
	const appendFile = (_path: string, data: string): Promise<void> => {
		call += 1;
		if (call === 1) {
			// The first write stalls until released after the second was requested.
			return new Promise<void>((resolve) => release.push(() => { landed += data; resolve(); }));
		}
		landed += data;
		return Promise.resolve();
	};
	const appender = createTranscriptAppender("/dev/null", appendFile);
	appender.append({ n: 1 });
	appender.append({ n: 2 });
	// A macrotask boundary drains every queued promise callback deterministically:
	// the ordered appender has now issued write 1 (and only write 1); a
	// non-serialized one issued both synchronously and write 2 already landed.
	await new Promise((resolve) => setImmediate(resolve));
	for (const r of release) r();
	await appender.settled();
	const order = landed.trim().split("\n").map((line) => JSON.parse(line).n);
	assert.deepEqual(order, [1, 2]);
});

test("a failed write does not block the next record", async () => {
	let landed = "";
	let call = 0;
	const appendFile = (_path: string, data: string): Promise<void> => {
		call += 1;
		if (call === 1) return Promise.reject(new Error("disk full"));
		landed += data;
		return Promise.resolve();
	};
	const appender = createTranscriptAppender("/dev/null", appendFile);
	appender.append({ n: 1 });
	appender.append({ n: 2 });
	await appender.settled();
	assert.deepEqual(landed.trim().split("\n").map((line) => JSON.parse(line).n), [2]);
});
