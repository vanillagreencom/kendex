import { afterAll, expect, test } from "bun:test";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pendingRequest, respond } from "./fixtures/http.ts";

// A disposable copy keeps the network and clock local to this surface. No SDK mock or global timers.
const root = join(process.cwd(), "tmp", "manager-versions-tests");
mkdirSync(root, { recursive: true });
const manager = resolve(import.meta.dir, "../extensions/manager");
let source = readFileSync(join(manager, "versions.ts"), "utf8");
for (const [before, after] of [
	['from "./paths.js"', `from ${JSON.stringify(join(manager, "paths.ts"))}`],
	['from "./process.js"', `from ${JSON.stringify(join(manager, "process.ts"))}`],
	['from "./types.js"', `from ${JSON.stringify(join(manager, "types.ts"))}`],
	['from "node:https"', `from ${JSON.stringify(join(import.meta.dir, "fixtures/http.ts"))}`],
	['NPM_CHECK_TIMEOUT_MS = 4_000', 'NPM_CHECK_TIMEOUT_MS = 5'],
]) {
	expect(source.split(before).length - 1).toBe(1);
	source = source.replace(before, after);
}
writeFileSync(join(root, "versions.ts"), source);
const { fetchNpmLatest } = await import(join(root, "versions.ts"));
afterAll(() => rmSync(root, { recursive: true, force: true }));

// Real waits verify the deadline scheduler. A short bound in the copy avoids a multi-second test.
test("npm check enforces a total deadline even with response data arriving", async () => {
	const pending = fetchNpmLatest("example", new AbortController().signal);
	const res = respond();
	res.emit("data", Buffer.from("{"));
	await expect(pending).rejects.toThrow("npm check deadline exceeded");
	expect(pendingRequest().destroyedCount).toBe(1);
	expect(res.destroyedCount).toBe(1);
});

test("npm check caps response bytes before buffering them", async () => {
	const pending = fetchNpmLatest("example", new AbortController().signal);
	const res = respond();
	res.emit("data", Buffer.alloc(256 * 1024 + 1));
	await expect(pending).rejects.toThrow("npm response byte limit exceeded");
	expect(pendingRequest().destroyedCount).toBe(1);
	expect(res.destroyedCount).toBe(1);
});

test("npm check rejects request and response errors and cancellation", async () => {
	for (const row of ["request", "response", "aborted", "cancelled", "status"] as const) {
		const owner = new AbortController();
		const pending = fetchNpmLatest("example", owner.signal);
		if (row === "request") pendingRequest().emit("error", new Error("request failed"));
		else if (row === "cancelled") owner.abort();
		else {
			const res = respond(row === "status" ? 503 : 200);
			if (row === "response") res.emit("error", new Error("response failed"));
			if (row === "aborted") res.emit("aborted");
		}
		expect(pendingRequest().destroyedCount).toBe(1);
		await expect(pending).rejects.toThrow();
	}
});

test("npm check parses a complete bounded response", async () => {
	const pending = fetchNpmLatest("example", new AbortController().signal);
	const res = respond();
	res.emit("data", Buffer.from('{"version":"2.0.0"}'));
	res.emit("end");
	expect(await pending).toBe("2.0.0");
	expect(pendingRequest().destroyedCount).toBe(0);
});
