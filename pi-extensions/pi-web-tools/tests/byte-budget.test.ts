import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test, { type TestContext } from "node:test";
import { BODY_IDLE_TIMEOUT_MS, ByteBudget, ByteBudgetExhausted, IN_FLIGHT_BYTE_BUDGET, IN_FLIGHT_WAIT_TIMEOUT_MS, PDF_READ_BYTE_LIMIT, readLocalPdfWithin, readPdfWithin, readTextWithin, TEXT_READ_BYTE_LIMIT, type UrlReads } from "../src/extract/byte-budget.js";
import { streamedBody, tempDir, urlReads } from "./fixtures.js";

/** What a text read of a 10-byte body returns after the reads under test: how much of the call budget they left. */
async function leftAfter(reads: UrlReads): Promise<string> {
	return readTextWithin(new Response("0123456789"), reads).then((read) => read.text, (error: Error) => error.name);
}

/** Runs every promise continuation queued so far: a read granted in-flight room reaches its body's first pull within them. */
const settle = () => new Promise<void>((resolve) => setImmediate(resolve));

// A "stall" body sends its chunks, then nothing, and never closes: a read that settles on it never waited for another chunk.
for (const row of [
	{ name: "under the limit", chunks: 3, end: "close", limit: 16, headers: new Headers(), expected: { length: 12, cut: undefined, pulled: 3, cancelled: false } },
	{ name: "exactly the limit with no declared length, then open and silent", chunks: 4, end: "stall", limit: 16, headers: new Headers(), expected: { length: 16, cut: { atBytes: 16, by: "read-limit" }, pulled: 4, cancelled: true } },
	{ name: "over the limit mid-chunk", chunks: 100, end: "close", limit: 10, headers: new Headers(), expected: { length: 10, cut: { atBytes: 10, by: "read-limit" }, pulled: 3, cancelled: true } },
	{ name: "over the limit at a chunk edge", chunks: 100, end: "close", limit: 8, headers: new Headers(), expected: { length: 8, cut: { atBytes: 8, by: "read-limit" }, pulled: 2, cancelled: true } },
	{ name: "exactly its declared length, then open and silent", chunks: 2, end: "stall", limit: 16, headers: new Headers({ "content-length": "8" }), expected: { length: 8, cut: undefined, pulled: 2, cancelled: true } },
	{ name: "exactly a declared length equal to the limit, then open and silent", chunks: 4, end: "stall", limit: 16, headers: new Headers({ "content-length": "16" }), expected: { length: 16, cut: undefined, pulled: 4, cancelled: true } },
	{ name: "past its declared length", chunks: 100, end: "close", limit: 16, headers: new Headers({ "content-length": "6" }), expected: { length: 6, cut: { atBytes: 6, by: "declared-length" }, pulled: 2, cancelled: true } },
	{ name: "past the declared length of its compressed bytes", chunks: 3, end: "close", limit: 16, headers: new Headers({ "content-length": "6", "content-encoding": "gzip" }), expected: { length: 12, cut: undefined, pulled: 3, cancelled: false } },
] as const) {
	test(`UrlReads.readBody: ${row.name}`, async (t) => {
		const { body, probe } = streamedBody(row.chunks, 4, row.end);
		const pending = urlReads(t).readBody(new Response(body, { headers: row.headers }), row.limit);
		const read = await Promise.race([pending, settle().then(() => undefined)]);
		assert.ok(read, "the read did not settle: it is waiting for a chunk the body never sends");
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

/** A read of a gated body under its own web_fetch call budget, as one of several concurrent calls would make: a text read by
 * default, a PDF read with PDF_READ_BYTE_LIMIT. Its outcome names a byte-budget error's budget. */
function concurrentCallRead(signal?: AbortSignal, perRead = TEXT_READ_BYTE_LIMIT, headers = new Headers()) {
	const reads = new ByteBudget().openUrl(signal);
	const body = gatedBody();
	const read = reads.readBody(new Response(body.body, { headers }), perRead).then(() => "read", (error: Error) => error instanceof ByteBudgetExhausted ? `${error.name}:${error.budget}` : error.name);
	return { reads, body, read };
}

const SLOTS = IN_FLIGHT_BYTE_BUDGET / TEXT_READ_BYTE_LIMIT;
/** Text reads that leave too little in-flight room for a PDF read and enough for one more text read. */
const HOLDERS_UNDER_PDF = Math.floor((IN_FLIGHT_BYTE_BUDGET - PDF_READ_BYTE_LIMIT) / TEXT_READ_BYTE_LIMIT) + 1;

/** Ends every read and returns its in-flight room, so the next test starts with the whole budget free. */
async function finishAll(calls: Array<ReturnType<typeof concurrentCallRead>>): Promise<void> {
	for (const call of calls) call.body.finish(0);
	await Promise.all(calls.map((call) => call.read));
	for (const call of calls) call.reads.release();
}

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

test("a waiting PDF read keeps a text read that would fit behind it, and its abort grants that read the room", { timeout: 10_000 }, async () => {
	const holders = Array.from({ length: HOLDERS_UNDER_PDF }, () => concurrentCallRead());
	const controller = new AbortController();
	const pdf = concurrentCallRead(controller.signal, PDF_READ_BYTE_LIMIT);
	const text = concurrentCallRead();
	await settle();
	const textWhilePdfWaits = text.body.probe.pulled;
	controller.abort();
	const pdfOutcome = await pdf.read;
	await settle();
	const textAfterAbort = text.body.probe.pulled;
	await finishAll([...holders, pdf, text]);
	assert.deepEqual({ textWhilePdfWaits, pdfOutcome, textAfterAbort }, { textWhilePdfWaits: 0, pdfOutcome: "AbortError", textAfterAbort: 1 });
});

for (const row of [
	{ name: "a declared length reserves only that length", headers: new Headers({ "content-length": "8" }), expected: 1 },
	{ name: "no declared length reserves the whole ceiling", headers: new Headers(), expected: 0 },
	{ name: "a compressed body's declared length reserves the whole ceiling", headers: new Headers({ "content-length": "8", "content-encoding": "gzip" }), expected: 0 },
]) {
	test(`in-flight reservation of a PDF read: ${row.name}`, { timeout: 10_000 }, async () => {
		const holders = Array.from({ length: HOLDERS_UNDER_PDF }, () => concurrentCallRead());
		const controller = new AbortController();
		const pdf = concurrentCallRead(controller.signal, PDF_READ_BYTE_LIMIT, row.headers);
		await settle();
		const pulled = pdf.body.probe.pulled;
		controller.abort();
		await finishAll([...holders, pdf]);
		assert.equal(pulled, row.expected);
	});
}

/** Reads of other web_fetch calls that have each read TEXT_READ_BYTE_LIMIT bytes and hold them while their URLs are processed.
 * They await no chunk, so no BODY_IDLE_TIMEOUT_MS deadline returns their in-flight room; the test's end releases it. */
async function heldReads(t: TestContext, count: number): Promise<UrlReads[]> {
	const chunk = new Uint8Array(TEXT_READ_BYTE_LIMIT);
	const held = await Promise.all(Array.from({ length: count }, async () => {
		const reads = new ByteBudget().openUrl();
		await reads.readBody(new Response(new ReadableStream<Uint8Array>({ pull: (controller) => controller.enqueue(chunk) })), TEXT_READ_BYTE_LIMIT);
		return reads;
	}));
	t.after(() => { for (const reads of held) reads.release(); });
	return held;
}

test("a read that waits IN_FLIGHT_WAIT_TIMEOUT_MS for in-flight room fails naming that budget, cancels its body and holds nothing", { timeout: 10_000 }, async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout"] });
	await heldReads(t, HOLDERS_UNDER_PDF);
	const pdf = concurrentCallRead(undefined, PDF_READ_BYTE_LIMIT);
	const text = concurrentCallRead();
	await settle();
	t.mock.timers.tick(IN_FLIGHT_WAIT_TIMEOUT_MS - 1);
	await settle();
	const textBeforeTimeout = text.body.probe.pulled;
	t.mock.timers.tick(1);
	const pdfOutcome = await pdf.read;
	await settle();
	const textAfterTimeout = text.body.probe.pulled;
	await finishAll([pdf, text]);
	assert.deepEqual({ textBeforeTimeout, pdfOutcome, pdfCancelled: pdf.body.probe.cancelled, textAfterTimeout }, {
		textBeforeTimeout: 0, pdfOutcome: "ByteBudgetExhausted:in-flight", pdfCancelled: true, textAfterTimeout: 1,
	});
});

test("a read granted in-flight room before IN_FLIGHT_WAIT_TIMEOUT_MS stops its wait timer, which then removes no other waiting read", { timeout: 10_000 }, async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout"] });
	const holders = await heldReads(t, SLOTS);
	const granted = concurrentCallRead();
	await settle();
	holders[0]!.release();
	await settle();
	// The granted read ends holding one byte, so it awaits no chunk while the clock runs past BODY_IDLE_TIMEOUT_MS.
	granted.body.finish(1);
	await granted.read;
	t.mock.timers.tick(IN_FLIGHT_WAIT_TIMEOUT_MS / 2);
	const waiting = concurrentCallRead();
	await settle();
	t.mock.timers.tick(IN_FLIGHT_WAIT_TIMEOUT_MS / 2);
	await settle();
	holders[1]!.release();
	await settle();
	// Asserted before any read is awaited: a waiting read the stale timer removed is never granted, so awaiting it would hang.
	assert.deepEqual({ grantedPulled: granted.body.probe.pulled, waitingPulled: waiting.body.probe.pulled }, { grantedPulled: 1, waitingPulled: 1 });
	await finishAll([granted, waiting]);
	assert.equal(await waiting.read, "read");
});

test("a read whose body sends nothing for BODY_IDLE_TIMEOUT_MS fails naming the stall, cancels its body and returns its in-flight room", { timeout: 10_000 }, async (t) => {
	t.mock.timers.enable({ apis: ["setTimeout"] });
	await heldReads(t, SLOTS - 1);
	const stalledReads = new ByteBudget().openUrl();
	t.after(() => stalledReads.release());
	const stalledBody = streamedBody(1, 4, "stall");
	const stalled = stalledReads.readBody(new Response(stalledBody.body), TEXT_READ_BYTE_LIMIT).then(() => "read", (error: Error) => error.message.split(":")[0]);
	const waiting = concurrentCallRead();
	await settle();
	t.mock.timers.tick(BODY_IDLE_TIMEOUT_MS - 1);
	await settle();
	const waitingBeforeDeadline = waiting.body.probe.pulled;
	t.mock.timers.tick(1);
	// Raced against the event loop, not awaited alone: a read with no idle deadline never settles.
	const stalledOutcome = await Promise.race([stalled, settle().then(() => "pending")]);
	await settle();
	const waitingAfterDeadline = waiting.body.probe.pulled;
	await finishAll([waiting]);
	assert.deepEqual({ waitingBeforeDeadline, stalledOutcome, stalledCancelled: stalledBody.probe.cancelled, waitingAfterDeadline }, {
		waitingBeforeDeadline: 0, stalledOutcome: "web_fetch body stalled", stalledCancelled: true, waitingAfterDeadline: 1,
	});
});
