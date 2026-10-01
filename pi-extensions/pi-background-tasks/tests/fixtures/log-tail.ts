import assert from "node:assert/strict";
import fs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
import { createTaskOutputReader } from "../../extensions/log-tail.js";
import type { ManagedTask } from "../../extensions/types.js";

const nativeOpen = fs.open;
let reads = 0;
let bytes = 0;
let closes = 0;
let failRead = false;
fs.open = async (...args: Parameters<typeof nativeOpen>) => {
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
			if (key === "close") return async () => { closes += 1; await target.close(); };
			const value: unknown = Reflect.get(target, key);
			return typeof value === "function" ? value.bind(target) : value;
		},
	});
};
syncBuiltinESMExports();
const errors: string[] = [];
const reader = createTaskOutputReader((_file, error) => errors.push(error));
const first = { logFile: "first.log", output: "" } as ManagedTask;
const second = { logFile: "second.log", output: "" } as ManagedTask;
await fs.writeFile(first.logFile, "x".repeat(1024) + "0123456789");
await fs.writeFile(second.logFile, "second tail");
assert.equal(await reader.read(first, 10), "0123456789");
assert.equal(bytes, 10);
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
assert.equal(reads - before, 2, "concurrent reads must share the byte read, including short reads");
await fs.writeFile(first.logFile, "€ok");
assert.equal(await reader.read(first, 4), "ok", "discard partial leading UTF-8 bytes");
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
console.log(JSON.stringify({ reads, bytes, closes, errors: errors.length }));
