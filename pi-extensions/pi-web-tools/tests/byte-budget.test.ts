import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { ByteBudget, IN_FLIGHT_BYTE_BUDGET, readLocalPdfWithin, readPdfWithin, readTextWithin, TEXT_READ_BYTE_LIMIT, type UrlReads } from "../src/extract/byte-budget.js";
import { streamedBody, tempDir, urlReads } from "./fixtures.js";

/** What a text read of a 10-byte body returns after the reads under test: how much of the call budget they left. */
async function leftAfter(reads: UrlReads): Promise<string> {
	return readTextWithin(new Response("0123456789"), reads).then((read) => read.text, (error: Error) => error.name);
}

for (const row of [
	{ name: "under the limit", chunks: 3, chunkBytes: 4, limit: 16, expected: { length: 12, cut: undefined, pulled: 3, cancelled: false } },
	{ name: "exactly the limit", chunks: 4, chunkBytes: 4, limit: 16, expected: { length: 16, cut: undefined, pulled: 4, cancelled: false } },
	{ name: "over the limit mid-chunk", chunks: 100, chunkBytes: 4, limit: 10, expected: { length: 10, cut: { atBytes: 10, by: "read-limit" }, pulled: 3, cancelled: true } },
	{ name: "over the limit at a chunk edge", chunks: 100, chunkBytes: 4, limit: 8, expected: { length: 8, cut: { atBytes: 8, by: "read-limit" }, pulled: 3, cancelled: true } },
]) {
	test(`UrlReads.readBody: ${row.name}`, async (t) => {
		const { body, probe } = streamedBody(row.chunks, row.chunkBytes);
		const read = await urlReads(t).readBody(new Response(body), row.limit);
		assert.deepEqual({ length: read.bytes.byteLength, cut: read.cut, pulled: probe.pulled, cancelled: probe.cancelled }, row.expected);
	});
}

test("ByteBudget lowers each read to what the call has left, names that ceiling, then refuses", async (t) => {
	const reads = urlReads(t, TEXT_READ_BYTE_LIMIT + 5);
	const first = await readTextWithin(new Response(streamedBody(TEXT_READ_BYTE_LIMIT / 1024 + 1, 1024).body), reads);
	const second = await readTextWithin(new Response("0123456789"), reads);
	const refused = streamedBody(1, 1);
	const third = await readTextWithin(new Response(refused.body), reads).then(() => "read", (error: Error) => error.name);
	assert.deepEqual({ first: first.cut, second, third, refusedBodyCancelled: refused.probe.cancelled }, {
		first: { atBytes: TEXT_READ_BYTE_LIMIT, by: "read-limit" },
		second: { text: "01234", cut: { atBytes: 5, by: "call-budget" } },
		third: "ByteBudgetExhausted",
		refusedBodyCancelled: true,
	});
});

for (const row of [
	{ name: "declared length over the limit", chunks: 100, declared: true, expected: { outcome: "PDF too large", pulled: 0, left: "0123456789" } },
	{ name: "streamed length over the limit", chunks: 100, declared: false, expected: { outcome: "PDF too large", pulled: 3, left: "ByteBudgetExhausted" } },
	{ name: "within the limit", chunks: 2, declared: true, expected: { outcome: "8 bytes", pulled: 2, left: "01" } },
]) {
	test(`readPdfWithin: ${row.name}`, async (t) => {
		const { body, probe } = streamedBody(row.chunks, 4);
		const headers = row.declared ? { "content-length": String(row.chunks * 4) } : undefined;
		const reads = urlReads(t, 10);
		const outcome = await readPdfWithin(new Response(body, { headers }), reads, "https://example.com/a.pdf").then((bytes) => `${bytes.byteLength} bytes`, (error: Error) => error.message.split(":")[0]);
		assert.deepEqual({ outcome, pulled: probe.pulled, left: await leftAfter(reads) }, row.expected);
	});
}

for (const row of [
	{ name: "over the call budget", size: 11, expected: { outcome: "PDF too large", left: "0123456789" } },
	{ name: "within the call budget", size: 8, expected: { outcome: "8 bytes", left: "01" } },
]) {
	test(`readLocalPdfWithin: ${row.name}`, async (t) => {
		const path = join(tempDir(t), "doc.pdf");
		writeFileSync(path, "p".repeat(row.size));
		const reads = urlReads(t, 10);
		const outcome = await readLocalPdfWithin(path, reads).then((bytes) => `${bytes.byteLength} bytes`, (error: Error) => error.message.split(":")[0]);
		assert.deepEqual({ outcome, left: await leftAfter(reads) }, row.expected);
	});
}

