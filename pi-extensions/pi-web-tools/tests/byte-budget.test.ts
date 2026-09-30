import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";
import { ByteBudget, readBodyWithin, readLocalPdfWithin, readPdfWithin, readTextWithin, TEXT_READ_BYTE_LIMIT } from "../src/extract/byte-budget.js";
import { tempDir } from "./fixtures.js";

/** A body of `chunks` chunks of `chunkBytes` bytes that counts the chunks pulled and records a cancel. */
function streamedBody(chunks: number, chunkBytes: number) {
	const probe = { pulled: 0, cancelled: false };
	const chunk = new Uint8Array(chunkBytes).fill(0x61);
	const body = new ReadableStream<Uint8Array>({
		pull(controller) {
			if (probe.pulled === chunks) return controller.close();
			probe.pulled++;
			controller.enqueue(chunk);
		},
		cancel() { probe.cancelled = true; },
	}, { highWaterMark: 0 });
	return { body, probe };
}

for (const row of [
	{ name: "under the limit", chunks: 3, chunkBytes: 4, limit: 16, expected: { length: 12, truncatedAtBytes: undefined, pulled: 3, cancelled: false } },
	{ name: "exactly the limit", chunks: 4, chunkBytes: 4, limit: 16, expected: { length: 16, truncatedAtBytes: undefined, pulled: 4, cancelled: false } },
	{ name: "over the limit mid-chunk", chunks: 100, chunkBytes: 4, limit: 10, expected: { length: 10, truncatedAtBytes: 10, pulled: 3, cancelled: true } },
	{ name: "over the limit at a chunk edge", chunks: 100, chunkBytes: 4, limit: 8, expected: { length: 8, truncatedAtBytes: 8, pulled: 3, cancelled: true } },
]) {
	test(`readBodyWithin: ${row.name}`, async () => {
		const { body, probe } = streamedBody(row.chunks, row.chunkBytes);
		const read = await readBodyWithin(new Response(body), row.limit);
		assert.deepEqual({ length: read.bytes.byteLength, truncatedAtBytes: read.truncatedAtBytes, pulled: probe.pulled, cancelled: probe.cancelled }, row.expected);
	});
}

test("ByteBudget lowers each read to what the call has left, then refuses", async () => {
	const budget = new ByteBudget(TEXT_READ_BYTE_LIMIT + 5);
	const first = await readTextWithin(new Response(streamedBody(TEXT_READ_BYTE_LIMIT / 1024 + 1, 1024).body), budget);
	const second = await readTextWithin(new Response("0123456789"), budget);
	const refused = streamedBody(1, 1);
	const third = await readTextWithin(new Response(refused.body), budget).then(() => "read", (error: Error) => error.message);
	assert.deepEqual({ first: first.truncatedAtBytes, second, third: third.startsWith("web_fetch byte budget exhausted"), refusedBodyCancelled: refused.probe.cancelled }, { first: TEXT_READ_BYTE_LIMIT, second: { text: "01234", truncatedAtBytes: 5 }, third: true, refusedBodyCancelled: true });
});

for (const row of [
	{ name: "declared length over the limit", chunks: 100, declared: true, expected: { outcome: "PDF too large", pulled: 0 } },
	{ name: "streamed length over the limit", chunks: 100, declared: false, expected: { outcome: "PDF too large", pulled: 3 } },
	{ name: "within the limit", chunks: 2, declared: true, expected: { outcome: "8 bytes", pulled: 2 } },
]) {
	test(`readPdfWithin: ${row.name}`, async () => {
		const { body, probe } = streamedBody(row.chunks, 4);
		const headers = row.declared ? { "content-length": String(row.chunks * 4) } : undefined;
		const outcome = await readPdfWithin(new Response(body, { headers }), new ByteBudget(10), "https://example.com/a.pdf").then((bytes) => `${bytes.byteLength} bytes`, (error: Error) => error.message.split(":")[0]);
		assert.deepEqual({ outcome, pulled: probe.pulled }, row.expected);
	});
}

for (const row of [
	{ name: "over the call budget", size: 11, expected: "PDF too large" },
	{ name: "within the call budget", size: 10, expected: "10 bytes" },
]) {
	test(`readLocalPdfWithin: ${row.name}`, async (t) => {
		const path = join(tempDir(t), "doc.pdf");
		writeFileSync(path, "p".repeat(row.size));
		const outcome = await readLocalPdfWithin(path, new ByteBudget(10)).then((bytes) => `${bytes.byteLength} bytes`, (error: Error) => error.message.split(":")[0]);
		assert.equal(outcome, row.expected);
	});
}
