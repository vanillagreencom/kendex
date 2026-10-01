import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { setImmediate } from "node:timers/promises";
import { createTaskOutputReader } from "../../extensions/log-tail.js";
import { PROBE_CONCURRENCY } from "../../extensions/probes.js";
import type { ManagedTask } from "../../extensions/types.js";

const nativeOpen = fs.open;
let reads = 0;
let bytes = 0;
let closes = 0;
let failRead = false;
let opens = 0;
let holdClose = false;
const heldCloses: (() => void)[] = [];
fs.open = async (...args: Parameters<typeof nativeOpen>) => {
	opens += 1;
	const handle = await nativeOpen(...args);
	return new Proxy(handle, {
		get(target, key) {
			if (key === "read") return async (buffer: Buffer, offset: number, length: number, position: number) => {
				reads += 1;
				if (failRead) throw Object.assign(new Error("injected disk error"), { code: "EIO" });
				// FileHandle.read can return fewer bytes than the caller requested.
				const result = await target.read(buffer, offset, Math.min(length, 3), position);
				bytes += result.bytesRead;
				return result;
			};
			if (key === "close") return async () => {
				if (holdClose) await new Promise<void>((resolve) => heldCloses.push(resolve));
				closes += 1; await target.close();
			};
			const value: unknown = Reflect.get(target, key);
			return typeof value === "function" ? value.bind(target) : value;
		},
	});
};
syncBuiltinESMExports();
const errors: string[] = [];
const invalid = new Set<ManagedTask>();
const reader = createTaskOutputReader((_file, error) => errors.push(error), (task) => !invalid.has(task));
const first = { logFile: "first.log", output: "" } as ManagedTask;
const second = { logFile: "second.log", output: "" } as ManagedTask;
// Commands can emit all of these UTF-8 characters, including U+FFFD itself.
const characterRows = [
	{ name: "bmp", output: "€".repeat(10_001), maxChars: 10_000, expected: "€".repeat(10_000), truncated: true },
	{ name: "surrogate suffix", output: "x".repeat(100) + "😀" + "€".repeat(9), maxChars: 10, expected: "\uDE00" + "€".repeat(9), truncated: true },
	{ name: "single surrogate", output: "😀", maxChars: 1, expected: "\uDE00", truncated: true },
	{ name: "decoded clipping", output: "😀".repeat(10), maxChars: 10, expected: "😀".repeat(5), truncated: true },
	{ name: "partial prefix", output: "€".repeat(30), maxChars: 10, expected: "€".repeat(10), truncated: true },
	{ name: "replacement character", output: "\uFFFDok", maxChars: 4, expected: "\uFFFDok", truncated: false },
	{ name: "short unicode", output: "€ok", maxChars: 4, expected: "€ok", truncated: false },
	{ name: "exact unicode", output: "€".repeat(10), maxChars: 10, expected: "€".repeat(10), truncated: false },
];
for (const row of characterRows) {
	await fs.writeFile(first.logFile, row.output);
	const beforeBytes = bytes;
	const tail = await reader.readTail(first, row.maxChars);
	assert.deepEqual({ text: tail.text, truncated: tail.truncated }, { text: row.expected, truncated: row.truncated }, `character tail: ${row.name}`);
	assert.equal(bytes - beforeBytes, Math.min(Buffer.byteLength(row.output), 3 * row.maxChars + 1), `UTF-8 byte bound: ${row.name}`);
}
await fs.writeFile(first.logFile, "x".repeat(1024) + "0123456789");
await fs.writeFile(second.logFile, "second tail");
const beforeAscii = bytes;
assert.equal(await reader.read(first, 10), "0123456789");
assert.equal(bytes - beforeAscii, 31);
assert.equal(await reader.read(second, 10), "econd tail");
const readCount = reads;
for (const task of [first, second, first]) await reader.read(task, 10);
assert.equal(reads, readCount, "unchanged tasks must keep independent caches");
await fs.writeFile(first.logFile, "x".repeat(1024) + "abcdefghij");
await fs.utimes(first.logFile, new Date(2000), new Date(2000));
assert.equal(await reader.read(first, 10), "abcdefghij", "same-size mtime change must invalidate");
await fs.appendFile(first.logFile, "NEXT");
assert.equal(await reader.read(first, 10), "efghijNEXT");
await fs.truncate(first.logFile, 2);
assert.equal(await reader.read(first, 10), "xx");
assert.equal(await reader.read(second, 4), "tail", "limit changes must invalidate");
reader.clear();
const before = reads;
await Promise.all([reader.read(second, 4), reader.read(second, 4)]);
assert.equal(reads - before, 4, "concurrent reads must share the byte read, including short reads");
await fs.writeFile(first.logFile, "");
assert.equal(await reader.read(first, 10), "");
await fs.rm(first.logFile);
assert.equal(await reader.read(first, 10), "");
first.output = "not flushed";
assert.equal(await reader.read(first, 10), "not flushed");
first.output = "";
await fs.writeFile(first.logFile, "failed");
failRead = true;
assert.match(await reader.read(first, 10), /^\[log unreadable:/);
assert.equal(errors.length, 1);
assert.ok(closes > 0);
failRead = false;
holdClose = true;
// Exits, dashboard and tools ask the same owner for different tasks and limits.
for (const action of ["invalid", "clear"] as const) {
	const tasks = Array.from({ length: PROBE_CONCURRENCY * 2 + 1 }, () => ({ ...second }));
	const beforeOpens = opens;
	const pending = tasks.map((task, index) => index % 2 ? reader.read(task, 4) : reader.readTail(task, 4).then((tail) => tail.text));
	const duplicate = reader.read(tasks.at(-1)!, 4);
	// Real file reads reach finally.close; the fixture holds that close, not a timer.
	while (heldCloses.length < PROBE_CONCURRENCY) await setImmediate();
	assert.equal(opens - beforeOpens, PROBE_CONCURRENCY, "shared admission must hold through close");
	let replacement: Promise<string> | undefined;
	if (action === "invalid") invalid.add(tasks.at(-1)!);
	else { reader.clear(); replacement = reader.read({ ...second }, 4); }
	await setImmediate();
	assert.equal(opens - beforeOpens, PROBE_CONCURRENCY, "clear must not release active descriptors");
	for (const release of heldCloses.splice(0)) release();
	const remaining = action === "invalid" ? PROBE_CONCURRENCY : 1;
	while (heldCloses.length < remaining) await setImmediate();
	assert.equal(opens - beforeOpens, PROBE_CONCURRENCY + remaining, "stale queued reads must not open");
	for (const release of heldCloses.splice(0)) release();
	// A stale acquisition can reach held close after the released batches.
	// No timer keeps that blocked await alive; beforeExit makes it an assertion.
	const blocked = () => assert.fail(`stale queued reads must not open: ${action} left unresolved reads after close release`);
	process.once("beforeExit", blocked);
	try {
		assert.deepEqual(await Promise.all(pending), tasks.map((_, index) => index < PROBE_CONCURRENCY || action === "invalid" && index < tasks.length - 1 ? "tail" : ""));
		assert.equal(await duplicate, "", "stale pending deduplication must not restart acquisition");
		if (replacement) assert.equal(await replacement, "tail", "new session waits for old close");
	} finally { process.removeListener("beforeExit", blocked); }
}
console.log(JSON.stringify({ reads, bytes, closes, errors: errors.length }));