for (const row of [
	{ name: "within the limit", size: 8, perRead: 16, expected: { content: "ffffffff", size: 8, cut: undefined, left: "01" } },
	{ name: "over the limit", size: 20, perRead: 6, expected: { content: "ffffff", size: 20, cut: { atBytes: 6, by: "read-limit" }, left: "0123" } },
]) {
	test(`UrlReads.readFile: ${row.name}`, async (t) => {
		const path = join(tempDir(t), "file.txt");
		writeFileSync(path, "f".repeat(row.size));
		const reads = urlReads(t, 10);
		const read = await reads.readFile(path, row.perRead);
		assert.deepEqual({ content: read.bytes.toString(), size: read.size, cut: read.cut, left: await leftAfter(reads) }, row.expected);
	});
}

/** A body whose one pull waits until `finish` delivers `bytes` bytes and ends it; `pulled` counts the reads that reached it. */
function gatedBody() {
	const probe = { pulled: 0, cancelled: false };
	let finish!: (bytes: number) => void;
	const gate = new Promise<number>((resolve) => { finish = resolve; });
	const body = new ReadableStream<Uint8Array>({
		async pull(controller) {
			probe.pulled++;
			const bytes = await gate;
			if (bytes) controller.enqueue(new Uint8Array(bytes));
			controller.close();
		},
		cancel() { probe.cancelled = true; },
	}, { highWaterMark: 0 });
	return { body, probe, finish };
}

/** Runs every promise continuation queued so far: a read granted in-flight room reaches its body's first pull within them. */
const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

/** A text read of a gated body under its own web_fetch call budget, as one of several concurrent calls would make. */
function concurrentCallRead(signal?: AbortSignal) {
	const reads = new ByteBudget().openUrl(signal);
	const body = gatedBody();
	const read = reads.readBody(new Response(body.body), TEXT_READ_BYTE_LIMIT).then(() => "read", (error: Error) => error.name);
	return { reads, body, read };
}

const SLOTS = IN_FLIGHT_BYTE_BUDGET / TEXT_READ_BYTE_LIMIT;

test("reads of concurrent web_fetch calls hold at most IN_FLIGHT_BYTE_BUDGET at once, and a waiting read starts after a release", { timeout: 10_000 }, async () => {
	const calls = Array.from({ length: SLOTS + 2 }, () => concurrentCallRead());
	const started = () => calls.map((call) => call.body.probe.pulled);
	await settle();
	const whileFull = started();
	calls[0]!.body.finish(0);
	await settle();
	const afterUnusedRoomReturned = started();
	calls[1]!.body.finish(1);
	await settle();
	const whileOneByteHeld = started();
	calls[1]!.reads.release();
	await settle();
	const afterRelease = started();
	for (const call of calls) call.body.finish(0);
	await Promise.all(calls.map((call) => call.read));
	for (const call of calls) call.reads.release();
	const waiting = Array(SLOTS + 2).fill(0);
	assert.deepEqual({ whileFull, afterUnusedRoomReturned, whileOneByteHeld, afterRelease }, {
		whileFull: waiting.map((_, index) => index < SLOTS ? 1 : 0),
		afterUnusedRoomReturned: waiting.map((_, index) => index <= SLOTS ? 1 : 0),
		whileOneByteHeld: waiting.map((_, index) => index <= SLOTS ? 1 : 0),
		afterRelease: waiting.map(() => 1),
	});
});

test("a read aborted while it waits for in-flight room rejects, cancels its body and frees nothing", { timeout: 10_000 }, async () => {
	const holders = Array.from({ length: SLOTS }, () => concurrentCallRead());
	const controller = new AbortController();
	const aborted = concurrentCallRead(controller.signal);
	const behind = concurrentCallRead();
	await settle();
	controller.abort();
	const abortedOutcome = await aborted.read;
	await settle();
	const behindWhileHoldersRead = behind.body.probe.pulled;
	holders[0]!.body.finish(0);
	await settle();
	const behindAfterRelease = behind.body.probe.pulled;
	for (const call of [...holders, behind]) call.body.finish(0);
	await Promise.all([...holders, behind].map((call) => call.read));
	for (const call of [...holders, aborted, behind]) call.reads.release();
	assert.deepEqual({ abortedOutcome, abortedPulled: aborted.body.probe.pulled, abortedCancelled: aborted.body.probe.cancelled, behindWhileHoldersRead, behindAfterRelease }, {
		abortedOutcome: "AbortError", abortedPulled: 0, abortedCancelled: true, behindWhileHoldersRead: 0, behindAfterRelease: 1,
	});
});

test("a URL's next read waits only for room its own earlier read does not already hold", { timeout: 10_000 }, async (t) => {
	const holders = Array.from({ length: SLOTS - 1 }, () => concurrentCallRead());
	const reads = urlReads(t);
	await reads.readBody(new Response("x"), TEXT_READ_BYTE_LIMIT);
	const next = gatedBody();
	const nextRead = reads.readBody(new Response(next.body), TEXT_READ_BYTE_LIMIT);
	await settle();
	const nextPulled = next.probe.pulled;
	for (const call of holders) call.body.finish(0);
	next.finish(0);
	await Promise.all([...holders.map((call) => call.read), nextRead]);
	for (const call of holders) call.reads.release();
	assert.equal(nextPulled, 1);
});
